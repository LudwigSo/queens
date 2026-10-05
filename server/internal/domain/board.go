package domain

import "fmt"

// ValidateBoard checks that a level is a real Queens puzzle before it can be
// published: regions are ids 0..size-1, the stored solution places exactly one
// queen per row, column and region with no two queens touching, and it is the
// ONLY solution. Published levels are immutable and clients download them, so a
// broken board would be broken on every device for good.
//
// The same rules live in queens/scripts/levels.gd (validate), which the client
// runs on every downloaded level.
func ValidateBoard(size int, regions [][]int, solution []int) error {
	if size < 4 || size > 20 {
		return fmt.Errorf("implausible size %d", size)
	}
	if len(regions) != size || len(solution) != size {
		return fmt.Errorf("regions/solution do not match size %d", size)
	}
	seen := make([]bool, size)
	for _, row := range regions {
		if len(row) != size {
			return fmt.Errorf("a region row is not %d wide", size)
		}
		for _, id := range row {
			if id < 0 || id >= size {
				return fmt.Errorf("region id %d outside 0..%d", id, size-1)
			}
			seen[id] = true
		}
	}
	for id, ok := range seen {
		if !ok {
			return fmt.Errorf("region %d has no cell", id)
		}
	}
	cols := make([]bool, size)
	regs := make([]bool, size)
	for r, c := range solution {
		if c < 0 || c >= size {
			return fmt.Errorf("solution row %d: column %d outside the board", r, c)
		}
		if cols[c] {
			return fmt.Errorf("solution: two queens in column %d", c)
		}
		cols[c] = true
		reg := regions[r][c]
		if regs[reg] {
			return fmt.Errorf("solution: two queens in region %d", reg)
		}
		regs[reg] = true
		if r > 0 && abs(solution[r-1]-c) <= 1 {
			return fmt.Errorf("solution: queens in rows %d and %d touch", r-1, r)
		}
	}
	if n := countSolutions(size, regions, 2); n != 1 {
		return fmt.Errorf("the board has %d solutions, want exactly 1", n)
	}
	return nil
}

// countSolutions counts solutions row by row and stops at limit.
func countSolutions(size int, regions [][]int, limit int) int {
	cols := make([]bool, size)
	regs := make([]bool, size)
	found := 0
	var rec func(r, prev int)
	rec = func(r, prev int) {
		if found >= limit {
			return
		}
		if r == size {
			found++
			return
		}
		for c := 0; c < size; c++ {
			reg := regions[r][c]
			if cols[c] || regs[reg] || (r > 0 && abs(prev-c) <= 1) {
				continue
			}
			cols[c], regs[reg] = true, true
			rec(r+1, c)
			cols[c], regs[reg] = false, false
		}
	}
	rec(0, -2)
	return found
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
