package sqlite

import (
	"context"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

type levelRepo struct{ r, w dbtx }

const levelCols = `id, size, difficulty, stars, seed, regions_json, solution_json, content_hash,
	par_override, in_current_set, created_at, updated_at`

func scanLevel(s interface{ Scan(...any) error }) (*domain.Level, error) {
	var l domain.Level
	var inSet int
	if err := s.Scan(&l.ID, &l.Size, &l.Difficulty, &l.Stars, &l.Seed, &l.RegionsJSON, &l.SolutionJSON,
		&l.ContentHash, &l.ParOverride, &inSet, &l.CreatedAt, &l.UpdatedAt); err != nil {
		return nil, mapErr(err)
	}
	l.InCurrentSet = inSet != 0
	return &l, nil
}

func (q *levelRepo) Get(ctx context.Context, id string) (*domain.Level, error) {
	return scanLevel(q.r.QueryRowContext(ctx, `SELECT `+levelCols+` FROM levels WHERE id = ?`, id))
}

func (q *levelRepo) All(ctx context.Context) ([]domain.Level, error) {
	rows, err := q.r.QueryContext(ctx, `SELECT `+levelCols+` FROM levels ORDER BY id ASC`)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []domain.Level
	for rows.Next() {
		l, err := scanLevel(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *l)
	}
	return out, rows.Err()
}

func (q *levelRepo) Upsert(ctx context.Context, lv *domain.Level, now int64) error {
	_, err := q.w.ExecContext(ctx, `INSERT INTO levels
		(id, size, difficulty, stars, seed, regions_json, solution_json, content_hash, par_override,
		 in_current_set, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
		ON CONFLICT (id) DO UPDATE SET
		  stars = excluded.stars, seed = excluded.seed, regions_json = excluded.regions_json,
		  solution_json = excluded.solution_json, content_hash = excluded.content_hash,
		  in_current_set = 1, updated_at = excluded.updated_at`,
		lv.ID, lv.Size, lv.Difficulty, lv.Stars, lv.Seed, lv.RegionsJSON, lv.SolutionJSON, lv.ContentHash,
		lv.ParOverride, now, now)
	return mapErr(err)
}

// MarkNotInSet flags levels that vanished from the shipped file. Rows are kept
// forever: old results and leaderboards still point at them.
func (q *levelRepo) MarkNotInSet(ctx context.Context, keepIDs []string, now int64) ([]string, error) {
	args := make([]any, 0, len(keepIDs)+1)
	for _, id := range keepIDs {
		args = append(args, id)
	}
	sqlStr := `SELECT id FROM levels WHERE in_current_set = 1`
	if len(keepIDs) > 0 {
		sqlStr += ` AND id NOT IN (` + placeholders(len(keepIDs)) + `)`
	}
	sqlStr += ` ORDER BY id ASC`
	rows, err := q.r.QueryContext(ctx, sqlStr, args...)
	if err != nil {
		return nil, mapErr(err)
	}
	var gone []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		gone = append(gone, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, id := range gone {
		if _, err := q.w.ExecContext(ctx,
			`UPDATE levels SET in_current_set = 0, updated_at = ? WHERE id = ?`, now, id); err != nil {
			return nil, mapErr(err)
		}
	}
	return gone, nil
}

func (q *levelRepo) InsertLevelSet(ctx context.Context, hash string, count int, now int64) error {
	_, err := q.w.ExecContext(ctx,
		`INSERT INTO level_sets (hash, level_count, imported_at) VALUES (?, ?, ?)
		 ON CONFLICT (hash) DO NOTHING`, hash, count, now)
	return mapErr(err)
}

func (q *levelRepo) CurrentLevelSet(ctx context.Context) (*domain.LevelSet, error) {
	var s domain.LevelSet
	err := q.r.QueryRowContext(ctx,
		`SELECT hash, level_count, imported_at FROM level_sets ORDER BY imported_at DESC, hash ASC LIMIT 1`).
		Scan(&s.Hash, &s.LevelCount, &s.ImportedAt)
	if err != nil {
		return nil, mapErr(err)
	}
	return &s, nil
}

func (q *levelRepo) GetPlayerLevel(ctx context.Context, playerID, levelID string) (*domain.PlayerLevel, error) {
	var pl domain.PlayerLevel
	err := q.r.QueryRowContext(ctx,
		`SELECT player_id, level_id, last_started_at, plays FROM player_levels WHERE player_id = ? AND level_id = ?`,
		playerID, levelID).Scan(&pl.PlayerID, &pl.LevelID, &pl.LastStartedAt, &pl.Plays)
	if err != nil {
		return nil, mapErr(err)
	}
	return &pl, nil
}

func (q *levelRepo) ListPlayerLevels(ctx context.Context, playerID string) ([]domain.PlayerLevel, error) {
	rows, err := q.r.QueryContext(ctx,
		`SELECT player_id, level_id, last_started_at, plays FROM player_levels WHERE player_id = ? ORDER BY level_id ASC`,
		playerID)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []domain.PlayerLevel
	for rows.Next() {
		var pl domain.PlayerLevel
		if err := rows.Scan(&pl.PlayerID, &pl.LevelID, &pl.LastStartedAt, &pl.Plays); err != nil {
			return nil, err
		}
		out = append(out, pl)
	}
	return out, rows.Err()
}

func (q *levelRepo) RecordStart(ctx context.Context, playerID, levelID string, now int64) error {
	_, err := q.w.ExecContext(ctx,
		`INSERT INTO player_levels (player_id, level_id, last_started_at, plays) VALUES (?, ?, ?, 1)
		 ON CONFLICT (player_id, level_id) DO UPDATE SET
		   last_started_at = excluded.last_started_at, plays = player_levels.plays + 1`,
		playerID, levelID, now)
	return mapErr(err)
}

// EligibleLevelIDs answers "which levels could this player have started inside
// this round". A level qualifies when it was never started, when its cooldown
// runs out before the round ends, or when it was already started inside the
// round. It is the input to the round-score ceiling: a score above
// 2 * sum(best-N bases over these levels) is impossible, not merely suspicious.
func (q *levelRepo) EligibleLevelIDs(ctx context.Context, playerID string, roundStart, roundEnd, cooldownSeconds int64) ([]string, error) {
	rows, err := q.r.QueryContext(ctx, `
		SELECT l.id FROM levels l
		  LEFT JOIN player_levels pl ON pl.player_id = ? AND pl.level_id = l.id
		 WHERE pl.level_id IS NULL
		    OR pl.last_started_at + ? < ?
		    OR pl.last_started_at >= ?
		 ORDER BY l.id ASC`, playerID, cooldownSeconds, roundEnd, roundStart)
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
