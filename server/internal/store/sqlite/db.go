// Package sqlite is the SQLite implementation of store.Store, on the pure-Go
// modernc.org/sqlite driver (no cgo, so GOOS=linux GOARCH=arm64 go build just
// works from a Windows dev box).
package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math/rand"
	"runtime"
	"strings"
	"time"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
	_ "modernc.org/sqlite"
)

// dbtx is satisfied by both *sql.DB and *sql.Tx, so a repository does not know
// whether it is inside a transaction.
type dbtx interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// DB holds the two pools. This is the single most important operational detail
// in the server:
//
//   - the write pool is capped at ONE connection, so writes serialise through
//     Go's connection pool (a clean FIFO that honours context cancellation)
//     instead of through SQLITE_BUSY retries;
//   - _txlock=immediate makes every transaction take the write lock up front,
//     removing the read-then-write upgrade deadlock (SQLITE_BUSY_SNAPSHOT);
//   - reads use their own pool and therefore never queue behind a slow submit;
//   - connections are never recycled, because a new connection would have to
//     re-run the pragmas.
type DB struct {
	w *sql.DB
	r *sql.DB
}

const (
	writeDSN = "file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)" +
		"&_pragma=foreign_keys(1)&_pragma=synchronous(NORMAL)" +
		"&_pragma=temp_store(MEMORY)&_txlock=immediate"
	readDSN = "file:%s?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)" +
		"&_pragma=synchronous(NORMAL)&mode=ro"
)

// Open opens (and creates) the database at path. Run Migrate before serving.
func Open(path string) (*DB, error) {
	w, err := sql.Open("sqlite", fmt.Sprintf(writeDSN, path))
	if err != nil {
		return nil, fmt.Errorf("open write pool: %w", err)
	}
	w.SetMaxOpenConns(1)
	w.SetMaxIdleConns(1)
	w.SetConnMaxLifetime(0)
	if err := w.Ping(); err != nil {
		w.Close()
		return nil, fmt.Errorf("ping write pool: %w", err)
	}
	// The read pool is opened read-only, so it must come after the write pool
	// has created the file.
	r, err := sql.Open("sqlite", fmt.Sprintf(readDSN, path))
	if err != nil {
		w.Close()
		return nil, fmt.Errorf("open read pool: %w", err)
	}
	n := runtime.NumCPU()
	if n < 4 {
		n = 4
	}
	r.SetMaxOpenConns(n)
	r.SetMaxIdleConns(n)
	r.SetConnMaxLifetime(0)
	return &DB{w: w, r: r}, nil
}

func (d *DB) Repos() store.Repos { return reposFor(d.r, d.w) }

func reposFor(r, w dbtx) store.Repos {
	return store.Repos{
		Players:  &playerRepo{r: r, w: w},
		Levels:   &levelRepo{r: r, w: w},
		Sessions: &sessionRepo{r: r, w: w},
		Results:  &resultRepo{r: r, w: w},
		Bests:    &bestRepo{r: r, w: w},
		League:   &leagueRepo{r: r, w: w},
		Friends:  &friendRepo{r: r, w: w},
		Flags:    &flagRepo{r: r, w: w},
		Rates:    &rateRepo{r: r, w: w},
	}
}

const txAttempts = 3

// InTx binds every repository -- reads included -- to one write transaction.
func (d *DB) InTx(ctx context.Context, fn func(context.Context, store.Repos) error) error {
	var lastErr error
	for attempt := 0; attempt < txAttempts; attempt++ {
		err := d.runTx(ctx, fn)
		if err == nil {
			return nil
		}
		lastErr = err
		// Only a busy database or a lost conditional update is worth retrying;
		// an application error is final.
		if !isBusy(err) && !errors.Is(err, domain.ErrRetry) {
			return err
		}
		if ctx.Err() != nil {
			return err
		}
		time.Sleep(time.Duration(20+rand.Intn(60)) * time.Millisecond)
	}
	return lastErr
}

func (d *DB) runTx(ctx context.Context, fn func(context.Context, store.Repos) error) error {
	tx, err := d.w.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	err = fn(ctx, reposFor(tx, tx))
	if err != nil {
		// CommitAndFail persists the work (an anti-cheat flag) and still fails.
		var caf store.CommitAndFail
		if errors.As(err, &caf) {
			if cerr := tx.Commit(); cerr != nil {
				return cerr
			}
			return caf.Err
		}
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

func isBusy(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "SQLITE_BUSY") || strings.Contains(s, "database is locked") ||
		strings.Contains(s, "SQLITE_LOCKED")
}

func (d *DB) Ping(ctx context.Context) error {
	if err := d.w.PingContext(ctx); err != nil {
		return err
	}
	return d.r.PingContext(ctx)
}

func (d *DB) Checkpoint(ctx context.Context) error {
	_, err := d.w.ExecContext(ctx, "PRAGMA wal_checkpoint(TRUNCATE)")
	return err
}

// BackupTo writes a consistent copy with VACUUM INTO, which is safe under WAL
// with concurrent readers and needs no cgo.
func (d *DB) BackupTo(ctx context.Context, path string) error {
	_, err := d.w.ExecContext(ctx, "VACUUM INTO ?", path)
	return err
}

func (d *DB) Close() error {
	err1 := d.r.Close()
	err2 := d.w.Close()
	if err1 != nil {
		return err1
	}
	return err2
}

// --- small helpers shared by the repositories -------------------------------

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func affected(res sql.Result, err error) (bool, error) {
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// placeholders renders "?,?,?" for an IN clause.
func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

func isUnique(err error) bool {
	return err != nil && (strings.Contains(err.Error(), "UNIQUE constraint failed") ||
		strings.Contains(err.Error(), "PRIMARY KEY constraint failed") ||
		strings.Contains(err.Error(), "constraint failed: UNIQUE"))
}

func mapErr(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		return domain.ErrNotFound
	}
	if isUnique(err) {
		return domain.ErrConflict
	}
	return err
}
