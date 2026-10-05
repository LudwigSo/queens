package service

import (
	"context"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

// --- GET /v1/league/runs ----------------------------------------------------

// RunView is one completed game of the current round, with everything the
// client's win screen needs to show it again.
type RunView struct {
	ResultID        string                `json:"result_id"`
	LevelID         string                `json:"level_id"`
	Size            int                   `json:"size"`
	Difficulty      float64               `json:"difficulty"`
	Stars           int                   `json:"stars"`
	Score           int                   `json:"score"`
	Counted         bool                  `json:"counted" doc:"False: the game missed the online rule and is not part of the round score."`
	InBest          bool                  `json:"in_best" doc:"One of the best N games that make up the round score."`
	Verified        bool                  `json:"verified"`
	FinishedAt      int64                 `json:"finished_at"`
	ElapsedSeconds  float64               `json:"elapsed_seconds"`
	ParSeconds      float64               `json:"par_seconds"`
	WrongPlacements int                   `json:"wrong_placements"`
	HintCount       int                   `json:"hint_count"`
	Breakdown       domain.ScoreBreakdown `json:"breakdown"`
}

type RunsView struct {
	Tier        string    `json:"tier"`
	RoundIndex  int64     `json:"round_index"`
	HasRounds   bool      `json:"has_rounds"`
	RoundEndsAt int64     `json:"round_ends_at"`
	BestN       int       `json:"best_n" doc:"0 in a tier without rounds: every counted game adds to the tier points."`
	RoundScore  int       `json:"round_score"`
	TierPoints  int       `json:"tier_points"`
	CutScore    int       `json:"cut_score" doc:"A new game must score more than this to raise the round score; 0 while fewer than best_n games are in."`
	Runs        []RunView `json:"runs"`
}

// runsLimit caps the list: a round holds at most a few dozen games, but a
// Silver player can collect many before reaching 10000 tier points.
const runsLimit = 200

// Runs lists the games of the player's current round (or, in a tier without
// rounds, every game since entering it), best first, with the cut a new game
// has to beat.
func (s *Service) Runs(ctx context.Context, playerID string) (*RunsView, error) {
	if err := s.CatchUp(ctx, playerID); err != nil {
		return nil, err
	}
	r := s.St.Repos()
	p, err := r.Players.Get(ctx, playerID)
	if err != nil {
		return nil, err
	}
	tierCfg, err := s.tier(p.Tier)
	if err != nil {
		return nil, err
	}
	idx := domain.RoundIndex(tierCfg, s.now())
	results, err := r.Results.RoundRuns(ctx, p.ID, tierCfg.ID, idx, runsLimit)
	if err != nil {
		return nil, err
	}
	view := &RunsView{
		Tier: tierCfg.ID, RoundIndex: idx, HasRounds: tierCfg.HasRounds(),
		RoundEndsAt: domain.RoundEnd(tierCfg, idx), TierPoints: p.TierPoints, Runs: []RunView{},
	}
	bestN := 0
	if tierCfg.HasRounds() {
		bestN = s.League.RoundBestN
		if s.League.RoundMode == "sum" {
			bestN = len(results)
		}
	}
	view.BestN = bestN
	var counted []int
	inBest := 0
	for _, x := range results {
		run := RunView{
			ResultID: x.ResultID, LevelID: x.LevelID, Size: x.Size, Difficulty: float64(x.Difficulty), Stars: x.Stars,
			Score: x.Score, Counted: x.Counted, Verified: x.Verified, FinishedAt: x.FinishedAt,
			ElapsedSeconds: x.ElapsedSeconds, ParSeconds: x.ParSeconds,
			WrongPlacements: x.WrongPlacements, HintCount: x.HintCount,
			Breakdown: domain.Breakdown(float64(x.Difficulty), x.Size, x.ParSeconds, x.ElapsedSeconds,
				x.WrongPlacements, x.HintCount, true),
		}
		if x.Counted {
			counted = append(counted, x.Score)
			// The list is best first, so the first N counted games are the ones
			// in the round score. A tier without rounds counts all of them.
			if !tierCfg.HasRounds() || inBest < bestN {
				run.InBest = true
				inBest++
			}
		}
		view.Runs = append(view.Runs, run)
	}
	if tierCfg.HasRounds() {
		view.RoundScore = domain.RoundScore(counted, s.League)
		view.CutScore = domain.CutScore(counted, s.League)
	}
	return view, nil
}

// --- GET /v1/league/join-options, POST /v1/league/join ----------------------

type JoinOption struct {
	GroupID string               `json:"group_id"`
	Members int                  `json:"members" doc:"People in the group now; bots are not counted."`
	Friends []domain.FriendBrief `json:"friends"`
}

type JoinOptionsView struct {
	Tier       string       `json:"tier"`
	RoundIndex int64        `json:"round_index"`
	Joined     bool         `json:"joined" doc:"Already in a group this round: nothing to choose."`
	Options    []JoinOption `json:"options"`
}

// JoinOptions lists the friends' groups of the player's current round that
// still have room. It is what the client asks after a promotion: "Anna is in
// Gold already -- join her group?". Global tiers and tiers without rounds have
// nothing to choose.
func (s *Service) JoinOptions(ctx context.Context, playerID string) (*JoinOptionsView, error) {
	r := s.St.Repos()
	p, err := r.Players.Get(ctx, playerID)
	if err != nil {
		return nil, err
	}
	return s.joinOptionsFor(ctx, r, p)
}

func (s *Service) joinOptionsFor(ctx context.Context, r store.Repos, p *domain.Player) (*JoinOptionsView, error) {
	tierCfg, err := s.tier(p.Tier)
	if err != nil {
		return nil, err
	}
	idx := domain.RoundIndex(tierCfg, s.now())
	view := &JoinOptionsView{Tier: tierCfg.ID, RoundIndex: idx, Options: []JoinOption{}}
	if !tierCfg.HasRounds() || tierCfg.Global {
		return view, nil
	}
	if _, err := r.League.GetMember(ctx, p.ID, tierCfg.ID, idx); err == nil {
		view.Joined = true
		return view, nil
	} else if err != domain.ErrNotFound {
		return nil, err
	}
	groups, err := r.League.FriendGroups(ctx, p.ID, tierCfg.ID, idx, p.ShadowExcluded, s.League.GroupMax)
	if err != nil {
		return nil, err
	}
	for _, g := range groups {
		view.Options = append(view.Options, JoinOption{GroupID: g.GroupID, Members: g.MemberCount, Friends: g.Friends})
	}
	return view, nil
}

// JoinGroup joins the current round now, into the friends' group the player
// picked, or by the normal placement when groupID is empty. It is idempotent: a
// player who is already in a group stays where they are.
func (s *Service) JoinGroup(ctx context.Context, playerID, groupID string) (*StandingView, error) {
	err := s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		p, err := s.catchUp(ctx, r, playerID)
		if err != nil {
			return err
		}
		tierCfg, err := s.tier(p.Tier)
		if err != nil {
			return err
		}
		if !tierCfg.HasRounds() {
			return domain.Errf(409, domain.CodeGroupFull, "this tier has no groups")
		}
		idx := domain.RoundIndex(tierCfg, s.now())
		if groupID != "" {
			opts, err := s.joinOptionsFor(ctx, r, p)
			if err != nil {
				return err
			}
			if opts.Joined {
				return nil
			}
			found := false
			for _, o := range opts.Options {
				found = found || o.GroupID == groupID
			}
			if !found {
				return domain.Errf(409, domain.CodeGroupFull, "that group is full or holds no friend of yours")
			}
		}
		if err := s.ensureRound(ctx, r, tierCfg, idx); err != nil {
			return err
		}
		_, _, err = s.ensureMembership(ctx, r, p, tierCfg, idx, groupID)
		return err
	})
	if err != nil {
		return nil, err
	}
	return s.Standing(ctx, playerID)
}
