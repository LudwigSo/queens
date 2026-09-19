package api

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/danielgtaylor/huma/v2"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/service"
)

// Field names match the record shapes documented in the header of
// queens/scripts/backend/backend.gd, so HttpBackend is a thin re-wrap of the
// {ok, data, error} envelope rather than a translation layer. The envelope
// itself deliberately does NOT go on the wire: it would make every operation a
// 200 with a discriminated union and destroy the generated schema, caching and
// 304s.

type TimeOutput struct {
	Body struct {
		ServerTime int64 `json:"server_time"`
	}
}

type RegisterInput struct {
	Authorization string `header:"Authorization" doc:"Optional. A bearer for this same player makes the call idempotent."`
	Body          struct {
		PlayerID      string `json:"player_id" format:"uuid" doc:"Client-generated v4 UUID. A name, not an authenticator."`
		Nickname      string `json:"nickname" minLength:"1" maxLength:"64" doc:"Trimmed and NFKC-normalised server-side; 2..16 runes after that."`
		ClientVersion string `json:"client_version,omitempty" maxLength:"32"`
	}
}

type RegisterOutput struct {
	Status int
	Body   struct {
		Profile    service.ProfileView `json:"profile"`
		Token      string              `json:"token,omitempty" doc:"Shown once. Empty when the caller already had a valid token."`
		IssuedAt   int64               `json:"issued_at,omitempty"`
		ServerTime int64               `json:"server_time"`
	}
}

type MeInput struct{ AuthHeader }

type MeOutput struct {
	Body service.ProfileView
}

type PatchMeInput struct {
	AuthHeader
	Body struct {
		Nickname string `json:"nickname" minLength:"1" maxLength:"64"`
	}
}

type EmptyOutput struct {
	Status int
}

type BootstrapInput struct{ AuthHeader }

type BootstrapOutput struct {
	Body struct {
		ServerTime      int64                             `json:"server_time"`
		Profile         service.ProfileView               `json:"profile"`
		LeagueConfig    json.RawMessage                   `json:"league_config" doc:"The shared league.json, verbatim."`
		ConfigHash      string                            `json:"config_hash"`
		LevelSetHash    string                            `json:"level_set_hash"`
		CooldownSeconds int64                             `json:"cooldown_seconds"`
		LevelMeta       map[string]service.LevelMetaEntry `json:"level_meta"`
		Standing        *service.StandingView             `json:"standing"`
		PendingSummary  *service.SummaryView              `json:"pending_summary,omitempty"`
		FriendLimit     int                               `json:"friend_limit"`
	}
}

type StartGameInput struct {
	AuthHeader
	Body struct {
		LevelID        string `json:"level_id" format:"uuid"`
		IntegrityToken string `json:"integrity_token,omitempty" doc:"Reserved for Play Integrity; ignored today."`
	}
}

type StartGameOutput struct {
	Status int
	Body   service.StartGameResult
}

type SubmitInput struct {
	AuthHeader
	Body service.ResultPayload
}

type SubmitOutput struct {
	Status int
	Body   json.RawMessage `doc:"The stored response; a replay returns the same bytes."`
}

type LeaderboardInput struct {
	AuthHeader
	ID    string `path:"id" format:"uuid"`
	Scope string `query:"scope" enum:"global,friends,flawless" default:"global"`
	Limit int    `query:"limit" minimum:"1" maximum:"100" default:"10"`
}

type LeaderboardOutput struct {
	CacheControl string `header:"Cache-Control"`
	Body         service.LeaderboardView
}

type LevelMetaInput struct {
	AuthHeader
	IfNoneMatch string `header:"If-None-Match"`
}

type LevelMetaOutput struct {
	Status       int
	ETag         string `header:"ETag"`
	CacheControl string `header:"Cache-Control"`
	Body         *service.LevelMetaView
}

type StandingInput struct{ AuthHeader }

type StandingOutput struct {
	CacheControl string `header:"Cache-Control"`
	Body         service.StandingView
}

type SummaryInput struct{ AuthHeader }

type SummaryOutput struct {
	Status int
	Body   *service.SummaryView
}

type AckInput struct {
	AuthHeader
	Body struct {
		RoundIndex int64 `json:"round_index" minimum:"0"`
	}
}

type FriendsInput struct{ AuthHeader }

type FriendsOutput struct {
	Body struct {
		Friends []domain.FriendRow `json:"friends"`
		Limit   int                `json:"limit"`
	}
}

type AddFriendInput struct {
	AuthHeader
	Body struct {
		Code string `json:"code" minLength:"1" maxLength:"16" doc:"QN- plus six of [A-Z2-7]; case and spacing are normalised."`
	}
}

type AddFriendOutput struct {
	Status int
	Body   domain.FriendRow
}

type RemoveFriendInput struct {
	AuthHeader
	PlayerID string `path:"player_id" format:"uuid"`
}

func (s *Server) register() {
	a := s.API

	huma.Register(a, huma.Operation{
		OperationID: "get-time", Method: http.MethodGet, Path: "/v1/time",
		Summary: "Server time", Description: "An explicit resync point; every response also carries X-Server-Time.",
		Tags: []string{"meta"},
	}, func(ctx context.Context, _ *struct{}) (*TimeOutput, error) {
		out := &TimeOutput{}
		out.Body.ServerTime = s.Svc.Clock.Now()
		return out, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "register-player", Method: http.MethodPost, Path: "/v1/players",
		Summary: "Register", Description: "Creates an account for a client-chosen UUID. 409 ERR_ID_TAKEN if it exists.",
		Tags: []string{"identity"}, DefaultStatus: http.StatusCreated,
	}, func(ctx context.Context, in *RegisterInput) (*RegisterOutput, error) {
		ip := ipFrom(ctx)
		if err := s.limit(s.Limits.registerIP, ip); err != nil {
			return nil, err
		}
		bearer := trimBearer(in.Authorization)
		res, err := s.Svc.Register(ctx, in.Body.PlayerID, in.Body.Nickname, in.Body.ClientVersion, bearer)
		if err != nil {
			return nil, errorOf(err)
		}
		out := &RegisterOutput{Status: http.StatusCreated}
		if !res.Created {
			out.Status = http.StatusOK
		}
		out.Body.Profile = res.Profile
		out.Body.Token = res.Token
		out.Body.IssuedAt = res.IssuedAt
		out.Body.ServerTime = s.Svc.Clock.Now()
		return out, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "bootstrap", Method: http.MethodGet, Path: "/v1/bootstrap",
		Summary: "Everything the client needs at launch", Tags: []string{"meta"},
	}, func(ctx context.Context, in *BootstrapInput) (*BootstrapOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		if err := s.limit(s.Limits.readsP, p.ID); err != nil {
			return nil, err
		}
		standing, err := s.Svc.Standing(ctx, p.ID)
		if err != nil {
			return nil, errorOf(err)
		}
		meta, _, err := s.Svc.LevelMeta(ctx, p.ID)
		if err != nil {
			return nil, errorOf(err)
		}
		summary, err := s.Svc.RoundSummary(ctx, p.ID)
		if err != nil {
			return nil, errorOf(err)
		}
		prof, err := s.Svc.Profile(ctx, p.ID)
		if err != nil {
			return nil, errorOf(err)
		}
		out := &BootstrapOutput{}
		out.Body.ServerTime = s.Svc.Clock.Now()
		out.Body.Profile = *prof
		out.Body.LeagueConfig = json.RawMessage(domain.LeagueConfigBytes())
		out.Body.ConfigHash = s.Svc.LeagueHash
		out.Body.LevelSetHash = s.Svc.LevelSetHash
		out.Body.CooldownSeconds = s.Cfg.CooldownSeconds
		out.Body.LevelMeta = meta.Levels
		out.Body.Standing = standing
		out.Body.PendingSummary = summary
		out.Body.FriendLimit = domain.FriendLimit
		return out, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "get-me", Method: http.MethodGet, Path: "/v1/me",
		Summary: "My profile", Tags: []string{"identity"},
	}, func(ctx context.Context, in *MeInput) (*MeOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		prof, err := s.Svc.Profile(ctx, p.ID)
		if err != nil {
			return nil, errorOf(err)
		}
		return &MeOutput{Body: *prof}, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "set-nickname", Method: http.MethodPatch, Path: "/v1/me",
		Summary: "Rename", Tags: []string{"identity"},
	}, func(ctx context.Context, in *PatchMeInput) (*MeOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		prof, err := s.Svc.SetNickname(ctx, p.ID, in.Body.Nickname)
		if err != nil {
			return nil, errorOf(err)
		}
		return &MeOutput{Body: *prof}, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "delete-me", Method: http.MethodDelete, Path: "/v1/me",
		Summary: "Delete my account",
		Description: "Removes the player and everything that hangs off them. There is no recovery: " +
			"the account lives on this device only.",
		Tags: []string{"identity"}, DefaultStatus: http.StatusNoContent,
	}, func(ctx context.Context, in *MeInput) (*EmptyOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		if err := s.Svc.DeleteAccount(ctx, p.ID); err != nil {
			return nil, errorOf(err)
		}
		return &EmptyOutput{Status: http.StatusNoContent}, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "start-game", Method: http.MethodPost, Path: "/v1/games",
		Summary: "Start a game", Description: "Mints the timed session that POST /v1/results needs.",
		Tags: []string{"play"}, DefaultStatus: http.StatusCreated,
	}, func(ctx context.Context, in *StartGameInput) (*StartGameOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		if err := s.limit(s.Limits.gamesP, p.ID); err != nil {
			return nil, err
		}
		if err := s.limit(s.Limits.gamesIP, ipFrom(ctx)); err != nil {
			return nil, err
		}
		res, err := s.Svc.StartGame(ctx, p.ID, in.Body.LevelID)
		if err != nil {
			return nil, errorOf(err)
		}
		status := http.StatusCreated
		if res.Reissued {
			status = http.StatusOK
		}
		return &StartGameOutput{Status: status, Body: *res}, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "submit-result", Method: http.MethodPost, Path: "/v1/results",
		Summary: "Submit a result",
		Description: "Idempotent by result_id: a replay returns the stored response with 200. " +
			"Every score is recomputed from the server's own level row.",
		Tags: []string{"play"}, DefaultStatus: http.StatusCreated,
	}, func(ctx context.Context, in *SubmitInput) (*SubmitOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		// An idempotent replay is not charged: a player returning from two weeks
		// offline with 40 queued results must not be throttled on their own
		// history. The service answers a replay before any work is done, so the
		// bucket is only charged once we know it is new.
		res, err := s.Svc.SubmitResult(ctx, p.ID, in.Body)
		if err != nil {
			return nil, errorOf(err)
		}
		if !res.Replay {
			if err := s.limit(s.Limits.resultsP, p.ID); err != nil {
				return nil, err
			}
			if err := s.limit(s.Limits.resultsIP, ipFrom(ctx)); err != nil {
				return nil, err
			}
		}
		status := http.StatusCreated
		if res.Replay {
			status = http.StatusOK
		}
		return &SubmitOutput{Status: status, Body: json.RawMessage(res.Body)}, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "level-leaderboard", Method: http.MethodGet, Path: "/v1/levels/{id}/leaderboard",
		Summary: "One level's leaderboard", Tags: []string{"boards"},
	}, func(ctx context.Context, in *LeaderboardInput) (*LeaderboardOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		if err := s.limit(s.Limits.readsP, p.ID); err != nil {
			return nil, err
		}
		view, err := s.Svc.Leaderboard(ctx, p.ID, in.ID, domain.Scope(in.Scope), in.Limit)
		if err != nil {
			return nil, errorOf(err)
		}
		return &LeaderboardOutput{CacheControl: "private, max-age=30", Body: *view}, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "level-meta", Method: http.MethodGet, Path: "/v1/levels/meta",
		Summary: "Par and cooldown for every level",
		Description: "Strongly ETagged. The body is per player, so the tag combines the level-set hash " +
			"with a digest of this player's own starts.",
		Tags: []string{"boards"},
	}, func(ctx context.Context, in *LevelMetaInput) (*LevelMetaOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		if err := s.limit(s.Limits.readsP, p.ID); err != nil {
			return nil, err
		}
		view, etag, err := s.Svc.LevelMeta(ctx, p.ID)
		if err != nil {
			return nil, errorOf(err)
		}
		if in.IfNoneMatch != "" && in.IfNoneMatch == etag {
			return &LevelMetaOutput{Status: http.StatusNotModified, ETag: etag,
				CacheControl: "private, no-cache"}, nil
		}
		return &LevelMetaOutput{Status: http.StatusOK, ETag: etag,
			CacheControl: "private, no-cache", Body: view}, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "league-standing", Method: http.MethodGet, Path: "/v1/league/standing",
		Summary: "My league standing", Tags: []string{"league"},
	}, func(ctx context.Context, in *StandingInput) (*StandingOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		if err := s.limit(s.Limits.readsP, p.ID); err != nil {
			return nil, err
		}
		view, err := s.Svc.Standing(ctx, p.ID)
		if err != nil {
			return nil, errorOf(err)
		}
		return &StandingOutput{CacheControl: "private, max-age=15", Body: *view}, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "round-summary", Method: http.MethodGet, Path: "/v1/league/summary",
		Summary:     "The newest unseen round summary",
		Description: "204 when nothing is pending.",
		Tags:        []string{"league"},
	}, func(ctx context.Context, in *SummaryInput) (*SummaryOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		view, err := s.Svc.RoundSummary(ctx, p.ID)
		if err != nil {
			return nil, errorOf(err)
		}
		if view == nil {
			return &SummaryOutput{Status: http.StatusNoContent}, nil
		}
		return &SummaryOutput{Status: http.StatusOK, Body: view}, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "ack-round-summary", Method: http.MethodPost, Path: "/v1/league/summary/ack",
		Summary:     "Mark the summary seen",
		Description: "Always 204: an index that does not match the pending summary is ignored, never an error.",
		Tags:        []string{"league"}, DefaultStatus: http.StatusNoContent,
	}, func(ctx context.Context, in *AckInput) (*EmptyOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		if err := s.Svc.AckRoundSummary(ctx, p.ID, in.Body.RoundIndex); err != nil {
			return nil, errorOf(err)
		}
		return &EmptyOutput{Status: http.StatusNoContent}, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "list-friends", Method: http.MethodGet, Path: "/v1/friends",
		Summary: "The players I follow", Tags: []string{"friends"},
	}, func(ctx context.Context, in *FriendsInput) (*FriendsOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		if err := s.limit(s.Limits.readsP, p.ID); err != nil {
			return nil, err
		}
		rows, err := s.Svc.Friends(ctx, p.ID)
		if err != nil {
			return nil, errorOf(err)
		}
		out := &FriendsOutput{}
		out.Body.Friends = rows
		out.Body.Limit = domain.FriendLimit
		return out, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "add-friend", Method: http.MethodPost, Path: "/v1/friends",
		Summary:     "Follow a friend code",
		Description: "Following is directed: adding someone does not make them follow you back.",
		Tags:        []string{"friends"}, DefaultStatus: http.StatusCreated,
	}, func(ctx context.Context, in *AddFriendInput) (*AddFriendOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		if err := s.limit(s.Limits.friendsP, p.ID); err != nil {
			return nil, err
		}
		if err := s.limit(s.Limits.friendsIP, ipFrom(ctx)); err != nil {
			return nil, err
		}
		row, err := s.Svc.AddFriend(ctx, p.ID, in.Body.Code)
		if err != nil {
			return nil, errorOf(err)
		}
		return &AddFriendOutput{Status: http.StatusCreated, Body: *row}, nil
	})

	huma.Register(a, huma.Operation{
		OperationID: "remove-friend", Method: http.MethodDelete, Path: "/v1/friends/{player_id}",
		Summary: "Unfollow", Tags: []string{"friends"}, DefaultStatus: http.StatusNoContent,
	}, func(ctx context.Context, in *RemoveFriendInput) (*EmptyOutput, error) {
		p, err := s.auth(ctx, in.Authorization)
		if err != nil {
			return nil, err
		}
		if err := s.Svc.RemoveFriend(ctx, p.ID, in.PlayerID); err != nil {
			return nil, errorOf(err)
		}
		return &EmptyOutput{Status: http.StatusNoContent}, nil
	})
}

func trimBearer(h string) string {
	if h == "" {
		return ""
	}
	const p = "Bearer "
	if len(h) > len(p) && h[:len(p)] == p {
		return h[len(p):]
	}
	return h
}
