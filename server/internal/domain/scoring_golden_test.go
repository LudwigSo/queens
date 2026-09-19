package domain

import "testing"

// The rows checked in at queens/tests/run_tests.gd:641-647.
func TestGoldenScores(t *testing.T) {
	rows := []struct {
		size       int
		difficulty float64
		wrong      int
		seconds    float64
		want       int
	}{
		{6, 8.0, 0, 45.0, 223},
		{6, 8.0, 0, 72.0, 166},
		{6, 8.0, 3, 150.0, 42},
		{10, 55.0, 0, 180.0, 1420},
		{10, 55.0, 0, 245.0, 1169},
		{10, 55.0, 5, 600.0, 190},
		{10, 55.0, 12, 900.0, 84}, // the knife edge
	}
	for _, r := range rows {
		got := Breakdown(r.difficulty, r.size, 0, r.seconds, r.wrong, 0, true).Score
		if got != r.want {
			t.Errorf("Breakdown(size %d, diff %v, wrong %d, %vs) = %d, want %d", r.size, r.difficulty, r.wrong, r.seconds, got, r.want)
		}
	}
}

func TestGoldenParAndBase(t *testing.T) {
	if got := ParSeconds(8.0, 6); got != 72.0 {
		t.Errorf("ParSeconds(8,6) = %v, want 72", got)
	}
	if got := ParSeconds(55.0, 10); got != 245.0 {
		t.Errorf("ParSeconds(55,10) = %v, want 245", got)
	}
	if got := Base(8.0, 6); got != 166 {
		t.Errorf("Base(8,6) = %d, want 166", got)
	}
	if got := Base(55.0, 10); got != 1169 {
		t.Errorf("Base(55,10) = %d, want 1169", got)
	}
}

// run_tests.gd:681-682: a stored par_seconds overrides the formula.
func TestStoredParOverride(t *testing.T) {
	if got := Breakdown(8.0, 6, 144.0, 72.0, 0, 0, true).Score; got != 257 {
		t.Errorf("stored par 144 at 72s = %d, want 257", got)
	}
}

func TestClampsAndBranches(t *testing.T) {
	if got := SpeedFactor(0, 245); got != SpeedMax {
		t.Errorf("SpeedFactor(0, par) = %v, want %v", got, SpeedMax)
	}
	if got := SpeedFactor(720, 240); got != SpeedMin {
		t.Errorf("SpeedFactor(3*par) = %v, want %v", got, SpeedMin)
	}
	if got := SpeedFactor(80, 240); got != SpeedMax {
		t.Errorf("SpeedFactor(par/3) = %v, want %v", got, SpeedMax)
	}
	if got := SpeedFactor(240, 240); got != 1.0 {
		t.Errorf("SpeedFactor(par) = %v, want 1", got)
	}
	if got := HintFactor(2); got != 1.0-0.2*2 {
		t.Errorf("HintFactor(2) = %v", got)
	}
	if got := HintFactor(99); got != HintMin {
		t.Errorf("HintFactor(99) = %v, want %v", got, HintMin)
	}
	if got := AccuracyFactor(100); got != AccuracyMin {
		t.Errorf("AccuracyFactor(100) = %v, want %v", got, AccuracyMin)
	}
	if got := Breakdown(55, 10, 0, 100, 0, 0, false).Score; got != 0 {
		t.Errorf("forfeit scores %d, want 0", got)
	}
}

func TestWeekIndexFixtures(t *testing.T) {
	if got := WeekIndex(0); got != -1 {
		t.Errorf("WeekIndex(0) = %d, want -1", got)
	}
	if got := WeekIndex(WeekEpochOffset); got != 0 {
		t.Errorf("WeekIndex(345600) = %d, want 0", got)
	}
	// Monday 2026-09-07 00:00 UTC is week 2957 (run_tests.gd:683-687).
	if got := WeekIndex(1788739200); got != 2957 {
		t.Errorf("WeekIndex(1788739200) = %d, want 2957", got)
	}
	if got := WeekIndex(1788739199); got != 2956 {
		t.Errorf("one second earlier = %d, want 2956", got)
	}
	if got := WeekStart(2957); got != 1788739200 {
		t.Errorf("WeekStart(2957) = %d", got)
	}
}
