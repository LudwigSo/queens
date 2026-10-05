// Package service holds the business logic. It talks to store.Repos and returns
// domain.CodedError; it knows nothing about HTTP.
package service

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"sync/atomic"

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
	// levels is the whole level table in memory, because the ceiling check needs
	// every base value on each submit. `queensd admin levels import` adds rows
	// from another process while this one runs, so the index is swapped whole
	// when the database holds more published levels than it does.
	levels   atomic.Pointer[levelIndex]
	reloadMu sync.Mutex

	openings openingsCache
}

type levelIndex struct {
	byID      map[string]domain.Level
	published int    // levels with a position: the count clients compare
	setHash   string // the ETag of the level table
}

func newLevelIndex(levels []domain.Level, setHash string) *levelIndex {
	idx := &levelIndex{byID: make(map[string]domain.Level, len(levels)), setHash: setHash}
	for _, l := range levels {
		idx.byID[l.ID] = l
		if l.Position > 0 {
			idx.published++
		}
	}
	return idx
}

func New(st store.Store, cfg *config.Config, clock domain.Clock, league *domain.LeagueConfig, leagueHash, levelSetHash string, levels []domain.Level) *Service {
	s := &Service{St: st, Cfg: cfg, Clock: clock, League: league, LeagueHash: leagueHash}
	s.levels.Store(newLevelIndex(levels, levelSetHash))
	return s
}

func (s *Service) now() int64 { return s.Clock.Now() }

// Level returns a cached level row.
func (s *Service) Level(id string) (domain.Level, bool) {
	l, ok := s.levels.Load().byID[id]
	return l, ok
}

// LoadedLevels is the number of level rows held, published or not.
func (s *Service) LoadedLevels() int { return len(s.levels.Load().byID) }

// LevelSetHash is the ETag of the level table as of the last (re)load.
func (s *Service) LevelSetHash() string { return s.levels.Load().setHash }

// levelFor is Level for request paths: an id this process has not seen may
// have been imported since it started, so a miss checks the database once.
func (s *Service) levelFor(ctx context.Context, id string) (domain.Level, bool, error) {
	if l, ok := s.Level(id); ok {
		return l, true, nil
	}
	if err := s.refreshLevels(ctx); err != nil {
		return domain.Level{}, false, err
	}
	l, ok := s.Level(id)
	return l, ok, nil
}

// refreshLevels reloads the index when the database publishes a different
// number of levels than it holds. One COUNT(*) when nothing changed. Imports
// are append-only, so a count is enough to notice one.
func (s *Service) refreshLevels(ctx context.Context) error {
	n, err := s.St.Repos().Levels.CountPublished(ctx)
	if err != nil {
		return err
	}
	if n == s.levels.Load().published {
		return nil
	}
	return s.ReloadLevels(ctx)
}

// ReloadLevels reads the whole level table again and swaps the index.
func (s *Service) ReloadLevels(ctx context.Context) error {
	s.reloadMu.Lock()
	defer s.reloadMu.Unlock()
	repos := s.St.Repos()
	levels, err := repos.Levels.All(ctx)
	if err != nil {
		return err
	}
	setHash := s.LevelSetHash()
	if set, err := repos.Levels.CurrentLevelSet(ctx); err == nil {
		setHash = set.Hash
	} else if err != domain.ErrNotFound {
		return err
	}
	next := newLevelIndex(levels, setHash)
	if prev := s.levels.Swap(next); prev.published != next.published {
		slog.Info("levels reloaded", "published", next.published, "was", prev.published, "level_set", setHash)
	}
	return nil
}

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
