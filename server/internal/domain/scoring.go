package domain

import "math"

// Port of queens/scripts/scoring.gd. GDScript floats are C doubles and GDScript
// round() is half-away-from-zero, exactly like math.Round, so this file is a
// literal transcription. Read the warnings before changing any expression here:
// every one of them has silently broken a port before.
const (
	BaseFlat          = 60.0
	BasePerSize       = 10.0
	BasePerDifficulty = 200.0
	DifficultyRef     = 20.0
	DifficultyExp     = 1.6
	ParBase           = 30.0
	ParPerDifficulty  = 3.0
	ParPerCell        = 0.5
	KWrong            = 0.5
	AccuracyMin       = 0.1
	SpeedMin          = 0.5
	SpeedMax          = 2.0

	// SpeedExponent is log2/log3 and MUST stay this literal. Computing it as
	// math.Log(2)/math.Log(3) changes the last bits and moves scores by one.
	SpeedExponent = 0.6309297535714574

	HintPenalty = 0.2
	HintMin     = 0.1

	WeekSeconds     = 604800
	WeekEpochOffset = 345600 // Unix epoch is a Thursday; Monday 1970-01-05 00:00 UTC.
)

// clampf mirrors GDScript clampf: two comparisons, not min(max(...)).
func clampf(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// Base returns the level's base points. The result is an int and *that integer*
// is what the factors multiply (see Breakdown).
func Base(difficulty float64, size int) int {
	d := difficulty
	if d < 0.0 {
		d = 0.0
	}
	d = d / DifficultyRef
	return int(math.Round(BaseFlat + BasePerSize*float64(size) + BasePerDifficulty*math.Pow(d, DifficultyExp)))
}

// ParSeconds keeps the source order ((0.5 * size) * size) of the GDScript.
func ParSeconds(difficulty float64, size int) float64 {
	return ParBase + ParPerDifficulty*difficulty + ParPerCell*float64(size)*float64(size)
}

// AccuracyFactor clamps wrong in int space before converting, like maxi().
func AccuracyFactor(wrongPlacements int) float64 {
	w := wrongPlacements
	if w < 0 {
		w = 0
	}
	v := 1.0 / (1.0 + KWrong*float64(w))
	if v > AccuracyMin {
		return v
	}
	return AccuracyMin
}

// SpeedFactor returns SpeedMax for a non-positive elapsed or par. Keep the
// branch: historic pending_results rows may carry elapsed == 0.
func SpeedFactor(elapsedSeconds, par float64) float64 {
	if elapsedSeconds <= 0.0 || par <= 0.0 {
		return SpeedMax
	}
	return clampf(math.Pow(par/elapsedSeconds, SpeedExponent), SpeedMin, SpeedMax)
}

// HintFactor(2) is 0.5999999999999999778 in both runtimes. Do not "fix" it.
func HintFactor(hintCount int) float64 {
	h := hintCount
	if h < 0 {
		h = 0
	}
	return clampf(1.0-HintPenalty*float64(h), HintMin, 1.0)
}

// ScoreBreakdown mirrors Scoring.breakdown().
type ScoreBreakdown struct {
	Score          int     `json:"score"`
	Base           int     `json:"base"`
	ParSeconds     float64 `json:"par_seconds"`
	AccuracyFactor float64 `json:"accuracy_factor"`
	SpeedFactor    float64 `json:"speed_factor"`
	HintFactor     float64 `json:"hint_factor"`
	Flawless       bool    `json:"flawless"`
}

// Breakdown reproduces Scoring.breakdown(). par <= 0 falls back to the formula,
// exactly like the GDScript reading result.par_seconds.
//
// WARNING, the multiplication below must stay left-associative and written on
// one line. The fixture (size 10, difficulty 55, wrong 12, elapsed 900) -> 84 is
// a knife edge: base=1169, accuracy=1/7, speed clamps to 0.5.
//
//	1169 * (1/7) == 166.99999999999999073... which is within half a ULP of 167.0,
//	so it IS 167.0; 167.0 * 0.5 = 83.5 -> 84.
//
// Reassociated as float64(b) * (accuracy*speed) it yields 83.4999999999999953 -> 83.
func Breakdown(difficulty float64, size int, par, elapsedSeconds float64, wrong, hints int, completed bool) ScoreBreakdown {
	if par <= 0.0 {
		par = ParSeconds(difficulty, size)
	}
	b := Base(difficulty, size)
	accuracy := AccuracyFactor(wrong)
	speed := SpeedFactor(elapsedSeconds, par)
	hint := HintFactor(hints)
	total := 0
	if completed {
		total = int(math.Round(float64(b) * accuracy * speed * hint))
	}
	return ScoreBreakdown{
		Score:          total,
		Base:           b,
		ParSeconds:     par,
		AccuracyFactor: accuracy,
		SpeedFactor:    speed,
		HintFactor:     hint,
		Flawless:       completed && wrong == 0 && hints == 0,
	}
}

// floorDiv is integer floor division, negative-aware. GDScript computes these
// indices as int(floor(float(a) / b)); below 2^53 the two are provably identical
// and this form removes the question.
func floorDiv(a, b int64) int64 {
	q := a / b
	if (a%b != 0) && ((a < 0) != (b < 0)) {
		q--
	}
	return q
}

// WeekIndex: weeks start Monday 00:00 UTC; index 0 is the week of 1970-01-05.
// WeekIndex(0) == -1 and WeekIndex(345600) == 0.
func WeekIndex(unixTime int64) int64 {
	return floorDiv(unixTime-WeekEpochOffset, WeekSeconds)
}

func WeekStart(index int64) int64 { return index*WeekSeconds + WeekEpochOffset }
func WeekEnd(index int64) int64   { return WeekStart(index + 1) }

// pow2 is 2^x, used by the anomaly half-life decay.
func pow2(x float64) float64 { return math.Pow(2, x) }
