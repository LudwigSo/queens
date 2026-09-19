package domain

import (
	"errors"
	"time"
)

// Clock is injected everywhere so tests can travel in time. Never call
// time.Now() in a service; never let SQLite produce a timestamp.
type Clock interface{ Now() int64 }

type SystemClock struct{}

func (SystemClock) Now() int64 { return time.Now().Unix() }

// FixedClock is the test clock. Set is safe to call between requests.
type FixedClock struct{ T int64 }

func (c *FixedClock) Now() int64  { return c.T }
func (c *FixedClock) Set(t int64) { c.T = t }
func (c *FixedClock) Add(d int64) { c.T += d }

// Sentinel errors shared by the store and the services.
var (
	ErrNotFound = errors.New("not found")
	ErrConflict = errors.New("conflict")
	// ErrRetry means a conditional update lost a race and the whole transaction
	// closure should run again.
	ErrRetry = errors.New("retry transaction")
)

const (
	// CooldownDefault is the per-level lock, 7 days (GameConfig.cooldown_seconds).
	CooldownDefault int64 = 7 * 86400
	// SessionFreshness governs the weight-1 session_stale signal only.
	SessionFreshness int64 = 6 * 3600
	// SessionAcceptance is how long a session may still back a submission. It is
	// long on purpose: pending_results is an offline queue and a player can be
	// offline for weeks. Shortening this silently destroys honest scores.
	SessionAcceptance int64 = 30 * 86400
	// AnomalyHalfLife is 30 days; AnomalyShadowAt / AnomalyClearAt give the
	// exclusion hysteresis.
	AnomalyHalfLife float64 = 30 * 86400
	AnomalyShadowAt float64 = 15
	AnomalyClearAt  float64 = 5

	FriendLimit    = 50
	NicknameMinLen = 2
	NicknameMaxLen = 16
)

type Player struct {
	ID               string
	Nickname         string
	FriendCode       string
	Tier             string
	TierPoints       int
	TierSince        int64
	SettledRoundEnd  int64
	Games            int
	Flawless         int
	BestScore        int
	RoundsPlayed     int
	PerfectStreak    int
	AnomalyScore     float64
	AnomalyUpdatedAt int64
	ShadowExcluded   bool
	BannedAt         *int64
	AuthProvider     *string
	AuthExternalID   *string
	ClientVersion    string
	CreatedAt        int64
	UpdatedAt        int64
	LastSeenAt       int64
}

type Token struct {
	Hash       string
	PlayerID   string
	CreatedAt  int64
	LastSeenAt int64
	RevokedAt  *int64
	BannedAt   *int64
}

type Level struct {
	ID           string
	Size         int
	Difficulty   int
	Stars        int
	Seed         int
	RegionsJSON  string
	SolutionJSON string
	ContentHash  string
	ParOverride  *float64
	InCurrentSet bool
	CreatedAt    int64
	UpdatedAt    int64
}

// Par returns the level's par, preferring a server-side override. The client
// never gets a say: par is the numerator of (par/elapsed)^0.63, so a submitted
// par_seconds of 1e9 would pin the speed factor at its maximum.
func (l Level) Par() float64 {
	if l.ParOverride != nil && *l.ParOverride > 0 {
		return *l.ParOverride
	}
	return ParSeconds(float64(l.Difficulty), l.Size)
}

func (l Level) BasePoints() int { return Base(float64(l.Difficulty), l.Size) }

type LevelSet struct {
	Hash       string
	LevelCount int
	ImportedAt int64
}

type PlayerLevel struct {
	PlayerID      string
	LevelID       string
	LastStartedAt int64
	Plays         int
}

// CooldownRemaining mirrors queens/scripts/cooldown.gd: clamped into
// [0, cooldownSeconds] so a backwards clock jump cannot extend a lock.
func CooldownRemaining(lastStartedAt, now, cooldownSeconds int64) int64 {
	if lastStartedAt <= 0 {
		return 0
	}
	r := cooldownSeconds - (now - lastStartedAt)
	if r < 0 {
		return 0
	}
	if r > cooldownSeconds {
		return cooldownSeconds
	}
	return r
}

type Session struct {
	ID                string
	PlayerID          string
	LevelID           string
	IssuedAt          int64
	ExpiresAt         int64
	ConsumedAt        *int64
	ResultID          *string
	TierAtIssue       string
	RoundIndexAtIssue int64
	GroupID           string
	IntegrityVerdict  *string
	ClientVersion     string
}

type Result struct {
	ResultID             string
	PlayerID             string
	LevelID              string
	SessionID            *string
	Tier                 string
	RoundIndex           int64
	Completed            bool
	Verified             bool
	Schema               int
	Size                 int
	Difficulty           int
	Stars                int
	ParSeconds           float64
	Base                 int
	StartedAt            int64
	FinishedAt           int64
	ReceivedAt           int64
	ElapsedSeconds       float64
	ClientElapsedSeconds float64
	QueensPlaced         int
	WrongPlacements      int
	QueensRemoved        int
	ClearCount           int
	HintCount            int
	Taps                 int
	Score                int
	ClientScore          int
	Flawless             bool
	ClientVersion        string
	PayloadHash          string
	ResponseJSON         string
}

type BestGame struct {
	LevelID string `json:"level_id"`
	Score   int    `json:"score"`
}

type LevelBest struct {
	PlayerID        string
	LevelID         string
	ResultID        string
	Score           int
	WrongPlacements int
	TimeSeconds     float64
	AchievedAt      int64
}

type FlawlessBest struct {
	PlayerID    string
	LevelID     string
	ResultID    string
	Score       int
	TimeSeconds float64
	AchievedAt  int64
}

type LeaderboardEntry struct {
	Rank            int     `json:"rank"`
	PlayerID        string  `json:"player_id"`
	Nickname        string  `json:"nickname"`
	Score           int     `json:"score"`
	TimeSeconds     float64 `json:"time_seconds"`
	WrongPlacements int     `json:"wrong_placements"`
	AchievedAt      int64   `json:"achieved_at"`
	IsMe            bool    `json:"is_me"`
	IsFriend        bool    `json:"is_friend"`
}

type Scope string

const (
	ScopeGlobal   Scope = "global"
	ScopeFriends  Scope = "friends"
	ScopeFlawless Scope = "flawless"
)

type BoardQuery struct {
	LevelID   string
	Me        string
	Scope     Scope
	Limit     int
	FriendIDs []string
}

const (
	RoundOpen    = "open"
	RoundClosing = "closing"
	RoundClosed  = "closed"
)

type Round struct {
	Tier             string
	RoundIndex       int64
	StartsAt         int64
	EndsAt           int64
	State            string
	GroupSeq         int
	UpCount          *int
	BelowPlayers     *int
	MembersInTier    *int
	ClosingStartedAt *int64
	ClosedAt         *int64
	CreatedAt        int64
}

// UpCountOr returns the frozen up_count or -1, the "use the percentage" sentinel.
func (r Round) UpCountOr() int {
	if r.UpCount == nil {
		return -1
	}
	return *r.UpCount
}

// FrozenCounts are written onto the round row when it is claimed, so every group
// of the round and every resumed close see the same numbers.
type FrozenCounts struct {
	UpCount       *int
	BelowPlayers  *int
	MembersInTier *int
}

type Group struct {
	ID          string
	Tier        string
	RoundIndex  int64
	Quarantine  bool
	Capacity    *int
	MemberCount int
	State       string
	ClosedAt    *int64
	CreatedAt   int64
}

type Summary struct {
	ID         string
	PlayerID   string
	TierBefore string
	RoundIndex int64
	TierAfter  string
	Outcome    string
	Reason     string
	Rank       int
	GroupSize  int
	RoundScore int
	TierPoints int
	BestGame   *BestGame
	Seen       bool
	SeenAt     *int64
	CreatedAt  int64
}

type FriendRow struct {
	PlayerID    string `json:"player_id"`
	Nickname    string `json:"nickname"`
	Tier        string `json:"tier"`
	RoundScore  int    `json:"round_score"`
	FriendSince int64  `json:"friend_since"`
	FriendCode  string `json:"friend_code"`
}

type Flag struct {
	ID         string
	PlayerID   string
	Signal     string
	Weight     float64
	ResultID   *string
	SessionID  *string
	DetailJSON *string
	CreatedAt  int64
}

// Anti-cheat signal names and weights (handover 7.5).
const (
	SigScoreMismatch        = "score_mismatch"
	SigElapsedBelowFloor    = "elapsed_below_floor"
	SigElapsedAboveWall     = "elapsed_above_wall"
	SigNoExploration        = "no_exploration"
	SigTapsEqualPlaced      = "taps_equal_placed"
	SigNoSession            = "no_session"
	SigSessionStale         = "session_stale"
	SigSessionReuse         = "session_reuse"
	SigCooldownViolation    = "cooldown_violation_attempt"
	SigFinishedBeforeStart  = "finished_before_started"
	SigFriendCodeProbing    = "friend_code_probing"
	SigImpossibleRound      = "impossible_round_score"
	SigPerfectStreak        = "perfect_streak"
	SigLevelMetaMismatch    = "level_meta_mismatch"
	SigReplayBodyMismatch   = "replay_body_mismatch"
	SigPlayerMismatch       = "payload_player_mismatch"
	SigSessionLevelMismatch = "session_level_mismatch"
)

const (
	WScoreMismatch     = 3.0
	WElapsedBelowFloor = 5.0
	WElapsedAboveWall  = 2.0
	WNoExploration     = 4.0
	WTapsEqualPlaced   = 2.0
	WNoSession         = 8.0
	WSessionStale      = 1.0
	WCooldownViolation = 3.0
	WFinishedBefore    = 4.0
	WFriendProbing     = 2.0
	WImpossibleRound   = 20.0
	WPerfectStreak     = 0.5
	WPerfectStreakCap  = 6.0
	WLevelMetaMismatch = 1.0
	WPlayerMismatch    = 8.0
	WSessionReuse      = 2.0
)

// ElapsedFloor is the shortest humanly possible game: 1.5 s of screen
// transition and first look, 0.45 s per deliberate tap, 0.010 s per cell of
// visual search. 6x6 -> 4.56 s, 10x10 -> 7.00 s.
//
// Be honest about what this buys: speed_factor saturates at par/3, which for a
// 6x6 at difficulty 8 is 24 s, five times the floor. The floor does not protect
// the score; it catches automation claiming 0.1 s and feeds the flag column.
func ElapsedFloor(size int) float64 {
	s := float64(size)
	return 1.5 + 0.45*s + 0.010*s*s
}

// DecayAnomaly applies the 30-day half-life lazily, on read.
func DecayAnomaly(score float64, updatedAt, now int64) float64 {
	if score <= 0 || updatedAt <= 0 || now <= updatedAt {
		return score
	}
	return score * pow2(-float64(now-updatedAt)/AnomalyHalfLife)
}
