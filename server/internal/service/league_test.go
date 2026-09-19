package service_test

import (
	"context"
	"testing"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

// Bronze and Silver promote by tier points, on the spot. The player moves tier,
// the counter restarts, and they deliberately do NOT join the new tier's running
// round: auto-joining would create a phantom zero-score member who then gets
// relegated for inactivity.
func TestPromotionByScorePromotesWithoutJoining(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")

	var last *submitOutcome
	for i := 0; i < 40; i++ {
		lv := h.freshLevelAnySize(t)
		st := h.start(t, p, lv.ID)
		h.clock.Add(30)
		res := h.submit(t, h.payload(p, lv, st, 30, 0, 0))
		last = &submitOutcome{promotedTo: res.Decoded.PromotedTo, tier: res.Decoded.Tier,
			tierPoints: res.Decoded.TierPoints, promoScore: res.Decoded.PromoScore}
		if res.Decoded.PromotedTo != "" {
			break
		}
	}
	if last == nil || last.promotedTo != "silver" {
		t.Fatalf("expected a promotion to silver, got %+v", last)
	}
	// The response still describes the round that was just played.
	if last.tier != "bronze" {
		t.Errorf("response tier = %q, want the old tier bronze", last.tier)
	}
	if last.tierPoints < last.promoScore {
		t.Errorf("tier points %d must be the pre-reset value, at least %d", last.tierPoints, last.promoScore)
	}

	prof := h.profile(t, p)
	if prof.Tier != "silver" || prof.TierPoints != 0 {
		t.Errorf("after promotion: tier %q points %d, want silver 0", prof.Tier, prof.TierPoints)
	}
	st := h.standing(t, p)
	if st.Tier != "silver" {
		t.Errorf("standing tier = %q", st.Tier)
	}
	if st.Joined {
		t.Error("a promotion must not auto-join the new tier's running round")
	}
	if st.Rules.PromoScore != 10000 || st.Rules.UpTo != "gold" {
		t.Errorf("silver rules wrong: %+v", st.Rules)
	}

	sum := h.summary(t, p)
	if sum == nil || sum.Reason != domain.ReasonScore || sum.Outcome != domain.OutcomePromoted {
		t.Fatalf("expected a promoted/score summary, got %+v", sum)
	}
	if sum.TierBefore != "bronze" || sum.TierAfter != "silver" {
		t.Errorf("summary tiers wrong: %+v", sum)
	}
	if sum.BestGame == nil || sum.BestGame.Score == 0 {
		t.Error("the summary must name the best game of the round")
	}
}

// up_to is a TIER ID now, not a display name: the server has no locale.
func TestStandingRulesCarryIDsNotProse(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	st := h.standing(t, p)
	if st.Tier != "bronze" || st.Rules.UpTo != "silver" {
		t.Errorf("expected bronze with up_to silver, got %q / %q", st.Tier, st.Rules.UpTo)
	}
	if st.Joined || st.Group != nil {
		t.Error("an unjoined standing carries no group")
	}
	if st.Rules.UpCount != -1 {
		t.Errorf("a percentage tier reports up_count -1, got %d", st.Rules.UpCount)
	}
	if st.Rules.BestN != 15 || st.Rules.RoundDays != 3 {
		t.Errorf("rules wrong: %+v", st.Rules)
	}
	if st.RoundEndsAt <= h.clock.Now() {
		t.Error("the round must end in the future")
	}
}

// The closer settles a Bronze round: ranks, one summary each, no promotions
// (Bronze promotes by points only), and re-running it changes nothing.
func TestCloserBronzeBoundaryIsIdempotent(t *testing.T) {
	h := newHarness(t)
	players := []string{h.register(t, "Ann"), h.register(t, "Bob"), h.register(t, "Cid")}
	// One shared level, so the only thing separating the scores is the time
	// taken. Different levels have different base points and would decide the
	// ranking instead.
	lv := h.levelOfSize(t, 6)
	for i, p := range players {
		st := h.start(t, p, lv.ID)
		elapsed := float64(40 + i*60) // slower each time
		h.clock.Add(int64(elapsed) + 1)
		h.submit(t, h.payload(p, lv, st, elapsed, 0, 0))
	}
	bronze := h.tier(t, "bronze")
	idx := domain.RoundIndex(bronze, h.clock.Now())

	h.clock.Set(domain.RoundEnd(bronze, idx) + 1)
	if err := h.svc.CloseDueRounds(context.Background()); err != nil {
		t.Fatalf("close: %v", err)
	}

	for i, p := range players {
		sum := h.summary(t, p)
		if sum == nil {
			t.Fatalf("player %d has no summary", i)
		}
		if sum.Reason != domain.ReasonRound || sum.Outcome != domain.OutcomeStayed {
			t.Errorf("player %d: got %s/%s, want round/stayed", i, sum.Reason, sum.Outcome)
		}
		if sum.TierBefore != "bronze" || sum.TierAfter != "bronze" {
			t.Errorf("player %d: bronze never relegates and only promotes by points, got %s->%s", i, sum.TierBefore, sum.TierAfter)
		}
		if sum.Rank != i+1 {
			t.Errorf("player %d: rank %d, want %d", i, sum.Rank, i+1)
		}
		if sum.GroupSize != 3 {
			t.Errorf("player %d: group size %d, want 3", i, sum.GroupSize)
		}
	}

	before := h.summaryCount(t, players[0])
	if err := h.svc.CloseDueRounds(context.Background()); err != nil {
		t.Fatalf("re-close: %v", err)
	}
	if after := h.summaryCount(t, players[0]); after != before {
		t.Errorf("re-running the closer must be a no-op: %d -> %d summaries", before, after)
	}
}

// Percentages: 15 % up and 25 % down of 30 is 5 and 8, and both round
// half-away-from-zero (4.5 -> 5, 7.5 -> 8).
func TestCloserPlatinumPercentages(t *testing.T) {
	h := newHarness(t)
	players := h.seedTierGroup(t, "platinum", 30)
	plat := h.tier(t, "platinum")
	idx := domain.RoundIndex(plat, h.clock.Now())
	h.clock.Set(domain.RoundEnd(plat, idx) + 1)
	if err := h.svc.CloseDueRounds(context.Background()); err != nil {
		t.Fatal(err)
	}

	promoted, relegated, stayed := 0, 0, 0
	for _, p := range players {
		switch h.profile(t, p).Tier {
		case "diamond":
			promoted++
		case "gold":
			relegated++
		case "platinum":
			stayed++
		}
	}
	if promoted != 5 || relegated != 8 || stayed != 17 {
		t.Errorf("got %d up / %d down / %d stayed, want 5 / 8 / 17", promoted, relegated, stayed)
	}
	// A relegated player restarts their tier points.
	for _, p := range players {
		if h.profile(t, p).Tier != "platinum" && h.profile(t, p).TierPoints != 0 {
			t.Errorf("tier points must restart on a tier change")
			break
		}
	}
}

// Gold is a floor: once reached it is never lost, not even after an idle round.
func TestGoldFloorNeverRelegates(t *testing.T) {
	h := newHarness(t)
	players := h.seedTierGroup(t, "gold", 10)
	gold := h.tier(t, "gold")
	idx := domain.RoundIndex(gold, h.clock.Now())
	h.clock.Set(domain.RoundEnd(gold, idx) + 1)
	if err := h.svc.CloseDueRounds(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, p := range players {
		if got := h.profile(t, p).Tier; got != "gold" && got != "platinum" {
			t.Errorf("a gold player may only stay or promote, got %q", got)
		}
	}
}

// A player who never comes back is collapsed into ONE summary, however many
// rounds they missed.
func TestAbsentPlayerCollapsesToOneSummary(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	lv := h.freshLevelAnySize(t)
	st := h.start(t, p, lv.ID)
	h.clock.Add(30)
	h.submit(t, h.payload(p, lv, st, 30, 0, 0))

	// Five bronze rounds later, without playing.
	bronze := h.tier(t, "bronze")
	h.clock.Add(5 * bronze.RoundSeconds())
	if err := h.svc.CatchUp(context.Background(), p); err != nil {
		t.Fatalf("catch up: %v", err)
	}

	// One summary for the round they played, and at most one more for the gap.
	n := h.summaryCount(t, p)
	if n > 2 {
		t.Errorf("expected the absence to collapse, got %d summaries", n)
	}
	if got := h.profile(t, p).Tier; got != "bronze" {
		t.Errorf("bronze is inactive=stay, so an absent player stays, got %q", got)
	}
	// A second catch-up must be a no-op.
	if err := h.svc.CatchUp(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	if again := h.summaryCount(t, p); again != n {
		t.Errorf("catch-up must be idempotent: %d -> %d", n, again)
	}
}

// Platinum relegates the inactive; three missed weeks still cost only one tier,
// and only one summary is written.
func TestAbsentPlatinumRelegatesOnceToGold(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	h.setTier(t, p, "platinum")
	plat := h.tier(t, "platinum")
	h.clock.Add(3 * plat.RoundSeconds())
	if err := h.svc.CatchUp(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	if got := h.profile(t, p).Tier; got != "gold" {
		t.Errorf("tier = %q, want gold (one step, stopped by the floor)", got)
	}
	sum := h.summary(t, p)
	if sum == nil || sum.Outcome != domain.OutcomeInactiveRelegated {
		t.Fatalf("expected inactive_relegated, got %+v", sum)
	}
	if sum.TierBefore != "platinum" || sum.TierAfter != "gold" {
		t.Errorf("summary must name the original and the final tier, got %s -> %s", sum.TierBefore, sum.TierAfter)
	}
	if n := h.summaryCount(t, p); n != 1 {
		t.Errorf("expected exactly one summary, got %d", n)
	}
}

// Challenger is three tiers above the floor, and every further miss is a no-op.
func TestAbsentChallengerCollapsesToGold(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	h.setTier(t, p, "challenger")
	ch := h.tier(t, "challenger")
	h.clock.Add(200 * ch.RoundSeconds())
	if err := h.svc.CatchUp(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	if got := h.profile(t, p).Tier; got != "gold" {
		t.Errorf("tier = %q, want gold", got)
	}
	if n := h.summaryCount(t, p); n != 1 {
		t.Errorf("years of absence must still be one summary, got %d", n)
	}
}

// The summary is shown once: ack with a matching index clears it, a mismatch
// leaves it, and ack never errors.
func TestSummaryAckOnlyOnMatchingIndex(t *testing.T) {
	h := newHarness(t)
	p := h.register(t, "Ann")
	h.setTier(t, p, "platinum")
	plat := h.tier(t, "platinum")
	h.clock.Add(2 * plat.RoundSeconds())
	if err := h.svc.CatchUp(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	sum := h.summary(t, p)
	if sum == nil {
		t.Fatal("expected a summary")
	}

	if err := h.svc.AckRoundSummary(context.Background(), p, sum.RoundIndex+999); err != nil {
		t.Fatalf("ack with a wrong index must not error: %v", err)
	}
	if h.summary(t, p) == nil {
		t.Error("a mismatched ack must leave the summary pending")
	}
	if err := h.svc.AckRoundSummary(context.Background(), p, sum.RoundIndex); err != nil {
		t.Fatal(err)
	}
	if got := h.summary(t, p); got != nil {
		t.Errorf("after a matching ack nothing is pending, got %+v", got)
	}
}

// Groups pack fill-first: 47 players give 30 + 17, both above the min_group_size
// cliff, and the 30 behaves exactly like the tested case.
func TestGroupsPackFillFirst(t *testing.T) {
	h := newHarness(t)
	players := h.seedTierGroup(t, "bronze", 47)
	counts := map[string]int{}
	for _, p := range players {
		st := h.standing(t, p)
		if st.Group == nil {
			t.Fatalf("player %s did not join", p)
		}
		counts[st.Group.GroupID] = st.Group.Size
	}
	if len(counts) != 2 {
		t.Fatalf("expected two groups, got %d: %v", len(counts), counts)
	}
	sizes := []int{}
	for _, n := range counts {
		sizes = append(sizes, n)
	}
	if !(sizes[0] == 30 && sizes[1] == 17 || sizes[0] == 17 && sizes[1] == 30) {
		t.Errorf("expected 30 + 17, got %v", sizes)
	}
}

// A global tier is one unbounded group; the data is special-cased, not the code.
func TestGlobalTierIsOneGroup(t *testing.T) {
	h := newHarness(t)
	players := h.seedTierGroup(t, "diamond", 40)
	seen := map[string]bool{}
	for _, p := range players {
		st := h.standing(t, p)
		if st.Group == nil {
			t.Fatalf("player %s did not join", p)
		}
		seen[st.Group.GroupID] = true
		if st.Group.Size != 40 {
			t.Errorf("group size %d, want 40", st.Group.Size)
		}
	}
	if len(seen) != 1 {
		t.Errorf("a global tier must be one group, got %d", len(seen))
	}
}

type submitOutcome struct {
	promotedTo string
	tier       string
	tierPoints int
	promoScore int
}
