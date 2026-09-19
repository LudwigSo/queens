package domain

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// Cross-language parity. GDScript is the oracle: queens/tools/gen_fixtures.gd
// runs the real Scoring and LeagueRules and writes what they produce; this test
// reads the same files and asserts Go agrees.
//
// Floats are compared by their IEEE-754 bit pattern, never by decimal text:
// JSON does not round-trip a double, so a decimal comparison would be testing
// the printer rather than the maths.

func fixturePath(name string) string {
	return filepath.Join("..", "..", "..", "shared", "fixtures", name)
}

func readFixture(t *testing.T, name string, into any) {
	t.Helper()
	data, err := os.ReadFile(fixturePath(name))
	if err != nil {
		t.Fatalf("read %s: %v\nRegenerate with: godot --headless --path queens --script tools/gen_fixtures.gd", name, err)
	}
	if err := json.Unmarshal(data, into); err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
}

// hexOf renders a float64 the way the generator does.
func hexOf(v float64) string { return fmt.Sprintf("%016x", math.Float64bits(v)) }

// withinOneULP reports whether two doubles are the same or adjacent.
func withinOneULP(a, b float64) bool {
	if a == b {
		return true
	}
	if math.IsNaN(a) || math.IsNaN(b) || math.Signbit(a) != math.Signbit(b) {
		return false
	}
	ua, ub := math.Float64bits(a), math.Float64bits(b)
	if ua > ub {
		ua, ub = ub, ua
	}
	return ub-ua <= 1
}

func fromHex(t *testing.T, s string) float64 {
	t.Helper()
	bits, err := strconv.ParseUint(s, 16, 64)
	if err != nil {
		t.Fatalf("bad float hex %q: %v", s, err)
	}
	return math.Float64frombits(bits)
}

func TestHexEncodingSelfCheck(t *testing.T) {
	if got := hexOf(1.0); got != "3ff0000000000000" {
		t.Fatalf("hexOf(1.0) = %s; the two runtimes are not encoding the same way", got)
	}
	if got := fromHex(t, "3ff0000000000000"); got != 1.0 {
		t.Fatalf("fromHex round trip = %v", got)
	}
}

type scoringFixture struct {
	Format    int `json:"format"`
	Constants struct {
		BaseFlatHex          string `json:"base_flat_hex"`
		BasePerSizeHex       string `json:"base_per_size_hex"`
		BasePerDifficultyHex string `json:"base_per_difficulty_hex"`
		DifficultyRefHex     string `json:"difficulty_ref_hex"`
		DifficultyExpHex     string `json:"difficulty_exponent_hex"`
		ParBaseHex           string `json:"par_base_hex"`
		ParPerDifficultyHex  string `json:"par_per_difficulty_hex"`
		ParPerCellHex        string `json:"par_per_cell_hex"`
		KWrongHex            string `json:"k_wrong_hex"`
		AccuracyMinHex       string `json:"accuracy_min_hex"`
		SpeedMinHex          string `json:"speed_min_hex"`
		SpeedMaxHex          string `json:"speed_max_hex"`
		SpeedExponentHex     string `json:"speed_exponent_hex"`
		HintPenaltyHex       string `json:"hint_penalty_hex"`
		HintMinHex           string `json:"hint_min_hex"`
		WeekSeconds          int64  `json:"week_seconds"`
		WeekEpochOffset      int64  `json:"week_epoch_offset"`
	} `json:"constants"`
	Cases []struct {
		Size          int     `json:"size"`
		DifficultyHex string  `json:"difficulty_hex"`
		Wrong         int     `json:"wrong"`
		Hints         int     `json:"hints"`
		ElapsedHex    string  `json:"elapsed_hex"`
		Completed     bool    `json:"completed"`
		ParOverride   float64 `json:"par_override"`
		Expect        struct {
			Score       int    `json:"score"`
			Base        int    `json:"base"`
			ParHex      string `json:"par_hex"`
			AccuracyHex string `json:"accuracy_hex"`
			SpeedHex    string `json:"speed_hex"`
			HintHex     string `json:"hint_hex"`
			Flawless    bool   `json:"flawless"`
		} `json:"expect"`
	} `json:"cases"`
	Week []struct {
		T     int64 `json:"t"`
		Index int64 `json:"index"`
	} `json:"week"`
	WeekBounds []struct {
		Index int64 `json:"index"`
		Start int64 `json:"start"`
		End   int64 `json:"end"`
	} `json:"week_bounds"`
}

// A retyped constant is the classic way to break this port: SPEED_EXPONENT in
// particular is a literal that looks like log2/log3 but must not be computed.
func TestScoringConstants(t *testing.T) {
	var f scoringFixture
	readFixture(t, "scoring_cases.json", &f)
	c := f.Constants
	for _, tc := range []struct {
		name string
		want string
		got  float64
	}{
		{"BASE_FLAT", c.BaseFlatHex, BaseFlat},
		{"BASE_PER_SIZE", c.BasePerSizeHex, BasePerSize},
		{"BASE_PER_DIFFICULTY", c.BasePerDifficultyHex, BasePerDifficulty},
		{"DIFFICULTY_REF", c.DifficultyRefHex, DifficultyRef},
		{"DIFFICULTY_EXPONENT", c.DifficultyExpHex, DifficultyExp},
		{"PAR_BASE", c.ParBaseHex, ParBase},
		{"PAR_PER_DIFFICULTY", c.ParPerDifficultyHex, ParPerDifficulty},
		{"PAR_PER_CELL", c.ParPerCellHex, ParPerCell},
		{"K_WRONG", c.KWrongHex, KWrong},
		{"ACCURACY_MIN", c.AccuracyMinHex, AccuracyMin},
		{"SPEED_MIN", c.SpeedMinHex, SpeedMin},
		{"SPEED_MAX", c.SpeedMaxHex, SpeedMax},
		{"SPEED_EXPONENT", c.SpeedExponentHex, SpeedExponent},
		{"HINT_PENALTY", c.HintPenaltyHex, HintPenalty},
		{"HINT_MIN", c.HintMinHex, HintMin},
	} {
		if got := hexOf(tc.got); got != tc.want {
			t.Errorf("%s = %s (%v), want %s (%v)", tc.name, got, tc.got, tc.want, fromHex(t, tc.want))
		}
	}
	if c.WeekSeconds != WeekSeconds || c.WeekEpochOffset != WeekEpochOffset {
		t.Errorf("week constants differ: %d/%d vs %d/%d",
			c.WeekSeconds, c.WeekEpochOffset, WeekSeconds, WeekEpochOffset)
	}
}

func TestScoringCases(t *testing.T) {
	var f scoringFixture
	readFixture(t, "scoring_cases.json", &f)
	if len(f.Cases) == 0 {
		t.Fatal("no cases")
	}
	for i, c := range f.Cases {
		difficulty := fromHex(t, c.DifficultyHex)
		elapsed := fromHex(t, c.ElapsedHex)
		bd := Breakdown(difficulty, c.Size, c.ParOverride, elapsed, c.Wrong, c.Hints, c.Completed)
		// An integer mismatch is unconditionally fatal: it is a different score.
		if bd.Score != c.Expect.Score || bd.Base != c.Expect.Base {
			t.Fatalf("case %d (size %d, difficulty %v, wrong %d, hints %d, %vs): score %d/base %d, want %d/%d",
				i, c.Size, difficulty, c.Wrong, c.Hints, elapsed, bd.Score, bd.Base, c.Expect.Score, c.Expect.Base)
		}
		for _, f := range []struct {
			name string
			got  float64
			want string
		}{
			{"par", bd.ParSeconds, c.Expect.ParHex},
			{"accuracy", bd.AccuracyFactor, c.Expect.AccuracyHex},
			{"speed", bd.SpeedFactor, c.Expect.SpeedHex},
			{"hint", bd.HintFactor, c.Expect.HintHex},
		} {
			// The factors are allowed to differ by one unit in the last place.
			// Go's math.Pow and the engine's libm pow are both within an ULP of
			// correctly rounded, but they are not the same implementation, and
			// the speed factor is a pow. The SCORE is compared exactly above:
			// that is the number a player sees, and TestSweepDigest proves the
			// two runtimes agree on four million of them.
			if !withinOneULP(f.got, fromHex(t, f.want)) {
				t.Errorf("case %d: %s = %s (%v), want %s (%v)",
					i, f.name, hexOf(f.got), f.got, f.want, fromHex(t, f.want))
			}
		}
		if bd.Flawless != c.Expect.Flawless {
			t.Errorf("case %d: flawless = %v", i, bd.Flawless)
		}
	}
}

func TestWeekIndexParity(t *testing.T) {
	var f scoringFixture
	readFixture(t, "scoring_cases.json", &f)
	for _, w := range f.Week {
		if got := WeekIndex(w.T); got != w.Index {
			t.Errorf("WeekIndex(%d) = %d, want %d", w.T, got, w.Index)
		}
	}
	for _, b := range f.WeekBounds {
		if got := WeekStart(b.Index); got != b.Start {
			t.Errorf("WeekStart(%d) = %d, want %d", b.Index, got, b.Start)
		}
		if got := WeekEnd(b.Index); got != b.End {
			t.Errorf("WeekEnd(%d) = %d, want %d", b.Index, got, b.End)
		}
	}
}

type leagueFixture struct {
	ConfigHash string `json:"config_hash"`
	RoundIndex []struct {
		Tier   string `json:"tier"`
		T      int64  `json:"t"`
		Expect int64  `json:"expect"`
	} `json:"round_index"`
	RoundBounds []struct {
		Tier  string `json:"tier"`
		Index int64  `json:"index"`
		Start int64  `json:"start"`
		End   int64  `json:"end"`
	} `json:"round_bounds"`
	Slots []struct {
		Tier   string `json:"tier"`
		Below  int    `json:"below"`
		Expect int    `json:"expect"`
	} `json:"slots"`
	Openings []struct {
		Tier    string `json:"tier"`
		Below   int    `json:"below"`
		Members int    `json:"members"`
		Expect  int    `json:"expect"`
	} `json:"openings"`
	Counts []struct {
		Tier    string `json:"tier"`
		N       int    `json:"n"`
		Leader  int    `json:"leader"`
		UpCount int    `json:"up_count"`
		Expect  struct {
			Up   int `json:"up"`
			Down int `json:"down"`
		} `json:"expect"`
	} `json:"counts"`
	RoundScore []struct {
		Scores []int `json:"scores"`
		Expect int   `json:"expect"`
	} `json:"round_score"`
	Evaluate []struct {
		Tier    string `json:"tier"`
		UpCount int    `json:"up_count"`
		Members []struct {
			PlayerID     string `json:"player_id"`
			Nickname     string `json:"nickname"`
			RoundScore   int    `json:"round_score"`
			Games        int    `json:"games"`
			LastSubmitAt int64  `json:"last_submit_at"`
		} `json:"members"`
		Expect struct {
			PromoteCount  int `json:"promote_count"`
			RelegateCount int `json:"relegate_count"`
			Members       []struct {
				PlayerID string `json:"player_id"`
				Rank     int    `json:"rank"`
				Zone     string `json:"zone"`
			} `json:"members"`
		} `json:"expect"`
	} `json:"evaluate"`
	Transitions []struct {
		Tier    string `json:"tier"`
		Outcome string `json:"outcome"`
		Expect  string `json:"expect"`
	} `json:"transitions"`
	InactiveOutcome []struct {
		Tier   string `json:"tier"`
		Expect string `json:"expect"`
	} `json:"inactive_outcome"`
	PromoteTier []struct {
		Tier   string `json:"tier"`
		Expect string `json:"expect"`
	} `json:"promote_tier"`
	RelegateTier []struct {
		Tier   string `json:"tier"`
		Expect string `json:"expect"`
	} `json:"relegate_tier"`
}

func TestLeagueCases(t *testing.T) {
	var f leagueFixture
	readFixture(t, "league_cases.json", &f)
	cfg := DefaultLeagueConfig()

	if f.ConfigHash != LeagueConfigHash() {
		t.Fatalf("the fixtures were generated from a different league.json\n got %s\nwant %s",
			f.ConfigHash, LeagueConfigHash())
	}

	tier := func(id string) Tier {
		tc, ok := cfg.TierByID(id)
		if !ok {
			t.Fatalf("unknown tier %q", id)
		}
		return tc
	}

	t.Run("round_index", func(t *testing.T) {
		for _, c := range f.RoundIndex {
			if got := RoundIndex(tier(c.Tier), c.T); got != c.Expect {
				t.Errorf("RoundIndex(%s, %d) = %d, want %d", c.Tier, c.T, got, c.Expect)
			}
		}
	})
	t.Run("round_bounds", func(t *testing.T) {
		for _, c := range f.RoundBounds {
			if got := RoundStart(tier(c.Tier), c.Index); got != c.Start {
				t.Errorf("RoundStart(%s, %d) = %d, want %d", c.Tier, c.Index, got, c.Start)
			}
			if got := RoundEnd(tier(c.Tier), c.Index); got != c.End {
				t.Errorf("RoundEnd(%s, %d) = %d, want %d", c.Tier, c.Index, got, c.End)
			}
		}
	})
	t.Run("slots", func(t *testing.T) {
		for _, c := range f.Slots {
			if got := Slots(tier(c.Tier), c.Below); got != c.Expect {
				t.Errorf("Slots(%s, %d) = %d, want %d", c.Tier, c.Below, got, c.Expect)
			}
		}
	})
	t.Run("openings", func(t *testing.T) {
		for _, c := range f.Openings {
			if got := Openings(cfg, tier(c.Tier), c.Below, c.Members); got != c.Expect {
				t.Errorf("Openings(%s, below %d, in %d) = %d, want %d", c.Tier, c.Below, c.Members, got, c.Expect)
			}
		}
	})
	t.Run("counts", func(t *testing.T) {
		for _, c := range f.Counts {
			got := Counts(c.N, tier(c.Tier), cfg, c.Leader, c.UpCount)
			if got.Up != c.Expect.Up || got.Down != c.Expect.Down {
				t.Errorf("Counts(%s, n %d, leader %d, up %d) = %d/%d, want %d/%d",
					c.Tier, c.N, c.Leader, c.UpCount, got.Up, got.Down, c.Expect.Up, c.Expect.Down)
			}
		}
	})
	t.Run("round_score", func(t *testing.T) {
		for _, c := range f.RoundScore {
			if got := RoundScore(c.Scores, cfg); got != c.Expect {
				t.Errorf("RoundScore(%v) = %d, want %d", c.Scores, got, c.Expect)
			}
		}
	})
	t.Run("evaluate", func(t *testing.T) {
		for i, c := range f.Evaluate {
			members := make([]Member, 0, len(c.Members))
			for _, m := range c.Members {
				members = append(members, Member{
					PlayerID: m.PlayerID, Nickname: m.Nickname, RoundScore: m.RoundScore,
					Games: m.Games, LastSubmitAt: m.LastSubmitAt,
				})
			}
			ev := Evaluate(members, tier(c.Tier), cfg, c.UpCount)
			if ev.PromoteCount != c.Expect.PromoteCount || ev.RelegateCount != c.Expect.RelegateCount {
				t.Errorf("case %d (%s, up %d, n %d): %d up / %d down, want %d / %d",
					i, c.Tier, c.UpCount, len(members), ev.PromoteCount, ev.RelegateCount,
					c.Expect.PromoteCount, c.Expect.RelegateCount)
			}
			if len(ev.Members) != len(c.Expect.Members) {
				t.Fatalf("case %d: %d members out, want %d", i, len(ev.Members), len(c.Expect.Members))
			}
			for j, want := range c.Expect.Members {
				got := ev.Members[j]
				// The order itself is the assertion: the fixtures contain
				// deliberate ties, which the Go comparator breaks by player_id.
				if got.PlayerID != want.PlayerID || got.Rank != want.Rank || got.Zone != want.Zone {
					t.Errorf("case %d position %d: %s rank %d zone %s, want %s rank %d zone %s",
						i, j, got.PlayerID, got.Rank, got.Zone, want.PlayerID, want.Rank, want.Zone)
				}
			}
		}
	})
	t.Run("transitions", func(t *testing.T) {
		for _, c := range f.Transitions {
			if got := cfg.Apply(c.Tier, c.Outcome); got != c.Expect {
				t.Errorf("Apply(%s, %s) = %s, want %s", c.Tier, c.Outcome, got, c.Expect)
			}
		}
		for _, c := range f.InactiveOutcome {
			if got := InactiveOutcome(tier(c.Tier)); got != c.Expect {
				t.Errorf("InactiveOutcome(%s) = %s, want %s", c.Tier, got, c.Expect)
			}
		}
		for _, c := range f.PromoteTier {
			if got := cfg.PromoteTier(c.Tier); got != c.Expect {
				t.Errorf("PromoteTier(%s) = %s, want %s", c.Tier, got, c.Expect)
			}
		}
		for _, c := range f.RelegateTier {
			if got := cfg.RelegateTier(c.Tier); got != c.Expect {
				t.Errorf("RelegateTier(%s) = %s, want %s", c.Tier, got, c.Expect)
			}
		}
	})
}

// elapsedSweepSet must walk the same values in the same order as
// gen_fixtures.gd, or the digests cannot match.
func elapsedSweepSet() []float64 {
	out := []float64{0}
	for v := 1; v <= 60; v++ {
		out = append(out, float64(v))
	}
	for v := 65; v <= 300; v += 5 {
		out = append(out, float64(v))
	}
	for v := 310; v <= 600; v += 10 {
		out = append(out, float64(v))
	}
	for v := 630; v <= 1200; v += 30 {
		out = append(out, float64(v))
	}
	for v := 1260; v <= 3600; v += 60 {
		out = append(out, float64(v))
	}
	for v := 3900; v <= 7200; v += 300 {
		out = append(out, float64(v))
	}
	out = append(out, 14400, 21600, 43200, 86400)
	out = append(out, 0.5, 2.5, 12.25, 33.75, 99.5)
	return out
}

// TestSweepDigest is the real proof of the port. Four million scores over every
// shipped level are hashed in both runtimes and the digests compared, which
// answers the "is math.Pow the same as the engine's" question empirically
// rather than by argument.
func TestSweepDigest(t *testing.T) {
	raw, err := os.ReadFile(fixturePath("sweep.sha256"))
	if err != nil {
		t.Fatalf("read sweep.sha256: %v", err)
	}
	var wantHash string
	var wantCases, wantLevels int
	for _, line := range strings.Split(strings.ReplaceAll(string(raw), "\r", ""), "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch key {
		case "sha256":
			wantHash = value
		case "cases":
			wantCases, _ = strconv.Atoi(value)
		case "levels":
			wantLevels, _ = strconv.Atoi(value)
		}
	}
	if wantHash == "" {
		t.Fatal("sweep.sha256 has no digest")
	}

	levels := sweepLevels(t)
	if len(levels) != wantLevels {
		t.Fatalf("the level file has %d levels, the fixture was generated from %d", len(levels), wantLevels)
	}

	h := sha256.New()
	w := bufio.NewWriterSize(h, 1<<16)
	count := 0
	elapsed := elapsedSweepSet()
	for _, lv := range levels {
		for wrong := 0; wrong <= 25; wrong++ {
			for hints := 0; hints <= 6; hints++ {
				for _, e := range elapsed {
					score := Breakdown(float64(lv.difficulty), lv.size, 0, e, wrong, hints, true).Score
					w.WriteString(strconv.Itoa(score))
					w.WriteByte('\n')
					count++
				}
			}
		}
	}
	w.Flush()
	got := hex.EncodeToString(h.Sum(nil))
	if count != wantCases {
		t.Fatalf("walked %d cases, the fixture has %d: the two runtimes are not enumerating the same set", count, wantCases)
	}
	if got != wantHash {
		t.Fatalf("sweep digest differs.\n got %s\nwant %s\nThe Go port and the engine disagree on at least one of %d scores.",
			got, wantHash, count)
	}
}

type sweepLevel struct {
	size       int
	difficulty int
}

// sweepLevels reads the level file in its on-disk order, which is the order the
// generator walks.
func sweepLevels(t *testing.T) []sweepLevel {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "queens", "levels", "queens.json"))
	if err != nil {
		t.Fatalf("read level file: %v", err)
	}
	var f struct {
		Levels []struct {
			Size       int `json:"size"`
			Difficulty int `json:"difficulty"`
		} `json:"levels"`
	}
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatalf("decode level file: %v", err)
	}
	out := make([]sweepLevel, 0, len(f.Levels))
	for _, l := range f.Levels {
		out = append(out, sweepLevel{size: l.Size, difficulty: l.Difficulty})
	}
	return out
}
