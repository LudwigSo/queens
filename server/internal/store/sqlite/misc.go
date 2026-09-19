package sqlite

import (
	"context"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

// --- friends (directed: player_id follows friend_id) -------------------------

type friendRepo struct{ r, w dbtx }

// List returns the people I follow. round_score is filled in by the service,
// which knows each friend's own tier round (round lengths differ per tier, so it
// cannot be one join).
func (q *friendRepo) List(ctx context.Context, playerID string) ([]domain.FriendRow, error) {
	rows, err := q.r.QueryContext(ctx,
		`SELECT f.friend_id, p.nickname, p.tier, p.friend_code, f.created_at
		   FROM friends f JOIN players p ON p.id = f.friend_id
		  WHERE f.player_id = ? ORDER BY f.created_at ASC, f.friend_id ASC`, playerID)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []domain.FriendRow
	for rows.Next() {
		var f domain.FriendRow
		if err := rows.Scan(&f.PlayerID, &f.Nickname, &f.Tier, &f.FriendCode, &f.FriendSince); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

func (q *friendRepo) IDs(ctx context.Context, playerID string) ([]string, error) {
	rows, err := q.r.QueryContext(ctx,
		`SELECT friend_id FROM friends WHERE player_id = ? ORDER BY friend_id ASC`, playerID)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

func (q *friendRepo) Count(ctx context.Context, playerID string) (int, error) {
	var n int
	err := q.r.QueryRowContext(ctx, `SELECT COUNT(*) FROM friends WHERE player_id = ?`, playerID).Scan(&n)
	return n, mapErr(err)
}

func (q *friendRepo) Add(ctx context.Context, playerID, friendID string, now int64) (bool, error) {
	return affected(q.w.ExecContext(ctx,
		`INSERT INTO friends (player_id, friend_id, created_at) VALUES (?, ?, ?)
		 ON CONFLICT (player_id, friend_id) DO NOTHING`, playerID, friendID, now))
}

func (q *friendRepo) Remove(ctx context.Context, playerID, friendID string) (bool, error) {
	return affected(q.w.ExecContext(ctx,
		`DELETE FROM friends WHERE player_id = ? AND friend_id = ?`, playerID, friendID))
}

func (q *friendRepo) IsFriend(ctx context.Context, playerID, otherID string) (bool, error) {
	var one int
	err := q.r.QueryRowContext(ctx,
		`SELECT 1 FROM friends WHERE player_id = ? AND friend_id = ?`, playerID, otherID).Scan(&one)
	if err != nil {
		if mapErr(err) == domain.ErrNotFound {
			return false, nil
		}
		return false, mapErr(err)
	}
	return true, nil
}

// --- anti-cheat flags --------------------------------------------------------

type flagRepo struct{ r, w dbtx }

func (q *flagRepo) Insert(ctx context.Context, f *domain.Flag) error {
	_, err := q.w.ExecContext(ctx,
		`INSERT INTO player_flags (id, player_id, signal, weight, result_id, session_id, detail_json, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		f.ID, f.PlayerID, f.Signal, f.Weight, f.ResultID, f.SessionID, f.DetailJSON, f.CreatedAt)
	return mapErr(err)
}

func (q *flagRepo) ListByPlayer(ctx context.Context, playerID string, limit int) ([]domain.Flag, error) {
	rows, err := q.r.QueryContext(ctx,
		`SELECT id, player_id, signal, weight, result_id, session_id, detail_json, created_at
		   FROM player_flags WHERE player_id = ? ORDER BY created_at DESC, id DESC LIMIT ?`, playerID, limit)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []domain.Flag
	for rows.Next() {
		var f domain.Flag
		if err := rows.Scan(&f.ID, &f.PlayerID, &f.Signal, &f.Weight, &f.ResultID, &f.SessionID,
			&f.DetailJSON, &f.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

func (q *flagRepo) ReadAnomaly(ctx context.Context, playerID string) (float64, int64, bool, error) {
	var score float64
	var updatedAt int64
	var shadow int
	err := q.r.QueryRowContext(ctx,
		`SELECT anomaly_score, anomaly_updated_at, shadow_excluded FROM players WHERE id = ?`, playerID).
		Scan(&score, &updatedAt, &shadow)
	return score, updatedAt, shadow != 0, mapErr(err)
}

func (q *flagRepo) WriteAnomaly(ctx context.Context, playerID string, score float64, updatedAt int64, shadow bool) error {
	_, err := q.w.ExecContext(ctx,
		`UPDATE players SET anomaly_score = ?, anomaly_updated_at = ?, shadow_excluded = ? WHERE id = ?`,
		score, updatedAt, boolToInt(shadow), playerID)
	return mapErr(err)
}

func (q *flagRepo) DeleteBefore(ctx context.Context, createdBefore int64) (int64, error) {
	res, err := q.w.ExecContext(ctx, `DELETE FROM player_flags WHERE created_at < ?`, createdBefore)
	if err != nil {
		return 0, mapErr(err)
	}
	return res.RowsAffected()
}

// --- rate counters (daily; the hourly buckets live in memory) ----------------

type rateRepo struct{ r, w dbtx }

func (q *rateRepo) Bump(ctx context.Context, key string, day int64) (int, error) {
	if _, err := q.w.ExecContext(ctx,
		`INSERT INTO rate_counters (key, day, count) VALUES (?, ?, 1)
		 ON CONFLICT (key, day) DO UPDATE SET count = rate_counters.count + 1`, key, day); err != nil {
		return 0, mapErr(err)
	}
	var n int
	err := q.r.QueryRowContext(ctx, `SELECT count FROM rate_counters WHERE key = ? AND day = ?`, key, day).Scan(&n)
	return n, mapErr(err)
}

func (q *rateRepo) Peek(ctx context.Context, key string, day int64) (int, error) {
	var n int
	err := q.r.QueryRowContext(ctx, `SELECT count FROM rate_counters WHERE key = ? AND day = ?`, key, day).Scan(&n)
	if err != nil {
		if mapErr(err) == domain.ErrNotFound {
			return 0, nil
		}
		return 0, mapErr(err)
	}
	return n, nil
}

func (q *rateRepo) DeleteBefore(ctx context.Context, day int64) (int64, error) {
	res, err := q.w.ExecContext(ctx, `DELETE FROM rate_counters WHERE day < ?`, day)
	if err != nil {
		return 0, mapErr(err)
	}
	return res.RowsAffected()
}
