package service

import (
	"context"
	"regexp"
	"strings"
	"sync"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

// Friend codes are server-generated and directed: I follow you, there is no
// accept flow, which matches the shipped UI. The offline stub derived codes from
// GDScript's hash(), which is engine-defined and not reproducible in Go, so the
// server owns them now.
var friendCodeRe = regexp.MustCompile(`^QN-[A-Z2-7]{6}$`)

// probeCounter tracks unknown-code lookups per player per hour. With 32^6
// (about 1.07 billion) codes, the rate limit is the real enumeration defence;
// this only feeds the flag column.
type probeCounter struct {
	mu   sync.Mutex
	seen map[string]*probeEntry
}

type probeEntry struct {
	count int
	since int64
}

var probes = probeCounter{seen: map[string]*probeEntry{}}

func (c *probeCounter) bump(playerID string, now int64) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.seen[playerID]
	if !ok || now-e.since > 3600 {
		e = &probeEntry{since: now}
		c.seen[playerID] = e
	}
	e.count++
	return e.count
}

// Friends returns the people I follow, each with their score in their OWN tier's
// current round (round lengths differ per tier, so this cannot be one join).
func (s *Service) Friends(ctx context.Context, playerID string) ([]domain.FriendRow, error) {
	r := s.St.Repos()
	rows, err := r.Friends.List(ctx, playerID)
	if err != nil {
		return nil, err
	}
	for i := range rows {
		t, ok := s.League.TierByID(rows[i].Tier)
		if !ok {
			continue
		}
		idx := domain.RoundIndex(t, s.now())
		m, err := r.League.GetMember(ctx, rows[i].PlayerID, t.ID, idx)
		if err == nil {
			rows[i].RoundScore = m.RoundScore
		} else if err != domain.ErrNotFound {
			return nil, err
		}
	}
	if rows == nil {
		rows = []domain.FriendRow{}
	}
	return rows, nil
}

func (s *Service) AddFriend(ctx context.Context, playerID, code string) (*domain.FriendRow, error) {
	code = strings.ToUpper(strings.TrimSpace(code))
	if !friendCodeRe.MatchString(code) {
		return nil, domain.Err(422, domain.CodeFriendCodeFmt)
	}
	var out *domain.FriendRow
	err := s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		me, err := r.Players.Get(ctx, playerID)
		if err != nil {
			return err
		}
		if code == me.FriendCode {
			return domain.Err(422, domain.CodeFriendOwnCode)
		}
		other, err := r.Players.GetByFriendCode(ctx, code)
		if err == domain.ErrNotFound {
			if probes.bump(playerID, s.now()) > 50 {
				if ferr := s.flag(ctx, r, playerID, domain.SigFriendCodeProbing, domain.WFriendProbing, nil, nil, nil); ferr != nil {
					return ferr
				}
				return store.CommitAndFail{Err: domain.Err(404, domain.CodeFriendCodeUnkn)}
			}
			return domain.Err(404, domain.CodeFriendCodeUnkn)
		}
		if err != nil {
			return err
		}
		n, err := r.Friends.Count(ctx, playerID)
		if err != nil {
			return err
		}
		if n >= domain.FriendLimit {
			return domain.Err(409, domain.CodeFriendLimit, domain.FriendLimit)
		}
		added, err := r.Friends.Add(ctx, playerID, other.ID, s.now())
		if err != nil {
			return err
		}
		if !added {
			return domain.Err(409, domain.CodeFriendAlready)
		}
		out = &domain.FriendRow{
			PlayerID: other.ID, Nickname: other.Nickname, Tier: other.Tier,
			FriendSince: s.now(), FriendCode: other.FriendCode,
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if t, ok := s.League.TierByID(out.Tier); ok {
		idx := domain.RoundIndex(t, s.now())
		if m, err := s.St.Repos().League.GetMember(ctx, out.PlayerID, t.ID, idx); err == nil {
			out.RoundScore = m.RoundScore
		}
	}
	return out, nil
}

func (s *Service) RemoveFriend(ctx context.Context, playerID, friendID string) error {
	return s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		removed, err := r.Friends.Remove(ctx, playerID, friendID)
		if err != nil {
			return err
		}
		if !removed {
			return domain.Err(404, domain.CodeFriendUnknown)
		}
		return nil
	})
}
