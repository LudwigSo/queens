package sqlite

import (
	"context"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

type sessionRepo struct{ r, w dbtx }

const sessionCols = `id, player_id, level_id, issued_at, expires_at, consumed_at, result_id,
	tier_at_issue, round_index_at_issue, group_id, integrity_verdict, client_version`

func scanSession(s interface{ Scan(...any) error }) (*domain.Session, error) {
	var x domain.Session
	if err := s.Scan(&x.ID, &x.PlayerID, &x.LevelID, &x.IssuedAt, &x.ExpiresAt, &x.ConsumedAt, &x.ResultID,
		&x.TierAtIssue, &x.RoundIndexAtIssue, &x.GroupID, &x.IntegrityVerdict, &x.ClientVersion); err != nil {
		return nil, mapErr(err)
	}
	return &x, nil
}

func (q *sessionRepo) Insert(ctx context.Context, s *domain.Session) error {
	_, err := q.w.ExecContext(ctx, `INSERT INTO game_sessions
		(id, player_id, level_id, issued_at, expires_at, consumed_at, result_id,
		 tier_at_issue, round_index_at_issue, group_id, integrity_verdict, client_version)
		VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?)`,
		s.ID, s.PlayerID, s.LevelID, s.IssuedAt, s.ExpiresAt,
		s.TierAtIssue, s.RoundIndexAtIssue, s.GroupID, s.IntegrityVerdict, s.ClientVersion)
	return mapErr(err)
}

func (q *sessionRepo) Get(ctx context.Context, id string) (*domain.Session, error) {
	return scanSession(q.r.QueryRowContext(ctx, `SELECT `+sessionCols+` FROM game_sessions WHERE id = ?`, id))
}

// FindReusable returns the newest unconsumed session for this (player, level).
// POST /games is never retried by the client, so a request that was processed
// but whose response was lost must not cost the player a seven-day lock.
func (q *sessionRepo) FindReusable(ctx context.Context, playerID, levelID string, since int64) (*domain.Session, error) {
	return scanSession(q.r.QueryRowContext(ctx, `SELECT `+sessionCols+` FROM game_sessions
		 WHERE player_id = ? AND level_id = ? AND consumed_at IS NULL AND issued_at >= ?
		 ORDER BY issued_at DESC, id ASC LIMIT 1`, playerID, levelID, since))
}

// Consume is the single-use guard. RowsAffected == 0 means the session was
// already spent: the caller checks whether it was spent by this very result_id
// (a legitimate replay) before returning ERR_SESSION_USED.
func (q *sessionRepo) Consume(ctx context.Context, id, resultID string, now int64) (bool, error) {
	return affected(q.w.ExecContext(ctx,
		`UPDATE game_sessions SET consumed_at = ?, result_id = ? WHERE id = ? AND consumed_at IS NULL`,
		now, resultID, id))
}

func (q *sessionRepo) DeleteUnconsumedBefore(ctx context.Context, issuedBefore int64) (int64, error) {
	res, err := q.w.ExecContext(ctx,
		`DELETE FROM game_sessions WHERE consumed_at IS NULL AND issued_at < ?
		  AND id IN (SELECT id FROM game_sessions WHERE consumed_at IS NULL AND issued_at < ? LIMIT 5000)`,
		issuedBefore, issuedBefore)
	if err != nil {
		return 0, mapErr(err)
	}
	return res.RowsAffected()
}

func (q *sessionRepo) DeleteConsumedBefore(ctx context.Context, consumedBefore int64) (int64, error) {
	res, err := q.w.ExecContext(ctx,
		`DELETE FROM game_sessions WHERE consumed_at IS NOT NULL AND consumed_at < ?
		  AND id IN (SELECT id FROM game_sessions WHERE consumed_at IS NOT NULL AND consumed_at < ? LIMIT 5000)`,
		consumedBefore, consumedBefore)
	if err != nil {
		return 0, mapErr(err)
	}
	return res.RowsAffected()
}
