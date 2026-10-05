package sqlite

import (
	"context"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

type levelRepo struct{ r, w dbtx }

const levelCols = `id, size, difficulty, stars, seed, regions_json, solution_json, content_hash,
	par_override, in_current_set, position, created_at, updated_at`

func scanLevel(s interface{ Scan(...any) error }) (*domain.Level, error) {
	var l domain.Level
	var inSet int
	if err := s.Scan(&l.ID, &l.Size, &l.Difficulty, &l.Stars, &l.Seed, &l.RegionsJSON, &l.SolutionJSON,
		&l.ContentHash, &l.ParOverride, &inSet, &l.Position, &l.CreatedAt, &l.UpdatedAt); err != nil {
		return nil, mapErr(err)
	}
	l.InCurrentSet = inSet != 0
	return &l, nil
}

func (q *levelRepo) Get(ctx context.Context, id string) (*domain.Level, error) {
	return scanLevel(q.r.QueryRowContext(ctx, `SELECT `+levelCols+` FROM levels WHERE id = ?`, id))
}

func (q *levelRepo) All(ctx context.Context) ([]domain.Level, error) {
	return q.list(ctx, `SELECT `+levelCols+` FROM levels ORDER BY id ASC`)
}

func (q *levelRepo) list(ctx context.Context, query string, args ...any) ([]domain.Level, error) {
	rows, err := q.r.QueryContext(ctx, query, args...)
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

// Published lists the levels clients download, in client order.
func (q *levelRepo) Published(ctx context.Context) ([]domain.Level, error) {
	return q.list(ctx, `SELECT `+levelCols+` FROM levels WHERE position > 0 ORDER BY position ASC, id ASC`)
}

// GetMany returns the published levels among ids, in client order. Unknown and
// unpublished ids are skipped.
func (q *levelRepo) GetMany(ctx context.Context, ids []string) ([]domain.Level, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return q.list(ctx, `SELECT `+levelCols+` FROM levels WHERE position > 0 AND id IN (`+
		placeholders(len(ids))+`) ORDER BY position ASC, id ASC`, args...)
}

// CountPublished is the number clients compare their own level count with.
func (q *levelRepo) CountPublished(ctx context.Context) (int, error) {
	var n int
	err := q.r.QueryRowContext(ctx, `SELECT COUNT(*) FROM levels WHERE position > 0`).Scan(&n)
	return n, mapErr(err)
}

func (q *levelRepo) MaxPosition(ctx context.Context) (int, error) {
	var n int
	err := q.r.QueryRowContext(ctx, `SELECT COALESCE(MAX(position), 0) FROM levels`).Scan(&n)
	return n, mapErr(err)
}

// Insert adds a new level. Levels are immutable once stored, so there is no
// update path: levelset.Import refuses a changed board before it gets here.
func (q *levelRepo) Insert(ctx context.Context, lv *domain.Level, now int64) error {
	_, err := q.w.ExecContext(ctx, `INSERT INTO levels
		(id, size, difficulty, stars, seed, regions_json, solution_json, content_hash, par_override,
		 in_current_set, position, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)`,
		lv.ID, lv.Size, lv.Difficulty, lv.Stars, lv.Seed, lv.RegionsJSON, lv.SolutionJSON, lv.ContentHash,
		lv.ParOverride, lv.Position, now, now)
	if isUnique(err) {
		return domain.ErrConflict
	}
	return mapErr(err)
}

// Publish gives an unpublished level (position 0) its position. It never moves
// a published one: the client order is append-only too.
func (q *levelRepo) Publish(ctx context.Context, id string, position int, now int64) error {
	_, err := q.w.ExecContext(ctx,
		`UPDATE levels SET position = ?, in_current_set = 1, updated_at = ? WHERE id = ? AND position = 0`,
		position, now, id)
	return mapErr(err)
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

const playerLevelCols = `player_id, level_id, last_started_at, plays, completions, last_completed_at,
	best_time, best_score, best_score_time, best_wrong, best_result_id, best_at`

func scanPlayerLevel(s interface{ Scan(...any) error }) (*domain.PlayerLevel, error) {
	var pl domain.PlayerLevel
	if err := s.Scan(&pl.PlayerID, &pl.LevelID, &pl.LastStartedAt, &pl.Plays, &pl.Completions, &pl.LastCompletedAt,
		&pl.BestTime, &pl.BestScore, &pl.BestScoreTime, &pl.BestWrong, &pl.BestResultID, &pl.BestAt); err != nil {
		return nil, mapErr(err)
	}
	return &pl, nil
}

func (q *levelRepo) GetPlayerLevel(ctx context.Context, playerID, levelID string) (*domain.PlayerLevel, error) {
	return scanPlayerLevel(q.r.QueryRowContext(ctx,
		`SELECT `+playerLevelCols+` FROM player_levels WHERE player_id = ? AND level_id = ?`, playerID, levelID))
}

func (q *levelRepo) ListPlayerLevels(ctx context.Context, playerID string) ([]domain.PlayerLevel, error) {
	rows, err := q.r.QueryContext(ctx,
		`SELECT `+playerLevelCols+` FROM player_levels WHERE player_id = ? ORDER BY level_id ASC`, playerID)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []domain.PlayerLevel
	for rows.Next() {
		pl, err := scanPlayerLevel(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *pl)
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

// ApplyResult folds one accepted result into the player's level state. The
// play is counted here only for an offline game (RecordStart counted the
// session-backed ones). The best-score update uses the same strict order as the
// client's SaveData.update_best_score, so a full tie keeps the older run.
func (q *levelRepo) ApplyResult(ctx context.Context, playerID, levelID string, r domain.PlayerLevelResult) error {
	plays, started := 0, int64(0)
	if r.CountPlay {
		plays, started = 1, r.StartedAt
	}
	if _, err := q.w.ExecContext(ctx,
		`INSERT INTO player_levels (player_id, level_id, last_started_at, plays) VALUES (?, ?, ?, ?)
		 ON CONFLICT (player_id, level_id) DO UPDATE SET
		   plays = player_levels.plays + excluded.plays,
		   last_started_at = MAX(player_levels.last_started_at, excluded.last_started_at)`,
		playerID, levelID, started, plays); err != nil {
		return mapErr(err)
	}
	if !r.Completed {
		return nil
	}
	if _, err := q.w.ExecContext(ctx,
		`UPDATE player_levels SET
		   completions = completions + 1,
		   last_completed_at = MAX(last_completed_at, ?1),
		   best_time = CASE WHEN best_time <= 0 OR ?2 < best_time THEN ?2 ELSE best_time END
		 WHERE player_id = ?3 AND level_id = ?4`,
		r.FinishedAt, r.Elapsed, playerID, levelID); err != nil {
		return mapErr(err)
	}
	_, err := q.w.ExecContext(ctx,
		`UPDATE player_levels SET
		   best_score = ?1, best_wrong = ?2, best_score_time = ?3, best_result_id = ?4, best_at = ?5
		 WHERE player_id = ?6 AND level_id = ?7
		   AND (best_result_id = ''
		    OR ?1 > best_score
		    OR (?1 = best_score AND ?2 < best_wrong)
		    OR (?1 = best_score AND ?2 = best_wrong AND ?3 < best_score_time))`,
		r.Score, r.Wrong, r.Elapsed, r.ResultID, r.FinishedAt, playerID, levelID)
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
