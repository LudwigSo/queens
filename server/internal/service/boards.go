package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

type LeaderboardView struct {
	Entries      []domain.LeaderboardEntry `json:"entries"`
	MyEntry      *domain.LeaderboardEntry  `json:"my_entry,omitempty"`
	MyRank       int                       `json:"my_rank"`
	TotalPlayers int                       `json:"total_players"`
	ParSeconds   float64                   `json:"par_seconds"`
}

// Leaderboard serves one level's board in one of three scopes.
func (s *Service) Leaderboard(ctx context.Context, playerID, levelID string, scope domain.Scope, limit int) (*LeaderboardView, error) {
	lv, ok := s.Level(levelID)
	if !ok {
		return nil, domain.Err(404, domain.CodeLevelUnknown)
	}
	if limit < 1 {
		limit = 10
	}
	if limit > 100 {
		limit = 100
	}
	switch scope {
	case domain.ScopeGlobal, domain.ScopeFriends, domain.ScopeFlawless:
	default:
		scope = domain.ScopeGlobal
	}
	r := s.St.Repos()
	q := domain.BoardQuery{LevelID: levelID, Me: playerID, Scope: scope, Limit: limit}
	if scope == domain.ScopeFriends {
		ids, err := r.Friends.IDs(ctx, playerID)
		if err != nil {
			return nil, err
		}
		q.FriendIDs = ids
	}
	entries, err := r.Bests.Board(ctx, q)
	if err != nil {
		return nil, err
	}
	rank, err := r.Bests.Rank(ctx, q)
	if err != nil {
		return nil, err
	}
	total, err := r.Bests.Total(ctx, q)
	if err != nil {
		return nil, err
	}
	view := &LeaderboardView{Entries: entries, MyRank: rank, TotalPlayers: total, ParSeconds: lv.Par()}
	if view.Entries == nil {
		view.Entries = []domain.LeaderboardEntry{}
	}
	if rank > 0 {
		view.MyEntry, err = s.myEntry(ctx, playerID, levelID, scope, rank)
		if err != nil {
			return nil, err
		}
	}
	return view, nil
}

func (s *Service) myEntry(ctx context.Context, playerID, levelID string, scope domain.Scope, rank int) (*domain.LeaderboardEntry, error) {
	r := s.St.Repos()
	p, err := r.Players.Get(ctx, playerID)
	if err != nil {
		return nil, err
	}
	if scope == domain.ScopeFlawless {
		b, err := r.Bests.MyFlawless(ctx, playerID, levelID)
		if err == domain.ErrNotFound {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		return &domain.LeaderboardEntry{
			Rank: rank, PlayerID: playerID, Nickname: p.Nickname, Score: b.Score,
			TimeSeconds: b.TimeSeconds, WrongPlacements: 0, AchievedAt: b.AchievedAt, IsMe: true,
		}, nil
	}
	b, err := r.Bests.MyBest(ctx, playerID, levelID)
	if err == domain.ErrNotFound {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &domain.LeaderboardEntry{
		Rank: rank, PlayerID: playerID, Nickname: p.Nickname, Score: b.Score,
		TimeSeconds: b.TimeSeconds, WrongPlacements: b.WrongPlacements, AchievedAt: b.AchievedAt, IsMe: true,
	}, nil
}

type LevelMetaEntry struct {
	ParSeconds  float64 `json:"par_seconds"`
	LockedUntil int64   `json:"locked_until"`
}

type LevelMetaView struct {
	Levels          map[string]LevelMetaEntry `json:"levels"`
	LevelSetHash    string                    `json:"level_set_hash"`
	CooldownSeconds int64                     `json:"cooldown_seconds"`
	ServerTime      int64                     `json:"server_time"`
}

// LevelMeta returns par and the per-player lock for every level, plus the ETag.
//
// The body is per player (locked_until), so the ETag combines the level-set hash
// with a digest of this player's own starts: it changes only when the level set
// changes or when this player starts a game, which is exactly as often as the
// body does.
func (s *Service) LevelMeta(ctx context.Context, playerID string) (*LevelMetaView, string, error) {
	rows, err := s.St.Repos().Levels.ListPlayerLevels(ctx, playerID)
	if err != nil {
		return nil, "", err
	}
	locks := make(map[string]int64, len(rows))
	for _, pl := range rows {
		locks[pl.LevelID] = pl.LastStartedAt + s.Cfg.CooldownSeconds
	}
	out := &LevelMetaView{
		Levels:          make(map[string]LevelMetaEntry, len(s.levels)),
		LevelSetHash:    s.LevelSetHash,
		CooldownSeconds: s.Cfg.CooldownSeconds,
		ServerTime:      s.now(),
	}
	for id, lv := range s.levels {
		out.Levels[id] = LevelMetaEntry{ParSeconds: lv.Par(), LockedUntil: locks[id]}
	}

	ids := make([]string, 0, len(locks))
	for id := range locks {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	h := sha256.New()
	h.Write([]byte(playerID))
	for _, id := range ids {
		fmt.Fprintf(h, "\n%s:%d", id, locks[id])
	}
	etag := fmt.Sprintf(`"%s.%s"`, first16(s.LevelSetHash), first16(hex.EncodeToString(h.Sum(nil))))
	return out, etag, nil
}

func first16(s string) string {
	if len(s) <= 16 {
		return s
	}
	return s[:16]
}
