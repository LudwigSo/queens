package service_test

import (
	"context"
	"sort"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

// A Gold group is topped up to 30 with bots that look like anyone else, keep
// their identity across reads, play over the week, and give up a seat to every
// person who joins.
func TestBotsFillGoldAndGiveWayToPeople(t *testing.T) {
	h := newHarness(t)
	// Monday morning, so the week still has days left to watch the bots play.
	gold := h.tier(t, "gold")
	h.clock.Set(domain.RoundStart(gold, domain.RoundIndex(gold, h.clock.Now())) + 3600)
	ann := h.registerIn(t, "Ann", "gold")
	h.start(t, ann, h.freshLevelAnySize(t).ID)

	st := h.standing(t, ann)
	if st.Group == nil || st.Group.Size != 30 || len(st.Group.Members) != 30 {
		t.Fatalf("a gold group with one person shows 30 rows, got %+v", st.Group)
	}
	ids := map[string]string{}
	for _, m := range st.Group.Members {
		if m.Nickname == "" || m.PlayerID == "" {
			t.Errorf("a bot needs a name and an id: %+v", m)
		}
		ids[m.PlayerID] = m.Nickname
	}
	if len(ids) != 30 {
		t.Errorf("30 distinct members, got %d", len(ids))
	}

	// Later in the week the same bots have played more.
	before := map[string]int{}
	for _, m := range st.Group.Members {
		before[m.PlayerID] = m.RoundScore
	}
	h.clock.Add(3 * 86400)
	later := h.standing(t, ann)
	grew := false
	for _, m := range later.Group.Members {
		if _, ok := ids[m.PlayerID]; !ok {
			t.Fatalf("member %s appeared from nowhere", m.PlayerID)
		}
		if m.RoundScore < before[m.PlayerID] {
			t.Errorf("a bot's score went down: %s", m.Nickname)
		}
		grew = grew || m.RoundScore > before[m.PlayerID]
	}
	if !grew {
		t.Error("over three days at least one bot must have played")
	}

	// A second person takes a bot's seat: still 30, both people present.
	bob := h.registerIn(t, "Bob", "gold")
	h.start(t, bob, h.freshLevelAnySize(t).ID)
	both := h.standing(t, ann)
	if both.Group.Size != 30 {
		t.Errorf("one bot leaves for every person, got %d", both.Group.Size)
	}
	seen := 0
	for _, m := range both.Group.Members {
		if m.PlayerID == ann || m.PlayerID == bob {
			seen++
		}
	}
	if seen != 2 {
		t.Errorf("both people must be in the standing, found %d", seen)
	}
}

// Silver has no bots and no groups; Diamond is global and has no bots either.
func TestBotsOnlyInGoldAndPlatinum(t *testing.T) {
	h := newHarness(t)
	d := h.registerIn(t, "Dia", "diamond")
	h.start(t, d, h.freshLevelAnySize(t).ID)
	if st := h.standing(t, d); st.Group == nil || st.Group.Size != 1 {
		t.Errorf("diamond holds only its people, got %+v", st.Group)
	}
	p := h.registerIn(t, "Pla", "platinum")
	h.start(t, p, h.freshLevelAnySize(t).ID)
	if st := h.standing(t, p); st.Group == nil || st.Group.Size != 30 {
		t.Errorf("platinum is topped up to 30, got %+v", st.Group)
	}
}

// Bots compete: at the close a bot can hold a promotion place, and the person
// below it does not get that place.
func TestBotsTakePlacesAtTheClose(t *testing.T) {
	h := newHarness(t)
	ann := h.registerIn(t, "Ann", "gold")
	lv := h.levelOfSize(t, 6) // a small level: well below the strongest bots
	st := h.start(t, ann, lv.ID)
	h.clock.Add(300)
	h.submit(t, h.payload(ann, lv, st, 300, 3, 0))

	gold := h.tier(t, "gold")
	idx := domain.RoundIndex(gold, h.clock.Now())
	h.clock.Set(domain.RoundEnd(gold, idx) + 1)
	if err := h.svc.CloseDueRounds(context.Background()); err != nil {
		t.Fatal(err)
	}
	sum := h.summary(t, ann)
	if sum == nil || sum.GroupSize != 30 {
		t.Fatalf("expected a summary of a group of 30, got %+v", sum)
	}
	if sum.Rank <= 6 {
		t.Errorf("one slow 6x6 game should not beat the week's best bots, rank %d", sum.Rank)
	}
	if sum.Outcome != domain.OutcomeStayed {
		t.Errorf("outside the top six of 30 a gold player stays, got %s", sum.Outcome)
	}
	if h.summaryCount(t, ann) != 1 {
		t.Error("exactly one summary")
	}
}

// Friends sit together: a group that random placement considers full (30)
// still takes a friend, up to 50, in either direction of the follow.
func TestFriendsJoinBeyondThirtyUpToFifty(t *testing.T) {
	h := newHarness(t)
	members := h.seedTierGroup(t, "platinum", 30)
	full := h.standing(t, members[0]).Group.GroupID

	stranger := h.registerIn(t, "Stranger", "platinum")
	h.start(t, stranger, h.freshLevelAnySize(t).ID)
	if got := h.standing(t, stranger).Group.GroupID; got == full {
		t.Error("random placement stops at 30")
	}

	// I follow a member.
	fan := h.registerIn(t, "Fan", "platinum")
	h.follow(t, fan, members[0])
	h.start(t, fan, h.freshLevelAnySize(t).ID)
	if got := h.standing(t, fan); got.Group.GroupID != full || got.Group.Size != 31 {
		t.Errorf("a friend joins the full group: %s size %d", got.Group.GroupID, got.Group.Size)
	}
	// A member follows me.
	idol := h.registerIn(t, "Idol", "platinum")
	h.follow(t, members[1], idol)
	h.start(t, idol, h.freshLevelAnySize(t).ID)
	if got := h.standing(t, idol).Group.GroupID; got != full {
		t.Error("being followed by a member is friendship too")
	}

	// Up to 50 people, then a friend goes elsewhere.
	for i := 0; i < 18; i++ {
		f := h.registerIn(t, "F"+itoa(int64(i)), "platinum")
		h.follow(t, f, members[2])
		h.start(t, f, h.freshLevelAnySize(t).ID)
	}
	if got := h.standing(t, members[0]).Group.Size; got != 50 {
		t.Fatalf("the group holds 50 people now, got %d", got)
	}
	late := h.registerIn(t, "Late", "platinum")
	h.follow(t, late, members[3])
	h.start(t, late, h.freshLevelAnySize(t).ID)
	if got := h.standing(t, late).Group.GroupID; got == full {
		t.Error("group_max is 50, even for friends")
	}
}

// After a promotion the client asks which friends' groups it could join; the
// summary says how many there are, and joining one places the player there.
func TestJoinAFriendsGroupAfterPromotion(t *testing.T) {
	h := newHarness(t)
	friend := h.registerIn(t, "Friend", "gold")
	h.start(t, friend, h.freshLevelAnySize(t).ID)
	friendGroup := h.standing(t, friend).Group.GroupID

	p := h.registerIn(t, "Climber", "silver")
	h.follow(t, p, friend)
	ctx := context.Background()
	if err := h.st.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		return r.Players.AddGameStats(ctx, p, 0, 0, 9999, h.clock.Now())
	}); err != nil {
		t.Fatal(err)
	}
	lv := h.freshLevelAnySize(t)
	st := h.start(t, p, lv.ID)
	h.clock.Add(30)
	if res := h.submit(t, h.payload(p, lv, st, 30, 0, 0)); res.Decoded.PromotedTo != "gold" {
		t.Fatalf("expected a promotion to gold, got %+v", res.Decoded)
	}

	sum := h.summary(t, p)
	if sum == nil || sum.JoinOptions != 1 {
		t.Fatalf("the promotion summary must offer one friend's group, got %+v", sum)
	}
	opts, err := h.svc.JoinOptions(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	if opts.Tier != "gold" || opts.Joined || len(opts.Options) != 1 || opts.Options[0].GroupID != friendGroup ||
		len(opts.Options[0].Friends) != 1 || opts.Options[0].Friends[0].Nickname != "Friend" {
		t.Fatalf("join options wrong: %+v", opts)
	}

	if _, err := h.svc.JoinGroup(ctx, p, "lg_gold_0_999"); codedError(t, err).Code != domain.CodeGroupFull {
		t.Error("a group that is not on offer is refused")
	}
	view, err := h.svc.JoinGroup(ctx, p, friendGroup)
	if err != nil {
		t.Fatal(err)
	}
	if !view.Joined || view.Group.GroupID != friendGroup {
		t.Errorf("joined %+v, want %s", view.Group, friendGroup)
	}
	again, err := h.svc.JoinOptions(ctx, p)
	if err != nil || !again.Joined || len(again.Options) != 0 {
		t.Errorf("once joined there is nothing to choose: %+v %v", again, err)
	}
	// Joining again is a no-op, not an error.
	if _, err := h.svc.JoinGroup(ctx, p, friendGroup); err != nil {
		t.Errorf("a repeated join must not fail: %v", err)
	}
}

// Diamond counts a game only when it was started online and synced within the
// grace period; anything else is stored and listed, but adds nothing.
func TestOnlineRuleInDiamond(t *testing.T) {
	h := newHarness(t)
	p := h.registerIn(t, "Dia", "diamond")

	// Offline: no session at all.
	lv := h.freshLevelAnySize(t)
	off := h.submit(t, h.payloadNoSession(p, lv, 60, 0, 0))
	if off.Decoded.Counted || off.Decoded.RoundScore != 0 || off.Decoded.TierPoints != 0 {
		t.Errorf("an offline diamond game must not count: %+v", off.Decoded)
	}
	if n := h.flagCount(t, p, domain.SigNoSession); n != 1 {
		t.Errorf("diamond still flags a missing session, got %d", n)
	}

	// Started online but synced an hour after finishing.
	lv2 := h.freshLevelAnySize(t)
	st2 := h.start(t, p, lv2.ID)
	h.clock.Add(60)
	late := h.payload(p, lv2, st2, 60, 0, 0)
	h.clock.Add(3600)
	lateRes := h.submit(t, late)
	if lateRes.Decoded.Counted || lateRes.Decoded.RoundScore != 0 {
		t.Errorf("a game synced an hour late must not count: %+v", lateRes.Decoded)
	}

	// Online throughout.
	lv3 := h.freshLevelAnySize(t)
	st3 := h.start(t, p, lv3.ID)
	h.clock.Add(60)
	ok := h.submit(t, h.payload(p, lv3, st3, 60, 0, 0))
	if !ok.Decoded.Counted || ok.Decoded.RoundScore != ok.Decoded.Breakdown.Score {
		t.Errorf("an online game counts: %+v", ok.Decoded)
	}
	if got := h.standing(t, p).MyRoundScore; got != ok.Decoded.Breakdown.Score {
		t.Errorf("round score %d, want only the online game's %d", got, ok.Decoded.Breakdown.Score)
	}

	runs, err := h.svc.Runs(context.Background(), p)
	if err != nil {
		t.Fatal(err)
	}
	counted := 0
	for _, r := range runs.Runs {
		if r.Counted {
			counted++
		}
	}
	if len(runs.Runs) != 3 || counted != 1 || runs.RoundScore != ok.Decoded.Breakdown.Score {
		t.Errorf("runs list every game and mark the one that counted: %+v", runs)
	}
}

// The run overview: best first, the best 15 marked, and the 15th best is the
// score a new game has to beat.
func TestRunsListTheRoundBestFirst(t *testing.T) {
	h := newHarness(t)
	p := h.registerIn(t, "Ann", "platinum")
	var scores []int
	for i := 0; i < 16; i++ {
		lv := h.freshLevel(t, 6)
		st := h.start(t, p, lv.ID)
		h.clock.Add(60 + int64(i)*30)
		res := h.submit(t, h.payload(p, lv, st, float64(60+i*30), 1, 0))
		scores = append(scores, res.Decoded.Breakdown.Score)
	}
	runs, err := h.svc.Runs(context.Background(), p)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs.Runs) != 16 || runs.BestN != 15 || !runs.HasRounds || runs.RoundEndsAt <= h.clock.Now() {
		t.Fatalf("runs header wrong: %+v", runs)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(scores)))
	inBest := 0
	for i, r := range runs.Runs {
		if r.Score != scores[i] {
			t.Errorf("run %d: score %d, want %d (best first)", i, r.Score, scores[i])
		}
		if r.InBest {
			inBest++
		}
		if r.Breakdown.Score != r.Score || r.Size != 6 || r.LevelID == "" {
			t.Errorf("run %d lacks its details: %+v", i, r)
		}
	}
	if inBest != 15 || runs.Runs[15].InBest {
		t.Errorf("the best 15 are marked, the 16th is not (%d marked)", inBest)
	}
	if runs.CutScore != scores[14] {
		t.Errorf("cut score %d, want the 15th best %d", runs.CutScore, scores[14])
	}
	if runs.RoundScore != h.standing(t, p).MyRoundScore {
		t.Errorf("runs and standing disagree: %d vs %d", runs.RoundScore, h.standing(t, p).MyRoundScore)
	}

	// Bronze: no rounds, every game counts, nothing to beat.
	b := h.register(t, "Bea")
	lv := h.freshLevelAnySize(t)
	st := h.start(t, b, lv.ID)
	h.clock.Add(40)
	h.submit(t, h.payload(b, lv, st, 40, 0, 0))
	br, err := h.svc.Runs(context.Background(), b)
	if err != nil {
		t.Fatal(err)
	}
	if br.HasRounds || br.BestN != 0 || br.CutScore != 0 || br.RoundEndsAt != 0 || len(br.Runs) != 1 || !br.Runs[0].InBest ||
		br.TierPoints != br.Runs[0].Score {
		t.Errorf("bronze runs wrong: %+v", br)
	}
}
