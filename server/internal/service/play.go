package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"sort"

	"github.com/ludwigsonnenberg/queens-server/internal/auth"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

// --- POST /v1/games ---------------------------------------------------------

type LevelBrief struct {
	Size       int     `json:"size"`
	Difficulty float64 `json:"difficulty"`
	Stars      int     `json:"stars"`
	ParSeconds float64 `json:"par_seconds"`
}

type SessionView struct {
	Token     string     `json:"token"`
	IssuedAt  int64      `json:"issued_at"`
	ExpiresAt int64      `json:"expires_at"`
	Level     LevelBrief `json:"level"`
}

type StartGameResult struct {
	RoundIndex  int64       `json:"round_index"`
	GroupID     string      `json:"group_id"`
	Joined      bool        `json:"joined"`
	Tier        string      `json:"tier"`
	LockedUntil int64       `json:"locked_until"`
	Session     SessionView `json:"session"`
	ServerTime  int64       `json:"server_time"`
	Reissued    bool        `json:"-"`
}

// StartGame is the timed-session mint. In one transaction: catch up the league,
// validate the level, enforce the server-authoritative cooldown, record the
// start, join the round, and issue a session.
func (s *Service) StartGame(ctx context.Context, playerID, levelID string) (*StartGameResult, error) {
	lv, ok := s.Level(levelID)
	if !ok {
		return nil, domain.Err(404, domain.CodeLevelUnknown)
	}
	var out *StartGameResult
	err := s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		p, err := s.catchUp(ctx, r, playerID)
		if err != nil {
			return err
		}
		tierCfg, err := s.tier(p.Tier)
		if err != nil {
			return err
		}
		idx := domain.RoundIndex(tierCfg, s.now())
		if err := s.ensureRound(ctx, r, tierCfg, idx); err != nil {
			return err
		}

		// A still-open session for this level is handed back instead of minting
		// a second one. The client never retries POST /games, so a request that
		// was processed but whose response was lost must not cost the player a
		// seven-day lock on the level.
		if existing, err := r.Sessions.FindReusable(ctx, p.ID, levelID, s.now()-s.Cfg.SessionTTL); err == nil {
			m, _, err := s.ensureMembership(ctx, r, p, tierCfg, idx)
			if err != nil {
				return err
			}
			out = s.startResult(p, lv, existing, m, idx)
			out.Reissued = true
			return nil
		} else if err != domain.ErrNotFound {
			return err
		}

		// Cooldown, server-side: the client's clock cannot be trusted and the
		// local one was defeatable by changing the device time.
		pl, err := r.Levels.GetPlayerLevel(ctx, p.ID, levelID)
		if err != nil && err != domain.ErrNotFound {
			return err
		}
		if pl != nil {
			remaining := domain.CooldownRemaining(pl.LastStartedAt, s.now(), s.Cfg.CooldownSeconds)
			if remaining > 0 {
				// A near-miss is ordinary clock skew; a big one is an attempt.
				if remaining > 60 {
					if err := s.flag(ctx, r, p.ID, domain.SigCooldownViolation, domain.WCooldownViolation,
						map[string]any{"level_id": levelID, "remaining": remaining}, nil, nil); err != nil {
						return err
					}
					return store.CommitAndFail{Err: domain.Err(409, domain.CodeLevelLocked, remaining)}
				}
				return domain.Err(409, domain.CodeLevelLocked, remaining)
			}
		}
		if err := r.Levels.RecordStart(ctx, p.ID, levelID, s.now()); err != nil {
			return err
		}

		m, _, err := s.ensureMembership(ctx, r, p, tierCfg, idx)
		if err != nil {
			return err
		}

		id, err := auth.NewSessionID()
		if err != nil {
			return err
		}
		sess := &domain.Session{
			ID: id, PlayerID: p.ID, LevelID: levelID,
			IssuedAt: s.now(), ExpiresAt: s.now() + s.Cfg.SessionTTL,
			TierAtIssue: tierCfg.ID, RoundIndexAtIssue: idx, GroupID: m.GroupID,
			ClientVersion: p.ClientVersion,
		}
		if err := r.Sessions.Insert(ctx, sess); err != nil {
			return err
		}
		out = s.startResult(p, lv, sess, m, idx)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Service) startResult(p *domain.Player, lv domain.Level, sess *domain.Session, m *domain.Member, idx int64) *StartGameResult {
	return &StartGameResult{
		RoundIndex: idx, GroupID: m.GroupID, Joined: true, Tier: p.Tier,
		LockedUntil: s.now() + s.Cfg.CooldownSeconds,
		Session: SessionView{
			Token: auth.SessionToken(s.Cfg.TokenPepper, sess.ID), IssuedAt: sess.IssuedAt, ExpiresAt: sess.ExpiresAt,
			Level: LevelBrief{Size: lv.Size, Difficulty: float64(lv.Difficulty), Stars: lv.Stars, ParSeconds: lv.Par()},
		},
		ServerTime: s.now(),
	}
}

// --- POST /v1/results -------------------------------------------------------

// ResultPayload is GameResult.to_dict() as it arrives.
//
// Only the fields the server cannot do without are required. Everything it
// overrides (size, difficulty, stars, par_seconds) or ignores (week_index,
// score, player_id) is optional, so a client on a slightly older level file is
// never locked out of submitting: a content update must not become an outage.
type ResultPayload struct {
	Schema          int     `json:"schema" required:"false" minimum:"1" maximum:"9"`
	ResultID        string  `json:"result_id" format:"uuid" doc:"Idempotency key, generated by the client."`
	PlayerID        string  `json:"player_id,omitempty" doc:"Ignored; the bearer decides. A mismatch is flagged."`
	LevelID         string  `json:"level_id" doc:"Ignored when a session token is present: the session decides."`
	Size            int     `json:"size,omitempty" doc:"Overridden from the level row."`
	Difficulty      float64 `json:"difficulty,omitempty" doc:"Overridden from the level row."`
	Stars           int     `json:"stars,omitempty" doc:"Overridden from the level row."`
	ParSeconds      float64 `json:"par_seconds,omitempty" doc:"IGNORED. Par is the numerator of the speed factor and must be the server's."`
	StartedAt       int64   `json:"started_at,omitempty"`
	FinishedAt      int64   `json:"finished_at,omitempty" doc:"Clamped to the server clock."`
	ElapsedSeconds  float64 `json:"elapsed_seconds" minimum:"0" maximum:"1000000" doc:"Clamped into a humanly possible range."`
	Completed       bool    `json:"completed"`
	QueensPlaced    int     `json:"queens_placed,omitempty" minimum:"0" maximum:"100000"`
	WrongPlacements int     `json:"wrong_placements,omitempty" minimum:"0" maximum:"100000"`
	QueensRemoved   int     `json:"queens_removed,omitempty" minimum:"0" maximum:"100000"`
	ClearCount      int     `json:"clear_count,omitempty" minimum:"0" maximum:"100000"`
	HintCount       int     `json:"hint_count,omitempty" minimum:"0" maximum:"1000"`
	Taps            int     `json:"taps,omitempty" minimum:"0" maximum:"1000000"`
	WeekIndex       int64   `json:"week_index,omitempty" doc:"IGNORED."`
	Score           int     `json:"score,omitempty" doc:"Kept only to compare against the recomputed score."`
	ClientVersion   string  `json:"client_version,omitempty" maxLength:"32"`
	SessionToken    string  `json:"session_token,omitempty" maxLength:"128" doc:"Empty means unverified: the result counts but never reaches a leaderboard."`
}

// SubmitResponse is the body the client stores and replays.
type SubmitResponse struct {
	Breakdown  domain.ScoreBreakdown `json:"breakdown"`
	RoundScore int                   `json:"round_score"`
	GroupRank  int                   `json:"group_rank"`
	GroupSize  int                   `json:"group_size"`
	Zone       string                `json:"zone"`
	Tier       string                `json:"tier"`
	RoundIndex int64                 `json:"round_index"`
	TierPoints int                   `json:"tier_points"`
	PromoScore int                   `json:"promo_score"`
	PromotedTo string                `json:"promoted_to"`
	Verified   bool                  `json:"verified"`
	ServerTime int64                 `json:"server_time"`
}

type SubmitResult struct {
	Body    []byte // the exact stored bytes
	Replay  bool   // true -> HTTP 200 instead of 201
	Decoded SubmitResponse
}

func payloadHash(p ResultPayload) string {
	b, _ := json.Marshal(p)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// SubmitResult recomputes the score from the server's own tables and records it.
//
// What is defensible here is the arithmetic, the level's intrinsic worth, the
// volume and the identity -- not the claim about HOW a board was solved. Every
// counter in the payload is self-reported by hardware the reporter controls.
func (s *Service) SubmitResult(ctx context.Context, playerID string, p ResultPayload) (*SubmitResult, error) {
	if !uuidV4.MatchString(p.ResultID) {
		return nil, domain.Errf(400, domain.CodeBadRequest, "result_id must be a v4 UUID")
	}
	if p.QueensPlaced < 0 || p.WrongPlacements < 0 || p.QueensRemoved < 0 || p.ClearCount < 0 ||
		p.HintCount < 0 || p.Taps < 0 || p.ElapsedSeconds < 0 {
		return nil, domain.Errf(400, domain.CodeBadRequest, "counters must not be negative")
	}

	// Reject a forged session token before touching the database. On SQLite,
	// where reads and writes share a lock, that is a real denial-of-service
	// difference.
	sessionID := ""
	if p.SessionToken != "" {
		id, err := auth.VerifySessionToken(s.Cfg.TokenPepper, p.SessionToken)
		if err != nil {
			return nil, domain.Err(422, domain.CodeSessionInvalid)
		}
		sessionID = id
	}

	hash := payloadHash(p)
	replaceForfeit := false

	// Idempotency is checked before any rate-limit bucket is charged: a player
	// coming back from two weeks offline with 40 queued results must not be
	// throttled on their own history.
	if stored, err := s.St.Repos().Results.Get(ctx, p.ResultID); err == nil {
		if stored.PlayerID != playerID {
			_ = s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
				return s.flag(ctx, r, playerID, domain.SigPlayerMismatch, domain.WPlayerMismatch,
					map[string]any{"result_id": p.ResultID}, &p.ResultID, nil)
			})
			return nil, domain.Err(403, domain.CodeSessionMismatch)
		}
		if stored.Completed || !p.Completed {
			// Return the stored bytes verbatim. A different body for the same id
			// is the client-crash path described above, not a cheat, so it is
			// logged and never rejected.
			if stored.PayloadHash != hash {
				_ = s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
					return s.flag(ctx, r, playerID, domain.SigReplayBodyMismatch, 1,
						map[string]any{"result_id": p.ResultID}, &p.ResultID, nil)
				})
			}
			var decoded SubmitResponse
			_ = json.Unmarshal([]byte(stored.ResponseJSON), &decoded)
			return &SubmitResult{Body: []byte(stored.ResponseJSON), Replay: true, Decoded: decoded}, nil
		}
		// Stored forfeit, incoming completed: completed wins regardless of
		// arrival order.
		replaceForfeit = true
	} else if err != domain.ErrNotFound {
		return nil, err
	}

	var out *SubmitResult
	err := s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		var err error
		out, err = s.submitInTx(ctx, r, playerID, p, hash, sessionID, replaceForfeit)
		return err
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Service) submitInTx(ctx context.Context, r store.Repos, playerID string, p ResultPayload,
	hash, sessionID string, replaceForfeit bool) (*SubmitResult, error) {

	player, err := s.catchUp(ctx, r, playerID)
	if err != nil {
		return nil, err
	}
	now := s.now()

	// --- session -----------------------------------------------------------
	var sess *domain.Session
	verified := false
	levelID := p.LevelID
	var sessPtr *string
	if sessionID != "" {
		sess, err = r.Sessions.Get(ctx, sessionID)
		if err == domain.ErrNotFound {
			return nil, domain.Err(422, domain.CodeSessionInvalid)
		}
		if err != nil {
			return nil, err
		}
		if sess.PlayerID != playerID {
			if err := s.flag(ctx, r, playerID, domain.SigPlayerMismatch, domain.WPlayerMismatch,
				map[string]any{"session_id": sessionID}, &p.ResultID, &sessionID); err != nil {
				return nil, err
			}
			return nil, store.CommitAndFail{Err: domain.Err(403, domain.CodeSessionMismatch)}
		}
		if now-sess.IssuedAt > domain.SessionAcceptance {
			return nil, domain.Err(410, domain.CodeSessionExpired)
		}
		consumed, err := r.Sessions.Consume(ctx, sessionID, p.ResultID, now)
		if err != nil {
			return nil, err
		}
		if !consumed {
			if sess.ResultID == nil || *sess.ResultID != p.ResultID {
				if err := s.flag(ctx, r, playerID, domain.SigSessionReuse, domain.WSessionReuse,
					map[string]any{"session_id": sessionID}, &p.ResultID, &sessionID); err != nil {
					return nil, err
				}
				return nil, store.CommitAndFail{Err: domain.Err(409, domain.CodeSessionUsed)}
			}
		}
		verified = true
		sessPtr = &sessionID
		if sess.LevelID != p.LevelID {
			if err := s.flag(ctx, r, playerID, domain.SigSessionLevelMismatch, 2,
				map[string]any{"session_level": sess.LevelID, "payload_level": p.LevelID}, &p.ResultID, &sessionID); err != nil {
				return nil, err
			}
		}
		levelID = sess.LevelID // the session decides, never the payload
		// The freshness window is a signal, not a rejection: an offline queue
		// legitimately replays games days later.
		if now-sess.IssuedAt > s.Cfg.SessionTTL {
			if err := s.flag(ctx, r, playerID, domain.SigSessionStale, domain.WSessionStale, nil, &p.ResultID, &sessionID); err != nil {
				return nil, err
			}
		}
	} else {
		// No session: accepted, but never trusted onto a leaderboard.
		if p.FinishedAt >= s.Cfg.NoSessionGraceUntil {
			if err := s.flag(ctx, r, playerID, domain.SigNoSession, domain.WNoSession, nil, &p.ResultID, nil); err != nil {
				return nil, err
			}
		}
		if pl, err := r.Levels.GetPlayerLevel(ctx, playerID, levelID); err == nil {
			if pl.LastStartedAt > p.StartedAt && now-pl.LastStartedAt < s.Cfg.CooldownSeconds {
				if err := s.flag(ctx, r, playerID, domain.SigCooldownViolation, domain.WCooldownViolation,
					map[string]any{"level_id": levelID}, &p.ResultID, nil); err != nil {
					return nil, err
				}
			}
		} else if err != domain.ErrNotFound {
			return nil, err
		}
	}

	lv, ok := s.Level(levelID)
	if !ok {
		return nil, domain.Err(404, domain.CodeLevelUnknown)
	}
	if p.PlayerID != "" && p.PlayerID != playerID {
		if err := s.flag(ctx, r, playerID, domain.SigPlayerMismatch, domain.WPlayerMismatch,
			map[string]any{"payload_player": p.PlayerID}, &p.ResultID, sessPtr); err != nil {
			return nil, err
		}
		return nil, store.CommitAndFail{Err: domain.Err(403, domain.CodeSessionMismatch)}
	}

	// --- server-side overrides ---------------------------------------------
	// par_seconds must NEVER come from the client: it is the numerator of
	// (par/elapsed)^0.63, so par_seconds 1e9 would pin the speed factor at its
	// maximum for any elapsed. A mismatch is accepted with a weight-1 flag
	// rather than rejected, because a client on a slightly older queens.json
	// would otherwise be locked out of submitting -- turning a content update
	// into an outage.
	par := lv.Par()
	if p.Size != lv.Size || int(p.Difficulty) != lv.Difficulty || p.Stars != lv.Stars ||
		(p.ParSeconds > 0 && math.Abs(p.ParSeconds-par) > 0.001) {
		if err := s.flag(ctx, r, playerID, domain.SigLevelMetaMismatch, domain.WLevelMetaMismatch,
			map[string]any{
				"client": map[string]any{"size": p.Size, "difficulty": p.Difficulty, "stars": p.Stars, "par": p.ParSeconds},
				"server": map[string]any{"size": lv.Size, "difficulty": lv.Difficulty, "stars": lv.Stars, "par": par},
			}, &p.ResultID, sessPtr); err != nil {
			return nil, err
		}
	}
	finished := p.FinishedAt
	if finished > now {
		finished = now
	}

	// --- the elapsed clamp --------------------------------------------------
	// Be honest about which bound does the work: a cheater wants a SMALL
	// elapsed, and the floor does not protect the score, because speed_factor
	// saturates at par/3, five times the floor on a 6x6. The floor catches
	// automation claiming 0.1 s and feeds the flag column. Time is not the cheat
	// lever; volume is, and the cooldown, the rate limits and the ceiling are
	// what answer volume.
	floor := domain.ElapsedFloor(lv.Size)
	var wall int64
	if sess != nil {
		wall = now - sess.IssuedAt
	} else if finished > p.StartedAt {
		wall = finished - p.StartedAt
	}
	upper := float64(wall) + 2
	if upper > 86400 {
		upper = 86400
	}
	if upper < floor {
		upper = floor
	}
	elapsed := p.ElapsedSeconds
	if elapsed < floor {
		elapsed = floor
		if err := s.flag(ctx, r, playerID, domain.SigElapsedBelowFloor, domain.WElapsedBelowFloor,
			map[string]any{"client": p.ElapsedSeconds, "floor": floor}, &p.ResultID, sessPtr); err != nil {
			return nil, err
		}
	} else if elapsed > upper {
		elapsed = upper
		if err := s.flag(ctx, r, playerID, domain.SigElapsedAboveWall, domain.WElapsedAboveWall,
			map[string]any{"client": p.ElapsedSeconds, "upper": upper}, &p.ResultID, sessPtr); err != nil {
			return nil, err
		}
	}

	// --- hard rejections: physically impossible, not merely suspicious ------
	if p.Completed {
		switch {
		case p.QueensPlaced < lv.Size,
			p.Taps < p.QueensPlaced,
			p.WrongPlacements > p.QueensPlaced,
			p.HintCount > lv.Size,
			p.ElapsedSeconds > 86400,
			finished-p.StartedAt < int64(elapsed)-2:
			return nil, domain.Err(422, domain.CodeResultInvalid)
		}
	} else if p.FinishedAt > 0 && p.FinishedAt < p.StartedAt {
		if err := s.flag(ctx, r, playerID, domain.SigFinishedBeforeStart, domain.WFinishedBefore, nil, &p.ResultID, sessPtr); err != nil {
			return nil, err
		}
	}

	bd := domain.Breakdown(float64(lv.Difficulty), lv.Size, par, elapsed, p.WrongPlacements, p.HintCount, p.Completed)
	// The tolerance is the math.Pow ULP difference between Go and the client's
	// libm; it must not fire on an honest client.
	if p.Completed && abs(p.Score-bd.Score) > 1 {
		if err := s.flag(ctx, r, playerID, domain.SigScoreMismatch, domain.WScoreMismatch,
			map[string]any{"client": p.Score, "server": bd.Score}, &p.ResultID, sessPtr); err != nil {
			return nil, err
		}
	}

	// --- round bookkeeping --------------------------------------------------
	tierCfg, err := s.tier(player.Tier)
	if err != nil {
		return nil, err
	}
	// The second term can never win once finished_at is clamped to now; it is
	// kept because the stub computed it and the intent is explicit.
	idx := domain.RoundIndex(tierCfg, now)
	if fi := domain.RoundIndex(tierCfg, finished); fi > idx {
		idx = fi
	}
	if err := s.ensureRound(ctx, r, tierCfg, idx); err != nil {
		return nil, err
	}
	// A forfeit joins the round too, exactly like the stub's submit path.
	member, _, err := s.ensureMembership(ctx, r, player, tierCfg, idx)
	if err != nil {
		return nil, err
	}

	if p.Completed {
		if err := s.checkCeiling(ctx, r, player, tierCfg, idx, bd.Score, p.ResultID); err != nil {
			return nil, err
		}
	}

	rec := &domain.Result{
		ResultID: p.ResultID, PlayerID: playerID, LevelID: levelID, SessionID: sessPtr,
		Tier: tierCfg.ID, RoundIndex: idx, Completed: p.Completed, Verified: verified, Schema: p.Schema,
		Size: lv.Size, Difficulty: lv.Difficulty, Stars: lv.Stars, ParSeconds: par, Base: bd.Base,
		StartedAt: p.StartedAt, FinishedAt: finished, ReceivedAt: now,
		ElapsedSeconds: elapsed, ClientElapsedSeconds: p.ElapsedSeconds,
		QueensPlaced: p.QueensPlaced, WrongPlacements: p.WrongPlacements, QueensRemoved: p.QueensRemoved,
		ClearCount: p.ClearCount, HintCount: p.HintCount, Taps: p.Taps,
		Score: bd.Score, ClientScore: p.Score, Flawless: bd.Flawless,
		ClientVersion: p.ClientVersion, PayloadHash: hash, ResponseJSON: "",
	}
	if replaceForfeit {
		ok, err := r.Results.ReplaceForfeit(ctx, rec)
		if err != nil {
			return nil, err
		}
		if !ok {
			stored, err := r.Results.Get(ctx, p.ResultID)
			if err != nil {
				return nil, err
			}
			var decoded SubmitResponse
			_ = json.Unmarshal([]byte(stored.ResponseJSON), &decoded)
			return &SubmitResult{Body: []byte(stored.ResponseJSON), Replay: true, Decoded: decoded}, nil
		}
	} else if err := r.Results.Insert(ctx, rec); err != nil {
		return nil, err
	}

	promotedTo := ""
	if p.Completed {
		if err := s.applyCompleted(ctx, r, player, tierCfg, idx, lv, p, bd, elapsed, par, finished, verified); err != nil {
			return nil, err
		}
	}

	// Re-read what the response reports, inside the same transaction.
	player, err = r.Players.Get(ctx, playerID)
	if err != nil {
		return nil, err
	}
	member, err = r.League.GetMember(ctx, playerID, tierCfg.ID, idx)
	if err != nil {
		return nil, err
	}
	g, err := r.League.GetGroup(ctx, member.GroupID)
	if err != nil {
		return nil, err
	}
	rank, err := r.League.MemberRank(ctx, g.ID, member)
	if err != nil {
		return nil, err
	}
	upCount, err := s.upCountFor(ctx, r, tierCfg)
	if err != nil {
		return nil, err
	}
	leader, err := r.League.GroupLeaderScore(ctx, g.ID)
	if err != nil {
		return nil, err
	}
	counts := domain.Counts(g.MemberCount, tierCfg, s.League, leader, upCount)
	pointsBefore := player.TierPoints

	if p.Completed && domain.ReachesPromo(tierCfg, player.TierPoints) {
		promotedTo, err = s.promoteByScore(ctx, r, player, tierCfg, idx, member, g.MemberCount, rank)
		if err != nil {
			return nil, err
		}
	}

	resp := SubmitResponse{
		Breakdown: bd, RoundScore: member.RoundScore, GroupRank: rank, GroupSize: g.MemberCount,
		Zone: zoneFor(rank, member.RoundScore, g.MemberCount, counts),
		// tier and round_index still describe the OLD tier's round; only
		// promoted_to names the new one. That is the stub's behaviour.
		Tier: tierCfg.ID, RoundIndex: idx,
		TierPoints: pointsBefore, PromoScore: tierCfg.PromoScoreOf(), PromotedTo: promotedTo,
		Verified: verified, ServerTime: now,
	}
	body, err := json.Marshal(resp)
	if err != nil {
		return nil, err
	}
	if err := r.Results.SetResponse(ctx, p.ResultID, string(body)); err != nil {
		return nil, err
	}
	return &SubmitResult{Body: body, Decoded: resp}, nil
}

// applyCompleted updates the stats, the round score and the soft signals of a
// completed game.
func (s *Service) applyCompleted(ctx context.Context, r store.Repos, player *domain.Player, tierCfg domain.Tier,
	idx int64, lv domain.Level, p ResultPayload, bd domain.ScoreBreakdown, elapsed, par float64, finished int64, verified bool) error {

	// Only a session-backed result reaches a leaderboard.
	if verified {
		if _, err := r.Bests.UpsertBest(ctx, &domain.LevelBest{
			PlayerID: player.ID, LevelID: lv.ID, ResultID: p.ResultID, Score: bd.Score,
			WrongPlacements: p.WrongPlacements, TimeSeconds: elapsed, AchievedAt: finished,
		}); err != nil {
			return err
		}
		// The flawless SCOPE filters on wrong == 0 only, while
		// breakdown.flawless also requires hints == 0. Keep the scope as it
		// shipped; tightening it later is additive.
		if p.WrongPlacements == 0 {
			if _, err := r.Bests.UpsertFlawless(ctx, &domain.FlawlessBest{
				PlayerID: player.ID, LevelID: lv.ID, ResultID: p.ResultID, Score: bd.Score,
				TimeSeconds: elapsed, AchievedAt: finished,
			}); err != nil {
				return err
			}
		}
	}

	flawless := 0
	if bd.Flawless {
		flawless = 1
	}
	if err := r.Players.AddGameStats(ctx, player.ID, flawless, bd.Score, s.now()); err != nil {
		return err
	}

	scores, err := r.Results.RoundScores(ctx, player.ID, tierCfg.ID, idx, s.League.RoundBestN)
	if err != nil {
		return err
	}
	games, err := r.Results.CountRoundGames(ctx, player.ID, tierCfg.ID, idx)
	if err != nil {
		return err
	}
	if err := r.League.UpdateMemberScore(ctx, player.ID, tierCfg.ID, idx,
		domain.RoundScore(scores, s.League), games, finished); err != nil {
		return err
	}

	// Soft signals. no_exploration is the signature of reading the solution out
	// of the APK: a real player removes a queen or clears the board at least
	// once on a hard level.
	if p.QueensRemoved == 0 && p.ClearCount == 0 && p.WrongPlacements == 0 && elapsed < par/3 {
		if err := s.flag(ctx, r, player.ID, domain.SigNoExploration, domain.WNoExploration, nil, &p.ResultID, nil); err != nil {
			return err
		}
	}
	if p.Taps == p.QueensPlaced && p.QueensPlaced > 0 {
		if err := s.flag(ctx, r, player.ID, domain.SigTapsEqualPlaced, domain.WTapsEqualPlaced, nil, &p.ResultID, nil); err != nil {
			return err
		}
	}
	// The perfect streak is the only signal that catches the PATIENT cheater --
	// and it also catches the world's best player, which is exactly why it
	// flags rather than rejects.
	streak := 0
	if p.WrongPlacements == 0 && p.HintCount == 0 && elapsed < par/3 {
		streak = player.PerfectStreak + 1
		if domain.WPerfectStreak*float64(streak) <= domain.WPerfectStreakCap {
			if err := s.flag(ctx, r, player.ID, domain.SigPerfectStreak, domain.WPerfectStreak,
				map[string]any{"n": streak}, &p.ResultID, nil); err != nil {
				return err
			}
		}
	}
	return r.Players.SetPerfectStreak(ctx, player.ID, streak)
}

// checkCeiling rejects a round score that is not merely suspicious but
// impossible.
//
// The most a single game can be worth is 2 * base (accuracy and hint cap at 1.0,
// speed at 2.0). A round score is the best N games, and the cooldown caps how
// many distinct levels a player can even start inside one round, so the maximum
// is 2 * sum of the N largest base values among the levels whose cooldown allows
// a start. Anything above that is arithmetic, not judgement. It catches
// replaying one high-value level and forging base by lying about size.
func (s *Service) checkCeiling(ctx context.Context, r store.Repos, player *domain.Player, tierCfg domain.Tier,
	idx int64, newScore int, resultID string) error {

	scores, err := r.Results.RoundScores(ctx, player.ID, tierCfg.ID, idx, s.League.RoundBestN)
	if err != nil {
		return err
	}
	candidate := domain.RoundScore(append(scores, newScore), s.League)

	eligible, err := r.Levels.EligibleLevelIDs(ctx, player.ID,
		domain.RoundStart(tierCfg, idx), domain.RoundEnd(tierCfg, idx), s.Cfg.CooldownSeconds)
	if err != nil {
		return err
	}
	bases := make([]int, 0, len(eligible))
	for _, id := range eligible {
		if lv, ok := s.Level(id); ok {
			bases = append(bases, lv.BasePoints())
		}
	}
	sort.Sort(sort.Reverse(sort.IntSlice(bases)))
	n := s.League.RoundBestN
	if n > len(bases) {
		n = len(bases)
	}
	ceiling := 0
	for i := 0; i < n; i++ {
		ceiling += 2 * bases[i]
	}
	if candidate > ceiling {
		if err := s.flag(ctx, r, player.ID, domain.SigImpossibleRound, domain.WImpossibleRound,
			map[string]any{"candidate": candidate, "ceiling": ceiling}, &resultID, nil); err != nil {
			return err
		}
		return store.CommitAndFail{Err: domain.Err(422, domain.CodeResultInvalid)}
	}
	return nil
}

// promoteByScore moves a Bronze or Silver player up the moment their tier points
// reach the threshold.
//
// It deliberately does NOT join the new tier's running round: that is the stub's
// behaviour and it is pinned by a test. Auto-joining would create phantom
// zero-score members who then get relegated for inactivity.
func (s *Service) promoteByScore(ctx context.Context, r store.Repos, player *domain.Player, tierCfg domain.Tier,
	idx int64, member *domain.Member, groupSize, rank int) (string, error) {

	above := s.League.PromoteTier(tierCfg.ID)
	if above == tierCfg.ID {
		return "", nil
	}
	best, err := r.Results.BestGame(ctx, player.ID, tierCfg.ID, idx)
	if err != nil {
		return "", err
	}
	if _, err := r.League.InsertSummary(ctx, &domain.Summary{
		ID: uuidNew(), PlayerID: player.ID, TierBefore: tierCfg.ID, RoundIndex: idx, TierAfter: above,
		Outcome: domain.OutcomePromoted, Reason: domain.ReasonScore,
		Rank: rank, GroupSize: groupSize, RoundScore: member.RoundScore,
		TierPoints: player.TierPoints, BestGame: best, CreatedAt: s.now(),
	}); err != nil {
		return "", err
	}
	aboveCfg, err := s.tier(above)
	if err != nil {
		return "", err
	}
	settled := domain.RoundStart(aboveCfg, domain.RoundIndex(aboveCfg, s.now()))
	ok, err := r.Players.SetTier(ctx, player.ID, tierCfg.ID, above, s.now(), settled)
	if err != nil {
		return "", err
	}
	if !ok {
		return "", domain.ErrRetry
	}
	// The old membership stays and keeps its score: other members' ranks depend
	// on it. left_at tells the closer not to settle this player again.
	if err := r.League.MarkMemberLeft(ctx, player.ID, tierCfg.ID, idx, s.now()); err != nil {
		return "", err
	}
	return above, nil
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}
