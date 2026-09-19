package sqlite

import (
	"context"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

type resultRepo struct{ r, w dbtx }

const resultCols = `result_id, player_id, level_id, session_id, tier, round_index, completed, verified,
	schema, size, difficulty, stars, par_seconds, base, started_at, finished_at, received_at,
	elapsed_seconds, client_elapsed_seconds, queens_placed, wrong_placements, queens_removed,
	clear_count, hint_count, taps, score, client_score, flawless, client_version, payload_hash, response_json`

func scanResult(s interface{ Scan(...any) error }) (*domain.Result, error) {
	var x domain.Result
	var completed, verified, flawless int
	if err := s.Scan(&x.ResultID, &x.PlayerID, &x.LevelID, &x.SessionID, &x.Tier, &x.RoundIndex,
		&completed, &verified, &x.Schema, &x.Size, &x.Difficulty, &x.Stars, &x.ParSeconds, &x.Base,
		&x.StartedAt, &x.FinishedAt, &x.ReceivedAt, &x.ElapsedSeconds, &x.ClientElapsedSeconds,
		&x.QueensPlaced, &x.WrongPlacements, &x.QueensRemoved, &x.ClearCount, &x.HintCount, &x.Taps,
		&x.Score, &x.ClientScore, &flawless, &x.ClientVersion, &x.PayloadHash, &x.ResponseJSON); err != nil {
		return nil, mapErr(err)
	}
	x.Completed = completed != 0
	x.Verified = verified != 0
	x.Flawless = flawless != 0
	return &x, nil
}

func (q *resultRepo) Get(ctx context.Context, id string) (*domain.Result, error) {
	return scanResult(q.r.QueryRowContext(ctx, `SELECT `+resultCols+` FROM results WHERE result_id = ?`, id))
}

func (q *resultRepo) Insert(ctx context.Context, x *domain.Result) error {
	_, err := q.w.ExecContext(ctx, `INSERT INTO results (`+resultCols+`)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		x.ResultID, x.PlayerID, x.LevelID, x.SessionID, x.Tier, x.RoundIndex,
		boolToInt(x.Completed), boolToInt(x.Verified), x.Schema, x.Size, x.Difficulty, x.Stars, x.ParSeconds, x.Base,
		x.StartedAt, x.FinishedAt, x.ReceivedAt, x.ElapsedSeconds, x.ClientElapsedSeconds,
		x.QueensPlaced, x.WrongPlacements, x.QueensRemoved, x.ClearCount, x.HintCount, x.Taps,
		x.Score, x.ClientScore, boolToInt(x.Flawless), x.ClientVersion, x.PayloadHash, x.ResponseJSON)
	return mapErr(err)
}

// ReplaceForfeit overwrites a stored forfeit in place when the completed run of
// the same result_id arrives afterwards. This is a client-crash path, not a
// cheat: App.record_result clears current_game in memory but only saves after
// the await, so a process death between the two rebuilds a forfeit with the
// same id on the next launch. Completed wins regardless of arrival order.
func (q *resultRepo) ReplaceForfeit(ctx context.Context, x *domain.Result) (bool, error) {
	return affected(q.w.ExecContext(ctx, `UPDATE results SET
		level_id = ?, session_id = ?, tier = ?, round_index = ?, completed = ?, verified = ?, schema = ?,
		size = ?, difficulty = ?, stars = ?, par_seconds = ?, base = ?, started_at = ?, finished_at = ?,
		received_at = ?, elapsed_seconds = ?, client_elapsed_seconds = ?, queens_placed = ?, wrong_placements = ?,
		queens_removed = ?, clear_count = ?, hint_count = ?, taps = ?, score = ?, client_score = ?, flawless = ?,
		client_version = ?, payload_hash = ?, response_json = ?
		WHERE result_id = ? AND completed = 0`,
		x.LevelID, x.SessionID, x.Tier, x.RoundIndex, boolToInt(x.Completed), boolToInt(x.Verified), x.Schema,
		x.Size, x.Difficulty, x.Stars, x.ParSeconds, x.Base, x.StartedAt, x.FinishedAt,
		x.ReceivedAt, x.ElapsedSeconds, x.ClientElapsedSeconds, x.QueensPlaced, x.WrongPlacements,
		x.QueensRemoved, x.ClearCount, x.HintCount, x.Taps, x.Score, x.ClientScore, boolToInt(x.Flawless),
		x.ClientVersion, x.PayloadHash, x.ResponseJSON, x.ResultID))
}

func (q *resultRepo) SetResponse(ctx context.Context, id, responseJSON string) error {
	_, err := q.w.ExecContext(ctx, `UPDATE results SET response_json = ? WHERE result_id = ?`, responseJSON, id)
	return mapErr(err)
}

// RoundScores returns the best `bestN` completed scores of the round, the input
// to LeagueRules.round_score.
func (q *resultRepo) RoundScores(ctx context.Context, playerID, tier string, roundIndex int64, bestN int) ([]int, error) {
	rows, err := q.r.QueryContext(ctx,
		`SELECT score FROM results
		  WHERE player_id = ? AND tier = ? AND round_index = ? AND completed = 1
		  ORDER BY score DESC LIMIT ?`, playerID, tier, roundIndex, bestN)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []int
	for rows.Next() {
		var s int
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (q *resultRepo) CountRoundGames(ctx context.Context, playerID, tier string, roundIndex int64) (int, error) {
	var n int
	err := q.r.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM results WHERE player_id = ? AND tier = ? AND round_index = ? AND completed = 1`,
		playerID, tier, roundIndex).Scan(&n)
	return n, mapErr(err)
}

// BestGame is the highest-scoring completed result of the round. Ties keep the
// earliest, matching the strict > of the GDScript.
func (q *resultRepo) BestGame(ctx context.Context, playerID, tier string, roundIndex int64) (*domain.BestGame, error) {
	var b domain.BestGame
	err := q.r.QueryRowContext(ctx,
		`SELECT level_id, score FROM results
		  WHERE player_id = ? AND tier = ? AND round_index = ? AND completed = 1
		  ORDER BY score DESC, finished_at ASC, result_id ASC LIMIT 1`,
		playerID, tier, roundIndex).Scan(&b.LevelID, &b.Score)
	if err != nil {
		if err := mapErr(err); err == domain.ErrNotFound {
			return nil, nil
		}
		return nil, mapErr(err)
	}
	return &b, nil
}
