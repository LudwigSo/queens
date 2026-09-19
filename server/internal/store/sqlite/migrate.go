package sqlite

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"log/slog"
	"sort"
	"strconv"
	"strings"
)

//go:embed migrations/*.sql
var migrationFS embed.FS

type migration struct {
	version int
	name    string
	sql     string
}

func loadMigrations() ([]migration, error) {
	entries, err := fs.Glob(migrationFS, "migrations/*.sql")
	if err != nil {
		return nil, err
	}
	sort.Strings(entries)
	out := make([]migration, 0, len(entries))
	for _, e := range entries {
		base := strings.TrimSuffix(strings.TrimPrefix(e, "migrations/"), ".sql")
		num, rest, ok := strings.Cut(base, "_")
		if !ok {
			return nil, fmt.Errorf("migration %q is not NNNN_name.sql", e)
		}
		v, err := strconv.Atoi(num)
		if err != nil {
			return nil, fmt.Errorf("migration %q has no numeric version: %w", e, err)
		}
		body, err := migrationFS.ReadFile(e)
		if err != nil {
			return nil, err
		}
		out = append(out, migration{version: v, name: rest, sql: string(body)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].version < out[j].version })
	return out, nil
}

// Migrate applies every pending migration, one transaction per file. It is
// forward-only on purpose: one environment does not need down-migrations, and a
// rollback is a restore from the nightly backup.
func (d *DB) Migrate(ctx context.Context, now int64) error {
	migs, err := loadMigrations()
	if err != nil {
		return err
	}
	if _, err := d.w.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version INTEGER NOT NULL PRIMARY KEY, name TEXT NOT NULL, applied_at INTEGER NOT NULL) STRICT`); err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}
	applied := map[int]bool{}
	rows, err := d.w.QueryContext(ctx, `SELECT version FROM schema_migrations ORDER BY version`)
	if err != nil {
		return err
	}
	for rows.Next() {
		var v int
		if err := rows.Scan(&v); err != nil {
			rows.Close()
			return err
		}
		applied[v] = true
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	for _, m := range migs {
		if applied[m.version] {
			continue
		}
		tx, err := d.w.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, m.sql); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("migration %04d_%s: %w", m.version, m.name, err)
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)`,
			m.version, m.name, now); err != nil {
			_ = tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		slog.Info("migration applied", "version", m.version, "name", m.name)
	}
	return nil
}
