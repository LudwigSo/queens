package service

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/google/uuid"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

// catchUp brings one player's league state up to now. It runs first inside the
// transaction of POST /games and POST /results, and in its own transaction
// before the read-only league endpoints.
//
// Both a ticker and this lazy path close rounds, ticker primary. The lazy path
// is what makes a cold start, a crashed ticker and a suspended machine all
// self-heal; once the ticker has run it is a single indexed SELECT that returns
// nothing.
func (s *Service) catchUp(ctx context.Context, r store.Repos, playerID string) (*domain.Player, error) {
	p, err := r.Players.Get(ctx, playerID)
	if err != nil {
		return nil, err
	}
	// 1. Close any round of my tier that has ended.
	due, err := r.League.DueRounds(ctx, s.now(), p.Tier)
	if err != nil {
		return nil, err
	}
	for _, round := range due {
		if err := s.closeRoundInTx(ctx, r, round); err != nil {
			return nil, err
		}
	}
	if len(due) > 0 {
		if p, err = r.Players.Get(ctx, playerID); err != nil { // the close may have moved me
			return nil, err
		}
	}

	// 2. Collapse the rounds I was absent for.
	//
	// The stub loops one round per missed round; three years away is 156
	// iterations (365 in Bronze). Instead compute the outcome once: if it is
	// frozen, write one summary; if it is relegate, walk down, which is bounded
	// by the tier count because the Gold floor turns every further miss into a
	// no-op, and write one summary naming the original and the final tier. The
	// client only ever shows the latest unseen summary anyway.
	//
	// None of the missed rounds can have a membership row for me: a membership
	// needs POST /games, which runs this step first, and a membership in an
	// ended round was settled in step 1.
	tierCfg, err := s.tier(p.Tier)
	if err != nil {
		return nil, err
	}
	idxNow := domain.RoundIndex(tierCfg, s.now())
	missed := idxNow - domain.RoundIndex(tierCfg, p.SettledRoundEnd)
	if missed <= 0 {
		return p, nil
	}

	tierBefore := p.Tier
	pointsBefore := p.TierPoints
	outcome := domain.InactiveOutcome(tierCfg)
	cur := tierCfg
	if outcome == domain.OutcomeInactiveRelegated {
		steps := 0
		for missed > 0 && steps < len(s.League.Tiers) {
			if domain.InactiveOutcome(cur) != domain.OutcomeInactiveRelegated {
				break
			}
			nextID := s.League.RelegateTier(cur.ID)
			if nextID == cur.ID { // a floor tier: every further miss is a no-op
				break
			}
			if cur, err = s.tier(nextID); err != nil {
				return nil, err
			}
			missed--
			steps++
		}
	}
	tierAfter := cur.ID

	beforeCfg, err := s.tier(tierBefore)
	if err != nil {
		return nil, err
	}
	sum := &domain.Summary{
		ID: uuid.NewString(), PlayerID: p.ID,
		TierBefore: tierBefore, RoundIndex: domain.RoundIndex(beforeCfg, s.now()) - 1,
		TierAfter: tierAfter, Outcome: outcome, Reason: domain.ReasonRound,
		TierPoints: pointsBefore, CreatedAt: s.now(),
	}
	if _, err := r.League.InsertSummary(ctx, sum); err != nil {
		return nil, err
	}
	afterCfg, err := s.tier(tierAfter)
	if err != nil {
		return nil, err
	}
	settled := domain.RoundStart(afterCfg, domain.RoundIndex(afterCfg, s.now()))
	ok, err := r.Players.SetTier(ctx, p.ID, tierBefore, tierAfter, s.now(), settled)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, domain.ErrRetry
	}
	return r.Players.Get(ctx, p.ID)
}

// CatchUp runs the lazy catch-up in its own transaction, for the read endpoints.
func (s *Service) CatchUp(ctx context.Context, playerID string) error {
	return s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		_, err := s.catchUp(ctx, r, playerID)
		return err
	})
}

// CloseDueRounds is the ticker entry point: every tier, every overdue round.
func (s *Service) CloseDueRounds(ctx context.Context) error {
	var due []domain.Round
	if err := s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		var err error
		due, err = r.League.DueRounds(ctx, s.now(), "")
		return err
	}); err != nil {
		return err
	}
	for _, round := range due {
		if err := s.CloseRound(ctx, round); err != nil {
			slog.Error("closing round failed", "tier", round.Tier, "round", round.RoundIndex, "err", err)
		}
	}
	return nil
}

// CloseRound closes one round in several transactions: the claim, then one per
// group, then the finish. A Diamond round must not hold the write lock for a
// minute, and a crash resumes exactly where it stopped.
func (s *Service) CloseRound(ctx context.Context, round domain.Round) error {
	if err := s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		return s.claimRound(ctx, r, round)
	}); err != nil {
		return err
	}
	for {
		var groups []domain.Group
		if err := s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
			var err error
			groups, err = r.League.OpenGroups(ctx, round.Tier, round.RoundIndex)
			return err
		}); err != nil {
			return err
		}
		if len(groups) == 0 {
			break
		}
		for _, g := range groups {
			g := g
			if err := s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
				return s.closeGroup(ctx, r, round, g)
			}); err != nil {
				return err
			}
		}
	}
	return s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		return r.League.FinishRound(ctx, round.Tier, round.RoundIndex, s.now())
	})
}

// closeRoundInTx is the lazy path: it runs inside the caller's transaction, so
// a player who returns after a crash settles their own round immediately.
func (s *Service) closeRoundInTx(ctx context.Context, r store.Repos, round domain.Round) error {
	if err := s.claimRound(ctx, r, round); err != nil {
		return err
	}
	groups, err := r.League.OpenGroups(ctx, round.Tier, round.RoundIndex)
	if err != nil {
		return err
	}
	for _, g := range groups {
		if err := s.closeGroup(ctx, r, round, g); err != nil {
			return err
		}
	}
	return r.League.FinishRound(ctx, round.Tier, round.RoundIndex, s.now())
}

// claimRound takes ownership of a close and freezes the population counts, so
// every group of the round and every resumed close see the same numbers.
func (s *Service) claimRound(ctx context.Context, r store.Repos, round domain.Round) error {
	fresh, err := r.League.GetRound(ctx, round.Tier, round.RoundIndex)
	if err != nil {
		return err
	}
	if fresh.State == domain.RoundClosed {
		return nil
	}
	if fresh.State == domain.RoundClosing {
		return nil // resume: the counts are already frozen
	}
	frozen, err := s.freezeCounts(ctx, r, *fresh)
	if err != nil {
		return err
	}
	if _, err := r.League.ClaimRound(ctx, round.Tier, round.RoundIndex, s.now(), frozen); err != nil {
		return err
	}
	return nil
}

// freezeCounts computes the numbers that must not move while a round closes.
//
// Openings() is a pure function of the two population counts, so it already
// accounts for the capped tier's own relegation analytically: TIER CLOSE ORDER
// DOES NOT MATTER. It only stays true if both tiers see the SAME two counts,
// which is why whichever of Diamond/Challenger claims second reuses the pair its
// sibling round already froze.
func (s *Service) freezeCounts(ctx context.Context, r store.Repos, round domain.Round) (domain.FrozenCounts, error) {
	t, err := s.tier(round.Tier)
	if err != nil {
		return domain.FrozenCounts{}, err
	}
	var belowID, cappedID string
	switch {
	case t.UpMode == domain.UpModeOpenings:
		belowID, cappedID = t.ID, s.League.PromoteTier(t.ID)
	case t.IsCapped():
		belowID, cappedID = s.League.RelegateTier(t.ID), t.ID
	default:
		return domain.FrozenCounts{}, nil
	}
	if belowID == cappedID {
		return domain.FrozenCounts{}, nil
	}
	capped, err := s.tier(cappedID)
	if err != nil {
		return domain.FrozenCounts{}, err
	}

	var below, in int
	sibling := belowID
	if t.ID == belowID {
		sibling = cappedID
	}
	sib, err := r.League.RoundEndingAt(ctx, sibling, round.EndsAt)
	if err != nil && err != domain.ErrNotFound {
		return domain.FrozenCounts{}, err
	}
	if sib != nil && sib.State != domain.RoundOpen && sib.BelowPlayers != nil && sib.MembersInTier != nil {
		below, in = *sib.BelowPlayers, *sib.MembersInTier
	} else {
		if below, err = r.Players.CountByTier(ctx, belowID); err != nil {
			return domain.FrozenCounts{}, err
		}
		if in, err = r.Players.CountByTier(ctx, cappedID); err != nil {
			return domain.FrozenCounts{}, err
		}
	}
	f := domain.FrozenCounts{BelowPlayers: &below, MembersInTier: &in}
	if t.UpMode == domain.UpModeOpenings {
		up := domain.Openings(s.League, capped, below, in)
		f.UpCount = &up
	}
	return f, nil
}

// closeGroup evaluates one group and settles every member. The claim is the
// first statement, so a re-run skips groups that are already done; the summary
// insert gates the tier move, so summary and promotion are one atomic fact per
// member and a resumed close applies neither twice.
func (s *Service) closeGroup(ctx context.Context, r store.Repos, round domain.Round, g domain.Group) error {
	claimed, err := r.League.ClaimGroupClose(ctx, g.ID, s.now())
	if err != nil {
		return err
	}
	if !claimed {
		return nil
	}
	fresh, err := r.League.GetRound(ctx, round.Tier, round.RoundIndex)
	if err != nil {
		return err
	}
	tierCfg, err := s.tier(round.Tier)
	if err != nil {
		return err
	}
	members, err := r.League.GroupMembersSorted(ctx, g.ID)
	if err != nil {
		return err
	}
	ev := domain.Evaluate(members, tierCfg, s.League, fresh.UpCountOr())
	for _, m := range ev.Members {
		if err := r.League.SetMemberOutcome(ctx, m.PlayerID, round.Tier, round.RoundIndex,
			m.Rank, m.Zone, domain.OutcomeForZone(m.Zone)); err != nil {
			return err
		}
		// A member who was promoted by score mid-round keeps their rank but is
		// not settled again: they already have their summary and their new tier.
		if m.LeftAt != 0 {
			continue
		}
		outcome := domain.OutcomeForZone(m.Zone)
		after := s.League.Apply(round.Tier, outcome)
		pl, err := r.Players.Get(ctx, m.PlayerID)
		if err != nil {
			return err
		}
		best, err := r.Results.BestGame(ctx, m.PlayerID, round.Tier, round.RoundIndex)
		if err != nil {
			return err
		}
		inserted, err := r.League.InsertSummary(ctx, &domain.Summary{
			ID: uuid.NewString(), PlayerID: m.PlayerID, TierBefore: round.Tier, RoundIndex: round.RoundIndex,
			TierAfter: after, Outcome: outcome, Reason: domain.ReasonRound,
			Rank: m.Rank, GroupSize: len(ev.Members), RoundScore: m.RoundScore,
			TierPoints: pl.TierPoints, BestGame: best, CreatedAt: s.now(),
		})
		if err != nil {
			return err
		}
		if !inserted {
			continue // settled by an earlier attempt
		}
		afterCfg, err := s.tier(after)
		if err != nil {
			return err
		}
		settled := domain.RoundStart(afterCfg, domain.RoundIndex(afterCfg, round.EndsAt))
		ok, err := r.Players.SetTier(ctx, m.PlayerID, round.Tier, after, round.EndsAt, settled)
		if err != nil {
			return err
		}
		if !ok {
			slog.Warn("member moved tier before the close applied", "player_id", m.PlayerID, "tier", round.Tier)
		}
	}
	return nil
}

// ensureMembership joins the player to the open round of their tier, creating
// the group when needed. It is idempotent: an existing membership is returned
// unchanged, so every later start is one read.
func (s *Service) ensureMembership(ctx context.Context, r store.Repos, p *domain.Player, tierCfg domain.Tier, idx int64) (*domain.Member, bool, error) {
	m, err := r.League.GetMember(ctx, p.ID, tierCfg.ID, idx)
	if err == nil {
		return m, false, nil
	}
	if err != domain.ErrNotFound {
		return nil, false, err
	}

	// Clear a stale shadow exclusion before choosing the group, so a player whose
	// score has decayed rejoins the ordinary population at the next start.
	quarantine := p.ShadowExcluded
	if p.ShadowExcluded {
		score, updatedAt, _, err := r.Flags.ReadAnomaly(ctx, p.ID)
		if err != nil {
			return nil, false, err
		}
		if domain.DecayAnomaly(score, updatedAt, s.now()) < domain.AnomalyClearAt {
			if err := r.Flags.WriteAnomaly(ctx, p.ID, score, updatedAt, false); err != nil {
				return nil, false, err
			}
			quarantine = false
		}
	}

	g, err := r.League.FindOpenGroup(ctx, tierCfg.ID, idx, quarantine)
	if err != nil && err != domain.ErrNotFound {
		return nil, false, err
	}
	var groupID string
	if g != nil {
		ok, err := r.League.IncGroupCount(ctx, g.ID)
		if err != nil {
			return nil, false, err
		}
		if ok {
			groupID = g.ID
		}
	}
	if groupID == "" {
		seq, err := r.League.NextGroupSeq(ctx, tierCfg.ID, idx)
		if err != nil {
			return nil, false, err
		}
		// A global tier gets ONE group with no capacity: the data is
		// special-cased, not the code.
		var capacity *int
		if !tierCfg.Global {
			c := s.League.GroupSize
			capacity = &c
		}
		groupID = fmt.Sprintf("lg_%s_%d_%03d", tierCfg.ID, idx, seq)
		if err := r.League.CreateGroup(ctx, &domain.Group{
			ID: groupID, Tier: tierCfg.ID, RoundIndex: idx, Quarantine: quarantine,
			Capacity: capacity, MemberCount: 1, State: domain.RoundOpen, CreatedAt: s.now(),
		}); err != nil {
			return nil, false, err
		}
	}
	if err := r.League.InsertMember(ctx, p.ID, tierCfg.ID, idx, groupID, s.now()); err != nil {
		return nil, false, err
	}
	if err := r.Players.IncRoundsPlayed(ctx, p.ID); err != nil {
		return nil, false, err
	}
	m, err = r.League.GetMember(ctx, p.ID, tierCfg.ID, idx)
	return m, true, err
}

// ensureRound makes sure the round row exists before anything references it.
func (s *Service) ensureRound(ctx context.Context, r store.Repos, t domain.Tier, idx int64) error {
	return r.League.EnsureRound(ctx, t.ID, idx,
		domain.RoundStart(t, idx), domain.RoundEnd(t, idx), s.now())
}
