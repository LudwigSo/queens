package service

import (
	"context"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

// RulesView is the presentation-free rule set. The server sends ids and numbers
// only: tier_name and rules_text are gone, and up_to is now a TIER ID, because
// the server has no locale and must not grow a copy of the translation table.
type RulesView struct {
	UpPct      int    `json:"up_pct"`
	DownPct    int    `json:"down_pct"`
	UpCount    int    `json:"up_count"`
	UpMode     string `json:"up_mode"`
	PromoScore int    `json:"promo_score"`
	UpTo       string `json:"up_to"`
	BestN      int    `json:"best_n"`
	RoundMode  string `json:"round_mode"`
	RoundDays  int    `json:"round_days"`
	Global     bool   `json:"global"`
	Floor      bool   `json:"floor"`
}

type GroupView struct {
	GroupID       string          `json:"group_id"`
	Tier          string          `json:"tier"`
	RoundIndex    int64           `json:"round_index"`
	Size          int             `json:"size"`
	PromoteCount  int             `json:"promote_count"`
	RelegateCount int             `json:"relegate_count"`
	Members       []domain.Member `json:"members"`
}

type StandingView struct {
	Tier         string     `json:"tier"`
	RoundIndex   int64      `json:"round_index"`
	RoundDays    int        `json:"round_days"`
	RoundEndsAt  int64      `json:"round_ends_at"`
	Joined       bool       `json:"joined"`
	Group        *GroupView `json:"group,omitempty"`
	MyRank       int        `json:"my_rank"`
	MyRoundScore int        `json:"my_round_score"`
	MyGames      int        `json:"my_games"`
	Zone         string     `json:"zone,omitempty"`
	MyTierPoints int        `json:"my_tier_points"`
	Rules        RulesView  `json:"rules"`
	ConfigHash   string     `json:"config_hash"`
}

// standingMembersTop caps what a global tier sends. The client renders at most
// 100 rows anyway; ranks stay absolute because they come from a window function,
// never from a position in the truncated slice.
const standingMembersTop = 100

// Standing builds the league standing. It runs the lazy catch-up first, then
// reads.
func (s *Service) Standing(ctx context.Context, playerID string) (*StandingView, error) {
	if err := s.CatchUp(ctx, playerID); err != nil {
		return nil, err
	}
	r := s.St.Repos()
	p, err := r.Players.Get(ctx, playerID)
	if err != nil {
		return nil, err
	}
	return s.standingFor(ctx, r, p)
}

func (s *Service) standingFor(ctx context.Context, r store.Repos, p *domain.Player) (*StandingView, error) {
	tierCfg, err := s.tier(p.Tier)
	if err != nil {
		return nil, err
	}
	idx := domain.RoundIndex(tierCfg, s.now())
	upCount, err := s.upCountFor(ctx, r, tierCfg)
	if err != nil {
		return nil, err
	}
	aboveID := s.League.PromoteTier(tierCfg.ID)
	upTo := aboveID
	if aboveID == tierCfg.ID {
		upTo = ""
	}
	view := &StandingView{
		Tier: tierCfg.ID, RoundIndex: idx, RoundDays: tierCfg.RoundDays,
		RoundEndsAt: domain.RoundEnd(tierCfg, idx), MyTierPoints: p.TierPoints,
		ConfigHash: s.LeagueHash,
		Rules: RulesView{
			UpPct: tierCfg.UpPct, DownPct: tierCfg.DownPct, UpCount: upCount, UpMode: tierCfg.UpMode,
			PromoScore: tierCfg.PromoScoreOf(), UpTo: upTo, BestN: s.League.RoundBestN,
			RoundMode: s.League.RoundMode, RoundDays: tierCfg.RoundDays,
			Global: tierCfg.Global, Floor: tierCfg.Floor,
		},
	}

	me, err := r.League.GetMember(ctx, p.ID, tierCfg.ID, idx)
	if err == domain.ErrNotFound {
		// Not joined: the client renders the tier, the timer and the rules, and
		// nothing else. A promotion deliberately does not auto-join the new
		// tier's running round.
		return view, nil
	}
	if err != nil {
		return nil, err
	}
	g, err := r.League.GetGroup(ctx, me.GroupID)
	if err != nil {
		return nil, err
	}
	leader, err := r.League.GroupLeaderScore(ctx, g.ID)
	if err != nil {
		return nil, err
	}
	c := domain.Counts(g.MemberCount, tierCfg, s.League, leader, upCount)
	promote, err := r.League.GroupPromoteCount(ctx, g.ID, c.Up)
	if err != nil {
		return nil, err
	}
	myRank, err := r.League.MemberRank(ctx, g.ID, me)
	if err != nil {
		return nil, err
	}
	lo, hi := 0, 0
	if g.MemberCount > standingMembersTop {
		lo, hi = myRank-5, myRank+5
	}
	members, err := r.League.StandingWindow(ctx, g.ID, p.ID, standingMembersTop, lo, hi)
	if err != nil {
		return nil, err
	}
	for i := range members {
		members[i].Zone = zoneFor(members[i].Rank, members[i].RoundScore, g.MemberCount, c)
	}

	view.Joined = true
	view.MyRank = myRank
	view.MyRoundScore = me.RoundScore
	view.MyGames = me.Games
	view.Zone = zoneFor(myRank, me.RoundScore, g.MemberCount, c)
	view.Group = &GroupView{
		GroupID: g.ID, Tier: g.Tier, RoundIndex: g.RoundIndex, Size: g.MemberCount,
		PromoteCount: promote, RelegateCount: c.Down, Members: members,
	}
	return view, nil
}

// zoneFor mirrors the branch order of Evaluate, including the rule that a zero
// round_score in the promote band falls through to safe.
func zoneFor(rank, roundScore, n int, c domain.CountsResult) string {
	switch {
	case rank <= c.Up && roundScore > 0:
		return domain.ZonePromote
	case rank > n-c.Down:
		return domain.ZoneRelegate
	default:
		return domain.ZoneSafe
	}
}

// SummaryView is the round summary the client shows once.
type SummaryView struct {
	RoundIndex int64            `json:"round_index"`
	TierBefore string           `json:"tier_before"`
	TierAfter  string           `json:"tier_after"`
	Outcome    string           `json:"outcome"`
	Reason     string           `json:"reason"`
	Rank       int              `json:"rank"`
	GroupSize  int              `json:"group_size"`
	RoundScore int              `json:"round_score"`
	TierPoints int              `json:"tier_points"`
	BestGame   *domain.BestGame `json:"best_game,omitempty"`
	Seen       bool             `json:"seen"`
}

func summaryView(s *domain.Summary) *SummaryView {
	if s == nil {
		return nil
	}
	return &SummaryView{
		RoundIndex: s.RoundIndex, TierBefore: s.TierBefore, TierAfter: s.TierAfter,
		Outcome: s.Outcome, Reason: s.Reason, Rank: s.Rank, GroupSize: s.GroupSize,
		RoundScore: s.RoundScore, TierPoints: s.TierPoints, BestGame: s.BestGame, Seen: s.Seen,
	}
}

// RoundSummary returns the newest unseen summary, or nil (HTTP 204).
func (s *Service) RoundSummary(ctx context.Context, playerID string) (*SummaryView, error) {
	if err := s.CatchUp(ctx, playerID); err != nil {
		return nil, err
	}
	sum, err := s.St.Repos().League.LatestUnseenSummary(ctx, playerID)
	if err != nil {
		return nil, err
	}
	return summaryView(sum), nil
}

// AckRoundSummary marks the newest unseen summary seen only when its index
// matches, exactly like the offline stub. A mismatch is not an error.
func (s *Service) AckRoundSummary(ctx context.Context, playerID string, roundIndex int64) error {
	return s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		return r.League.AckSummary(ctx, playerID, roundIndex, s.now())
	})
}
