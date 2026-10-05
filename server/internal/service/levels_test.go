package service_test

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/levelset"
	"github.com/ludwigsonnenberg/queens-server/internal/service"
)

func (h *harness) levelStates(t *testing.T, playerID string) map[string]service.LevelState {
	t.Helper()
	st, err := h.svc.MyLevelStates(context.Background(), playerID)
	if err != nil {
		t.Fatal(err)
	}
	return st
}

// The player's level state is derived from every accepted result: a session
// game counts its play at the start, an offline game when it arrives, a replay
// counts nothing, and a forfeit completed later counts one play and one
// completion.
func TestLevelStateFollowsResults(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	online, offline, crashed := h.freshLevel(t, 6), h.freshLevel(t, 6), h.freshLevel(t, 6)

	st := h.start(t, p, online.ID)
	h.clock.Add(61)
	done := h.payload(p, online, st, 60, 1, 0)
	res := h.submit(t, done)
	h.submit(t, done) // replay
	got := h.levelStates(t, p)[online.ID]
	want := service.LevelState{LastStartedAt: st.Session.IssuedAt, Plays: 1, Completions: 1,
		LastCompletedAt: done.FinishedAt, BestTime: 60, BestScore: res.Decoded.Breakdown.Score, BestScoreTime: 60,
		BestWrong: 1, BestResultID: done.ResultID, BestAt: done.FinishedAt}
	if got != want {
		t.Errorf("session game\n got %+v\nwant %+v", got, want)
	}

	forfeit := h.payloadNoSession(p, offline, 40, 0, 0)
	forfeit.Completed, forfeit.Score = false, 0
	h.submit(t, forfeit)
	if got := h.levelStates(t, p)[offline.ID]; got.Plays != 1 || got.Completions != 0 || got.LastStartedAt != forfeit.StartedAt {
		t.Errorf("offline forfeit: %+v", got)
	}
	h.clock.Add(100)
	win := h.payloadNoSession(p, offline, 50, 0, 0)
	h.submit(t, win)
	if got := h.levelStates(t, p)[offline.ID]; got.Plays != 2 || got.Completions != 1 || got.BestResultID != win.ResultID ||
		got.LastStartedAt != win.StartedAt || got.BestTime != 50 {
		t.Errorf("offline win after a forfeit: %+v", got)
	}

	// The crash path: a forfeit rebuilt from the marker, then the real result
	// with the same id. One game, so one play.
	lost := h.payloadNoSession(p, crashed, 70, 0, 0)
	lost.Completed, lost.Score = false, 0
	h.submit(t, lost)
	found := lost
	found.Completed = true
	found.Score = domain.Breakdown(float64(crashed.Difficulty), crashed.Size, crashed.Par(), 70, 0, 0, true).Score
	h.submit(t, found)
	if got := h.levelStates(t, p)[crashed.ID]; got.Plays != 1 || got.Completions != 1 || got.BestResultID != found.ResultID {
		t.Errorf("forfeit then completed: %+v", got)
	}

	if n := len(h.levelStates(t, h.register(t, "Bob"))); n != 0 {
		t.Errorf("a new player has %d level states, want 0", n)
	}
}

// A level imported while the server runs -- by `queensd admin levels import`
// in another process -- is counted, listed, downloadable and playable at once.
func TestImportedLevelIsServedWithoutRestart(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	p := h.register(t, "Ann")
	before, err := h.svc.LevelCount(ctx)
	if err != nil {
		t.Fatal(err)
	}

	f, err := levelset.Parse(levelset.Embedded())
	if err != nil {
		t.Fatal(err)
	}
	extra := f.Levels[0]
	extra.ID = "cccccccc-0000-4000-8000-000000000003"
	file := *f
	file.Levels = []levelset.FileLevel{extra}
	data, _ := json.Marshal(file)
	if _, err := levelset.Sync(ctx, h.st, data, h.clock.Now()); err != nil {
		t.Fatal(err)
	}

	if n, err := h.svc.LevelCount(ctx); err != nil || n != before+1 {
		t.Fatalf("count %d (%v), want %d", n, err, before+1)
	}
	ids, err := h.svc.LevelIDs(ctx)
	if err != nil || len(ids) != before+1 || ids[len(ids)-1] != extra.ID {
		t.Fatalf("ids end in %v (%v), want the new level last", ids[len(ids)-1], err)
	}
	got, err := h.svc.LevelsByID(ctx, []string{extra.ID, "unknown"})
	if err != nil || len(got) != 1 {
		t.Fatalf("download: %v, %v", got, err)
	}
	if v := got[0]; v.Position != before+1 || v.Size != extra.Size || len(v.Solution) != extra.Size ||
		v.Solution[0] != extra.Solution[0] || v.Regions[1][2] != extra.Regions[1][2] {
		t.Errorf("downloaded board does not match the file: %+v", v)
	}

	// No restart: the service learns the level on first use.
	if _, err := h.svc.StartGame(ctx, p, extra.ID); err != nil {
		t.Fatalf("a freshly imported level must be playable: %v", err)
	}
	meta, _, err := h.svc.LevelMeta(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := meta.Levels[extra.ID]; !ok {
		t.Error("level meta must include the imported level")
	}
}

func TestLevelsByIDIsBounded(t *testing.T) {
	h := newHarness(t)
	ids := make([]string, service.MaxLevelsPerRequest+1)
	for i := range ids {
		ids[i] = newUUID()
	}
	_, err := h.svc.LevelsByID(context.Background(), ids)
	if ce := codedError(t, err); ce.Status != 422 {
		t.Errorf("status %d, want 422", ce.Status)
	}
}
