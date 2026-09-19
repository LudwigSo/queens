package sqlite

import (
	"context"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

type leagueRepo struct{ r, w dbtx }

const roundCols = `tier, round_index, starts_at, ends_at, state, group_seq, up_count, below_players,
	members_in_tier, closing_started_at, closed_at, created_at`

func scanRound(s interface{ Scan(...any) error }) (*domain.Round, error) {
	var x domain.Round
	if err := s.Scan(&x.Tier, &x.RoundIndex, &x.StartsAt, &x.EndsAt, &x.State, &x.GroupSeq,
		&x.UpCount, &x.BelowPlayers, &x.MembersInTier, &x.ClosingStartedAt, &x.ClosedAt, &x.CreatedAt); err != nil {
		return nil, mapErr(err)
	}
	return &x, nil
}

func (q *leagueRepo) EnsureRound(ctx context.Context, tier string, idx, startsAt, endsAt, now int64) error {
	_, err := q.w.ExecContext(ctx,
		`INSERT INTO league_rounds (tier, round_index, starts_at, ends_at, state, group_seq, created_at)
		 VALUES (?, ?, ?, ?, 'open', 0, ?)
		 ON CONFLICT (tier, round_index) DO NOTHING`, tier, idx, startsAt, endsAt, now)
	return mapErr(err)
}

func (q *leagueRepo) GetRound(ctx context.Context, tier string, idx int64) (*domain.Round, error) {
	return scanRound(q.r.QueryRowContext(ctx,
		`SELECT `+roundCols+` FROM league_rounds WHERE tier = ? AND round_index = ?`, tier, idx))
}

// DueRounds lists rounds past their end that are not closed yet. tier == ""
// means every tier (the ticker); a tier narrows it to the lazy catch-up.
func (q *leagueRepo) DueRounds(ctx context.Context, now int64, tier string) ([]domain.Round, error) {
	sqlStr := `SELECT ` + roundCols + ` FROM league_rounds WHERE state IN ('open','closing') AND ends_at <= ?`
	args := []any{now}
	if tier != "" {
		sqlStr += ` AND tier = ?`
		args = append(args, tier)
	}
	sqlStr += ` ORDER BY ends_at ASC, tier ASC, round_index ASC`
	rows, err := q.r.QueryContext(ctx, sqlStr, args...)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []domain.Round
	for rows.Next() {
		x, err := scanRound(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *x)
	}
	return out, rows.Err()
}

// RoundEndingAt finds the round of another tier that ends at the same instant.
// The Diamond and Challenger closers share their frozen population counts
// through it, which is what makes Openings() order-independent in practice.
func (q *leagueRepo) RoundEndingAt(ctx context.Context, tier string, endsAt int64) (*domain.Round, error) {
	return scanRound(q.r.QueryRowContext(ctx,
		`SELECT `+roundCols+` FROM league_rounds WHERE tier = ? AND ends_at = ?
		 ORDER BY round_index DESC LIMIT 1`, tier, endsAt))
}

// ClaimRound is the exactly-once guard: RowsAffected == 1 means you own the
// close. The frozen counts are written by the claimant only.
func (q *leagueRepo) ClaimRound(ctx context.Context, tier string, idx, now int64, f domain.FrozenCounts) (bool, error) {
	return affected(q.w.ExecContext(ctx,
		`UPDATE league_rounds SET state = 'closing', closing_started_at = ?,
		        up_count = ?, below_players = ?, members_in_tier = ?
		  WHERE tier = ? AND round_index = ? AND state = 'open'`,
		now, f.UpCount, f.BelowPlayers, f.MembersInTier, tier, idx))
}

func (q *leagueRepo) FinishRound(ctx context.Context, tier string, idx, now int64) error {
	_, err := q.w.ExecContext(ctx,
		`UPDATE league_rounds SET state = 'closed', closed_at = ? WHERE tier = ? AND round_index = ? AND state = 'closing'`,
		now, tier, idx)
	return mapErr(err)
}

func (q *leagueRepo) NextGroupSeq(ctx context.Context, tier string, idx int64) (int, error) {
	if _, err := q.w.ExecContext(ctx,
		`UPDATE league_rounds SET group_seq = group_seq + 1 WHERE tier = ? AND round_index = ?`, tier, idx); err != nil {
		return 0, mapErr(err)
	}
	var seq int
	err := q.r.QueryRowContext(ctx,
		`SELECT group_seq FROM league_rounds WHERE tier = ? AND round_index = ?`, tier, idx).Scan(&seq)
	return seq, mapErr(err)
}

const groupCols = `id, tier, round_index, quarantine, capacity, member_count, state, closed_at, created_at`

func scanGroup(s interface{ Scan(...any) error }) (*domain.Group, error) {
	var g domain.Group
	var quarantine int
	if err := s.Scan(&g.ID, &g.Tier, &g.RoundIndex, &quarantine, &g.Capacity, &g.MemberCount,
		&g.State, &g.ClosedAt, &g.CreatedAt); err != nil {
		return nil, mapErr(err)
	}
	g.Quarantine = quarantine != 0
	return &g, nil
}

// FindOpenGroup packs fill-first, not spread: with 47 players a spread policy
// gives two groups of ~23 and dilutes every percentage rule, while fill-first
// gives 30 + 17, both above the min_group_size cliff, and the 30 behaves exactly
// like the tested case.
func (q *leagueRepo) FindOpenGroup(ctx context.Context, tier string, idx int64, quarantine bool) (*domain.Group, error) {
	return scanGroup(q.r.QueryRowContext(ctx,
		`SELECT `+groupCols+` FROM league_groups
		  WHERE tier = ? AND round_index = ? AND quarantine = ? AND state = 'open'
		    AND (capacity IS NULL OR member_count < capacity)
		  ORDER BY member_count DESC, id ASC LIMIT 1`, tier, idx, boolToInt(quarantine)))
}

func (q *leagueRepo) CreateGroup(ctx context.Context, g *domain.Group) error {
	_, err := q.w.ExecContext(ctx, `INSERT INTO league_groups
		(id, tier, round_index, quarantine, capacity, member_count, state, closed_at, created_at)
		VALUES (?, ?, ?, ?, ?, ?, 'open', NULL, ?)`,
		g.ID, g.Tier, g.RoundIndex, boolToInt(g.Quarantine), g.Capacity, g.MemberCount, g.CreatedAt)
	return mapErr(err)
}

// IncGroupCount is conditional so the capacity can never be exceeded. Under the
// single SQLite writer it cannot fail; the check is what a Postgres port needs.
func (q *leagueRepo) IncGroupCount(ctx context.Context, groupID string) (bool, error) {
	return affected(q.w.ExecContext(ctx,
		`UPDATE league_groups SET member_count = member_count + 1
		  WHERE id = ? AND state = 'open' AND (capacity IS NULL OR member_count < capacity)`, groupID))
}

func (q *leagueRepo) DecGroupCountsForPlayer(ctx context.Context, playerID string) error {
	_, err := q.w.ExecContext(ctx,
		`UPDATE league_groups SET member_count = member_count - 1
		  WHERE state = 'open'
		    AND id IN (SELECT group_id FROM league_members WHERE player_id = ? AND left_at IS NULL)`, playerID)
	return mapErr(err)
}

func (q *leagueRepo) OpenGroups(ctx context.Context, tier string, idx int64) ([]domain.Group, error) {
	rows, err := q.r.QueryContext(ctx,
		`SELECT `+groupCols+` FROM league_groups WHERE tier = ? AND round_index = ? AND state = 'open' ORDER BY id ASC`,
		tier, idx)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []domain.Group
	for rows.Next() {
		g, err := scanGroup(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *g)
	}
	return out, rows.Err()
}

// ClaimGroupClose must be the first statement of a group-close transaction, so a
// crash resumes exactly where it stopped.
func (q *leagueRepo) ClaimGroupClose(ctx context.Context, groupID string, now int64) (bool, error) {
	return affected(q.w.ExecContext(ctx,
		`UPDATE league_groups SET state = 'closed', closed_at = ? WHERE id = ? AND state = 'open'`, now, groupID))
}

func (q *leagueRepo) GetGroup(ctx context.Context, groupID string) (*domain.Group, error) {
	return scanGroup(q.r.QueryRowContext(ctx, `SELECT `+groupCols+` FROM league_groups WHERE id = ?`, groupID))
}

func (q *leagueRepo) GetMember(ctx context.Context, playerID, tier string, idx int64) (*domain.Member, error) {
	var m domain.Member
	var leftAt *int64
	err := q.r.QueryRowContext(ctx,
		`SELECT lm.player_id, p.nickname, lm.group_id, lm.round_score, lm.games, lm.last_submit_at, lm.left_at
		   FROM league_members lm JOIN players p ON p.id = lm.player_id
		  WHERE lm.player_id = ? AND lm.tier = ? AND lm.round_index = ?`, playerID, tier, idx).
		Scan(&m.PlayerID, &m.Nickname, &m.GroupID, &m.RoundScore, &m.Games, &m.LastSubmitAt, &leftAt)
	if err != nil {
		return nil, mapErr(err)
	}
	if leftAt != nil {
		m.LeftAt = *leftAt
	}
	return &m, nil
}

func (q *leagueRepo) InsertMember(ctx context.Context, playerID, tier string, idx int64, groupID string, now int64) error {
	_, err := q.w.ExecContext(ctx,
		`INSERT INTO league_members (player_id, tier, round_index, group_id, joined_at)
		 VALUES (?, ?, ?, ?, ?)`, playerID, tier, idx, groupID, now)
	return mapErr(err)
}

func (q *leagueRepo) UpdateMemberScore(ctx context.Context, playerID, tier string, idx int64, roundScore, games int, lastSubmitAt int64) error {
	_, err := q.w.ExecContext(ctx,
		`UPDATE league_members SET round_score = ?, games = ?, last_submit_at = ?
		  WHERE player_id = ? AND tier = ? AND round_index = ?`,
		roundScore, games, lastSubmitAt, playerID, tier, idx)
	return mapErr(err)
}

// MarkMemberLeft records a mid-round promotion by score. The row stays: other
// members' ranks depend on it and the score was real. The closer skips it.
func (q *leagueRepo) MarkMemberLeft(ctx context.Context, playerID, tier string, idx, now int64) error {
	_, err := q.w.ExecContext(ctx,
		`UPDATE league_members SET left_at = ? WHERE player_id = ? AND tier = ? AND round_index = ?`,
		now, playerID, tier, idx)
	return mapErr(err)
}

// The sort keys, spelled twice: unqualified for single-table queries and
// qualified for the ones that join players, which also has a `games` column.
const memberSort = `round_score DESC, games ASC, last_submit_at ASC, player_id ASC`
const memberSortQ = `lm.round_score DESC, lm.games ASC, lm.last_submit_at ASC, lm.player_id ASC`

func (q *leagueRepo) GroupMembersSorted(ctx context.Context, groupID string) ([]domain.Member, error) {
	rows, err := q.r.QueryContext(ctx,
		`SELECT lm.player_id, p.nickname, lm.round_score, lm.games, lm.last_submit_at, lm.left_at
		   FROM league_members lm JOIN players p ON p.id = lm.player_id
		  WHERE lm.group_id = ? ORDER BY `+memberSortQ, groupID)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []domain.Member
	for rows.Next() {
		var m domain.Member
		var leftAt *int64
		if err := rows.Scan(&m.PlayerID, &m.Nickname, &m.RoundScore, &m.Games, &m.LastSubmitAt, &leftAt); err != nil {
			return nil, err
		}
		if leftAt != nil {
			m.LeftAt = *leftAt
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (q *leagueRepo) GroupLeaderScore(ctx context.Context, groupID string) (int, error) {
	var n int
	err := q.r.QueryRowContext(ctx,
		`SELECT COALESCE(MAX(round_score), 0) FROM league_members WHERE group_id = ?`, groupID).Scan(&n)
	return n, mapErr(err)
}

// GroupPromoteCount counts how many of the top `up` rows actually have a score,
// mirroring the rule that a zero round_score never promotes.
func (q *leagueRepo) GroupPromoteCount(ctx context.Context, groupID string, up int) (int, error) {
	if up <= 0 {
		return 0, nil
	}
	var n int
	err := q.r.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM (SELECT round_score FROM league_members WHERE group_id = ?
		    ORDER BY `+memberSort+` LIMIT ?) t WHERE t.round_score > 0`, groupID, up).Scan(&n)
	return n, mapErr(err)
}

func (q *leagueRepo) MemberRank(ctx context.Context, groupID string, m *domain.Member) (int, error) {
	var n int
	err := q.r.QueryRowContext(ctx, `
		SELECT COUNT(*) + 1 FROM league_members
		 WHERE group_id = ?
		   AND (round_score > ?
		     OR (round_score = ? AND games < ?)
		     OR (round_score = ? AND games = ? AND last_submit_at < ?)
		     OR (round_score = ? AND games = ? AND last_submit_at = ? AND player_id < ?))`,
		groupID, m.RoundScore, m.RoundScore, m.Games, m.RoundScore, m.Games, m.LastSubmitAt,
		m.RoundScore, m.Games, m.LastSubmitAt, m.PlayerID).Scan(&n)
	return n, mapErr(err)
}

// StandingWindow returns the top rows plus a window around me plus my own row,
// with absolute ranks from the window function. A global tier can hold thousands
// of members; the client renders at most 100 and needs my row present.
func (q *leagueRepo) StandingWindow(ctx context.Context, groupID, me string, top, lo, hi int) ([]domain.Member, error) {
	rows, err := q.r.QueryContext(ctx, `
		WITH ranked AS (
		  SELECT lm.player_id, lm.round_score, lm.games, lm.last_submit_at,
		         ROW_NUMBER() OVER (ORDER BY `+memberSortQ+`) AS rn
		    FROM league_members lm WHERE lm.group_id = ?)
		SELECT r.player_id, p.nickname, r.round_score, r.games, r.last_submit_at, r.rn,
		       CASE WHEN f.friend_id IS NULL THEN 0 ELSE 1 END AS is_friend
		  FROM ranked r
		  JOIN players p ON p.id = r.player_id
		  LEFT JOIN friends f ON f.player_id = ? AND f.friend_id = r.player_id
		 WHERE r.rn <= ? OR (r.rn BETWEEN ? AND ?) OR r.player_id = ?
		 ORDER BY r.rn`, groupID, me, top, lo, hi, me)
	if err != nil {
		return nil, mapErr(err)
	}
	defer rows.Close()
	var out []domain.Member
	for rows.Next() {
		var m domain.Member
		var isFriend int
		if err := rows.Scan(&m.PlayerID, &m.Nickname, &m.RoundScore, &m.Games, &m.LastSubmitAt, &m.Rank, &isFriend); err != nil {
			return nil, err
		}
		m.IsFriend = isFriend != 0
		m.IsMe = m.PlayerID == me
		out = append(out, m)
	}
	return out, rows.Err()
}

func (q *leagueRepo) SetMemberOutcome(ctx context.Context, playerID, tier string, idx int64, rank int, zone, outcome string) error {
	_, err := q.w.ExecContext(ctx,
		`UPDATE league_members SET final_rank = ?, final_zone = ?, outcome = ?
		  WHERE player_id = ? AND tier = ? AND round_index = ?`, rank, zone, outcome, playerID, tier, idx)
	return mapErr(err)
}

// InsertSummary returns false when a summary for this (player, tier, round,
// reason) already exists. That makes the closer idempotent: summary and tier
// move are one atomic fact per member, and a re-run applies neither twice.
func (q *leagueRepo) InsertSummary(ctx context.Context, s *domain.Summary) (bool, error) {
	var bestLevel *string
	var bestScore *int
	if s.BestGame != nil {
		bestLevel = &s.BestGame.LevelID
		bestScore = &s.BestGame.Score
	}
	return affected(q.w.ExecContext(ctx, `INSERT INTO round_summaries
		(id, player_id, tier_before, round_index, tier_after, outcome, reason, rank, group_size,
		 round_score, tier_points, best_level_id, best_score, seen, seen_at, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?)
		ON CONFLICT (player_id, tier_before, round_index, reason) DO NOTHING`,
		s.ID, s.PlayerID, s.TierBefore, s.RoundIndex, s.TierAfter, s.Outcome, s.Reason, s.Rank, s.GroupSize,
		s.RoundScore, s.TierPoints, bestLevel, bestScore, s.CreatedAt))
}

func (q *leagueRepo) LatestUnseenSummary(ctx context.Context, playerID string) (*domain.Summary, error) {
	var s domain.Summary
	var bestLevel *string
	var bestScore *int
	var seen int
	err := q.r.QueryRowContext(ctx,
		`SELECT id, player_id, tier_before, round_index, tier_after, outcome, reason, rank, group_size,
		        round_score, tier_points, best_level_id, best_score, seen, seen_at, created_at
		   FROM round_summaries WHERE player_id = ? AND seen = 0
		  ORDER BY created_at DESC, id DESC LIMIT 1`, playerID).
		Scan(&s.ID, &s.PlayerID, &s.TierBefore, &s.RoundIndex, &s.TierAfter, &s.Outcome, &s.Reason,
			&s.Rank, &s.GroupSize, &s.RoundScore, &s.TierPoints, &bestLevel, &bestScore, &seen, &s.SeenAt, &s.CreatedAt)
	if err != nil {
		if mapErr(err) == domain.ErrNotFound {
			return nil, nil
		}
		return nil, mapErr(err)
	}
	s.Seen = seen != 0
	if bestLevel != nil && bestScore != nil {
		s.BestGame = &domain.BestGame{LevelID: *bestLevel, Score: *bestScore}
	}
	return &s, nil
}

// AckSummary marks the newest unseen summary seen only when its index matches,
// exactly like local_backend.gd. A mismatch is silently ignored: the call never
// errors.
func (q *leagueRepo) AckSummary(ctx context.Context, playerID string, roundIndex, now int64) error {
	_, err := q.w.ExecContext(ctx,
		`UPDATE round_summaries SET seen = 1, seen_at = ?
		  WHERE id = (SELECT id FROM round_summaries WHERE player_id = ? AND seen = 0
		              ORDER BY created_at DESC, id DESC LIMIT 1)
		    AND round_index = ?`, now, playerID, roundIndex)
	return mapErr(err)
}

func (q *leagueRepo) CountSummaries(ctx context.Context, playerID string) (int, error) {
	var n int
	err := q.r.QueryRowContext(ctx, `SELECT COUNT(*) FROM round_summaries WHERE player_id = ?`, playerID).Scan(&n)
	return n, mapErr(err)
}
