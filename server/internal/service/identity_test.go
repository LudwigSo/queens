package service_test

import (
	"context"
	"strings"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

func TestRegisterNewPlayer(t *testing.T) {
	h := newHarness(t)
	id := newUUID()
	res, err := h.svc.Register(context.Background(), id, "  Ann  ", "1.0", "")
	if err != nil {
		t.Fatal(err)
	}
	if !res.Created || res.Token == "" {
		t.Fatal("a new player gets a token")
	}
	if res.Profile.Nickname != "Ann" {
		t.Errorf("the nickname must be trimmed, got %q", res.Profile.Nickname)
	}
	if res.Profile.Tier != "bronze" || res.Profile.TierPoints != 0 {
		t.Errorf("a new player starts at bronze with no points: %+v", res.Profile)
	}
	if !friendCodeShape(res.Profile.FriendCode) {
		t.Errorf("friend code %q is not QN- plus six of [A-Z2-7]", res.Profile.FriendCode)
	}
	if res.Profile.Stats.Games != 0 || res.Profile.Stats.RoundsPlayed != 0 {
		t.Errorf("stats must start at zero: %+v", res.Profile.Stats)
	}
	// The token authenticates; the id is only a name.
	p, err := h.svc.ResolveToken(context.Background(), res.Token)
	if err != nil || p.ID != id {
		t.Fatalf("the token must resolve to the player: %v", err)
	}
}

func TestRegisterRejectsANonUUID(t *testing.T) {
	h := newHarness(t)
	_, err := h.svc.Register(context.Background(), "not-a-uuid", "Ann", "1.0", "")
	if ce := codedError(t, err); ce.Code != domain.CodeBadRequest {
		t.Errorf("expected ERR_BAD_REQUEST, got %s", ce.Code)
	}
}

// An unauthenticated caller must never be handed a token for an id that already
// exists. The client regenerates its UUID once and retries.
func TestRegisterExistingIDWithoutTokenIsRefused(t *testing.T) {
	h := newHarness(t)
	id := newUUID()
	if _, err := h.svc.Register(context.Background(), id, "Ann", "1.0", ""); err != nil {
		t.Fatal(err)
	}
	_, err := h.svc.Register(context.Background(), id, "Mallory", "1.0", "")
	ce := codedError(t, err)
	if ce.Code != domain.CodeIDTaken || ce.Status != 409 {
		t.Fatalf("expected 409 ERR_ID_TAKEN, got %d %s", ce.Status, ce.Code)
	}
	// The original account is untouched.
	p, _ := h.svc.Profile(context.Background(), id)
	if p.Nickname != "Ann" {
		t.Errorf("the existing account must not be overwritten, got %q", p.Nickname)
	}
}

// Re-registering with your own token is the "known device" case: idempotent, no
// new token, nickname refreshed.
func TestRegisterWithOwnTokenIsIdempotent(t *testing.T) {
	h := newHarness(t)
	id := newUUID()
	first, err := h.svc.Register(context.Background(), id, "Ann", "1.0", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := h.svc.Register(context.Background(), id, "Annabel", "1.0", first.Token)
	if err != nil {
		t.Fatal(err)
	}
	if second.Created || second.Token != "" {
		t.Error("a known device must not be issued a second token")
	}
	if second.Profile.Nickname != "Annabel" {
		t.Errorf("the nickname must be updated, got %q", second.Profile.Nickname)
	}
}

func TestNicknameRules(t *testing.T) {
	h := newHarness(t)
	cases := []struct {
		name string
		nick string
		code string
	}{
		{"too short", "A", domain.CodeNicknameLength},
		{"too short after trimming", "  A  ", domain.CodeNicknameLength},
		{"too long", strings.Repeat("a", 17), domain.CodeNicknameLength},
		{"empty", "   ", domain.CodeNicknameLength},
		{"denylisted", "xxNIGGERxx", domain.CodeNicknameInvalid},
		{"denylisted with separators", "n.i.g.g.e.r", domain.CodeNicknameInvalid},
		{"impersonating the service", "QueensAdmin", domain.CodeNicknameInvalid},
		{"zero-width joiner", "An​na", domain.CodeNicknameInvalid},
		{"only punctuation", "!!!!", domain.CodeNicknameInvalid},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := h.svc.Register(context.Background(), newUUID(), tc.nick, "1.0", "")
			if ce := codedError(t, err); ce.Code != tc.code {
				t.Errorf("got %s, want %s", ce.Code, tc.code)
			}
		})
	}
	for _, ok := range []string{"Ab", strings.Repeat("a", 16), "Ludwig", "Åsa", "日本語"} {
		if _, err := h.svc.Register(context.Background(), newUUID(), ok, "1.0", ""); err != nil {
			t.Errorf("%q should be accepted: %v", ok, err)
		}
	}
}

// NFKC runs before the length check, so a lookalike cannot smuggle a longer
// string past it.
func TestNicknameIsNormalisedBeforeMeasuring(t *testing.T) {
	h := newHarness(t)
	// Seventeen fullwidth letters normalise to seventeen ASCII ones.
	wide := strings.Repeat("ａ", 17)
	_, err := h.svc.Register(context.Background(), newUUID(), wide, "1.0", "")
	if ce := codedError(t, err); ce.Code != domain.CodeNicknameLength {
		t.Errorf("got %s, want a length rejection", ce.Code)
	}
}

func TestSetNickname(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	out, err := h.svc.SetNickname(context.Background(), p, "Bea")
	if err != nil {
		t.Fatal(err)
	}
	if out.Nickname != "Bea" {
		t.Errorf("got %q", out.Nickname)
	}
	if _, err := h.svc.SetNickname(context.Background(), p, "A"); err == nil {
		t.Error("a too-short rename must be refused")
	}
}

func TestResolveTokenRejectsUnknownAndBanned(t *testing.T) {
	h := newHarness(t)
	if _, err := h.svc.ResolveToken(context.Background(), ""); codedError(t, err).Status != 401 {
		t.Error("an empty bearer is 401")
	}
	if _, err := h.svc.ResolveToken(context.Background(), "nonsense"); codedError(t, err).Status != 401 {
		t.Error("an unknown token is 401")
	}
	id := newUUID()
	res, err := h.svc.Register(context.Background(), id, "Ann", "1.0", "")
	if err != nil {
		t.Fatal(err)
	}
	at := h.clock.Now()
	if err := h.st.Repos().Players.SetBanned(context.Background(), id, &at); err != nil {
		t.Fatal(err)
	}
	_, err = h.svc.ResolveToken(context.Background(), res.Token)
	if ce := codedError(t, err); ce.Status != 403 || ce.Code != domain.CodeBanned {
		t.Errorf("a banned player is 403 ERR_BANNED, got %d %s", ce.Status, ce.Code)
	}
}

// Deleting an account removes everything and leaves the remaining members'
// group count right.
func TestDeleteAccountCascadesAndFixesGroupCount(t *testing.T) {
	h := newHarness(t)
	lv := h.levelOfSize(t, 6)
	a := h.registerAndPlay(t, "Aaa", lv, 50, 0)
	b := h.registerAndPlay(t, "Bbb", lv, 60, 0)

	before := h.standing(t, b)
	if before.Group == nil || before.Group.Size != 2 {
		t.Fatalf("expected a group of two, got %+v", before.Group)
	}
	if err := h.svc.DeleteAccount(context.Background(), a); err != nil {
		t.Fatal(err)
	}
	after := h.standing(t, b)
	if after.Group == nil || after.Group.Size != 1 {
		t.Errorf("group size after deletion = %+v, want 1", after.Group)
	}
	if _, err := h.svc.Profile(context.Background(), a); err != domain.ErrNotFound {
		t.Errorf("the player must be gone, got %v", err)
	}
	board := h.board(t, b, lv.ID, domain.ScopeGlobal)
	for _, e := range board.Entries {
		if e.PlayerID == a {
			t.Error("the deleted player must be off the leaderboard")
		}
	}
}

func friendCodeShape(code string) bool {
	if len(code) != 9 || !strings.HasPrefix(code, "QN-") {
		return false
	}
	for _, r := range code[3:] {
		if !strings.ContainsRune("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", r) {
			return false
		}
	}
	return true
}
