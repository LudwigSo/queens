package sqlite_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
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
