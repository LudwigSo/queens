// Package service holds the business logic. It talks to store.Repos and returns
// domain.CodedError; it knows nothing about HTTP.
package service

import (
	"context"
	"encoding/json"
	"log/slog"

	"github.com/google/uuid"
	"github.com/ludwigsonnenberg/queens-server/internal/config"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

type Service struct {
	St    store.Store
	Cfg   *config.Config
	Clock domain.Clock
	// League is the embedded shared/league.json, and LeagueHash its digest, so a
	// client can tell whether its own copy has drifted.
	League     *domain.LeagueConfig
	LeagueHash string
	// LevelSetHash is the ETag of the level table, refreshed at boot.
	LevelSetHash string
	// levels is the whole level table in memory: 100 rows that change only at
	// boot, and the ceiling check needs their base points on every submit.
	levels map[string]domain.Level

	openings openingsCache
}

func New(st store.Store, cfg *config.Config, clock domain.Clock, league *domain.LeagueConfig, leagueHash, levelSetHash string, levels []domain.Level) *Service {
	m := make(map[string]domain.Level, len(levels))
	for _, l := range levels {
		m[l.ID] = l
	}
	return &Service{
		St: st, Cfg: cfg, Clock: clock, League: league,
		LeagueHash: leagueHash, LevelSetHash: levelSetHash, levels: m,
	}
}

func (s *Service) now() int64 { return s.Clock.Now() }

// Level returns a cached level row.
func (s *Service) Level(id string) (domain.Level, bool) {
	l, ok := s.levels[id]
	return l, ok
}

func (s *Service) LevelCount() int { return len(s.levels) }

// tier looks up a tier and turns an unknown id into a 500. On the client an
// unknown tier falls back to Bronze, which is a fine default there and a
// data-corruption amplifier here.
func (s *Service) tier(id string) (domain.Tier, error) {
	t, ok := s.League.TierByID(id)
	if !ok {
		slog.Error("player has an unknown tier", "tier", id)
		return domain.Tier{}, domain.Errf(500, domain.CodeServer, "unknown tier "+id)
	}
	return t, nil
}

// flag appends an anti-cheat signal and updates the decayed anomaly score in the
// same transaction.
//
// Never reject a result because of a soft signal: a rejection tells the cheater
// which check fired and lets them binary-search the detection. Silence does not.
func (s *Service) flag(ctx context.Context, r store.Repos, playerID, signal string, weight float64, detail map[string]any, resultID, sessionID *string) error {
	now := s.now()
	var detailJSON *string
	if len(detail) > 0 {
		if b, err := json.Marshal(detail); err == nil {
			str := string(b)
			detailJSON = &str
		}
	}
	f := &domain.Flag{
		ID: uuid.NewString(), PlayerID: playerID, Signal: signal, Weight: weight,
		ResultID: resultID, SessionID: sessionID, DetailJSON: detailJSON, CreatedAt: now,
	}
	if err := r.Flags.Insert(ctx, f); err != nil {
		return err
	}
	score, updatedAt, shadow, err := r.Flags.ReadAnomaly(ctx, playerID)
	if err != nil {
		return err
	}
	next := domain.DecayAnomaly(score, updatedAt, now) + weight
	// Shadow exclusion is set automatically and cleared only on the next join,
	// so a player finishes the quarantined round they are in.
	if !shadow && next >= domain.AnomalyShadowAt {
		shadow = true
		slog.Warn("player shadow-excluded", "player_id", playerID, "anomaly", next, "signal", signal)
	}
	return r.Flags.WriteAnomaly(ctx, playerID, next, now, shadow)
}

// openingsCache memoises the Diamond up_count for 60 s while a round is open.
// It is two COUNT(*) queries, but standings are polled.
type openingsCache struct {
	tier     string
	value    int
	computed int64
}

func (s *Service) cachedOpenings(ctx context.Context, r store.Repos, below domain.Tier, capped domain.Tier) (int, error) {
	now := s.now()
	if s.openings.tier == below.ID && now-s.openings.computed < 60 {
		return s.openings.value, nil
	}
	belowN, err := r.Players.CountByTier(ctx, below.ID)
	if err != nil {
		return 0, err
	}
	inN, err := r.Players.CountByTier(ctx, capped.ID)
	if err != nil {
		return 0, err
	}
	v := domain.Openings(s.League, capped, belowN, inN)
	s.openings = openingsCache{tier: below.ID, value: v, computed: now}
	return v, nil
}

// upCountFor returns the fixed number of promotions for a tier, or -1 meaning
// "use the percentage". Only an openings-mode tier (Diamond) has one.
func (s *Service) upCountFor(ctx context.Context, r store.Repos, t domain.Tier) (int, error) {
	if t.UpMode != domain.UpModeOpenings {
		return -1, nil
	}
	aboveID := s.League.PromoteTier(t.ID)
	if aboveID == t.ID {
		return -1, nil
	}
	above, err := s.tier(aboveID)
	if err != nil {
		return 0, err
	}
	return s.cachedOpenings(ctx, r, t, above)
}
