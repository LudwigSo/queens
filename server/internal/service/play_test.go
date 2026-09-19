package service_test

import (
	"context"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/service"
)

func TestStartGameMintsSessionAndJoinsRound(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)

	res := h.start(t, p, lv.ID)
	if !res.Joined || res.Session.Token == "" {
		t.Fatalf("expected a joined round with a session, got %+v", res)
	}
	if res.Tier != "bronze" {
		t.Errorf("a new player starts in bronze, got %q", res.Tier)
	}
	wantGroup := "lg_bronze_" + itoa(res.RoundIndex) + "_001"
	if res.GroupID != wantGroup {
		t.Errorf("group id = %q, want %q", res.GroupID, wantGroup)
	}
	if res.Session.ExpiresAt != res.Session.IssuedAt+h.svc.Cfg.SessionTTL {
		t.Errorf("session freshness window is not the configured TTL")
	}
	if res.Session.Level.Size != 6 || res.Session.Level.ParSeconds != lv.Par() {
		t.Errorf("session level brief is wrong: %+v", res.Session.Level)
	}
	prof := h.profile(t, p)
	if prof.Stats.RoundsPlayed != 1 {
		t.Errorf("rounds_played = %d, want 1", prof.Stats.RoundsPlayed)
	}
}

// A second start of a different level in the same round must not count as a new
// round.
func TestStartGameSecondLevelDoesNotRejoin(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	levels := h.levelsOfSize(t, 6, 2)
	h.start(t, p, levels[0].ID)
	h.start(t, p, levels[1].ID)
	if got := h.profile(t, p).Stats.RoundsPlayed; got != 1 {
		t.Errorf("rounds_played = %d, want 1", got)
	}
}

func TestStartGameCooldownBlocksAndSevenDaysUnblocks(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	st := h.start(t, p, lv.ID)
	// Consume the session first: an unconsumed one is deliberately handed back
	// rather than refused (see TestStartGameReissuesAnOpenSession).
	h.clock.Add(60)
	h.submit(t, h.payload(p, lv, st, 60, 0, 0))

	_, err := h.svc.StartGame(context.Background(), p, lv.ID)
	ce := codedError(t, err)
	if ce.Code != domain.CodeLevelLocked {
		t.Fatalf("expected ERR_LEVEL_LOCKED, got %s", ce.Code)
	}
	if ce.Status != 409 || len(ce.Params) != 1 {
		t.Fatalf("expected 409 with a remaining param, got %d %v", ce.Status, ce.Params)
	}
	if remaining, ok := ce.Params[0].(int64); !ok || remaining <= 0 {
		t.Fatalf("remaining must be a positive number of seconds, got %v", ce.Params[0])
	}
	// The blocked attempt is flagged, and the flag survives the rejection.
	if n := h.flagCount(t, p, domain.SigCooldownViolation); n != 1 {
		t.Errorf("expected one cooldown flag, got %d", n)
	}

	h.clock.Add(7 * 86400)
	if _, err := h.svc.StartGame(context.Background(), p, lv.ID); err != nil {
		t.Fatalf("seven days later the level must be free: %v", err)
	}
}

// A lost response must not cost the player a seven-day lock.
func TestStartGameReissuesAnOpenSession(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	first := h.start(t, p, lv.ID)
	h.clock.Add(30)
	second, err := h.svc.StartGame(context.Background(), p, lv.ID)
	if err != nil {
		t.Fatalf("a second start with an open session must succeed: %v", err)
	}
	if second.Session.Token != first.Session.Token {
		t.Errorf("expected the same session to be handed back")
	}
	if !second.Reissued {
		t.Errorf("expected the result to be marked as a reissue")
	}
}

func TestStartGameUnknownLevel(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	_, err := h.svc.StartGame(context.Background(), p, "00000000-0000-4000-8000-000000000000")
	if ce := codedError(t, err); ce.Code != domain.CodeLevelUnknown || ce.Status != 404 {
		t.Fatalf("expected 404 ERR_LEVEL_UNKNOWN, got %d %s", ce.Status, ce.Code)
	}
}

// The score comes from the server's own level row. A client claiming a huge par
// would otherwise pin the speed factor at its maximum.
func TestSubmitRecomputesAndIgnoresClientPar(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.hardestLevel(t)
	st := h.start(t, p, lv.ID)

	h.clock.Add(245)
	pay := h.payload(p, lv, st, 245, 0, 0)
	// A par of 1e9 would pin the speed factor at its maximum for any elapsed.
	pay.ParSeconds = 1e9
	pay.Score = 99999
	res := h.submit(t, pay)

	want := domain.Breakdown(float64(lv.Difficulty), lv.Size, lv.Par(), 245, 0, 0, true)
	if res.Decoded.Breakdown.Score != want.Score {
		t.Errorf("score = %d, want %d recomputed from the level row", res.Decoded.Breakdown.Score, want.Score)
	}
	if res.Decoded.Breakdown.ParSeconds != lv.Par() {
		t.Errorf("par must come from the level row, got %v want %v", res.Decoded.Breakdown.ParSeconds, lv.Par())
	}
	if res.Decoded.Breakdown.SpeedFactor >= domain.SpeedMax {
		t.Error("the client par was honoured: the speed factor is pinned at its maximum")
	}
	if n := h.flagCount(t, p, domain.SigScoreMismatch); n != 1 {
		t.Errorf("a wildly wrong client score must flag once, got %d", n)
	}
}

// The +/-1 tolerance exists for the math.Pow ULP difference between runtimes and
// must not fire on an honest client.
func TestSubmitScoreMismatchTolerance(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.hardestLevel(t)

	st := h.start(t, p, lv.ID)
	h.clock.Add(245)
	pay := h.payload(p, lv, st, 245, 0, 0)
	pay.Score = pay.Score + 1 // within the math.Pow tolerance
	h.submit(t, pay)
	if n := h.flagCount(t, p, domain.SigScoreMismatch); n != 0 {
		t.Errorf("an off-by-one score must not flag, got %d", n)
	}

	lv2 := h.levelOfSizeExcept(t, lv.Size, lv.ID)
	st2 := h.start(t, p, lv2.ID)
	h.clock.Add(200)
	pay2 := h.payload(p, lv2, st2, 200, 0, 0)
	pay2.Score = pay2.Score + 2
	h.submit(t, pay2)
	if n := h.flagCount(t, p, domain.SigScoreMismatch); n != 1 {
		t.Errorf("an off-by-two score must flag, got %d", n)
	}
}

func TestSubmitDuplicateReturnsByteIdenticalResponse(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	st := h.start(t, p, lv.ID)
	h.clock.Add(60)
	pay := h.payload(p, lv, st, 60, 0, 0)

	first := h.submit(t, pay)
	if first.Replay {
		t.Fatal("the first submission is not a replay")
	}
	second := h.submit(t, pay)
	if !second.Replay {
		t.Fatal("the second submission must be a replay")
	}
	if string(first.Body) != string(second.Body) {
		t.Errorf("replay body differs:\n%s\n%s", first.Body, second.Body)
	}
	if got := h.profile(t, p).Stats.Games; got != 1 {
		t.Errorf("a replay must not count again, games = %d", got)
	}
}

// The client appends to pending_results and clears current_game in memory, but
// only saves after the await; a crash in between rebuilds a FORFEIT with the
// same result_id on the next launch. Completed must win either way.
func TestSubmitForfeitThenCompletedResolvesToCompleted(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	st := h.start(t, p, lv.ID)
	h.clock.Add(60)

	forfeit := h.payload(p, lv, st, 60, 0, 0)
	forfeit.Completed = false
	forfeit.Score = 0
	h.submit(t, forfeit)
	if got := h.profile(t, p).Stats.Games; got != 0 {
		t.Fatalf("a forfeit must not count as a game, got %d", got)
	}

	done := forfeit
	done.Completed = true
	done.Score = domain.Breakdown(float64(lv.Difficulty), lv.Size, lv.Par(), 60, 0, 0, true).Score
	res := h.submit(t, done)
	if res.Replay {
		t.Fatal("the completed run must replace the forfeit, not replay it")
	}
	if res.Decoded.Breakdown.Score == 0 {
		t.Error("the completed run must score")
	}
	if got := h.profile(t, p).Stats.Games; got != 1 {
		t.Errorf("games = %d, want 1", got)
	}
}

func TestSubmitCompletedThenForfeitReturnsStored(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	st := h.start(t, p, lv.ID)
	h.clock.Add(60)

	done := h.payload(p, lv, st, 60, 0, 0)
	first := h.submit(t, done)

	forfeit := done
	forfeit.Completed = false
	forfeit.Score = 0
	second := h.submit(t, forfeit)
	if !second.Replay || string(second.Body) != string(first.Body) {
		t.Error("a late forfeit must return the stored completed response")
	}
	if n := h.flagCount(t, p, domain.SigReplayBodyMismatch); n != 1 {
		t.Errorf("a different body for the same id is logged once, got %d", n)
	}
}

func TestSubmitConsumedSessionWithAnotherResultID(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	st := h.start(t, p, lv.ID)
	h.clock.Add(60)
	h.submit(t, h.payload(p, lv, st, 60, 0, 0))

	second := h.payload(p, lv, st, 60, 0, 0)
	second.ResultID = newUUID()
	_, err := h.svc.SubmitResult(context.Background(), p, second)
	if ce := codedError(t, err); ce.Code != domain.CodeSessionUsed || ce.Status != 409 {
		t.Fatalf("expected 409 ERR_SESSION_USED, got %d %s", ce.Status, ce.Code)
	}
}

// A forged token is rejected before the database is touched.
func TestSubmitBadSessionSignature(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	st := h.start(t, p, lv.ID)
	pay := h.payload(p, lv, st, 60, 0, 0)
	pay.SessionToken = "abc.def"
	_, err := h.svc.SubmitResult(context.Background(), p, pay)
	if ce := codedError(t, err); ce.Code != domain.CodeSessionInvalid {
		t.Fatalf("expected ERR_SESSION_INVALID, got %s", ce.Code)
	}
}

func TestSubmitSessionOlderThanAcceptanceWindow(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	st := h.start(t, p, lv.ID)
	h.clock.Add(31 * 86400)
	_, err := h.svc.SubmitResult(context.Background(), p, h.payload(p, lv, st, 60, 0, 0))
	if ce := codedError(t, err); ce.Code != domain.CodeSessionExpired || ce.Status != 410 {
		t.Fatalf("expected 410 ERR_SESSION_EXPIRED, got %d %s", ce.Status, ce.Code)
	}
}

// Beyond the freshness window a session is still ACCEPTED: pending_results is an
// offline queue and a player can be offline for a fortnight.
func TestSubmitStaleSessionIsAcceptedWithAFlag(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	st := h.start(t, p, lv.ID)
	h.clock.Add(7 * 3600)
	res := h.submit(t, h.payload(p, lv, st, 60, 0, 0))
	if res.Decoded.Breakdown.Score == 0 {
		t.Error("a stale session must still score")
	}
	if n := h.flagCount(t, p, domain.SigSessionStale); n != 1 {
		t.Errorf("expected one stale flag, got %d", n)
	}
}

// A result with no session counts for stats and the league but never reaches a
// leaderboard.
func TestSubmitWithoutSessionIsUnverifiedAndOffTheBoard(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	pay := h.payloadNoSession(p, lv, 60, 0, 0)
	res := h.submit(t, pay)

	if res.Decoded.Verified {
		t.Error("a result without a session must be marked unverified")
	}
	if got := h.profile(t, p).Stats.Games; got != 1 {
		t.Errorf("it must still count as a game, got %d", got)
	}
	if res.Decoded.RoundScore == 0 {
		t.Error("it must still count for the round score")
	}
	board := h.board(t, p, lv.ID, domain.ScopeGlobal)
	if len(board.Entries) != 0 || board.MyRank != 0 {
		t.Errorf("an unverified result must stay off the leaderboard, got %+v", board)
	}
	if n := h.flagCount(t, p, domain.SigNoSession); n != 1 {
		t.Errorf("expected one no_session flag, got %d", n)
	}
}

func TestSubmitSubFloorElapsedClampsUpAndScoreDrops(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	st := h.start(t, p, lv.ID)
	h.clock.Add(300)

	pay := h.payload(p, lv, st, 0.1, 0, 0)
	res := h.submit(t, pay)

	floor := domain.ElapsedFloor(lv.Size)
	if got := h.storedResult(t, pay.ResultID).ElapsedSeconds; got != floor {
		t.Errorf("stored elapsed %v, want the floor %v", got, floor)
	}
	if n := h.flagCount(t, p, domain.SigElapsedBelowFloor); n != 1 {
		t.Errorf("expected one below-floor flag, got %d", n)
	}
	// Be honest about what the floor buys: speed_factor saturates at par/3,
	// which is far above it, so the score is unchanged. The floor catches
	// automation and feeds the flag column; it does not protect the score.
	want := domain.Breakdown(float64(lv.Difficulty), lv.Size, lv.Par(), floor, 0, 0, true).Score
	if res.Decoded.Breakdown.Score != want {
		t.Errorf("score %d, want %d", res.Decoded.Breakdown.Score, want)
	}
}

// An elapsed longer than the wall clock is clamped down, not rejected: it only
// ever hurts the submitter, and rejecting it would break honest clients.
func TestSubmitAboveWallElapsedClampsDown(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	st := h.start(t, p, lv.ID)
	h.clock.Add(60)

	res := h.submit(t, h.payload(p, lv, st, 5000, 0, 0))
	want := domain.Breakdown(float64(lv.Difficulty), lv.Size, lv.Par(), 62, 0, 0, true).Score
	if res.Decoded.Breakdown.Score != want {
		t.Errorf("score %d, want the wall-clamped %d", res.Decoded.Breakdown.Score, want)
	}
	if n := h.flagCount(t, p, domain.SigElapsedAboveWall); n != 1 {
		t.Errorf("expected one above-wall flag, got %d", n)
	}
}

func TestSubmitHardRejections(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	cases := []struct {
		name  string
		mutar func(*service.ResultPayload)
	}{
		{"too few queens on a solved board", func(x *service.ResultPayload) { x.QueensPlaced = 3 }},
		{"fewer taps than placements", func(x *service.ResultPayload) { x.Taps = 1; x.QueensPlaced = 6 }},
		{"more mistakes than placements", func(x *service.ResultPayload) { x.WrongPlacements = 99 }},
		{"more hints than cells in a row", func(x *service.ResultPayload) { x.HintCount = 50 }},
		{"a day and a half of elapsed", func(x *service.ResultPayload) { x.ElapsedSeconds = 90000 }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			lv := h.freshLevel(t, 6)
			st := h.start(t, p, lv.ID)
			h.clock.Add(60)
			pay := h.payload(p, lv, st, 60, 0, 0)
			tc.mutar(&pay)
			_, err := h.svc.SubmitResult(context.Background(), p, pay)
			if ce := codedError(t, err); ce.Code != domain.CodeResultInvalid || ce.Status != 422 {
				t.Fatalf("expected 422 ERR_RESULT_INVALID, got %d %s", ce.Status, ce.Code)
			}
		})
	}
}

func TestSubmitUpdatesStatsAndRoundScore(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	total := 0
	for i := 0; i < 3; i++ {
		lv := h.freshLevel(t, 6)
		st := h.start(t, p, lv.ID)
		h.clock.Add(60)
		res := h.submit(t, h.payload(p, lv, st, 60, 0, 0))
		total += res.Decoded.Breakdown.Score
	}
	prof := h.profile(t, p)
	if prof.Stats.Games != 3 || prof.Stats.Flawless != 3 {
		t.Errorf("stats = %+v, want 3 games all flawless", prof.Stats)
	}
	if prof.TierPoints != total {
		t.Errorf("tier points = %d, want the sum %d", prof.TierPoints, total)
	}
	st := h.standing(t, p)
	if st.MyRoundScore != total {
		t.Errorf("round score = %d, want %d", st.MyRoundScore, total)
	}
	if st.MyGames != 3 {
		t.Errorf("my_games = %d, want 3", st.MyGames)
	}
}

// The round score is the best 15 of the round, so a 16th weaker game adds
// nothing.
func TestRoundScoreKeepsOnlyTheBestFifteen(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	var scores []int
	for i := 0; i < 16; i++ {
		lv := h.freshLevel(t, 6)
		st := h.start(t, p, lv.ID)
		h.clock.Add(60 + int64(i)*30) // later games are slower, so worth less
		// Four mistakes each (never more than the queens placed) keeps the total
		// under bronze's 3000 promo score, so every game lands in one round.
		res := h.submit(t, h.payload(p, lv, st, float64(60+i*30), 4, 0))
		scores = append(scores, res.Decoded.Breakdown.Score)
	}
	want := domain.RoundScore(scores, h.svc.League)
	if got := h.standing(t, p).MyRoundScore; got != want {
		t.Errorf("round score = %d, want the best-15 sum %d", got, want)
	}
}

func TestSubmitForfeitJoinsRoundButChangesNothing(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	st := h.start(t, p, lv.ID)
	h.clock.Add(30)
	pay := h.payload(p, lv, st, 30, 0, 0)
	pay.Completed = false
	pay.Score = 0
	res := h.submit(t, pay)

	if res.Decoded.Breakdown.Score != 0 {
		t.Errorf("a forfeit scores 0, got %d", res.Decoded.Breakdown.Score)
	}
	prof := h.profile(t, p)
	if prof.Stats.Games != 0 || prof.TierPoints != 0 {
		t.Errorf("a forfeit must not move stats: %+v", prof.Stats)
	}
	if !h.standing(t, p).Joined {
		t.Error("a forfeit still joins the round")
	}
}

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var b []byte
	for v > 0 {
		b = append([]byte{byte('0' + v%10)}, b...)
		v /= 10
	}
	if neg {
		return "-" + string(b)
	}
	return string(b)
}
