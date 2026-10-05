package sqlite_test

import (
	"context"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/levelset"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
	"github.com/ludwigsonnenberg/queens-server/internal/testutil"
)

func embeddedFile(t *testing.T) *levelset.File {
	t.Helper()
	f, err := levelset.Parse(levelset.Embedded())
	if err != nil {
		t.Fatal(err)
	}
	return f
}

// withLevels returns a copy of f whose level list is levels.
func withLevels(f *levelset.File, levels []levelset.FileLevel) levelset.File {
	out := *f
	out.Levels = levels
	return out
}

func TestLevelSyncSeedsInFileOrderAndIsStable(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	f := embeddedFile(t)
	published, err := st.Repos().Levels.Published(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(published) != len(f.Levels) {
		t.Fatalf("expected %d published levels, got %d", len(f.Levels), len(published))
	}
	for i, l := range published {
		if l.ID != f.Levels[i].ID || l.Position != i+1 {
			t.Fatalf("published[%d] = %s at %d, want %s at %d (file order)", i, l.ID, l.Position, f.Levels[i].ID, i+1)
		}
	}
	set, err := st.Repos().Levels.CurrentLevelSet(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if set.LevelCount != len(f.Levels) || set.Hash == "" {
		t.Fatalf("level set looks wrong: %+v", set)
	}
	// A second sync of the same bytes changes nothing.
	rep, err := levelset.Sync(ctx, st, levelset.Embedded(), testutil.FixedNow+10)
	if err != nil {
		t.Fatal(err)
	}
	if rep.SetHash != set.Hash || rep.Added != 0 || rep.Published != 0 || rep.Unchanged != len(f.Levels) {
		t.Errorf("re-sync was not a no-op: %+v (hash before %s)", rep, set.Hash)
	}
}

// Published levels are immutable: clients compare counts, not contents, so an
// edit would never reach a device that has the old board.
func TestLevelImportRefusesChangedBoard(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	f := embeddedFile(t)
	for name, change := range map[string]func(*levelset.FileLevel){
		"difficulty": func(l *levelset.FileLevel) { l.Difficulty++ },
		"stars":      func(l *levelset.FileLevel) { l.Stars = l.Stars%5 + 1 },
		"seed":       func(l *levelset.FileLevel) { l.Seed++ },
	} {
		levels := append([]levelset.FileLevel(nil), f.Levels...)
		change(&levels[0])
		_, err := levelset.Sync(ctx, st, mustJSON(t, withLevels(f, levels)), testutil.FixedNow)
		if err == nil {
			t.Errorf("%s: expected a refusal", name)
		} else if !contains(err.Error(), levels[0].ID) {
			t.Errorf("%s: the error must name the level id, got %q", name, err)
		}
	}
}

func TestLevelImportRefusesInvalidBoard(t *testing.T) {
	f := embeddedFile(t)
	bad := f.Levels[0]
	bad.Solution = append([]int(nil), bad.Solution...)
	bad.Solution[0], bad.Solution[1] = bad.Solution[1], bad.Solution[0]
	if _, err := levelset.Parse(mustJSON(t, withLevels(f, []levelset.FileLevel{bad}))); err == nil {
		t.Error("a board whose solution breaks the rules must not parse")
	}
	// Seven regions, one per row: many solutions, so it is not a puzzle.
	open := levelset.FileLevel{ID: "6f1d2c1e-0000-4000-8000-000000000001", Size: 7, Regions: squareOf(7),
		Solution: []int{0, 2, 4, 6, 1, 3, 5}, Difficulty: 10, Stars: 1}
	if _, err := levelset.Parse(mustJSON(t, withLevels(f, []levelset.FileLevel{open}))); err == nil {
		t.Error("a board with more than one solution must not parse")
	}
}

// New levels are appended after the last one, in file order, and the import is
// idempotent. The new boards reuse existing layouts under new ids: valid, and
// all the import cares about.
func TestLevelImportAppendsInFileOrder(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	f := embeddedFile(t)
	before, _ := st.Repos().Levels.CurrentLevelSet(ctx)

	a, b := f.Levels[3], f.Levels[7]
	a.ID, b.ID = "aaaaaaaa-0000-4000-8000-000000000001", "bbbbbbbb-0000-4000-8000-000000000002"
	// b first: position follows the file, not the id.
	data := mustJSON(t, withLevels(f, []levelset.FileLevel{b, a}))
	rep, err := levelset.Sync(ctx, st, data, testutil.FixedNow+1)
	if err != nil {
		t.Fatal(err)
	}
	n := len(f.Levels)
	if rep.Added != 2 || rep.Total != n+2 {
		t.Fatalf("report %+v, want 2 added and %d in total", rep, n+2)
	}
	if rep.SetHash == before.Hash {
		t.Error("new levels must move the level-set hash")
	}
	for id, want := range map[string]int{b.ID: n + 1, a.ID: n + 2} {
		lv, err := st.Repos().Levels.Get(ctx, id)
		if err != nil || lv.Position != want {
			t.Errorf("%s: position %v (err %v), want %d", id, lv, err, want)
		}
	}
	got, err := st.Repos().Levels.CountPublished(ctx)
	if err != nil || got != n+2 {
		t.Errorf("CountPublished = %d (%v), want %d", got, err, n+2)
	}

	again, err := levelset.Sync(ctx, st, data, testutil.FixedNow+2)
	if err != nil {
		t.Fatal(err)
	}
	if again.Added != 0 || again.Unchanged != 2 || again.SetHash != rep.SetHash {
		t.Errorf("re-import was not a no-op: %+v", again)
	}
	// The embedded file on the next boot leaves the imported levels alone.
	if boot, err := levelset.Sync(ctx, st, levelset.Embedded(), testutil.FixedNow+3); err != nil || boot.Total != n+2 {
		t.Errorf("boot sync after an import: %+v, %v", boot, err)
	}
}

// A level missing from a file is never unpublished: a device that has it keeps
// it, and the count stays honest.
func TestLevelImportKeepsMissingLevels(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	f := embeddedFile(t)
	rep, err := levelset.Sync(ctx, st, mustJSON(t, withLevels(f, f.Levels[1:])), testutil.FixedNow+1)
	if err != nil {
		t.Fatal(err)
	}
	if rep.Total != len(f.Levels) {
		t.Errorf("total %d, want %d", rep.Total, len(f.Levels))
	}
	lv, err := st.Repos().Levels.Get(ctx, f.Levels[0].ID)
	if err != nil || lv.Position != 1 {
		t.Errorf("a level missing from the file must stay published at 1: %+v, %v", lv, err)
	}
}

func TestGetManySkipsUnknownAndKeepsGameOrder(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	f := embeddedFile(t)
	got, err := st.Repos().Levels.GetMany(ctx, []string{f.Levels[5].ID, "no-such-id", f.Levels[2].ID})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].ID != f.Levels[2].ID || got[1].ID != f.Levels[5].ID {
		t.Errorf("GetMany = %v", got)
	}
}

// ApplyResult is the player's level state: offline plays counted, the best run
// kept in the client's order (score, then fewer wrong, then faster; a tie keeps
// the older run), and the fastest time kept on its own.
func TestApplyResultBuildsLevelState(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	lv := testutil.Levels(t, st)[0]
	p := &domain.Player{ID: "22222222-2222-4222-8222-222222222222", Nickname: "B", FriendCode: "QN-BBBBBB",
		Tier: "bronze", CreatedAt: 1, UpdatedAt: 1, LastSeenAt: 1}
	if err := st.Repos().Players.Create(ctx, p); err != nil {
		t.Fatal(err)
	}
	apply := func(r domain.PlayerLevelResult) {
		t.Helper()
		if err := st.InTx(ctx, func(ctx context.Context, repos store.Repos) error {
			return repos.Levels.ApplyResult(ctx, p.ID, lv.ID, r)
		}); err != nil {
			t.Fatal(err)
		}
	}
	// A session start, then its forfeit: the play was counted by RecordStart.
	if err := st.Repos().Levels.RecordStart(ctx, p.ID, lv.ID, 1000); err != nil {
		t.Fatal(err)
	}
	apply(domain.PlayerLevelResult{ResultID: "r0", StartedAt: 1000})
	// Offline: counts a play.
	apply(domain.PlayerLevelResult{ResultID: "r1", StartedAt: 2000, CountPlay: true, Completed: true,
		FinishedAt: 2100, Elapsed: 100, Score: 500, Wrong: 2})
	apply(domain.PlayerLevelResult{ResultID: "r2", StartedAt: 1500, CountPlay: true, Completed: true,
		FinishedAt: 1580, Elapsed: 80, Score: 500, Wrong: 3}) // faster, but more wrong: not the best run
	apply(domain.PlayerLevelResult{ResultID: "r3", Completed: true, FinishedAt: 3000, Elapsed: 100, Score: 500, Wrong: 2}) // full tie: older stays
	pl, err := st.Repos().Levels.GetPlayerLevel(ctx, p.ID, lv.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := domain.PlayerLevel{PlayerID: p.ID, LevelID: lv.ID, LastStartedAt: 2000, Plays: 3,
		Completions: 3, LastCompletedAt: 3000, BestTime: 80,
		BestScore: 500, BestScoreTime: 100, BestWrong: 2, BestResultID: "r1", BestAt: 2100}
	if *pl != want {
		t.Errorf("state\n got %+v\nwant %+v", *pl, want)
	}
	apply(domain.PlayerLevelResult{ResultID: "r4", Completed: true, FinishedAt: 2500, Elapsed: 300, Score: 600, Wrong: 4})
	pl, _ = st.Repos().Levels.GetPlayerLevel(ctx, p.ID, lv.ID)
	if pl.BestResultID != "r4" || pl.BestScore != 600 || pl.BestTime != 80 || pl.LastCompletedAt != 3000 {
		t.Errorf("a higher score must win the best run and leave the rest: %+v", *pl)
	}
}
