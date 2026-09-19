package sqlite

import (
	"context"
	"fmt"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

type bestRepo struct{ r, w dbtx }

// The two board orders, quoted once so the index, the ROW_NUMBER window and the
// ORDER BY can never drift apart.
const (
	orderBest     = `score DESC, wrong_placements ASC, time_seconds ASC, achieved_at ASC, player_id ASC`
	orderFlawless = `time_seconds ASC, achieved_at ASC, player_id ASC`
)

// UpsertBest keeps the row only when the candidate sorts strictly before the
// stored one in the board order, so the leaderboard row and "my best" can never
// disagree.
func (q *bestRepo) UpsertBest(ctx context.Context, b *domain.LevelBest) (bool, error) {
	return affected(q.w.ExecContext(ctx, `INSERT INTO level_bests
		(player_id, level_id, result_id, score, wrong_placements, time_seconds, achieved_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (player_id, level_id) DO UPDATE SET
		  result_id = excluded.result_id, score = excluded.score,
		  wrong_placements = excluded.wrong_placements, time_seconds = excluded.time_seconds,
		  achieved_at = excluded.achieved_at
		WHERE excluded.score > level_bests.score
		   OR (excluded.score = level_bests.score AND excluded.wrong_placements < level_bests.wrong_placements)
		   OR (excluded.score = level_bests.score AND excluded.wrong_placements = level_bests.wrong_placements
		       AND excluded.time_seconds < level_bests.time_seconds)
		   OR (excluded.score = level_bests.score AND excluded.wrong_placements = level_bests.wrong_placements
		       AND excluded.time_seconds = level_bests.time_seconds AND excluded.achieved_at < level_bests.achieved_at)`,
		b.PlayerID, b.LevelID, b.ResultID, b.Score, b.WrongPlacements, b.TimeSeconds, b.AchievedAt))
}

// UpsertFlawless keeps each player's FASTEST CLEAN run, independently of their
// score-best row. The offline stub took the score-best entry and then filtered
// wrong == 0, which hid a player whose top-scoring run had one mistake even
// when they also had a clean run. This is a deliberate, accepted fix: strictly
// more players appear on the flawless board.
func (q *bestRepo) UpsertFlawless(ctx context.Context, b *domain.FlawlessBest) (bool, error) {
	return affected(q.w.ExecContext(ctx, `INSERT INTO level_flawless_bests
		(player_id, level_id, result_id, score, time_seconds, achieved_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT (player_id, level_id) DO UPDATE SET
		  result_id = excluded.result_id, score = excluded.score,
		  time_seconds = excluded.time_seconds, achieved_at = excluded.achieved_at
		WHERE excluded.time_seconds < level_flawless_bests.time_seconds
		   OR (excluded.time_seconds = level_flawless_bests.time_seconds
		       AND excluded.achieved_at < level_flawless_bests.achieved_at)`,
		b.PlayerID, b.LevelID, b.ResultID, b.Score, b.TimeSeconds, b.AchievedAt))
}

func (q *bestRepo) MyBest(ctx context.Context, playerID, levelID string) (*domain.LevelBest, error) {
	var b domain.LevelBest
	err := q.r.QueryRowContext(ctx,
		`SELECT player_id, level_id, result_id, score, wrong_placements, time_seconds, achieved_at
		   FROM level_bests WHERE player_id = ? AND level_id = ?`, playerID, levelID).
		Scan(&b.PlayerID, &b.LevelID, &b.ResultID, &b.Score, &b.WrongPlacements, &b.TimeSeconds, &b.AchievedAt)
	if err != nil {
		return nil, mapErr(err)
	}
	return &b, nil
}

func (q *bestRepo) MyFlawless(ctx context.Context, playerID, levelID string) (*domain.FlawlessBest, error) {
	var b domain.FlawlessBest
	err := q.r.QueryRowContext(ctx,
		`SELECT player_id, level_id, result_id, score, time_seconds, achieved_at
		   FROM level_flawless_bests WHERE player_id = ? AND level_id = ?`, playerID, levelID).
		Scan(&b.PlayerID, &b.LevelID, &b.ResultID, &b.Score, &b.TimeSeconds, &b.AchievedAt)
	if err != nil {
		return nil, mapErr(err)
	}
	return &b, nil
}

// scopeSQL builds the table, the eligibility predicate and its arguments.
// Shadow-excluded players are hidden from the global and flawless boards but
// stay visible to their own friends and to themselves: hiding them from a
// friend's list generates support mail from the friend.
func scopeSQL(q domain.BoardQuery) (table, where string, args []any) {
	switch q.Scope {
	case domain.ScopeFriends:
		in := placeholders(len(q.FriendIDs) + 1)
		args = append(args, q.LevelID, q.Me)
		for _, f := range q.FriendIDs {
			args = append(args, f)
		}
		return "level_bests", fmt.Sprintf(`b.level_id = ? AND b.player_id IN (%s)`, in), args
	case domain.ScopeFlawless:
		return "level_flawless_bests", `b.level_id = ? AND (p.shadow_excluded = 0 OR b.player_id = ?)`,
			[]any{q.LevelID, q.Me}
	default:
		return "level_bests", `b.level_id = ? AND (p.shadow_excluded = 0 OR b.player_id = ?)`,
			[]any{q.LevelID, q.Me}
	}
}

func (q *bestRepo) Board(ctx context.Context, bq domain.BoardQuery) ([]domain.LeaderboardEntry, error) {
	table, where, args := scopeSQL(bq)
	order := orderBest
	cols := `b.score, b.time_seconds, b.wrong_placements, b.achieved_at`
	if bq.Scope == domain.ScopeFlawless {
		order = orderFlawless
		cols = `b.score, b.time_seconds, 0 AS wrong_placements, b.achieved_at`
	}
	// The window ranks the whole eligible set, so ranks stay absolute after LIMIT.
	sqlStr := fmt.Sprintf(`
		SELECT ROW_NUMBER() OVER (ORDER BY %s) AS rn, b.player_id, p.nickname, %s,
		       CASE WHEN f.friend_id IS NULL THEN 0 ELSE 1 END AS is_friend
		  FROM %s b
		  JOIN players p ON p.id = b.player_id
		  LEFT JOIN friends f ON f.player_id = ? AND f.friend_id = b.player_id
		 WHERE %s
		 ORDER BY %s
		 LIMIT ?`, prefixCols(order), cols, table, where, prefixCols(order))
	full := append([]any{bq.Me}, args...)
	full = append(full, bq.Limit)
	rows, err := q.r.QueryContext(ctx, sqlStr, full...)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []domain.LeaderboardEntry
	for rows.Next() {
		var e domain.LeaderboardEntry
		var isFriend int
		if err := rows.Scan(&e.Rank, &e.PlayerID, &e.Nickname, &e.Score, &e.TimeSeconds,
			&e.WrongPlacements, &e.AchievedAt, &isFriend); err != nil {
			return nil, err
		}
		e.IsFriend = isFriend != 0
		e.IsMe = e.PlayerID == bq.Me
		out = append(out, e)
	}
	return out, rows.Err()
}

// prefixCols qualifies the bare column list with the b alias.
func prefixCols(order string) string {
	switch order {
	case orderBest:
		return `b.score DESC, b.wrong_placements ASC, b.time_seconds ASC, b.achieved_at ASC, b.player_id ASC`
	default:
		return `b.time_seconds ASC, b.achieved_at ASC, b.player_id ASC`
	}
}

// Rank is COUNT(*)+1 of strictly-better rows, spelled out as a lexicographic
// OR-chain. SQLite row-value comparison ((a,b,c) < (x,y,z)) would be wrong here
// because the keys mix ASC and DESC -- exactly the sort of bug nobody notices
// for months.
func (q *bestRepo) Rank(ctx context.Context, bq domain.BoardQuery) (int, error) {
	table, where, args := scopeSQL(bq)
	if bq.Scope == domain.ScopeFlawless {
		me, err := q.MyFlawless(ctx, bq.Me, bq.LevelID)
		if err == domain.ErrNotFound {
			return 0, nil
		}
		if err != nil {
			return 0, err
		}
		full := append([]any{}, args...)
		full = append(full, me.TimeSeconds, me.TimeSeconds, me.AchievedAt,
			me.TimeSeconds, me.AchievedAt, me.PlayerID)
		var n int
		err = q.r.QueryRowContext(ctx, fmt.Sprintf(`
			SELECT COUNT(*) + 1 FROM %s b JOIN players p ON p.id = b.player_id
			 WHERE %s AND (b.time_seconds < ?
			    OR (b.time_seconds = ? AND b.achieved_at < ?)
			    OR (b.time_seconds = ? AND b.achieved_at = ? AND b.player_id < ?))`, table, where), full...).Scan(&n)
		return n, mapErr(err)
	}
	me, err := q.MyBest(ctx, bq.Me, bq.LevelID)
	if err == domain.ErrNotFound {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	full := append([]any{}, args...)
	full = append(full,
		me.Score,
		me.Score, me.WrongPlacements,
		me.Score, me.WrongPlacements, me.TimeSeconds,
		me.Score, me.WrongPlacements, me.TimeSeconds, me.AchievedAt,
		me.Score, me.WrongPlacements, me.TimeSeconds, me.AchievedAt, me.PlayerID)
	var n int
	err = q.r.QueryRowContext(ctx, fmt.Sprintf(`
		SELECT COUNT(*) + 1 FROM %s b JOIN players p ON p.id = b.player_id
		 WHERE %s AND (b.score > ?
		    OR (b.score = ? AND b.wrong_placements < ?)
		    OR (b.score = ? AND b.wrong_placements = ? AND b.time_seconds < ?)
		    OR (b.score = ? AND b.wrong_placements = ? AND b.time_seconds = ? AND b.achieved_at < ?)
		    OR (b.score = ? AND b.wrong_placements = ? AND b.time_seconds = ? AND b.achieved_at = ?
		        AND b.player_id < ?))`, table, where), full...).Scan(&n)
	return n, mapErr(err)
}

func (q *bestRepo) Total(ctx context.Context, bq domain.BoardQuery) (int, error) {
	table, where, args := scopeSQL(bq)
	var n int
	err := q.r.QueryRowContext(ctx, fmt.Sprintf(
		`SELECT COUNT(*) FROM %s b JOIN players p ON p.id = b.player_id WHERE %s`, table, where), args...).Scan(&n)
	return n, mapErr(err)
}
