package service_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/ludwigsonnenberg/queens-server/internal/config"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/levelset"
	"github.com/ludwigsonnenberg/queens-server/internal/service"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
	"github.com/ludwigsonnenberg/queens-server/internal/testutil"
)

type harness struct {
	t     *testing.T
	svc   *service.Service
	clock *domain.FixedClock
	st    store.Store
	used  map[string]bool // levels already started by the current player
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	st := testutil.NewStore(t)
	clock := testutil.NewClock()
	cfg := &config.Config{
		Env: "dev", TokenPepper: "test-pepper",
		CooldownSeconds: domain.CooldownDefault, SessionTTL: domain.SessionFreshness,
	}
	levels, err := st.Repos().Levels.All(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	setHash, err := st.Repos().Levels.CurrentLevelSet(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	svc := service.New(st, cfg, clock, domain.DefaultLeagueConfig(), "league-hash", setHash.Hash, levels)
	return &harness{t: t, svc: svc, clock: clock, st: st, used: map[string]bool{}}
}

func newUUID() string { return uuid.NewString() }

func (h *harness) register(t *testing.T, nickname string) string {
	t.Helper()
	id := newUUID()
	if _, err := h.svc.Register(context.Background(), id, nickname, "test", ""); err != nil {
		t.Fatalf("register: %v", err)
	}
	return id
}

func (h *harness) profile(t *testing.T, playerID string) *service.ProfileView {
	t.Helper()
	p, err := h.svc.Profile(context.Background(), playerID)
	if err != nil {
		t.Fatalf("profile: %v", err)
	}
	return p
}

func (h *harness) start(t *testing.T, playerID, levelID string) *service.StartGameResult {
	t.Helper()
	res, err := h.svc.StartGame(context.Background(), playerID, levelID)
	if err != nil {
		t.Fatalf("start game: %v", err)
	}
	return res
}

func (h *harness) submit(t *testing.T, p service.ResultPayload) *service.SubmitResult {
	t.Helper()
	res, err := h.svc.SubmitResult(context.Background(), p.PlayerID, p)
	if err != nil {
		t.Fatalf("submit: %v", err)
	}
	return res
}

func (h *harness) standing(t *testing.T, playerID string) *service.StandingView {
	t.Helper()
	st, err := h.svc.Standing(context.Background(), playerID)
	if err != nil {
		t.Fatalf("standing: %v", err)
	}
	return st
}

func (h *harness) board(t *testing.T, playerID, levelID string, scope domain.Scope) *service.LeaderboardView {
	t.Helper()
	b, err := h.svc.Leaderboard(context.Background(), playerID, levelID, scope, 10)
	if err != nil {
		t.Fatalf("leaderboard: %v", err)
	}
	return b
}

// payload builds a completed, flawless run whose client score already matches
// the server's, so only the field under test differs.
func (h *harness) payload(playerID string, lv domain.Level, st *service.StartGameResult, elapsed float64, wrong, hints int) service.ResultPayload {
	p := h.payloadNoSession(playerID, lv, elapsed, wrong, hints)
	p.SessionToken = st.Session.Token
	p.StartedAt = st.Session.IssuedAt
	p.FinishedAt = h.clock.Now()
	return p
}

func (h *harness) payloadNoSession(playerID string, lv domain.Level, elapsed float64, wrong, hints int) service.ResultPayload {
	bd := domain.Breakdown(float64(lv.Difficulty), lv.Size, lv.Par(), elapsed, wrong, hints, true)
	now := h.clock.Now()
	return service.ResultPayload{
		Schema: 2, ResultID: newUUID(), PlayerID: playerID, LevelID: lv.ID,
		Size: lv.Size, Difficulty: float64(lv.Difficulty), Stars: lv.Stars, ParSeconds: lv.Par(),
		StartedAt: now - int64(elapsed) - 1, FinishedAt: now, ElapsedSeconds: elapsed, Completed: true,
		QueensPlaced: lv.Size, WrongPlacements: wrong, QueensRemoved: 1, ClearCount: 0,
		HintCount: hints, Taps: lv.Size * 3, WeekIndex: domain.WeekIndex(now),
		Score: bd.Score, ClientVersion: "test",
	}
}

func (h *harness) levels(t *testing.T) []domain.Level {
	t.Helper()
	all, err := h.st.Repos().Levels.All(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return all
}

func (h *harness) levelOfSize(t *testing.T, size int) domain.Level {
	t.Helper()
	for _, l := range h.levels(t) {
		if l.Size == size {
			return l
		}
	}
	t.Fatalf("no level of size %d", size)
	return domain.Level{}
}

func (h *harness) levelOfSizeExcept(t *testing.T, size int, except string) domain.Level {
	t.Helper()
	for _, l := range h.levels(t) {
		if l.Size == size && l.ID != except {
			return l
		}
	}
	t.Fatalf("no second level of size %d", size)
	return domain.Level{}
}

func (h *harness) levelsOfSize(t *testing.T, size, n int) []domain.Level {
	t.Helper()
	var out []domain.Level
	for _, l := range h.levels(t) {
		if l.Size == size {
			out = append(out, l)
			if len(out) == n {
				return out
			}
		}
	}
	t.Fatalf("fewer than %d levels of size %d", n, size)
	return nil
}

func (h *harness) levelOf(t *testing.T, size, difficulty int) domain.Level {
	t.Helper()
	for _, l := range h.levels(t) {
		if l.Size == size && l.Difficulty == difficulty {
			return l
		}
	}
	t.Fatalf("no level of size %d difficulty %d", size, difficulty)
	return domain.Level{}
}

// freshLevel returns a level this harness has not started yet, so the cooldown
// never interferes with a test that just needs "another game".
func (h *harness) freshLevel(t *testing.T, size int) domain.Level {
	t.Helper()
	for _, l := range h.levels(t) {
		if l.Size == size && !h.used[l.ID] {
			h.used[l.ID] = true
			return l
		}
	}
	t.Fatalf("ran out of unused levels of size %d", size)
	return domain.Level{}
}

func (h *harness) flagCount(t *testing.T, playerID, signal string) int {
	t.Helper()
	flags, err := h.st.Repos().Flags.ListByPlayer(context.Background(), playerID, 500)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, f := range flags {
		if f.Signal == signal {
			n++
		}
	}
	return n
}

func (h *harness) anomaly(t *testing.T, playerID string) (float64, bool) {
	t.Helper()
	score, updatedAt, shadow, err := h.st.Repos().Flags.ReadAnomaly(context.Background(), playerID)
	if err != nil {
		t.Fatal(err)
	}
	return domain.DecayAnomaly(score, updatedAt, h.clock.Now()), shadow
}

func codedError(t *testing.T, err error) *domain.CodedError {
	t.Helper()
	if err == nil {
		t.Fatal("expected an error, got nil")
	}
	var ce *domain.CodedError
	if !errors.As(err, &ce) {
		t.Fatalf("expected a coded error, got %T: %v", err, err)
	}
	return ce
}

var _ = levelset.Embedded

// hardestLevel returns the highest-difficulty level, so the score is large
// enough for off-by-one comparisons to be meaningful.
func (h *harness) hardestLevel(t *testing.T) domain.Level {
	t.Helper()
	var best domain.Level
	for _, l := range h.levels(t) {
		if l.Difficulty > best.Difficulty {
			best = l
		}
	}
	if best.ID == "" {
		t.Fatal("no levels")
	}
	return best
}

func (h *harness) storedResult(t *testing.T, resultID string) *domain.Result {
	t.Helper()
	r, err := h.st.Repos().Results.Get(context.Background(), resultID)
	if err != nil {
		t.Fatalf("stored result %s: %v", resultID, err)
	}
	return r
}

func (h *harness) tier(t *testing.T, id string) domain.Tier {
	t.Helper()
	tc, ok := h.svc.League.TierByID(id)
	if !ok {
		t.Fatalf("unknown tier %s", id)
	}
	return tc
}

func (h *harness) summary(t *testing.T, playerID string) *service.SummaryView {
	t.Helper()
	s, err := h.svc.RoundSummary(context.Background(), playerID)
	if err != nil {
		t.Fatalf("summary: %v", err)
	}
	return s
}

func (h *harness) summaryCount(t *testing.T, playerID string) int {
	t.Helper()
	n, err := h.st.Repos().League.CountSummaries(context.Background(), playerID)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// setTier moves a player directly, for tests that need a population in a tier
// the on-ramp would take thousands of points to reach.
func (h *harness) setTier(t *testing.T, playerID, tier string) {
	t.Helper()
	ctx := context.Background()
	p, err := h.st.Repos().Players.Get(ctx, playerID)
	if err != nil {
		t.Fatal(err)
	}
	tc := h.tier(t, tier)
	settled := domain.RoundStart(tc, domain.RoundIndex(tc, h.clock.Now()))
	if err := h.st.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		_, e := r.Players.SetTier(ctx, playerID, p.Tier, tier, h.clock.Now(), settled)
		return e
	}); err != nil {
		t.Fatal(err)
	}
}

// freshLevelAnySize returns a level this harness has not used yet, of any size.
func (h *harness) freshLevelAnySize(t *testing.T) domain.Level {
	t.Helper()
	for _, l := range h.levels(t) {
		if !h.used[l.ID] {
			h.used[l.ID] = true
			return l
		}
	}
	t.Fatal("ran out of unused levels")
	return domain.Level{}
}

// seedTierGroup creates n players in the given tier, each with one completed
// game so they have a real round score, ranked by the order they were created.
func (h *harness) seedTierGroup(t *testing.T, tier string, n int) []string {
	t.Helper()
	levels := h.levels(t)
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		p := h.register(t, "P"+itoa(int64(i)))
		if tier != "bronze" {
			h.setTier(t, p, tier)
		}
		lv := levels[i%len(levels)]
		st, err := h.svc.StartGame(context.Background(), p, lv.ID)
		if err != nil {
			t.Fatalf("seed start: %v", err)
		}
		// Later players are slower, so rank follows creation order. The clock
		// has to move with the game, or the elapsed exceeds the wall time and
		// the submission is rejected as impossible.
		elapsed := float64(30 + i*5)
		h.clock.Add(int64(elapsed) + 1)
		if _, err := h.svc.SubmitResult(context.Background(), p, h.payload(p, lv, st, elapsed, 0, 0)); err != nil {
			t.Fatalf("seed submit: %v", err)
		}
		out = append(out, p)
	}
	return out
}

// registerAndPlay creates a player who has completed one run of `lv`.
func (h *harness) registerAndPlay(t *testing.T, nickname string, lv domain.Level, elapsed float64, wrong int) string {
	t.Helper()
	p := h.register(t, nickname)
	st := h.start(t, p, lv.ID)
	h.clock.Add(int64(elapsed) + 1)
	h.submit(t, h.payload(p, lv, st, elapsed, wrong, 0))
	return p
}

func (h *harness) follow(t *testing.T, playerID, otherID string) {
	t.Helper()
	ctx := context.Background()
	other, err := h.st.Repos().Players.Get(ctx, otherID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.svc.AddFriend(ctx, playerID, other.FriendCode); err != nil {
		t.Fatalf("add friend: %v", err)
	}
}

func (h *harness) shadowExclude(t *testing.T, playerID string) {
	t.Helper()
	ctx := context.Background()
	if err := h.st.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		return r.Flags.WriteAnomaly(ctx, playerID, 20, h.clock.Now(), true)
	}); err != nil {
		t.Fatal(err)
	}
}
