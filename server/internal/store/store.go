// Package store defines the persistence boundary. Everything above it talks to
// these interfaces only, so the SQLite engine can be swapped for Postgres by
// writing one more implementation (with its own hand-written SQL and DDL -- the
// swap promise is kept by the interface, not by shared SQL).
package store

import (
	"context"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

// Repos is the set of repositories. Inside InTx every one of them -- reads
// included -- is bound to the same transaction.
type Repos struct {
	Players  PlayerRepo
	Levels   LevelRepo
	Sessions SessionRepo
	Results  ResultRepo
	Bests    LevelBestRepo
	League   LeagueRepo
	Friends  FriendRepo
	Flags    FlagRepo
	Rates    RateRepo
}

type Store interface {
	Repos() Repos
	// InTx runs fn in one write transaction (BEGIN IMMEDIATE). A non-nil return
	// rolls back. It retries the whole closure on a busy database and on
	// domain.ErrRetry, which a conditional update returns when it loses a race.
	InTx(ctx context.Context, fn func(context.Context, Repos) error) error
	Ping(ctx context.Context) error
	// Checkpoint runs PRAGMA wal_checkpoint(TRUNCATE) at shutdown.
	Checkpoint(ctx context.Context) error
	// BackupTo runs VACUUM INTO, which needs no cgo, unlike sqlite3 .backup.
	BackupTo(ctx context.Context, path string) error
	Close() error
}

// CommitAndFail commits the transaction and then returns Err. It exists for the
// two paths that must persist an anti-cheat flag while still rejecting the
// request: a locked level and an impossible round score.
type CommitAndFail struct{ Err error }

func (e CommitAndFail) Error() string { return e.Err.Error() }
func (e CommitAndFail) Unwrap() error { return e.Err }

type PlayerRepo interface {
	Get(ctx context.Context, id string) (*domain.Player, error)
	GetByFriendCode(ctx context.Context, code string) (*domain.Player, error)
	FriendCodeExists(ctx context.Context, code string) (bool, error)
	Create(ctx context.Context, p *domain.Player) error
	UpdateNickname(ctx context.Context, id, nickname string, now int64) error
	// AddGameStats bumps counters in SQL (never read-modify-write in Go).
	AddGameStats(ctx context.Context, id string, flawless, score int, now int64) error
	SetPerfectStreak(ctx context.Context, id string, n int) error
	IncRoundsPlayed(ctx context.Context, id string) error
	// SetTier is conditional on the current tier and resets tier_points when
	// from != to. false means the guard did not match: someone moved the player
	// first, so the caller returns domain.ErrRetry.
	SetTier(ctx context.Context, id, from, to string, tierSince, settledRoundEnd int64) (bool, error)
	SetSettledRoundEnd(ctx context.Context, id string, ts int64) error
	CountByTier(ctx context.Context, tier string) (int, error)
	TouchLastSeen(ctx context.Context, id string, now int64) error
	SetBanned(ctx context.Context, id string, at *int64) error
	Delete(ctx context.Context, id string) error
	List(ctx context.Context, limit int) ([]domain.Player, error)

	InsertToken(ctx context.Context, hash, playerID string, now int64) error
	GetToken(ctx context.Context, hash string) (*domain.Token, error)
	TouchToken(ctx context.Context, hash string, now int64) error
	RevokeTokens(ctx context.Context, playerID string, now int64) error
	DeleteRevokedTokensBefore(ctx context.Context, before int64) (int64, error)
}

type LevelRepo interface {
	Get(ctx context.Context, id string) (*domain.Level, error)
	All(ctx context.Context) ([]domain.Level, error)
	Upsert(ctx context.Context, lv *domain.Level, now int64) error
	MarkNotInSet(ctx context.Context, keepIDs []string, now int64) ([]string, error)
	InsertLevelSet(ctx context.Context, hash string, count int, now int64) error
	CurrentLevelSet(ctx context.Context) (*domain.LevelSet, error)

	GetPlayerLevel(ctx context.Context, playerID, levelID string) (*domain.PlayerLevel, error)
	ListPlayerLevels(ctx context.Context, playerID string) ([]domain.PlayerLevel, error)
	RecordStart(ctx context.Context, playerID, levelID string, now int64) error
	// EligibleLevelIDs lists the levels the player could have started inside
	// [roundStart, roundEnd) given the cooldown. It is the input to the
	// round-score ceiling check.
	EligibleLevelIDs(ctx context.Context, playerID string, roundStart, roundEnd, cooldownSeconds int64) ([]string, error)
}

type SessionRepo interface {
	Insert(ctx context.Context, s *domain.Session) error
	Get(ctx context.Context, id string) (*domain.Session, error)
	// FindReusable returns an unconsumed session for (player, level) issued at or
	// after `since`, so a lost response does not cost the player a 7-day lock.
	FindReusable(ctx context.Context, playerID, levelID string, since int64) (*domain.Session, error)
	// Consume is the single-use guard: UPDATE ... WHERE consumed_at IS NULL.
	Consume(ctx context.Context, id, resultID string, now int64) (bool, error)
	DeleteUnconsumedBefore(ctx context.Context, issuedBefore int64) (int64, error)
	DeleteConsumedBefore(ctx context.Context, consumedBefore int64) (int64, error)
}

type ResultRepo interface {
	Get(ctx context.Context, id string) (*domain.Result, error)
	Insert(ctx context.Context, r *domain.Result) error
	// ReplaceForfeit overwrites a stored completed=0 row in place. false means it
	// is no longer a forfeit, so the caller returns the stored response instead.
	ReplaceForfeit(ctx context.Context, r *domain.Result) (bool, error)
	SetResponse(ctx context.Context, id, responseJSON string) error
	RoundScores(ctx context.Context, playerID, tier string, roundIndex int64, bestN int) ([]int, error)
	CountRoundGames(ctx context.Context, playerID, tier string, roundIndex int64) (int, error)
	BestGame(ctx context.Context, playerID, tier string, roundIndex int64) (*domain.BestGame, error)
}

type LevelBestRepo interface {
	UpsertBest(ctx context.Context, b *domain.LevelBest) (bool, error)
	UpsertFlawless(ctx context.Context, b *domain.FlawlessBest) (bool, error)
	MyBest(ctx context.Context, playerID, levelID string) (*domain.LevelBest, error)
	MyFlawless(ctx context.Context, playerID, levelID string) (*domain.FlawlessBest, error)
	Board(ctx context.Context, q domain.BoardQuery) ([]domain.LeaderboardEntry, error)
	Rank(ctx context.Context, q domain.BoardQuery) (int, error)
	Total(ctx context.Context, q domain.BoardQuery) (int, error)
}

type LeagueRepo interface {
	EnsureRound(ctx context.Context, tier string, idx, startsAt, endsAt, now int64) error
	GetRound(ctx context.Context, tier string, idx int64) (*domain.Round, error)
	DueRounds(ctx context.Context, now int64, tier string) ([]domain.Round, error)
	RoundEndingAt(ctx context.Context, tier string, endsAt int64) (*domain.Round, error)
	ClaimRound(ctx context.Context, tier string, idx, now int64, f domain.FrozenCounts) (bool, error)
	FinishRound(ctx context.Context, tier string, idx, now int64) error
	NextGroupSeq(ctx context.Context, tier string, idx int64) (int, error)

	FindOpenGroup(ctx context.Context, tier string, idx int64, quarantine bool) (*domain.Group, error)
	CreateGroup(ctx context.Context, g *domain.Group) error
	IncGroupCount(ctx context.Context, groupID string) (bool, error)
	DecGroupCountsForPlayer(ctx context.Context, playerID string) error
	OpenGroups(ctx context.Context, tier string, idx int64) ([]domain.Group, error)
	ClaimGroupClose(ctx context.Context, groupID string, now int64) (bool, error)
	GetGroup(ctx context.Context, groupID string) (*domain.Group, error)

	GetMember(ctx context.Context, playerID, tier string, idx int64) (*domain.Member, error)
	InsertMember(ctx context.Context, playerID, tier string, idx int64, groupID string, now int64) error
	UpdateMemberScore(ctx context.Context, playerID, tier string, idx int64, roundScore, games int, lastSubmitAt int64) error
	MarkMemberLeft(ctx context.Context, playerID, tier string, idx, now int64) error
	GroupMembersSorted(ctx context.Context, groupID string) ([]domain.Member, error)
	GroupLeaderScore(ctx context.Context, groupID string) (int, error)
	GroupPromoteCount(ctx context.Context, groupID string, up int) (int, error)
	// MemberRank is COUNT(*)+1 of strictly-better rows, written as an explicit
	// lexicographic OR-chain (row-value comparison would be wrong: the sort keys
	// mix ASC and DESC).
	MemberRank(ctx context.Context, groupID string, m *domain.Member) (int, error)
	// StandingWindow returns the top `top` rows plus the window [lo, hi] around
	// me plus my own row, with absolute ranks.
	StandingWindow(ctx context.Context, groupID, me string, top, lo, hi int) ([]domain.Member, error)
	SetMemberOutcome(ctx context.Context, playerID, tier string, idx int64, rank int, zone, outcome string) error

	InsertSummary(ctx context.Context, s *domain.Summary) (bool, error)
	LatestUnseenSummary(ctx context.Context, playerID string) (*domain.Summary, error)
	AckSummary(ctx context.Context, playerID string, roundIndex, now int64) error
	CountSummaries(ctx context.Context, playerID string) (int, error)
}

type FriendRepo interface {
	List(ctx context.Context, playerID string) ([]domain.FriendRow, error)
	IDs(ctx context.Context, playerID string) ([]string, error)
	Count(ctx context.Context, playerID string) (int, error)
	Add(ctx context.Context, playerID, friendID string, now int64) (bool, error)
	Remove(ctx context.Context, playerID, friendID string) (bool, error)
	IsFriend(ctx context.Context, playerID, otherID string) (bool, error)
}

type FlagRepo interface {
	Insert(ctx context.Context, f *domain.Flag) error
	ListByPlayer(ctx context.Context, playerID string, limit int) ([]domain.Flag, error)
	ReadAnomaly(ctx context.Context, playerID string) (score float64, updatedAt int64, shadow bool, err error)
	WriteAnomaly(ctx context.Context, playerID string, score float64, updatedAt int64, shadow bool) error
	DeleteBefore(ctx context.Context, createdBefore int64) (int64, error)
}

type RateRepo interface {
	Bump(ctx context.Context, key string, day int64) (int, error)
	Peek(ctx context.Context, key string, day int64) (int, error)
	DeleteBefore(ctx context.Context, day int64) (int64, error)
}
