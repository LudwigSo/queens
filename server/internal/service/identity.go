package service

import (
	"context"
	"errors"
	"regexp"
	"strings"

	"github.com/ludwigsonnenberg/queens-server/internal/auth"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

// The client generates its own player id and keeps it: the whole save file is
// already keyed by it, and every queued pending_results row carries it, so
// re-keying would mean migrating the offline queue. The UUID is 122 bits of
// CSPRNG and unguessable, but it is a NAME, NOT AN AUTHENTICATOR -- the bearer
// token authenticates.
var uuidV4 = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type ProfileView struct {
	PlayerID   string    `json:"player_id"`
	Nickname   string    `json:"nickname"`
	FriendCode string    `json:"friend_code"`
	Tier       string    `json:"tier"`
	TierPoints int       `json:"tier_points"`
	CreatedAt  int64     `json:"created_at"`
	Stats      StatsView `json:"stats"`
}

type StatsView struct {
	Games        int `json:"games"`
	Flawless     int `json:"flawless"`
	BestScore    int `json:"best_score"`
	RoundsPlayed int `json:"rounds_played"`
}

func profileView(p *domain.Player) ProfileView {
	return ProfileView{
		PlayerID: p.ID, Nickname: p.Nickname, FriendCode: p.FriendCode, Tier: p.Tier,
		TierPoints: p.TierPoints, CreatedAt: p.CreatedAt,
		Stats: StatsView{Games: p.Games, Flawless: p.Flawless, BestScore: p.BestScore, RoundsPlayed: p.RoundsPlayed},
	}
}

type RegisterResult struct {
	Profile  ProfileView
	Token    string // empty when the caller already had a valid token
	IssuedAt int64
	Created  bool
}

// Register creates an account for a client-chosen id.
//
// It takes no local level data: existing players start fresh on the server
// (importing client-asserted bests would be trivially forgeable). The client
// keeps honouring its own local cooldowns for display.
func (s *Service) Register(ctx context.Context, playerID, nickname, clientVersion, bearer string) (*RegisterResult, error) {
	playerID = strings.ToLower(strings.TrimSpace(playerID))
	if !uuidV4.MatchString(playerID) {
		return nil, domain.Errf(400, domain.CodeBadRequest, "player_id must be a v4 UUID")
	}
	nick, err := domain.NormalizeNickname(nickname)
	if err != nil {
		return nil, nicknameError(err)
	}

	// An authenticated re-registration of the same id is the "known device"
	// case: idempotent, no new token, nickname refreshed like the stub does.
	if bearer != "" {
		if tok, err := s.St.Repos().Players.GetToken(ctx, auth.HashToken(bearer)); err == nil &&
			tok.RevokedAt == nil && tok.PlayerID == playerID {
			var out *RegisterResult
			err := s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
				p, err := r.Players.Get(ctx, playerID)
				if err != nil {
					return err
				}
				if p.Nickname != nick {
					if err := r.Players.UpdateNickname(ctx, playerID, nick, s.now()); err != nil {
						return err
					}
					p.Nickname = nick
				}
				out = &RegisterResult{Profile: profileView(p), Created: false}
				return nil
			})
			return out, err
		}
	}

	var out *RegisterResult
	err = s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		if _, err := r.Players.Get(ctx, playerID); err == nil {
			// Astronomically unlikely, but an unauthenticated caller must never
			// be handed a token for an existing account. The client regenerates
			// its UUID once and retries.
			return domain.Err(409, domain.CodeIDTaken)
		} else if err != domain.ErrNotFound {
			return err
		}

		code, err := s.uniqueFriendCode(ctx, r)
		if err != nil {
			return err
		}
		now := s.now()
		bottom, err := s.tier(s.League.BottomTier())
		if err != nil {
			return err
		}
		p := &domain.Player{
			ID: playerID, Nickname: nick, FriendCode: code, Tier: bottom.ID,
			TierSince: now, SettledRoundEnd: domain.RoundStart(bottom, domain.RoundIndex(bottom, now)),
			ClientVersion: clientVersion, CreatedAt: now, UpdatedAt: now, LastSeenAt: now,
		}
		if err := r.Players.Create(ctx, p); err != nil {
			if errors.Is(err, domain.ErrConflict) {
				return domain.Err(409, domain.CodeIDTaken)
			}
			return err
		}
		token, hash, err := auth.NewToken()
		if err != nil {
			return err
		}
		if err := r.Players.InsertToken(ctx, hash, p.ID, now); err != nil {
			return err
		}
		out = &RegisterResult{Profile: profileView(p), Token: token, IssuedAt: now, Created: true}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// uniqueFriendCode draws until the code is free. Inside the single write
// transaction the check-then-insert is race-free, and the UNIQUE index is the
// backstop.
func (s *Service) uniqueFriendCode(ctx context.Context, r store.Repos) (string, error) {
	for i := 0; i < 5; i++ {
		code, err := auth.NewFriendCode()
		if err != nil {
			return "", err
		}
		exists, err := r.Players.FriendCodeExists(ctx, code)
		if err != nil {
			return "", err
		}
		if !exists {
			return code, nil
		}
	}
	return "", domain.Errf(500, domain.CodeServer, "could not find a free friend code")
}

func nicknameError(err error) error {
	if errors.Is(err, domain.ErrNicknameLength) {
		return domain.Err(422, domain.CodeNicknameLength)
	}
	return domain.Err(422, domain.CodeNicknameInvalid)
}

func (s *Service) Profile(ctx context.Context, playerID string) (*ProfileView, error) {
	p, err := s.St.Repos().Players.Get(ctx, playerID)
	if err != nil {
		return nil, err
	}
	v := profileView(p)
	return &v, nil
}

func (s *Service) SetNickname(ctx context.Context, playerID, nickname string) (*ProfileView, error) {
	nick, err := domain.NormalizeNickname(nickname)
	if err != nil {
		return nil, nicknameError(err)
	}
	var out ProfileView
	err = s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		if err := r.Players.UpdateNickname(ctx, playerID, nick, s.now()); err != nil {
			return err
		}
		p, err := r.Players.Get(ctx, playerID)
		if err != nil {
			return err
		}
		out = profileView(p)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}

// DeleteAccount removes the player and everything that hangs off them. The open
// groups they were counted in are decremented first, so the remaining members'
// percentages stay right.
func (s *Service) DeleteAccount(ctx context.Context, playerID string) error {
	return s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		if err := r.League.DecGroupCountsForPlayer(ctx, playerID); err != nil {
			return err
		}
		return r.Players.Delete(ctx, playerID)
	})
}

// ResolveToken is the auth resolver: it turns a bearer into a player, or into
// 401/403.
func (s *Service) ResolveToken(ctx context.Context, bearer string) (*domain.Player, error) {
	if bearer == "" {
		return nil, domain.Err(401, domain.CodeUnauthorized)
	}
	tok, err := s.St.Repos().Players.GetToken(ctx, auth.HashToken(bearer))
	if err == domain.ErrNotFound {
		return nil, domain.Err(401, domain.CodeUnauthorized)
	}
	if err != nil {
		return nil, err
	}
	if tok.RevokedAt != nil {
		return nil, domain.Err(401, domain.CodeUnauthorized)
	}
	if tok.BannedAt != nil {
		return nil, domain.Err(403, domain.CodeBanned)
	}
	p, err := s.St.Repos().Players.Get(ctx, tok.PlayerID)
	if err != nil {
		return nil, err
	}
	// last_seen_at is bumped at most hourly: a write per request would serialise
	// the whole server behind the single SQLite writer.
	if s.now()-tok.LastSeenAt > 3600 {
		hash := auth.HashToken(bearer)
		_ = s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
			if err := r.Players.TouchToken(ctx, hash, s.now()); err != nil {
				return err
			}
			return r.Players.TouchLastSeen(ctx, p.ID, s.now())
		})
	}
	return p, nil
}
