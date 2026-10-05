package sqlite

import (
	"context"
	"encoding/json"
	"math"
	"path/filepath"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/levelset"
)

// Migration 0003 derives every player's level state from the results already
// stored, and the first boot after it publishes the stored levels in file
// order. Seeded under schema 2, then migrated.
func TestMigration0003BackfillsLevelState(t *testing.T) {
	ctx := context.Background()
	db, err := Open(filepath.Join(t.TempDir(), "old.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.migrate(ctx, 1, 2); err != nil {
		t.Fatal(err)
	}

	f, err := levelset.Parse(levelset.Embedded())
	if err != nil {
		t.Fatal(err)
	}
	shipped := f.Levels[0]
	const legacy = "0e0e0e0e-0000-4000-8000-00000000dead" // dropped from the file long ago
	regions, _ := json.Marshal(shipped.Regions)
	solution, _ := json.Marshal(shipped.Solution)
	for _, row := range []struct{ id, hash string }{{shipped.ID, levelset.ContentHash(shipped)}, {legacy, "x"}} {
		if _, err := db.w.ExecContext(ctx, `INSERT INTO levels
			(id, size, difficulty, stars, seed, regions_json, solution_json, content_hash, par_override,
			 in_current_set, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, 1, 1, 1)`,
			row.id, shipped.Size, shipped.Difficulty, shipped.Stars, shipped.Seed, string(regions), string(solution), row.hash); err != nil {
			t.Fatal(err)
		}
	}

	r := db.Repos()
	p := &domain.Player{ID: "33333333-3333-4333-8333-333333333333", Nickname: "C", FriendCode: "QN-CCCCCC",
		Tier: "bronze", CreatedAt: 1, UpdatedAt: 1, LastSeenAt: 1}
	if err := r.Players.Create(ctx, p); err != nil {
		t.Fatal(err)
	}
	if err := r.Levels.RecordStart(ctx, p.ID, shipped.ID, 100); err != nil {
		t.Fatal(err)
	}
	insert := func(id, level string, verified, completed bool, started, finished int64, elapsed float64, score, wrong int) {
		t.Helper()
		if err := r.Results.Insert(ctx, &domain.Result{
			ResultID: id, PlayerID: p.ID, LevelID: level, Tier: "bronze", Completed: completed, Verified: verified,
			Counted: true, Schema: 2, Size: shipped.Size, Difficulty: shipped.Difficulty, Stars: shipped.Stars,
			StartedAt: started, FinishedAt: finished, ReceivedAt: finished, ElapsedSeconds: elapsed,
			Score: score, WrongPlacements: wrong, PayloadHash: "h", ResponseJSON: "{}",
		}); err != nil {
			t.Fatal(err)
		}
	}
	insert("r1", shipped.ID, true, true, 100, 200, 90, 500, 1)  // the session game RecordStart counted
	insert("r2", shipped.ID, false, true, 300, 350, 40, 500, 1) // offline, same score and wrong, faster: the best run
	insert("r3", shipped.ID, false, true, 250, 260, 60, 400, 0) // offline, lower score
	insert("r4", legacy, false, false, 400, 410, 10, 0, 0)      // offline forfeit on a level with no row yet

	if err := db.migrate(ctx, 2, math.MaxInt); err != nil {
		t.Fatal(err)
	}
	got, err := r.Levels.GetPlayerLevel(ctx, p.ID, shipped.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := domain.PlayerLevel{PlayerID: p.ID, LevelID: shipped.ID, LastStartedAt: 300, Plays: 3,
		Completions: 3, LastCompletedAt: 350, BestTime: 40,
		BestScore: 500, BestScoreTime: 40, BestWrong: 1, BestResultID: "r2", BestAt: 350}
	if *got != want {
		t.Errorf("backfilled state\n got %+v\nwant %+v", *got, want)
	}
	got, err = r.Levels.GetPlayerLevel(ctx, p.ID, legacy)
	if err != nil {
		t.Fatal(err)
	}
	want = domain.PlayerLevel{PlayerID: p.ID, LevelID: legacy, LastStartedAt: 400, Plays: 1}
	if *got != want {
		t.Errorf("forfeit-only state\n got %+v\nwant %+v", *got, want)
	}

	// First boot on the new schema: the stored shipped level is published at 1,
	// the rest of the file after it, the legacy row stays unpublished.
	rep, err := levelset.Sync(ctx, db, levelset.Embedded(), 5)
	if err != nil {
		t.Fatal(err)
	}
	if rep.Published != 1 || rep.Added != len(f.Levels)-1 || rep.Total != len(f.Levels) {
		t.Errorf("first boot report %+v", rep)
	}
	if lv, _ := r.Levels.Get(ctx, shipped.ID); lv.Position != 1 {
		t.Errorf("shipped level at position %d, want 1", lv.Position)
	}
	if lv, _ := r.Levels.Get(ctx, legacy); lv.Position != 0 {
		t.Errorf("legacy level at position %d, want 0 (never offered to clients)", lv.Position)
	}
}
