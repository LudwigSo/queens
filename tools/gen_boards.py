"""Generate Queens puzzle boards with a unique solution and write them to a JSON level file.

Rules: one queen per row, column and colour region; no two queens may touch (incl. diagonally).

Level file format (queens/levels/queens.json):
    {"format": 1, "game": "queens", "levels": [
        {"id": "<uuid4>", "size": 6, "regions": [[...], ...], "solution": [c0, c1, ...],
         "difficulty": 20, "stars": 2, "seed": 1001},
        ...]}
The order of the array is the order in the game. Every level has a permanent
random id; player progress is stored under that id, so levels can be inserted,
reordered or removed later without breaking saved progress. Regenerating a file
keeps the id of every board that is already in it.
"""
import argparse, os, random, sys, json, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import queens_solver

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

MIN_SIZE, MAX_SIZE = 6, 10
SIZES = [6, 6, 7, 7, 7, 8, 8, 8, 9, 10]
assert all(MIN_SIZE <= n <= MAX_SIZE for n in SIZES)

def canonical(region):
    """Key that is identical for boards equal up to rotation, mirroring or region renaming."""
    n = len(region)
    best = None
    for flip in (False, True):
        g = [list(row) for row in region]
        if flip:
            g = [row[::-1] for row in g]
        for _ in range(4):
            g = [[g[n - 1 - c][r] for c in range(n)] for r in range(n)]  # rotate 90 degrees
            names = {}
            key = tuple(names.setdefault(v, len(names)) for row in g for v in row)
            if best is None or key < best:
                best = key
    return best

def parse_star_weights(text):
    """'1:30,2:30,3:20,4:15,5:5' -> {1: 30, 2: 30, 3: 20, 4: 15, 5: 5}."""
    weights = {}
    for part in text.split(","):
        star, weight = part.split(":")
        star, weight = int(star), float(weight)
        if not 1 <= star <= 5 or weight < 0:
            raise ValueError(f"bad star weight {part!r}")
        weights[star] = weight
    if sum(weights.values()) <= 0:
        raise ValueError("star weights must not all be zero")
    return weights

def split_quota(total, weights):
    """Split `total` items over the keys of `weights` proportionally (largest remainder)."""
    scale = total / sum(weights.values())
    exact = {k: w * scale for k, w in weights.items()}
    quota = {k: int(v) for k, v in exact.items()}
    for k in sorted(weights, key=lambda k: exact[k] - quota[k], reverse=True)[: total - sum(quota.values())]:
        quota[k] += 1
    return quota

def generate_levels(sizes, seed=1000, min_score=0.0, max_score=float("inf"), min_stars=1, max_stars=5,
                    star_weights=None, max_tries=300, seen=None, log=None):
    """Generate one level per entry of `sizes` (a list of board sizes).

    Every board is rated with the human-style solver, has to fall inside the
    score/star window, and must not repeat an earlier board up to symmetry and
    region renaming (`seen` is a set of canonical keys shared across calls).
    With `star_weights` the boards of each size are spread over the star ratings
    in that proportion; a star quota that cannot be filled within `max_tries`
    seeds is handed down to the next easier rating.
    """
    seen = set() if seen is None else seen
    log = log or (lambda msg: None)
    levels = []
    per_size = {}
    for n in sizes:
        per_size[n] = per_size.get(n, 0) + 1
    for n, need in sorted(per_size.items()):
        if star_weights:
            quota = split_quota(need, {s: w for s, w in star_weights.items() if min_stars <= s <= max_stars})
        else:
            quota = None
        got = 0
        attempts = 0
        rejected = {"duplicate": 0, "window": 0, "quota": 0}
        while got < need:
            if quota and attempts >= max_tries:
                hard = max((s for s, q in quota.items() if q > 0), default=None)
                if hard is None or hard <= min(quota):
                    raise RuntimeError(f"cannot fill the {n}x{n} quota: {quota} after {attempts} seeds")
                easier = max(s for s in quota if s < hard)
                quota[hard] -= 1
                quota[easier] = quota.get(easier, 0) + 1
                log(f"  {n}x{n}: no {hard}-star board in {attempts} seeds, taking a {easier}-star board instead")
                attempts = max_tries // 2
            queens, region, _ = generate(n, seed)
            seed += 1
            attempts += 1
            key = canonical(region)
            if key in seen:
                rejected["duplicate"] += 1
                continue
            rating = queens_solver.rate(n, region)
            assert rating["solved"] and rating["unique"] and rating["solution"] == queens
            stars = rating["stars"]
            if not (min_score <= rating["score"] <= max_score and min_stars <= stars <= max_stars):
                rejected["window"] += 1
                continue
            if quota is not None:
                if quota.get(stars, 0) <= 0:
                    rejected["quota"] += 1
                    continue
                quota[stars] -= 1
            seen.add(key)
            got += 1
            levels.append({"size": n, "regions": region, "solution": queens,
                           "difficulty": rating["score"], "stars": stars, "seed": seed - 1})
            log(f"level {len(levels)}: size {n}, seed {seed - 1}, difficulty {rating['score']} "
                f"({stars} stars, hardest: {rating['hardest']})")
        log(f"  {n}x{n}: {need} boards from {attempts} seeds, rejected {rejected}")
    return levels

LEVEL_FORMAT = 1

def read_levels(path):
    """Levels of an existing level file, or [] if there is none."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if data.get("format") != LEVEL_FORMAT:
        raise ValueError(f"{path}: unsupported level file format {data.get('format')!r}")
    return data["levels"]

def write_levels(out_path, levels):
    """Write the level file. Every level must carry an id."""
    assert all("id" in lv for lv in levels)
    assert len({lv["id"] for lv in levels}) == len(levels), "level ids must be unique"
    out = []
    for lv in levels:
        out.append({"id": lv["id"], "size": lv["size"], "regions": lv["regions"], "solution": lv["solution"],
                    "difficulty": lv["difficulty"], "stars": lv["stars"], "seed": lv.get("seed")})
    # One line per level keeps diffs readable and the file compact.
    body = ",\n".join("    " + json.dumps(lv, separators=(",", ":")) for lv in out)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write('{"format": %d, "game": "queens", "levels": [\n%s\n]}\n' % (LEVEL_FORMAT, body))

def sizes_for_count(count, min_size=MIN_SIZE, max_size=MAX_SIZE):
    """`count` sizes spread as evenly as possible over min_size..max_size, smallest first."""
    span = list(range(min_size, max_size + 1))
    return [span[i * len(span) // count] for i in range(count)]

def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate Queens levels with a unique solution and a difficulty rating.")
    ap.add_argument("out", nargs="?", default="queens/levels/queens.json", help="level file to write")
    ap.add_argument("--count", type=int, help=f"number of levels, spread evenly over the size range "
                                                f"(default: the built-in list of {len(SIZES)} sizes)")
    ap.add_argument("--min-size", type=int, default=MIN_SIZE, help=f"smallest board (default {MIN_SIZE})")
    ap.add_argument("--max-size", type=int, default=MAX_SIZE, help=f"largest board (default {MAX_SIZE})")
    ap.add_argument("--seed", type=int, default=1000, help="first random seed (default 1000)")
    ap.add_argument("--min-score", type=float, default=0.0, help="reject boards rated below this score")
    ap.add_argument("--max-score", type=float, default=float("inf"), help="reject boards rated above this score")
    ap.add_argument("--min-stars", type=int, default=1, help="reject boards with fewer stars (1..5)")
    ap.add_argument("--max-stars", type=int, default=5, help="reject boards with more stars (1..5)")
    ap.add_argument("--stars", type=parse_star_weights,
                    help="star mix per board size, e.g. 1:30,2:30,3:20,4:15,5:5 (default: whatever comes)")
    ap.add_argument("--max-tries", type=int, default=300,
                    help="seeds to try per size before an unfillable star quota is eased (default 300)")
    ap.add_argument("--sort", choices=["size", "score", "none"], default="size",
                    help="order of the new levels: by size (default), by difficulty score, or as generated")
    ap.add_argument("--append", action="store_true",
                    help="keep the levels already in the file and add the new ones after them")
    a = ap.parse_args(argv)
    if not MIN_SIZE <= a.min_size <= a.max_size <= MAX_SIZE:
        ap.error(f"sizes must satisfy {MIN_SIZE} <= min-size <= max-size <= {MAX_SIZE}")
    if a.count is not None and a.count < 1:
        ap.error("--count must be at least 1")
    sizes = sizes_for_count(a.count, a.min_size, a.max_size) if a.count else list(SIZES)
    existing = read_levels(a.out)
    known = {canonical(lv["regions"]): lv["id"] for lv in existing}
    seen = set(known) if a.append else set()
    levels = generate_levels(sizes, a.seed, a.min_score, a.max_score, a.min_stars, a.max_stars,
                             a.stars, a.max_tries, seen=seen, log=lambda m: print(m, file=sys.stderr))
    if a.sort == "score":
        levels.sort(key=lambda lv: (lv["difficulty"], lv["size"]))
    elif a.sort == "size":
        levels.sort(key=lambda lv: (lv["size"], lv["difficulty"]))
    for lv in levels:
        assert count_solutions(lv["size"], lv["regions"], limit=3) == 1
        # A board that is already in the file keeps its id so saved progress survives.
        lv["id"] = known.get(canonical(lv["regions"])) or str(uuid.uuid4())
    if a.append:
        levels = existing + levels
    write_levels(a.out, levels)
    stars = {}
    for lv in levels:
        stars[lv["stars"]] = stars.get(lv["stars"], 0) + 1
    print(f"wrote {len(levels)} levels to {a.out}; stars: {dict(sorted(stars.items()))}", file=sys.stderr)

if __name__ == "__main__":
    main()
