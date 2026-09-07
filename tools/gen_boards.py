"""Generate Queens puzzle boards with a unique solution and bake them into a GDScript file.

Rules: one queen per row, column and colour region; no two queens may touch (incl. diagonally).
"""
import random, sys, json

def solve(n, region, limit=2):
    """Return up to `limit` solutions (list of queen column per row) via backtracking."""
    cols_used = [False]*n
    reg_used = [False]*n
    placed = []
    found = []
    def rec(r):
        if len(found) >= limit:
            return
        if r == n:
            found.append(list(placed))
            return
        for c in range(n):
            if cols_used[c] or reg_used[region[r][c]]:
                continue
            if r > 0 and abs(placed[r-1]-c) <= 1:
                continue
            cols_used[c] = True; reg_used[region[r][c]] = True; placed.append(c)
            rec(r+1)
            placed.pop(); cols_used[c] = False; reg_used[region[r][c]] = False
    rec(0)
    return found

def count_solutions(n, region, limit=2):
    return len(solve(n, region, limit))

def region_connected(n, region, rid, skip=None):
    """True if all cells of region `rid` (ignoring `skip`) form one 4-connected blob."""
    cells = [(r, c) for r in range(n) for c in range(n) if region[r][c] == rid and (r, c) != skip]
    if not cells:
        return False
    seen = {cells[0]}
    stack = [cells[0]]
    while stack:
        r, c = stack.pop()
        for dr, dc in ((1,0),(-1,0),(0,1),(0,-1)):
            nb = (r+dr, c+dc)
            if nb not in seen and 0 <= nb[0] < n and 0 <= nb[1] < n                     and region[nb[0]][nb[1]] == rid and nb != skip:
                seen.add(nb); stack.append(nb)
    return len(seen) == len(cells)

def repair(n, region, queens, rng, max_steps=60):
    """Nudge region borders until the intended `queens` placement is the only solution.

    Each step takes an alternative solution, picks one of its queen cells that is
    not part of the intended solution, and hands that cell to a neighbouring region.
    The alternative then has two queens in one region and none in another, so it
    dies, while the intended solution keeps one queen per region.
    """
    for _ in range(max_steps):
        sols = solve(n, region, 2)
        if len(sols) == 1:
            return True
        alt = next(s for s in sols if s != queens)
        diff = [(r, alt[r]) for r in range(n) if alt[r] != queens[r]]
        rng.shuffle(diff)
        moved = False
        for r, c in diff:
            old = region[r][c]
            targets = set()
            for dr, dc in ((1,0),(-1,0),(0,1),(0,-1)):
                rr, cc = r+dr, c+dc
                if 0 <= rr < n and 0 <= cc < n and region[rr][cc] != old:
                    targets.add(region[rr][cc])
            targets = list(targets)
            rng.shuffle(targets)
            if targets and region_connected(n, region, old, skip=(r, c)):
                region[r][c] = targets[0]
                moved = True
                break
        if not moved:
            return False
    return count_solutions(n, region) == 1

def random_queens(n, rng):
    while True:
        perm = list(range(n)); rng.shuffle(perm)
        if all(abs(perm[i]-perm[i+1]) > 1 for i in range(n-1)):
            return perm

def grow_regions(n, queens, rng):
    region = [[-1]*n for _ in range(n)]
    frontier = []
    for r, c in enumerate(queens):
        region[r][c] = r
        frontier.append((r, c))
    # Weighted growth: each region has its own eagerness (irregular shapes), but
    # the chance shrinks with the region's current size so none swallows the board.
    weights = [rng.uniform(0.2, 1.0) for _ in range(n)]
    sizes = [1] * n
    max_size = max(3, int(n * n * 0.3))
    remaining = n*n - n
    while remaining:
        # pick a random cell with an unassigned neighbour
        cands = []
        for r in range(n):
            for c in range(n):
                if region[r][c] >= 0:
                    for dr, dc in ((1,0),(-1,0),(0,1),(0,-1)):
                        rr, cc = r+dr, c+dc
                        if 0 <= rr < n and 0 <= cc < n and region[rr][cc] < 0:
                            cands.append((r, c, rr, cc))
        open_cands = [x for x in cands if sizes[region[x[0]][x[1]]] < max_size]
        if open_cands:
            cands = open_cands
        w = [weights[region[r][c]] / sizes[region[r][c]] ** 0.6 for r, c, _, _ in cands]
        r, c, rr, cc = rng.choices(cands, weights=w)[0]
        region[rr][cc] = region[r][c]
        sizes[region[r][c]] += 1
        remaining -= 1
    return region

def generate(n, seed):
    rng = random.Random(seed)
    attempts = 0
    while True:
        attempts += 1
        queens = random_queens(n, rng)
        region = grow_regions(n, queens, rng)
        if repair(n, region, queens, rng):
            return queens, region, attempts

SIZES = [5, 6, 6, 7, 7, 7, 8, 8, 8, 9]

def main(out_path):
    levels = []
    for i, n in enumerate(SIZES):
        queens, region, attempts = generate(n, seed=1000 + i)
        assert count_solutions(n, region, limit=3) == 1
        levels.append({"size": n, "regions": region, "solution": queens})
        print(f"level {i+1}: size {n}, {attempts} attempts", file=sys.stderr)
    with open(out_path, "w", newline="\n") as f:
        f.write("# Auto-generated by tools/gen_boards.py - do not edit by hand.\n")
        f.write("# Each level: size, regions (row-major region id per cell), solution (queen column per row).\n")
        f.write('## Loaded via preload("res://scripts/levels.gd").\n\n')
        f.write("const LEVELS: Array = [\n")
        for lv in levels:
            f.write("\t{\n")
            f.write(f"\t\t\"size\": {lv['size']},\n")
            f.write("\t\t\"regions\": [\n")
            for row in lv["regions"]:
                f.write("\t\t\t" + json.dumps(row) + ",\n")
            f.write("\t\t],\n")
            f.write(f"\t\t\"solution\": {json.dumps(lv['solution'])},\n")
            f.write("\t},\n")
        f.write("]\n")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "levels.gd")
