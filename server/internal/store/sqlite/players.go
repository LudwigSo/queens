package sqlite

import (
	"context"
	"database/sql"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

type playerRepo struct{ r, w dbtx }

const playerCols = `id, nickname, friend_code, tier, tier_points, tier_since, settled_round_end,
	games, flawless, best_score, rounds_played, perfect_streak, anomaly_score, anomaly_updated_at,
	shadow_excluded, banned_at, auth_provider, auth_external_id, client_version,
	created_at, updated_at, last_seen_at`

func scanPlayer(s interface{ Scan(...any) error }) (*domain.Player, error) {
	var p domain.Player
	var shadow int
	if err := s.Scan(&p.ID, &p.Nickname, &p.FriendCode, &p.Tier, &p.TierPoints, &p.TierSince, &p.SettledRoundEnd,
		&p.Games, &p.Flawless, &p.BestScore, &p.RoundsPlayed, &p.PerfectStreak, &p.AnomalyScore, &p.AnomalyUpdatedAt,
		&shadow, &p.BannedAt, &p.AuthProvider, &p.AuthExternalID, &p.ClientVersion,
		&p.CreatedAt, &p.UpdatedAt, &p.LastSeenAt); err != nil {
		return nil, mapErr(err)
	}
	p.ShadowExcluded = shadow != 0
	return &p, nil
}

func (q *playerRepo) Get(ctx context.Context, id string) (*domain.Player, error) {
	return scanPlayer(q.r.QueryRowContext(ctx, `SELECT `+playerCols+` FROM players WHERE id = ?`, id))
}

func (q *playerRepo) GetByFriendCode(ctx context.Context, code string) (*domain.Player, error) {
	return scanPlayer(q.r.QueryRowContext(ctx, `SELECT `+playerCols+` FROM players WHERE friend_code = ?`, code))
}

func (q *playerRepo) FriendCodeExists(ctx context.Context, code string) (bool, error) {
	var one int
	err := q.r.QueryRowContext(ctx, `SELECT 1 FROM players WHERE friend_code = ?`, code).Scan(&one)
	if err == sql.ErrNoRows {
		return false, nil
	}
	return err == nil, mapErrNoRows(err)
}

func mapErrNoRows(err error) error {
	if err == nil || err == sql.ErrNoRows {
		return nil
	}
	return err
}

func (q *playerRepo) Create(ctx context.Context, p *domain.Player) error {
	_, err := q.w.ExecContext(ctx, `INSERT INTO players
		(id, nickname, friend_code, tier, tier_points, tier_since, settled_round_end,
		 games, flawless, best_score, rounds_played, perfect_streak, anomaly_score, anomaly_updated_at,
		 shadow_excluded, banned_at, auth_provider, auth_external_id, client_version, created_at, updated_at, last_seen_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, 0, 0, 0, 0, NULL, NULL, NULL, ?, ?, ?, ?)`,
		p.ID, p.Nickname, p.FriendCode, p.Tier, p.TierPoints, p.TierSince, p.SettledRoundEnd,
		p.ClientVersion, p.CreatedAt, p.UpdatedAt, p.LastSeenAt)
	return mapErr(err)
}

func (q *playerRepo) UpdateNickname(ctx context.Context, id, nickname string, now int64) error {
	_, err := q.w.ExecContext(ctx, `UPDATE players SET nickname = ?, updated_at = ? WHERE id = ?`, nickname, now, id)
	return mapErr(err)
}

// AddGameStats bumps every counter in SQL. best_score uses CASE rather than a
// read-modify-write in Go, so two concurrent submits cannot lose one.
func (q *playerRepo) AddGameStats(ctx context.Context, id string, flawless, score int, now int64) error {
	_, err := q.w.ExecContext(ctx, `UPDATE players SET
		games = games + 1,
		flawless = flawless + ?,
		best_score = CASE WHEN best_score < ? THEN ? ELSE best_score END,
		tier_points = tier_points + ?,
		updated_at = ?
		WHERE id = ?`, flawless, score, score, score, now, id)
	return mapErr(err)
}

func (q *playerRepo) SetPerfectStreak(ctx context.Context, id string, n int) error {
	_, err := q.w.ExecContext(ctx, `UPDATE players SET perfect_streak = ? WHERE id = ?`, n, id)
	return mapErr(err)
}

func (q *playerRepo) IncRoundsPlayed(ctx context.Context, id string) error {
	_, err := q.w.ExecContext(ctx, `UPDATE players SET rounds_played = rounds_played + 1 WHERE id = ?`, id)
	return mapErr(err)
}

// SetTier is guarded on the current tier so a concurrent promotion cannot be
// applied twice. tier_points restart at 0 on every actual tier change.
func (q *playerRepo) SetTier(ctx context.Context, id, from, to string, tierSince, settledRoundEnd int64) (bool, error) {
	if from == to {
		return affected(q.w.ExecContext(ctx,
			`UPDATE players SET settled_round_end = ?, updated_at = ? WHERE id = ? AND tier = ?`,
			settledRoundEnd, tierSince, id, from))
	}
	return affected(q.w.ExecContext(ctx,
		`UPDATE players SET tier = ?, tier_points = 0, tier_since = ?, settled_round_end = ?, updated_at = ?
		 WHERE id = ? AND tier = ?`,
		to, tierSince, settledRoundEnd, tierSince, id, from))
}

func (q *playerRepo) SetSettledRoundEnd(ctx context.Context, id string, ts int64) error {
	_, err := q.w.ExecContext(ctx, `UPDATE players SET settled_round_end = ? WHERE id = ?`, ts, id)
	return mapErr(err)
}

func (q *playerRepo) CountByTier(ctx context.Context, tier string) (int, error) {
	var n int
	err := q.r.QueryRowContext(ctx, `SELECT COUNT(*) FROM players WHERE tier = ?`, tier).Scan(&n)
	return n, mapErr(err)
}

func (q *playerRepo) TouchLastSeen(ctx context.Context, id string, now int64) error {
	_, err := q.w.ExecContext(ctx, `UPDATE players SET last_seen_at = ? WHERE id = ?`, now, id)
	return mapErr(err)
}

func (q *playerRepo) SetBanned(ctx context.Context, id string, at *int64) error {
	_, err := q.w.ExecContext(ctx, `UPDATE players SET banned_at = ? WHERE id = ?`, at, id)
	return mapErr(err)
}

func (q *playerRepo) Delete(ctx context.Context, id string) error {
	_, err := q.w.ExecContext(ctx, `DELETE FROM players WHERE id = ?`, id)
	return mapErr(err)
}

func (q *playerRepo) List(ctx context.Context, limit int) ([]domain.Player, error) {
	rows, err := q.r.QueryContext(ctx, `SELECT `+playerCols+` FROM players ORDER BY created_at DESC, id ASC LIMIT ?`, limit)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []domain.Player
	for rows.Next() {
		p, err := scanPlayer(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *p)
	}
	return out, rows.Err()
}

func (q *playerRepo) InsertToken(ctx context.Context, hash, playerID string, now int64) error {
	_, err := q.w.ExecContext(ctx,
		`INSERT INTO auth_tokens (token_hash, player_id, created_at, last_seen_at) VALUES (?, ?, ?, ?)`,
		hash, playerID, now, now)
	return mapErr(err)
}

// GetToken joins players so the resolver can tell 401 from 403 in one read.
func (q *playerRepo) GetToken(ctx context.Context, hash string) (*domain.Token, error) {
	var t domain.Token
	err := q.r.QueryRowContext(ctx,
		`SELECT t.token_hash, t.player_id, t.created_at, t.last_seen_at, t.revoked_at, p.banned_at
		   FROM auth_tokens t JOIN players p ON p.id = t.player_id
		  WHERE t.token_hash = ?`, hash).
		Scan(&t.Hash, &t.PlayerID, &t.CreatedAt, &t.LastSeenAt, &t.RevokedAt, &t.BannedAt)
	if err != nil {
		return nil, mapErr(err)
	}
	return &t, nil
}

func (q *playerRepo) TouchToken(ctx context.Context, hash string, now int64) error {
	_, err := q.w.ExecContext(ctx, `UPDATE auth_tokens SET last_seen_at = ? WHERE token_hash = ?`, now, hash)
	return mapErr(err)
}

func (q *playerRepo) RevokeTokens(ctx context.Context, playerID string, now int64) error {
	_, err := q.w.ExecContext(ctx,
		`UPDATE auth_tokens SET revoked_at = ? WHERE player_id = ? AND revoked_at IS NULL`, now, playerID)
	return mapErr(err)
}

func (q *playerRepo) DeleteRevokedTokensBefore(ctx context.Context, before int64) (int64, error) {
	res, err := q.w.ExecContext(ctx,
		`DELETE FROM auth_tokens WHERE revoked_at IS NOT NULL AND revoked_at < ?`, before)
	if err != nil {
		return 0, mapErr(err)
	}
	return res.RowsAffected()
}
