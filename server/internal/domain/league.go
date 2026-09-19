package domain

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"math"
	"sort"
)

// Port of queens/scripts/league_rules.gd and the `league` dict that used to live
// in queens/scripts/config.gd. The config now lives in queens/shared/league.json;
// the copy embedded here is kept in sync by TestLeagueFileInSync.
//
//go:embed league.json
var leagueJSON []byte

const (
	DaySeconds       = 86400
	RoundEpochOffset = WeekEpochOffset // Monday 1970-01-05 00:00 UTC, like calendar weeks.

	ZonePromote  = "promote"
	ZoneSafe     = "safe"
	ZoneRelegate = "relegate"

	OutcomePromoted          = "promoted"
	OutcomeStayed            = "stayed"
	OutcomeRelegated         = "relegated"
	OutcomeInactiveFrozen    = "inactive_frozen"
	OutcomeInactiveRelegated = "inactive_relegated"

	UpModePct      = "pct"
	UpModeOpenings = "openings"
	UpModeScore    = "score"

	ReasonRound = "round"
	ReasonScore = "score"
)

// Tier mirrors one entry of league.json. MaxSlots, MinSlots and PlayersPerSlot
// are pointers because IsCapped() tests *presence* of max_slots, not its value.
type Tier struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	RoundDays      int    `json:"round_days"`
	UpMode         string `json:"up_mode"`
	PromoScore     int    `json:"promo_score"`
	UpPct          int    `json:"up_pct"`
	DownPct        int    `json:"down_pct"`
	Inactive       string `json:"inactive"`
	Floor          bool   `json:"floor"`
	MinPromoScore  int    `json:"min_promo_score"`
	Global         bool   `json:"global"`
	MinSlots       *int   `json:"min_slots"`
	MaxSlots       *int   `json:"max_slots"`
	PlayersPerSlot *int   `json:"players_per_slot"`
}

type LeagueConfig struct {
	Format       int    `json:"format"`
	GroupSize    int    `json:"group_size"`
	MinGroupSize int    `json:"min_group_size"`
	RoundMode    string `json:"round_mode"`
	RoundBestN   int    `json:"round_best_n"`
	Tiers        []Tier `json:"tiers"`
}

// LoadLeagueConfig decodes league.json and applies every default the GDScript
// applies through dict.get(key, default). RoundBestN is defaulted at decode time
// on purpose: a later "if n == 0 { n = 15 }" would turn a deliberate 0 into 15.
func LoadLeagueConfig(data []byte) (*LeagueConfig, error) {
	var raw struct {
		Format       int    `json:"format"`
		GroupSize    int    `json:"group_size"`
		MinGroupSize int    `json:"min_group_size"`
		RoundMode    string `json:"round_mode"`
		RoundBestN   *int   `json:"round_best_n"`
		Tiers        []Tier `json:"tiers"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("league config: %w", err)
	}
	cfg := &LeagueConfig{
		Format:       raw.Format,
		GroupSize:    raw.GroupSize,
		MinGroupSize: raw.MinGroupSize,
		RoundMode:    raw.RoundMode,
		RoundBestN:   15,
		Tiers:        raw.Tiers,
	}
	if raw.RoundBestN != nil {
		cfg.RoundBestN = *raw.RoundBestN
	}
	if cfg.MinGroupSize == 0 {
		cfg.MinGroupSize = 5
	}
	if cfg.RoundMode == "" {
		cfg.RoundMode = "best_n"
	}
	if len(cfg.Tiers) == 0 {
		return nil, fmt.Errorf("league config: no tiers")
	}
	for i := range cfg.Tiers {
		t := &cfg.Tiers[i]
		if t.UpMode == "" {
			t.UpMode = UpModePct
		}
		if t.RoundDays < 1 {
			t.RoundDays = 7
		}
		if t.Inactive == "" {
			t.Inactive = "stay"
		}
	}
	return cfg, nil
}

// DefaultLeagueConfig returns the embedded config; it panics on a broken file
// because the server cannot serve anything without it.
func DefaultLeagueConfig() *LeagueConfig {
	cfg, err := LoadLeagueConfig(leagueJSON)
	if err != nil {
		panic(err)
	}
	return cfg
}

// LeagueConfigBytes is the raw embedded file, served verbatim in /v1/bootstrap.
func LeagueConfigBytes() []byte { return leagueJSON }

// TierByID returns (tier, false) for an unknown id. The GDScript falls back to
// index 0, which is a fine client default and a data-corruption amplifier on a
// server: callers must turn false into a 500 and log the id.
func (c *LeagueConfig) TierByID(id string) (Tier, bool) {
	for _, t := range c.Tiers {
		if t.ID == id {
			return t, true
		}
	}
	return Tier{}, false
}

func (c *LeagueConfig) TierIndex(id string) int {
	for i, t := range c.Tiers {
		if t.ID == id {
			return i
		}
	}
	return 0
}

func (c *LeagueConfig) BottomTier() string { return c.Tiers[0].ID }
func (c *LeagueConfig) TopTier() string    { return c.Tiers[len(c.Tiers)-1].ID }

func (c *LeagueConfig) PromoteTier(id string) string {
	i := c.TierIndex(id) + 1
	if i > len(c.Tiers)-1 {
		i = len(c.Tiers) - 1
	}
	return c.Tiers[i].ID
}

// RelegateTier: one tier down, except from the bottom tier and from a floor tier
// (Gold). The floor check is deliberately redundant with InactiveOutcome; both
// are tested in the GDScript and both are ported.
func (c *LeagueConfig) RelegateTier(id string) string {
	if t, ok := c.TierByID(id); ok && t.Floor {
		return id
	}
	i := c.TierIndex(id) - 1
	if i < 0 {
		i = 0
	}
	return c.Tiers[i].ID
}

func (t Tier) IsCapped() bool { return t.MaxSlots != nil }

// PromoScoreOf is the tier points needed to leave a score-mode tier, 0 elsewhere.
func (t Tier) PromoScoreOf() int {
	if t.UpMode != UpModeScore {
		return 0
	}
	if t.PromoScore < 0 {
		return 0
	}
	return t.PromoScore
}

func ReachesPromo(t Tier, tierPoints int) bool {
	need := t.PromoScoreOf()
	return need > 0 && tierPoints >= need
}

// --- rounds -----------------------------------------------------------------

func (t Tier) RoundSeconds() int64 {
	d := t.RoundDays
	if d < 1 {
		d = 1
	}
	return int64(d) * DaySeconds
}

// RoundIndex of the round of this tier containing unixTime. Integer floor
// division: negative-aware, unlike the truncating / of Go.
func RoundIndex(t Tier, unixTime int64) int64 {
	return floorDiv(unixTime-RoundEpochOffset, t.RoundSeconds())
}

func RoundStart(t Tier, index int64) int64 { return index*t.RoundSeconds() + RoundEpochOffset }
func RoundEnd(t Tier, index int64) int64   { return RoundStart(t, index+1) }

// --- capped top tier --------------------------------------------------------

func clampi(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// Slots of a capped tier given the population below it, or -1 when uncapped.
// below/perSlot is integer division, as in the GDScript.
func Slots(t Tier, belowPlayers int) int {
	if !t.IsCapped() {
		return -1
	}
	perSlot := 10
	if t.PlayersPerSlot != nil && *t.PlayersPerSlot > 1 {
		perSlot = *t.PlayersPerSlot
	}
	minSlots := 1
	if t.MinSlots != nil {
		minSlots = *t.MinSlots
	}
	return clampi(belowPlayers/perSlot, minSlots, *t.MaxSlots)
}

// Openings is a pure function of the two population counts, so it already
// accounts for the relegation of the capped tier analytically. Tier close order
// is therefore irrelevant -- the next reader will assume it is not.
func Openings(cfg *LeagueConfig, cappedTier Tier, belowPlayers, membersInTier int) int {
	total := Slots(cappedTier, belowPlayers)
	if total < 0 {
		return 0
	}
	leaving := Counts(membersInTier, cappedTier, cfg, 0, -1).Down
	v := total - (membersInTier - leaving)
	if v < 0 {
		return 0
	}
	return v
}

// --- scores and ranking -----------------------------------------------------

// RoundScore is the sum of the best N game scores of the round (or the plain sum
// in "sum" mode).
func RoundScore(scores []int, cfg *LeagueConfig) int {
	total := 0
	if cfg.RoundMode == "sum" {
		for _, s := range scores {
			total += s
		}
		return total
	}
	sorted := append([]int(nil), scores...)
	sort.Sort(sort.Reverse(sort.IntSlice(sorted)))
	n := cfg.RoundBestN
	if n > len(sorted) {
		n = len(sorted)
	}
	for i := 0; i < n; i++ {
		total += sorted[i]
	}
	return total
}

// Member is one row of a league group.
type Member struct {
	PlayerID     string `json:"player_id"`
	Nickname     string `json:"nickname"`
	RoundScore   int    `json:"round_score"`
	Games        int    `json:"games"`
	LastSubmitAt int64  `json:"last_submit_at"`
	IsMe         bool   `json:"is_me"`
	IsFriend     bool   `json:"is_friend"`
	Rank         int    `json:"rank"`
	Zone         string `json:"zone"`
	LeftAt       int64  `json:"-"`
	GroupID      string `json:"-"`
}

// SortMembers: higher score first, then fewer games, then earlier submit, then
// player_id. The fourth key is an addition to the GDScript, whose sort_custom is
// an unstable introsort: with real players an identical (score, games,
// last_submit_at) triple could otherwise flip rank between two calls and move
// someone across a promote/relegate boundary. It only orders pairs the GDScript
// comparator calls equivalent, so no existing expectation changes.
func SortMembers(members []Member) []Member {
	out := append([]Member(nil), members...)
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.RoundScore != b.RoundScore {
			return a.RoundScore > b.RoundScore
		}
		if a.Games != b.Games {
			return a.Games < b.Games
		}
		if a.LastSubmitAt != b.LastSubmitAt {
			return a.LastSubmitAt < b.LastSubmitAt
		}
		return a.PlayerID < b.PlayerID
	})
	return out
}

type CountsResult struct {
	Up   int
	Down int
}

// Counts: how many go up and down in a group of n whose leader scored
// leaderScore. upCount >= 0 replaces the percentage of the tier with a fixed
// number (the openings of a capped tier above); -1 means "use the percentage".
//
// The branch order is literal. Note the tiny-group branch returns BEFORE the
// up+down > n fixup and always reports down 0, and that the percentage rounding
// is half-away-from-zero and lands on exact halves (Platinum on 30: 4.5 -> 5,
// 7.5 -> 8), so banker's rounding would be wrong.
func Counts(n int, tierCfg Tier, cfg *LeagueConfig, leaderScore int, upCount int) CountsResult {
	if n <= 0 {
		return CountsResult{0, 0}
	}
	byScore := tierCfg.PromoScoreOf() > 0
	var wantsUp bool
	if upCount >= 0 {
		wantsUp = upCount > 0
	} else {
		wantsUp = tierCfg.UpPct > 0
	}
	wantsUp = wantsUp && !byScore

	if n < cfg.MinGroupSize {
		upTiny := 0
		if leaderScore >= tierCfg.MinPromoScore && wantsUp {
			upTiny = 1
		}
		return CountsResult{upTiny, 0}
	}
	up := 0
	if !byScore {
		if upCount >= 0 {
			up = upCount
			if up > n {
				up = n
			}
		} else {
			up = int(math.Round(float64(tierCfg.UpPct) / 100.0 * float64(n)))
		}
	}
	down := int(math.Round(float64(tierCfg.DownPct) / 100.0 * float64(n)))
	if up+down > n {
		down = n - up
	}
	return CountsResult{up, down}
}

type Evaluation struct {
	Members       []Member
	PromoteCount  int
	RelegateCount int
}

// Evaluate ranks the members and assigns zones. Two deliberate asymmetries are
// preserved: PromoteCount is the number ACTUALLY promoted (a zero round_score in
// the promote band falls through to safe), while RelegateCount is the INTENDED
// c.Down. And a zero-score member of a small group can still be marked relegate.
func Evaluate(members []Member, tierCfg Tier, cfg *LeagueConfig, upCount int) Evaluation {
	sorted := SortMembers(members)
	n := len(sorted)
	leader := 0
	if n > 0 {
		leader = sorted[0].RoundScore
	}
	c := Counts(n, tierCfg, cfg, leader, upCount)
	promoted := 0
	for i := range sorted {
		sorted[i].Rank = i + 1
		switch {
		case i < c.Up && sorted[i].RoundScore > 0:
			sorted[i].Zone = ZonePromote
			promoted++
		case i >= n-c.Down:
			sorted[i].Zone = ZoneRelegate
		default:
			sorted[i].Zone = ZoneSafe
		}
	}
	return Evaluation{Members: sorted, PromoteCount: promoted, RelegateCount: c.Down}
}

func OutcomeForZone(zone string) string {
	switch zone {
	case ZonePromote:
		return OutcomePromoted
	case ZoneRelegate:
		return OutcomeRelegated
	}
	return OutcomeStayed
}

// InactiveOutcome: a round without a game. A floor tier never relegates,
// whatever its `inactive` says.
func InactiveOutcome(t Tier) string {
	if t.Floor {
		return OutcomeInactiveFrozen
	}
	if t.Inactive == "relegate" {
		return OutcomeInactiveRelegated
	}
	return OutcomeInactiveFrozen
}

// Apply returns the tier a player is in after `outcome`.
func (c *LeagueConfig) Apply(tierID, outcome string) string {
	switch outcome {
	case OutcomePromoted:
		return c.PromoteTier(tierID)
	case OutcomeRelegated, OutcomeInactiveRelegated:
		return c.RelegateTier(tierID)
	}
	return tierID
}
