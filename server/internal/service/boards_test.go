package service_test

import (
	"context"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

// Global order: score desc, then fewer mistakes, then faster, then earlier, then
// player id. The last key is what keeps two identical runs from swapping rank
// between two calls.
func TestLeaderboardGlobalOrderAndRank(t *testing.T) {
	h := newHarness(t)
	lv := h.levelOfSize(t, 6)
	fast := h.registerAndPlay(t, "Fast", lv, 40, 0)
	slow := h.registerAndPlay(t, "Slow", lv, 200, 0)
	sloppy := h.registerAndPlay(t, "Sloppy", lv, 40, 3)

	board := h.board(t, fast, lv.ID, domain.ScopeGlobal)
	if len(board.Entries) != 3 {
		t.Fatalf("expected three entries, got %d", len(board.Entries))
	}
	if board.Entries[0].PlayerID != fast {
		t.Errorf("the fastest clean run leads, got %s", board.Entries[0].Nickname)
	}
	for i, e := range board.Entries {
		if e.Rank != i+1 {
			t.Errorf("entry %d has rank %d", i, e.Rank)
		}
	}
	if board.Entries[0].Score < board.Entries[1].Score {
		t.Error("entries must be ordered by score descending")
	}
	if board.MyRank != 1 || board.MyEntry == nil || !board.MyEntry.IsMe {
		t.Errorf("my_rank/my_entry wrong: %d %+v", board.MyRank, board.MyEntry)
	}
	if board.TotalPlayers != 3 {
		t.Errorf("total_players = %d, want 3", board.TotalPlayers)
	}
	if board.ParSeconds != lv.Par() {
		t.Errorf("par_seconds = %v, want %v", board.ParSeconds, lv.Par())
	}
	// The rank from the OR-chain must agree with the position in the list.
	other := h.board(t, slow, lv.ID, domain.ScopeGlobal)
	for _, e := range other.Entries {
		if e.PlayerID == slow && e.Rank != other.MyRank {
			t.Errorf("my_rank %d disagrees with the listed rank %d", other.MyRank, e.Rank)
		}
	}
	_ = sloppy
}

// The flawless board keeps each player's FASTEST CLEAN run, independently of
// their score-best. The offline stub filtered the score-best entry on wrong == 0
// and so hid a player whose top-scoring run had a mistake, even when they also
// had a clean run.
func TestFlawlessBoardKeepsFastestCleanRunIndependently(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")

	// A high-scoring run with one mistake on a hard level...
	hard := h.hardestLevel(t)
	st := h.start(t, p, hard.ID)
	h.clock.Add(100)
	best := h.submit(t, h.payload(p, hard, st, 100, 1, 0))

	// ...and a clean but lower-scoring run on an easy one.
	easy := h.levelOfSize(t, 6)
	st2 := h.start(t, p, easy.ID)
	h.clock.Add(90)
	clean := h.submit(t, h.payload(p, easy, st2, 90, 0, 0))
	if clean.Decoded.Breakdown.Score >= best.Decoded.Breakdown.Score {
		t.Fatalf("the test needs the clean run to score lower")
	}

	board := h.board(t, p, easy.ID, domain.ScopeFlawless)
	if len(board.Entries) != 1 || board.MyRank != 1 {
		t.Fatalf("the clean run must appear on the flawless board, got %+v", board)
	}
	if board.Entries[0].WrongPlacements != 0 {
		t.Error("a flawless entry has no mistakes")
	}
	// The run with a mistake never reaches the flawless board of its own level.
	if b := h.board(t, p, hard.ID, domain.ScopeFlawless); len(b.Entries) != 0 {
		t.Errorf("a run with a mistake must not be on the flawless board, got %+v", b.Entries)
	}
}

func TestFlawlessBoardOrdersByTime(t *testing.T) {
	h := newHarness(t)
	lv := h.levelOfSize(t, 6)
	slow := h.registerAndPlay(t, "Slow", lv, 300, 0)
	fast := h.registerAndPlay(t, "Fast", lv, 45, 0)
	board := h.board(t, fast, lv.ID, domain.ScopeFlawless)
	if len(board.Entries) != 2 {
		t.Fatalf("expected two entries, got %d", len(board.Entries))
	}
	if board.Entries[0].PlayerID != fast || board.Entries[1].PlayerID != slow {
		t.Error("the flawless board is ordered by time, fastest first")
	}
}

// Friendship is directed: A follows B, and B does not thereby see A.
func TestFriendsScopeIsDirected(t *testing.T) {
	h := newHarness(t)
	lv := h.levelOfSize(t, 6)
	a := h.registerAndPlay(t, "Aaa", lv, 50, 0)
	b := h.registerAndPlay(t, "Bbb", lv, 60, 0)
	h.follow(t, a, b)

	aBoard := h.board(t, a, lv.ID, domain.ScopeFriends)
	if len(aBoard.Entries) != 2 {
		t.Errorf("A follows B, so A sees both: got %d", len(aBoard.Entries))
	}
	bBoard := h.board(t, b, lv.ID, domain.ScopeFriends)
	if len(bBoard.Entries) != 1 || bBoard.Entries[0].PlayerID != b {
		t.Errorf("B does not follow A, so B sees only themselves: got %+v", bBoard.Entries)
	}
	for _, e := range aBoard.Entries {
		if e.PlayerID == b && !e.IsFriend {
			t.Error("a followed player must be marked is_friend")
		}
	}
}

func TestLeaderboardEmptyAndUnknownLevel(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	board := h.board(t, p, lv.ID, domain.ScopeGlobal)
	if len(board.Entries) != 0 || board.MyRank != 0 || board.MyEntry != nil {
		t.Errorf("an empty board has no entries, rank 0 and no my_entry: %+v", board)
	}
	_, err := h.svc.Leaderboard(context.Background(), p, "00000000-0000-4000-8000-000000000000", domain.ScopeGlobal, 10)
	if ce := codedError(t, err); ce.Code != domain.CodeLevelUnknown {
		t.Errorf("expected ERR_LEVEL_UNKNOWN, got %s", ce.Code)
	}
}

func TestLeaderboardLimitIsClamped(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)
	if _, err := h.svc.Leaderboard(context.Background(), p, lv.ID, domain.ScopeGlobal, 100000); err != nil {
		t.Fatal(err)
	}
	if _, err := h.svc.Leaderboard(context.Background(), p, lv.ID, domain.ScopeGlobal, -5); err != nil {
		t.Fatal(err)
	}
}

// A shadow-excluded player disappears from the global board for others, keeps
// their own view, and stays visible to the friends who follow them: hiding them
// there generates support mail from the friend.
func TestShadowExcludedHiddenGloballyVisibleToFriendsAndSelf(t *testing.T) {
	h := newHarness(t)
	lv := h.levelOfSize(t, 6)
	cheat := h.registerAndPlay(t, "Cheat", lv, 45, 0)
	other := h.registerAndPlay(t, "Other", lv, 200, 0)
	h.follow(t, other, cheat)
	h.shadowExclude(t, cheat)

	global := h.board(t, other, lv.ID, domain.ScopeGlobal)
	for _, e := range global.Entries {
		if e.PlayerID == cheat {
			t.Error("an excluded player must not appear on someone else's global board")
		}
	}
	own := h.board(t, cheat, lv.ID, domain.ScopeGlobal)
	found := false
	for _, e := range own.Entries {
		if e.PlayerID == cheat {
			found = true
		}
	}
	if !found || own.MyRank == 0 {
		t.Error("an excluded player still sees their own entry and rank")
	}
	friends := h.board(t, other, lv.ID, domain.ScopeFriends)
	found = false
	for _, e := range friends.Entries {
		if e.PlayerID == cheat {
			found = true
		}
	}
	if !found {
		t.Error("an excluded player stays visible to the friends who follow them")
	}
}

func TestLevelMetaCarriesParAndLocksAndAStableETag(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.levelOfSize(t, 6)

	meta, etag1, err := h.svc.LevelMeta(context.Background(), p)
	if err != nil {
		t.Fatal(err)
	}
	if len(meta.Levels) != h.svc.LevelCount() {
		t.Errorf("meta covers %d levels, want %d", len(meta.Levels), h.svc.LevelCount())
	}
	if meta.Levels[lv.ID].ParSeconds != lv.Par() {
		t.Errorf("par wrong: %v", meta.Levels[lv.ID].ParSeconds)
	}
	if meta.Levels[lv.ID].LockedUntil != 0 {
		t.Error("an unplayed level has no lock")
	}
	if _, etag2, _ := h.svc.LevelMeta(context.Background(), p); etag2 != etag1 {
		t.Error("the ETag must not move on its own")
	}

	h.start(t, p, lv.ID)
	meta3, etag3, err := h.svc.LevelMeta(context.Background(), p)
	if err != nil {
		t.Fatal(err)
	}
	if etag3 == etag1 {
		t.Error("starting a game must move the ETag")
	}
	if got := meta3.Levels[lv.ID].LockedUntil; got != h.clock.Now()+h.svc.Cfg.CooldownSeconds {
		t.Errorf("locked_until = %d, want now + cooldown", got)
	}
}
