package service_test

import (
	"context"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

// An excluded player is moved into a quarantine group: a separate group for the
// same round, holding only excluded players, evaluated by the identical code
// path with real promotions and relegations among themselves. Their own rank,
// summaries and progression are unchanged, and nothing in the response says so.
func TestShadowExcludedJoinsAQuarantineGroup(t *testing.T) {
	h := newHarness(t)
	honest := h.register(t, "Honest")
	cheat := h.register(t, "Cheat")
	h.shadowExclude(t, cheat)

	lv1 := h.freshLevelAnySize(t)
	h.start(t, honest, lv1.ID)
	lv2 := h.freshLevelAnySize(t)
	h.start(t, cheat, lv2.ID)

	a := h.standing(t, honest)
	b := h.standing(t, cheat)
	if a.Group == nil || b.Group == nil {
		t.Fatal("both players must have joined a group")
	}
	if a.Group.GroupID == b.Group.GroupID {
		t.Error("an excluded player must not share a group with an ordinary one")
	}
	if a.Group.Size != 1 || b.Group.Size != 1 {
		t.Errorf("each group holds one player, got %d and %d", a.Group.Size, b.Group.Size)
	}
	// The excluded player sees an ordinary standing: no UI difference.
	if !b.Joined || b.MyRank != 1 || b.Tier != "bronze" {
		t.Errorf("the excluded player's own view must look normal: %+v", b)
	}
}

// The score decays with a 30-day half-life, and the exclusion clears only on the
// next start, so a player finishes the quarantined round they are in.
func TestAnomalyDecaysAndClearsWithHysteresis(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	ctx := context.Background()

	if err := h.st.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		return r.Flags.WriteAnomaly(ctx, p, 15, h.clock.Now(), true)
	}); err != nil {
		t.Fatal(err)
	}
	score, shadow := h.anomaly(t, p)
	if score != 15 || !shadow {
		t.Fatalf("setup wrong: %v %v", score, shadow)
	}

	h.clock.Add(30 * 86400)
	score, _ = h.anomaly(t, p)
	if score < 7.4 || score > 7.6 {
		t.Errorf("after one half-life the score should be about 7.5, got %v", score)
	}
	// Still above the clear threshold, so a start does not un-exclude.
	h.start(t, p, h.freshLevelAnySize(t).ID)
	if _, shadow := h.anomaly(t, p); !shadow {
		t.Error("7.5 is still above the clear threshold")
	}

	// Two more half-lives take it under 5.
	h.clock.Add(60 * 86400)
	score, _ = h.anomaly(t, p)
	if score >= domain.AnomalyClearAt {
		t.Fatalf("expected the score to decay below %v, got %v", domain.AnomalyClearAt, score)
	}
	h.start(t, p, h.freshLevelAnySize(t).ID)
	if _, shadow := h.anomaly(t, p); shadow {
		t.Error("the exclusion should clear on the next start once the score has decayed")
	}
}

// A round score above what the level table allows is arithmetic, not judgement:
// the most a game can be worth is twice its base, and the cooldown caps how many
// distinct levels a round can contain.
func TestImpossibleRoundScoreIsRejected(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.hardestLevel(t)
	st := h.start(t, p, lv.ID)
	h.clock.Add(60)

	pay := h.payload(p, lv, st, 60, 0, 0)
	// Claim a score far beyond twice the base of every level put together. The
	// server recomputes, so this alone cannot inflate the round score; the
	// ceiling is what catches a forged one.
	pay.Score = 10_000_000
	res := h.submit(t, pay)
	if res.Decoded.Breakdown.Score > 2*lv.BasePoints() {
		t.Errorf("no single game may exceed twice its base: %d > %d", res.Decoded.Breakdown.Score, 2*lv.BasePoints())
	}
	if res.Decoded.RoundScore > 2*lv.BasePoints() {
		t.Errorf("the round score followed the forged value: %d", res.Decoded.RoundScore)
	}
}

// Sessions are only useful for the acceptance window; the sweeper drops what has
// aged out and leaves the rest alone.
func TestSweepDropsOnlyExpiredSessions(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	ctx := context.Background()

	old := h.start(t, p, h.freshLevelAnySize(t).ID)
	oldID := sessionIDOf(t, old.Session.Token)

	h.clock.Add(31 * 86400)
	fresh := h.start(t, p, h.freshLevelAnySize(t).ID)
	freshID := sessionIDOf(t, fresh.Session.Token)

	if err := h.svc.Sweep(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := h.st.Repos().Sessions.Get(ctx, oldID); err != domain.ErrNotFound {
		t.Errorf("a session past the acceptance window should be gone, got %v", err)
	}
	if _, err := h.st.Repos().Sessions.Get(ctx, freshID); err != nil {
		t.Errorf("a live session must survive the sweep: %v", err)
	}
}

// The response the client stores is the response it gets back on a replay, so
// the two must be the same bytes even after the league around it has moved on.
func TestReplayIsStableAfterTheRoundMovesOn(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.freshLevelAnySize(t)
	st := h.start(t, p, lv.ID)
	h.clock.Add(60)
	pay := h.payload(p, lv, st, 60, 0, 0)
	first := h.submit(t, pay)

	// Another game, and time passes.
	lv2 := h.freshLevelAnySize(t)
	st2 := h.start(t, p, lv2.ID)
	h.clock.Add(120)
	h.submit(t, h.payload(p, lv2, st2, 120, 0, 0))
	h.clock.Add(3600)

	again := h.submit(t, pay)
	if !again.Replay || string(again.Body) != string(first.Body) {
		t.Errorf("a replay must return the stored bytes, not a recomputed answer:\n%s\n%s", first.Body, again.Body)
	}
}

func sessionIDOf(t *testing.T, token string) string {
	t.Helper()
	for i := 0; i < len(token); i++ {
		if token[i] == '.' {
			return token[:i]
		}
	}
	t.Fatalf("malformed session token %q", token)
	return ""
}
