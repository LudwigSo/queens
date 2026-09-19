package service_test

import (
	"context"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

func TestAddFriendHappyPath(t *testing.T) {
	h := newHarness(t)
	a := h.register(t, "Aaa")
	b := h.register(t, "Bbb")
	code := h.friendCode(t, b)

	row, err := h.svc.AddFriend(context.Background(), a, code)
	if err != nil {
		t.Fatal(err)
	}
	if row.PlayerID != b || row.Nickname != "Bbb" || row.FriendCode != code {
		t.Errorf("unexpected friend row: %+v", row)
	}
	if row.Tier != "bronze" {
		t.Errorf("tier = %q", row.Tier)
	}

	list, err := h.svc.Friends(context.Background(), a)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].PlayerID != b {
		t.Errorf("friend list = %+v", list)
	}
	// Directed: B does not automatically follow A back.
	back, err := h.svc.Friends(context.Background(), b)
	if err != nil {
		t.Fatal(err)
	}
	if len(back) != 0 {
		t.Errorf("following is directed, B's list should be empty: %+v", back)
	}
}

// A code is accepted in any case and with surrounding space.
func TestAddFriendNormalisesTheCode(t *testing.T) {
	h := newHarness(t)
	a := h.register(t, "Aaa")
	b := h.register(t, "Bbb")
	code := h.friendCode(t, b)
	if _, err := h.svc.AddFriend(context.Background(), a, "  "+lower(code)+"  "); err != nil {
		t.Fatalf("a lower-case, padded code must work: %v", err)
	}
}

func TestAddFriendErrors(t *testing.T) {
	h := newHarness(t)
	a := h.register(t, "Aaa")
	b := h.register(t, "Bbb")
	codeB := h.friendCode(t, b)
	codeA := h.friendCode(t, a)

	cases := []struct {
		name string
		code string
		want string
	}{
		{"malformed", "nope", domain.CodeFriendCodeFmt},
		{"wrong alphabet", "QN-AAAA01", domain.CodeFriendCodeFmt},
		{"my own code", codeA, domain.CodeFriendOwnCode},
		{"nobody has it", "QN-ZZZZZZ", domain.CodeFriendCodeUnkn},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := h.svc.AddFriend(context.Background(), a, tc.code)
			if ce := codedError(t, err); ce.Code != tc.want {
				t.Errorf("got %s, want %s", ce.Code, tc.want)
			}
		})
	}

	if _, err := h.svc.AddFriend(context.Background(), a, codeB); err != nil {
		t.Fatal(err)
	}
	_, err := h.svc.AddFriend(context.Background(), a, codeB)
	if ce := codedError(t, err); ce.Code != domain.CodeFriendAlready || ce.Status != 409 {
		t.Errorf("a second add is 409 ERR_FRIEND_ALREADY, got %d %s", ce.Status, ce.Code)
	}
}

func TestFriendLimit(t *testing.T) {
	h := newHarness(t)
	a := h.register(t, "Aaa")
	for i := 0; i < domain.FriendLimit; i++ {
		other := h.register(t, "P"+itoa(int64(i)))
		if _, err := h.svc.AddFriend(context.Background(), a, h.friendCode(t, other)); err != nil {
			t.Fatalf("friend %d: %v", i, err)
		}
	}
	one := h.register(t, "Last")
	_, err := h.svc.AddFriend(context.Background(), a, h.friendCode(t, one))
	ce := codedError(t, err)
	if ce.Code != domain.CodeFriendLimit || ce.Status != 409 {
		t.Fatalf("expected 409 ERR_FRIEND_LIMIT, got %d %s", ce.Status, ce.Code)
	}
	if len(ce.Params) != 1 {
		t.Errorf("the limit must be in the params so the client can say it: %v", ce.Params)
	}
}

func TestRemoveFriend(t *testing.T) {
	h := newHarness(t)
	a := h.register(t, "Aaa")
	b := h.register(t, "Bbb")
	if _, err := h.svc.AddFriend(context.Background(), a, h.friendCode(t, b)); err != nil {
		t.Fatal(err)
	}
	if err := h.svc.RemoveFriend(context.Background(), a, b); err != nil {
		t.Fatal(err)
	}
	list, _ := h.svc.Friends(context.Background(), a)
	if len(list) != 0 {
		t.Errorf("expected an empty list, got %+v", list)
	}
	err := h.svc.RemoveFriend(context.Background(), a, b)
	if ce := codedError(t, err); ce.Code != domain.CodeFriendUnknown || ce.Status != 404 {
		t.Errorf("removing a non-friend is 404 ERR_FRIEND_UNKNOWN, got %d %s", ce.Status, ce.Code)
	}
}

// A friend's round score comes from THEIR tier's current round, which may be a
// different length from mine.
func TestFriendRoundScoreComesFromTheirOwnTier(t *testing.T) {
	h := newHarness(t)
	a := h.register(t, "Aaa")
	lv := h.levelOfSize(t, 6)
	b := h.registerAndPlay(t, "Bbb", lv, 50, 0)
	h.setTier(t, b, "silver")

	// Play again, now in silver's weekly round.
	lv2 := h.levelOfSizeExcept(t, 6, lv.ID)
	st := h.start(t, b, lv2.ID)
	h.clock.Add(60)
	res := h.submit(t, h.payload(b, lv2, st, 60, 0, 0))

	if _, err := h.svc.AddFriend(context.Background(), a, h.friendCode(t, b)); err != nil {
		t.Fatal(err)
	}
	list, err := h.svc.Friends(context.Background(), a)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 {
		t.Fatalf("expected one friend, got %d", len(list))
	}
	if list[0].Tier != "silver" {
		t.Errorf("friend tier = %q, want silver", list[0].Tier)
	}
	if list[0].RoundScore != res.Decoded.Breakdown.Score {
		t.Errorf("round score = %d, want the silver round's %d", list[0].RoundScore, res.Decoded.Breakdown.Score)
	}
}

func (h *harness) friendCode(t *testing.T, playerID string) string {
	t.Helper()
	p, err := h.st.Repos().Players.Get(context.Background(), playerID)
	if err != nil {
		t.Fatal(err)
	}
	return p.FriendCode
}

func lower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}
