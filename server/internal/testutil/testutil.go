// Package testutil builds a real SQLite store on a temp file, with a fixed
// clock and the real level set. Tests run against the same engine and the same
// SQL as production; there are no fakes below the store interface.
package testutil

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/levelset"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
	"github.com/ludwigsonnenberg/queens-server/internal/store/sqlite"
)

// Wednesday 2026-09-09 12:00:00 UTC. It sits inside week 2957 (the launch week
// the offline stub anchors to) and inside a Bronze round, so tests exercise both
// round lengths without arithmetic in the test body.
const FixedNow int64 = 1789293600

func NewClock() *domain.FixedClock { return &domain.FixedClock{T: FixedNow} }

// NewStore returns a migrated, level-seeded store that closes itself when the
// test ends.
func NewStore(t *testing.T) store.Store {
	t.Helper()
	dir := t.TempDir()
	db, err := sqlite.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	ctx := context.Background()
	if err := db.Migrate(ctx, FixedNow); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if _, err := levelset.Sync(ctx, db, levelset.Embedded(), FixedNow); err != nil {
		t.Fatalf("level sync: %v", err)
	}
	return db
}

// Levels returns the seeded levels in id order, so a test can pick a small or a
// large one deterministically.
func Levels(t *testing.T, st store.Store) []domain.Level {
	t.Helper()
	lv, err := st.Repos().Levels.All(context.Background())
	if err != nil {
		t.Fatalf("levels: %v", err)
	}
	return lv
}

// LevelOfSize returns the first seeded level with the given board size.
func LevelOfSize(t *testing.T, st store.Store, size int) domain.Level {
	t.Helper()
	for _, l := range Levels(t, st) {
		if l.Size == size {
			return l
		}
	}
	t.Fatalf("no level of size %d in the level set", size)
	return domain.Level{}
}
