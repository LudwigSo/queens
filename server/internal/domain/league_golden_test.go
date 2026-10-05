package domain

import "testing"

// Mirrors queens/tests/run_tests.gd:718-810 (_test_league_rules) one assertion
// at a time. The GDScript is the oracle; these values are its checked-in output.

func member(id string, score int, rest ...int) Member {
	games, last := 5, 100
	if len(rest) > 0 {
		games = rest[0]
	}
	if len(rest) > 1 {
		last = rest[1]
	}
	return Member{PlayerID: id, Nickname: id, RoundScore: score, Games: games, LastSubmitAt: int64(last), IsMe: id == "me"}
}

func cfgAndTier(t *testing.T, id string) (*LeagueConfig, Tier) {
	t.Helper()
	cfg := DefaultLeagueConfig()
	tier, ok := cfg.TierByID(id)
	if !ok {
		t.Fatalf("unknown tier %q", id)
	}
	return cfg, tier
}

func TestRoundScore(t *testing.T) {
	cfg := DefaultLeagueConfig()
	if got := RoundScore([]int{100, 50, 200}, cfg); got != 350 {
		t.Errorf("round score sums the games: %d", got)
	}
	many := make([]int, 0, 20)
	for i := 0; i < 20; i++ {
		many = append(many, 10*(i+1))
	}
	if got := RoundScore(many, cfg); got != 1950 {
		t.Errorf("round score keeps only the best 15: %d", got)
	}
	sumCfg := *cfg
	sumCfg.RoundMode = "sum"
	if got := RoundScore(many, &sumCfg); got != 2100 {
		t.Errorf("sum mode counts every game: %d", got)
	}
}

func TestTierTransitions(t *testing.T) {
	cfg := DefaultLeagueConfig()
	if cfg.TopTier() != "challenger" {
		t.Error("challenger is the top tier")
	}
	if cfg.PromoteTier("bronze") != "silver" || cfg.PromoteTier("diamond") != "challenger" || cfg.PromoteTier("challenger") != "challenger" {
		t.Error("promotion goes one tier up and stops at the top")
	}
	if cfg.RelegateTier("platinum") != "gold" || cfg.RelegateTier("challenger") != "diamond" || cfg.RelegateTier("bronze") != "bronze" {
		t.Error("relegation goes one tier down and stops at the bottom")
	}
	gold, _ := cfg.TierByID("gold")
	silver, _ := cfg.TierByID("silver")
	if cfg.RelegateTier("gold") != "gold" || !gold.Floor || silver.Floor {
		t.Error("gold is a floor: no relegation out of it")
	}
	diamond, _ := cfg.TierByID("diamond")
	challenger, _ := cfg.TierByID("challenger")
	platinum, _ := cfg.TierByID("platinum")
	if !diamond.Global || !challenger.Global || platinum.Global {
		t.Error("diamond and challenger are global tiers")
	}
	if !challenger.IsCapped() || diamond.IsCapped() {
		t.Error("only challenger is capped")
	}
	if diamond.UpMode != UpModeOpenings || platinum.UpMode != UpModePct {
		t.Error("diamond promotes into openings")
	}
	bronze, _ := cfg.TierByID("bronze")
	if bronze.UpMode != UpModeScore || bronze.PromoScoreOf() != 3000 || silver.PromoScoreOf() != 10000 || gold.PromoScoreOf() != 0 {
		t.Error("bronze and silver promote by tier points")
	}
	if ReachesPromo(bronze, 2999) || !ReachesPromo(bronze, 3000) || ReachesPromo(gold, 99999) {
		t.Error("threshold reached at promo_score, never in a percentage tier")
	}
	if _, ok := cfg.TierByID("nope"); ok {
		t.Error("an unknown tier must report false, not fall back to index 0")
	}
}

func TestRoundTiming(t *testing.T) {
	cfg := DefaultLeagueConfig()
	bronze, _ := cfg.TierByID("bronze")
	silver, _ := cfg.TierByID("silver")
	gold, _ := cfg.TierByID("gold")
	platinum, _ := cfg.TierByID("platinum")
	at := WeekStart(2957) + 2*86400
	if bronze.RoundDays != 0 || silver.RoundDays != 0 || gold.RoundDays != 7 {
		t.Error("round length per tier")
	}
	if bronze.HasRounds() || silver.HasRounds() || !gold.HasRounds() {
		t.Error("bronze and silver run without a timer")
	}
	if RoundIndex(platinum, at) != 2957 || RoundStart(gold, 2957) != WeekStart(2957) || RoundEnd(gold, 2957) != WeekEnd(2957) {
		t.Error("7-day rounds are calendar weeks")
	}
	if RoundIndex(bronze, at) != 0 || RoundIndex(silver, 0) != 0 || RoundStart(bronze, 0) != 0 || RoundEnd(silver, 0) != 0 {
		t.Error("a tier without rounds lives in round 0 and never ends")
	}
	c, err := LoadLeagueConfig([]byte(`{"tiers":[{"id":"x"}]}`))
	if err != nil || c.Tiers[0].RoundDays != 7 {
		t.Error("a tier without round_days plays weeks")
	}
}

func TestGroupsBotsAndOnlineRule(t *testing.T) {
	cfg := DefaultLeagueConfig()
	gold, _ := cfg.TierByID("gold")
	platinum, _ := cfg.TierByID("platinum")
	silver, _ := cfg.TierByID("silver")
	diamond, _ := cfg.TierByID("diamond")
	challenger, _ := cfg.TierByID("challenger")
	if cfg.GroupSize != 30 || cfg.GroupMax != 50 {
		t.Error("group size and the friends' cap")
	}
	if BotCount(gold, 1) != 29 || BotCount(platinum, 30) != 0 || BotCount(gold, 41) != 0 {
		t.Error("bots top gold and platinum up to 30")
	}
	if BotCount(silver, 1) != 0 || BotCount(diamond, 1) != 0 {
		t.Error("no bots elsewhere")
	}
	start, end := RoundStart(gold, 2957), RoundEnd(gold, 2957)
	names := map[string]bool{}
	for slot := 0; slot < 29; slot++ {
		seed := BotSeed(123456, slot)
		names[cfg.BotNickname(123456, slot)] = true
		prev := -1
		for step := int64(0); step < 8; step++ {
			p := BotProgress(gold, cfg, seed, start, end, start+step*86400)
			if p.RoundScore < prev {
				t.Fatalf("bot %d: score went down", slot)
			}
			prev = p.RoundScore
		}
		fin := BotProgress(gold, cfg, seed, start, end, end)
		if fin.Games < 1 || fin.Games > 15 || fin.LastSubmitAt < start || fin.LastSubmitAt >= end {
			t.Errorf("bot %d plays outside 1..15 games or outside its round: %+v", slot, fin)
		}
	}
	if len(names) != 29 {
		t.Error("the bots of a group have distinct names")
	}
	if !cfg.CountsForLeague(gold, false, 100, 100+30*86400) {
		t.Error("a lower tier counts a game synced weeks later")
	}
	if cfg.CountsForLeague(diamond, false, 100, 100) {
		t.Error("diamond needs a session")
	}
	if !cfg.CountsForLeague(challenger, true, 100, 700) || cfg.CountsForLeague(challenger, true, 100, 701) {
		t.Error("challenger accepts ten minutes of grace")
	}
}

func TestSlotsAndOpenings(t *testing.T) {
	cfg, challenger := cfgAndTier(t, "challenger")
	diamond, _ := cfg.TierByID("diamond")
	if Slots(challenger, 60) != 6 || Slots(challenger, 20) != 5 || Slots(challenger, 2000) != 50 {
		t.Error("challenger slots follow the diamond population within 5..50")
	}
	if Slots(diamond, 60) != -1 {
		t.Error("uncapped tiers have no slots")
	}
	if got := Openings(cfg, challenger, 60, 6); got != 3 {
		t.Errorf("a full challenger of six opens three slots: %d", got)
	}
	if got := Openings(cfg, challenger, 60, 4); got != 2 {
		t.Errorf("a tiny challenger relegates nobody, unfilled slots open: %d", got)
	}
	if Openings(cfg, challenger, 60, 0) != 6 || Openings(cfg, challenger, 500, 50) != 25 {
		t.Error("openings scale with the slots")
	}
}

func TestSortMembersOrder(t *testing.T) {
	sorted := SortMembers([]Member{
		member("late", 100, 5, 300), member("top", 200), member("early", 100, 5, 100), member("busy", 100, 9, 50),
	})
	want := []string{"top", "early", "late", "busy"}
	for i, id := range want {
		if sorted[i].PlayerID != id {
			t.Fatalf("members sort by score, games, submit time: position %d is %q, want %q", i, sorted[i].PlayerID, id)
		}
	}
}

// SortMembers adds player_id as a fourth key; the GDScript sort is unstable and
// leaves identical triples in an arbitrary order.
func TestSortMembersTieBreaksByPlayerID(t *testing.T) {
	sorted := SortMembers([]Member{member("c", 100), member("a", 100), member("b", 100)})
	for i, id := range []string{"a", "b", "c"} {
		if sorted[i].PlayerID != id {
			t.Fatalf("identical triples order by player_id: position %d is %q", i, sorted[i].PlayerID)
		}
	}
}

func thirtyMembers() []Member {
	members := make([]Member, 0, 30)
	for i := 0; i < 30; i++ {
		members = append(members, member("p"+string(rune('a'+i)), 1000-i*10))
	}
	return members
}

func TestEvaluateFullGroups(t *testing.T) {
	cfg := DefaultLeagueConfig()
	members := thirtyMembers()

	platinum, _ := cfg.TierByID("platinum")
	ev := Evaluate(members, platinum, cfg, -1)
	if ev.PromoteCount != 5 || ev.RelegateCount != 8 {
		t.Errorf("platinum: 15%% up and 25%% down of 30, got %d/%d", ev.PromoteCount, ev.RelegateCount)
	}
	if ev.Members[0].Zone != ZonePromote || ev.Members[4].Zone != ZonePromote || ev.Members[5].Zone != ZoneSafe {
		t.Error("top five promote")
	}
	if ev.Members[21].Zone != ZoneSafe || ev.Members[22].Zone != ZoneRelegate || ev.Members[29].Zone != ZoneRelegate {
		t.Error("bottom eight relegate")
	}
	if ev.Members[0].Rank != 1 || ev.Members[29].Rank != 30 {
		t.Error("ranks are assigned")
	}

	bronze, _ := cfg.TierByID("bronze")
	b := Evaluate(members, bronze, cfg, -1)
	if b.PromoteCount != 0 || b.RelegateCount != 0 || b.Members[0].Zone != ZoneSafe || b.Members[0].Rank != 1 {
		t.Error("bronze: a round promotes nobody, nobody down")
	}
	silver, _ := cfg.TierByID("silver")
	s := Evaluate(members, silver, cfg, -1)
	if s.PromoteCount != 0 || s.RelegateCount != 0 {
		t.Error("silver: a round promotes nobody, nobody down")
	}

	stray := bronze
	stray.UpPct = 50
	if Counts(30, stray, cfg, 1000, -1).Up != 0 || Counts(3, stray, cfg, 1000, -1).Up != 0 {
		t.Error("a score tier ignores a leftover up_pct")
	}

	gold, _ := cfg.TierByID("gold")
	g := Evaluate(members, gold, cfg, -1)
	if g.PromoteCount != 6 || g.RelegateCount != 0 {
		t.Errorf("gold: 20%% up, nobody down, got %d/%d", g.PromoteCount, g.RelegateCount)
	}

	diamond, _ := cfg.TierByID("diamond")
	d := Evaluate(members, diamond, cfg, 3)
	if d.PromoteCount != 3 || d.RelegateCount != 6 || d.Members[2].Zone != ZonePromote || d.Members[3].Zone != ZoneSafe {
		t.Error("diamond: exactly the open slots up, 20% down")
	}
	closed := Evaluate(members, diamond, cfg, 0)
	if closed.PromoteCount != 0 || closed.RelegateCount != 6 {
		t.Error("diamond without openings promotes nobody")
	}

	challenger, _ := cfg.TierByID("challenger")
	c := Evaluate(members, challenger, cfg, -1)
	if c.PromoteCount != 0 || c.RelegateCount != 15 || c.Members[14].Zone != ZoneSafe || c.Members[15].Zone != ZoneRelegate {
		t.Error("challenger: nobody up, bottom half down")
	}
}

// run_tests.gd:786 -- the asymmetry that PromoteCount counts actual promotions.
func TestZeroScoreNeverPromotes(t *testing.T) {
	cfg, gold := cfgAndTier(t, "gold")
	idle := make([]Member, 0, 10)
	for i := 0; i < 10; i++ {
		idle = append(idle, member("z"+string(rune('a'+i)), 0))
	}
	ev := Evaluate(idle, gold, cfg, -1)
	if ev.PromoteCount != 0 || ev.Members[0].Zone != ZoneSafe {
		t.Error("a zero score never promotes")
	}
}

func TestTinyGroups(t *testing.T) {
	cfg, platinum := cfgAndTier(t, "platinum")
	tiny := []Member{member("a", 600), member("b", 100), member("c", 50)}
	ev := Evaluate(tiny, platinum, cfg, -1)
	if ev.PromoteCount != 0 || ev.RelegateCount != 0 {
		t.Error("tiny platinum group: leader below 2500 stays")
	}
	tiny[0].RoundScore = 2600
	ev = Evaluate(tiny, platinum, cfg, -1)
	if ev.PromoteCount != 1 || ev.Members[0].Zone != ZonePromote || ev.RelegateCount != 0 {
		t.Error("tiny platinum group: strong leader promotes alone")
	}
	diamond, _ := cfg.TierByID("diamond")
	if Evaluate(tiny, diamond, cfg, 0).PromoteCount != 0 || Evaluate(tiny, diamond, cfg, 2).PromoteCount != 1 {
		t.Error("tiny diamond group: one up when a slot is open")
	}
	gold, _ := cfg.TierByID("gold")
	if len(Evaluate(nil, gold, cfg, -1).Members) != 0 {
		t.Error("empty group evaluates")
	}
}

func TestOutcomesAndApply(t *testing.T) {
	cfg := DefaultLeagueConfig()
	if OutcomeForZone(ZonePromote) != OutcomePromoted || OutcomeForZone(ZoneSafe) != OutcomeStayed || OutcomeForZone(ZoneRelegate) != OutcomeRelegated {
		t.Error("zones map to outcomes")
	}
	silver, _ := cfg.TierByID("silver")
	platinum, _ := cfg.TierByID("platinum")
	challenger, _ := cfg.TierByID("challenger")
	gold, _ := cfg.TierByID("gold")
	if InactiveOutcome(silver) != OutcomeInactiveFrozen || InactiveOutcome(platinum) != OutcomeInactiveRelegated || InactiveOutcome(challenger) != OutcomeInactiveRelegated {
		t.Error("inactive rule per tier")
	}
	if InactiveOutcome(gold) != OutcomeInactiveFrozen || InactiveOutcome(Tier{Floor: true, Inactive: "relegate"}) != OutcomeInactiveFrozen {
		t.Error("a floor tier freezes idle players whatever it says")
	}
	if cfg.Apply("silver", OutcomePromoted) != "gold" || cfg.Apply("platinum", OutcomeRelegated) != "gold" ||
		cfg.Apply("diamond", OutcomePromoted) != "challenger" || cfg.Apply("challenger", OutcomeRelegated) != "diamond" {
		t.Error("apply moves tiers")
	}
	if cfg.Apply("gold", OutcomeRelegated) != "gold" || cfg.Apply("gold", OutcomeInactiveRelegated) != "gold" ||
		cfg.Apply("platinum", OutcomeInactiveRelegated) != "gold" || cfg.Apply("gold", OutcomeStayed) != "gold" {
		t.Error("apply respects the gold floor")
	}
}

// RoundBestN must be defaulted at decode time so a deliberate 0 survives.
func TestRoundBestNDecodeDefault(t *testing.T) {
	cfg, err := LoadLeagueConfig([]byte(`{"format":1,"round_best_n":0,"tiers":[{"id":"bronze","round_days":3}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.RoundBestN != 0 {
		t.Errorf("an explicit 0 must not become 15, got %d", cfg.RoundBestN)
	}
	cfg, err = LoadLeagueConfig([]byte(`{"format":1,"tiers":[{"id":"bronze","round_days":3}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.RoundBestN != 15 {
		t.Errorf("a missing round_best_n defaults to 15, got %d", cfg.RoundBestN)
	}
	if cfg.Tiers[0].UpMode != UpModePct || cfg.Tiers[0].Inactive != "stay" {
		t.Error("tier defaults applied at decode")
	}
}
