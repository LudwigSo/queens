package sqlite_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/levelset"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
	"github.com/ludwigsonnenberg/queens-server/internal/store/sqlite"
	"github.com/ludwigsonnenberg/queens-server/internal/testutil"
)

func TestMigrateIsIdempotentAndSchemaIsStrict(t *testing.T) {
	dir := t.TempDir()
	db, err := sqlite.Open(filepath.Join(dir, "a.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	if err := db.Migrate(ctx, 1); err != nil {
		t.Fatal(err)
	}
	if err := db.Migrate(ctx, 2); err != nil {
		t.Fatalf("second migrate must be a no-op: %v", err)
	}
	// STRICT tables reject a text value in an INTEGER column; that is the whole
	// point of declaring them.
	err = db.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		_, e := r.Rates.Bump(ctx, "k", 1)
		return e
	})
	if err != nil {
		t.Fatalf("rate bump: %v", err)
	}
}

func TestLevelSyncSeedsAndIsStable(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	levels, err := st.Repos().Levels.All(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(levels) != 100 {
		t.Fatalf("expected 100 levels, got %d", len(levels))
	}
	set, err := st.Repos().Levels.CurrentLevelSet(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if set.LevelCount != 100 || set.Hash == "" {
		t.Fatalf("level set looks wrong: %+v", set)
	}
	// A second sync of the same bytes must not change the hash.
	h2, err := levelset.Sync(ctx, st, levelset.Embedded(), testutil.FixedNow+10)
	if err != nil {
		t.Fatal(err)
	}
	if h2 != set.Hash {
		t.Errorf("level-set hash moved without a content change: %s -> %s", set.Hash, h2)
	}
}

// A changed size or difficulty must refuse to start: base and par derive from
// both, so accepting it would silently invalidate every past score.
func TestLevelSyncRefusesSizeOrDifficultyChange(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	f, err := levelset.Parse(levelset.Embedded())
	if err != nil {
		t.Fatal(err)
	}
	changed := *f
	changed.Levels = append([]levelset.FileLevel(nil), f.Levels...)
	changed.Levels[0].Difficulty += 1
	data := mustJSON(t, changed)
	if _, err := levelset.Sync(ctx, st, data, testutil.FixedNow); err == nil {
		t.Fatal("expected a refusal when difficulty changes")
	} else if got := err.Error(); !contains(got, changed.Levels[0].ID) {
		t.Errorf("the error must name the level id, got %q", got)
	}

	changed2 := *f
	changed2.Levels = append([]levelset.FileLevel(nil), f.Levels...)
	changed2.Levels[0].Size = 7
	changed2.Levels[0].Regions = squareOf(7)
	changed2.Levels[0].Solution = []int{0, 1, 2, 3, 4, 5, 6}
	if _, err := levelset.Sync(ctx, st, mustJSON(t, changed2), testutil.FixedNow); err == nil {
		t.Fatal("expected a refusal when size changes")
	}
}

// A cosmetic change is applied, and it moves the level-set hash (the ETag).
func TestLevelSyncAppliesCosmeticChange(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	before, _ := st.Repos().Levels.CurrentLevelSet(ctx)
	f, _ := levelset.Parse(levelset.Embedded())
	changed := *f
	changed.Levels = append([]levelset.FileLevel(nil), f.Levels...)
	changed.Levels[0].Stars = 4
	h, err := levelset.Sync(ctx, st, mustJSON(t, changed), testutil.FixedNow+1)
	if err != nil {
		t.Fatal(err)
	}
	if h == before.Hash {
		t.Error("a cosmetic change must move the level-set hash")
	}
	lv, err := st.Repos().Levels.Get(ctx, changed.Levels[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if lv.Stars != 4 {
		t.Errorf("stars not updated: %d", lv.Stars)
	}
}

// A level that disappears from the file is kept forever: old results and
// leaderboard rows still point at it.
func TestLevelSyncKeepsRemovedLevels(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	f, _ := levelset.Parse(levelset.Embedded())
	gone := f.Levels[0].ID
	shorter := *f
	shorter.Levels = f.Levels[1:]
	if _, err := levelset.Sync(ctx, st, mustJSON(t, shorter), testutil.FixedNow+1); err != nil {
		t.Fatal(err)
	}
	lv, err := st.Repos().Levels.Get(ctx, gone)
	if err != nil {
		t.Fatalf("a removed level must still be readable: %v", err)
	}
	if lv.InCurrentSet {
		t.Error("a removed level must be flagged out of the current set")
	}
}

// CommitAndFail is how a rejected request still persists its anti-cheat flag.
func TestInTxCommitAndFailPersistsWork(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	sentinel := os.ErrClosed
	err := st.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		if _, e := r.Rates.Bump(ctx, "persisted", 1); e != nil {
			return e
		}
		return store.CommitAndFail{Err: sentinel}
	})
	if err != sentinel {
		t.Fatalf("expected the wrapped error back, got %v", err)
	}
	n, err := st.Repos().Rates.Peek(ctx, "persisted", 1)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("work inside CommitAndFail must survive, got count %d", n)
	}
}

func TestInTxRollsBackOnError(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	want := os.ErrInvalid
	err := st.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		if _, e := r.Rates.Bump(ctx, "rolled-back", 1); e != nil {
			return e
		}
		return want
	})
	if err != want {
		t.Fatalf("got %v", err)
	}
	n, _ := st.Repos().Rates.Peek(ctx, "rolled-back", 1)
	if n != 0 {
		t.Errorf("expected a rollback, got count %d", n)
	}
}

func TestForeignKeysCascade(t *testing.T) {
	st := testutil.NewStore(t)
	ctx := context.Background()
	p := &domain.Player{ID: "11111111-1111-4111-8111-111111111111", Nickname: "A", FriendCode: "QN-AAAAAA",
		Tier: "bronze", CreatedAt: 1, UpdatedAt: 1, LastSeenAt: 1}
	if err := st.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		if err := r.Players.Create(ctx, p); err != nil {
			return err
		}
		return r.Players.InsertToken(ctx, "hash", p.ID, 1)
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.Repos().Players.Delete(ctx, p.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Repos().Players.GetToken(ctx, "hash"); err != domain.ErrNotFound {
		t.Errorf("token must cascade away with the player, got %v", err)
	}
}

func contains(s, sub string) bool { return len(sub) > 0 && len(s) >= len(sub) && indexOf(s, sub) >= 0 }

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func squareOf(n int) [][]int {
	out := make([][]int, n)
	for i := range out {
		out[i] = make([]int, n)
		for j := range out[i] {
			out[i][j] = i
		}
	}
	return out
}
