"""Human-style solver and difficulty rater for Queens puzzle boards.

The solver only uses deductions a person could make while looking at the board,
from the cheapest ("this row has one cell left") to the most expensive
(nested trial and error). Every step is logged with a cost; the difficulty of
a board is the sum of the step costs of the cheapest path the solver found, so
a board that needs one hard deduction scores higher than a board that needs
many trivial ones, and a board that only falls to guessing scores highest.

Rules: one queen per row, column and colour region; no two queens may touch
(including diagonally).

Usage:
    python tools/queens_solver.py queens/levels/queens.json           # rate all levels
    python tools/queens_solver.py queens/levels/queens.json -v -l 3   # show every step of level 3
    python tools/queens_solver.py --board board.txt                    # rate an ad-hoc board
    python tools/queens_solver.py queens/levels/queens.json --json    # machine readable

A board file is one line per row, one character per cell, the character being
the region id (digit or letter). Blank lines and lines starting with '#' are
ignored.

Library use:
    from queens_solver import rate
    info = rate(n, regions)   # dict with score, stars, hardest, counts, solution, unique
"""
from __future__ import annotations

import argparse
import itertools
import json
import re
import sys
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Techniques, cheapest first. The cost is what a step of that kind adds to the
# board score. "stars" is the 1..5 rating a board gets when this is the hardest
# technique it needs.
# ---------------------------------------------------------------------------
TECHNIQUES = {
    "single":   dict(cost=1,  stars=1, text="a row, column or region has only one cell left"),
    "confined": dict(cost=2,  stars=1, text="a region fits in one row/column, or a row/column in one region"),
    "common":   dict(cost=3,  stars=2, text="every candidate of a unit rules out the same cell "
                                            "(a queen there would leave that unit empty)"),
    "subset":   dict(cost=4,  stars=3, text="k regions are confined to k rows/columns (or the reverse)"),
    "chain":    dict(cost=9,  stars=4, text="a queen on this cell forces singles that end in a contradiction"),
    "guess":    dict(cost=15, stars=5, text="trial and error with the full technique set"),
}
ORDER = list(TECHNIQUES)
GUESS_INNER_WEIGHT = 0.5   # work done inside a hypothetical branch counts half


def popcount(x: int) -> int:
    return bin(x).count("1")


def bits(x: int):
    while x:
        low = x & -x
        yield low.bit_length() - 1
        x ^= low


# ---------------------------------------------------------------------------
# Puzzle geometry (precomputed bitmasks)
# ---------------------------------------------------------------------------
class Puzzle:
    def __init__(self, n: int, region):
        self.n = n
        self.region = [list(row) for row in region]
        ids = sorted({v for row in self.region for v in row})
        if len(ids) != n:
            raise ValueError(f"board has {len(ids)} regions, expected {n}")
        self.id_of = {rid: k for k, rid in enumerate(ids)}
        self.ids = ids
        N = n * n
        self.all = (1 << N) - 1
        self.row_mask = [0] * n
        self.col_mask = [0] * n
        self.reg_mask = [0] * n
        self.cell_reg = [0] * N
        for r in range(n):
            for c in range(n):
                i = r * n + c
                k = self.id_of[self.region[r][c]]
                self.cell_reg[i] = k
                self.row_mask[r] |= 1 << i
                self.col_mask[c] |= 1 << i
                self.reg_mask[k] |= 1 << i
        # attack[i]: every cell (except i) that cannot hold a queen if i does.
        self.attack = [0] * N
        for r in range(n):
            for c in range(n):
                i = r * n + c
                m = self.row_mask[r] | self.col_mask[c] | self.reg_mask[self.cell_reg[i]]
                for dr in (-1, 0, 1):
                    for dc in (-1, 0, 1):
                        rr, cc = r + dr, c + dc
                        if 0 <= rr < n and 0 <= cc < n:
                            m |= 1 << (rr * n + cc)
                self.attack[i] = m & ~(1 << i)
        # units: (kind, index, mask)
        self.units = (
            [("row", r, self.row_mask[r]) for r in range(n)]
            + [("col", c, self.col_mask[c]) for c in range(n)]
            + [("region", k, self.reg_mask[k]) for k in range(n)]
        )

    def rc(self, i: int):
        return divmod(i, self.n)

    def name(self, i: int) -> str:
        r, c = self.rc(i)
        return f"r{r}c{c}"

    def unit_name(self, kind: str, idx: int) -> str:
        if kind == "region":
            return f"region {self.ids[idx]}"
        return f"{kind} {idx}"

    def cells_name(self, mask: int) -> str:
        return ",".join(self.name(i) for i in bits(mask))

    # Brute-force reference solver (row by row), independent from the deductions.
    def brute_force(self, limit: int = 2):
        n = self.n
        found = []
        cols = [False] * n
        regs = [False] * n
        placed = []

        def rec(r):
            if len(found) >= limit:
                return
            if r == n:
                found.append(list(placed))
                return
            for c in range(n):
                k = self.cell_reg[r * n + c]
                if cols[c] or regs[k]:
                    continue
                if r > 0 and abs(placed[-1] - c) <= 1:
                    continue
                cols[c] = regs[k] = True
                placed.append(c)
                rec(r + 1)
                placed.pop()
                cols[c] = regs[k] = False

        rec(0)
        return found


# ---------------------------------------------------------------------------
# Solver state and steps
# ---------------------------------------------------------------------------
@dataclass
class State:
    cand: int      # cells that may still hold a queen
    queens: int    # cells holding a queen

    def copy(self) -> "State":
        return State(self.cand, self.queens)


@dataclass
class Step:
    technique: str
    why: str
    place: int = -1         # cell index that receives a queen, or -1
    eliminate: int = 0      # bitmask of cells removed from the candidates
    depth: int = 0          # nesting depth (0 = main line)
    inner: list = field(default_factory=list)   # steps done inside a guess branch
    cost: float = 0.0
    final_state: "State | None" = None          # set when a guess branch solved the board


class Contradiction(Exception):
    pass


class Solver:
    def __init__(self, puzzle: Puzzle, max_guess_depth: int = 3, max_subset: int = 4,
                 techniques=None):
        self.p = puzzle
        self.max_guess_depth = max_guess_depth
        self.max_subset = max_subset
        # Subset of ORDER to use (mainly for tests); "single" is always on.
        self.techniques = set(ORDER if techniques is None else techniques) | {"single"}

    # -- helpers -----------------------------------------------------------
    def place(self, st: State, i: int) -> None:
        st.queens |= 1 << i
        st.cand &= ~(self.p.attack[i] | (1 << i))

    def apply(self, st: State, step: Step) -> None:
        if step.place >= 0:
            self.place(st, step.place)
        if step.eliminate:
            st.cand &= ~step.eliminate

    def open_units(self, st: State):
        """Units that do not hold a queen yet, as (kind, idx, candidate mask)."""
        out = []
        for kind, idx, mask in self.p.units:
            if mask & st.queens:
                continue
            out.append((kind, idx, mask & st.cand))
        return out

    def check(self, st: State) -> None:
        for kind, idx, cm in self.open_units(st):
            if cm == 0:
                raise Contradiction(self.p.unit_name(kind, idx))

    def solved(self, st: State) -> bool:
        return popcount(st.queens) == self.p.n

    # -- techniques: each returns a Step or None -----------------------------
    def t_single(self, st: State, depth: int):
        for kind, idx, cm in self.open_units(st):
            if cm and cm & (cm - 1) == 0:
                i = cm.bit_length() - 1
                return Step("single", f"{self.p.unit_name(kind, idx)} has only {self.p.name(i)} left", place=i)
        return None

    def t_confined(self, st: State, depth: int):
        p = self.p
        for kind, idx, cm in self.open_units(st):
            if not cm:
                continue
            if kind == "region":
                lines = [("row", p.row_mask), ("col", p.col_mask)]
            else:
                lines = [("region", p.reg_mask)]
            for lkind, masks in lines:
                for j, lm in enumerate(masks):
                    if cm & lm == cm:
                        elim = st.cand & lm & ~cm
                        if elim:
                            return Step("confined",
                                        f"{p.unit_name(kind, idx)} lies within {p.unit_name(lkind, j)}, "
                                        f"so the rest of it is out: {p.cells_name(elim)}",
                                        eliminate=elim)
        return None

    def t_common(self, st: State, depth: int):
        p = self.p
        for kind, idx, cm in self.open_units(st):
            if not cm:
                continue
            common = st.cand
            for i in bits(cm):
                common &= p.attack[i]
                if not common:
                    break
            if common:
                return Step("common",
                            f"every cell of {p.unit_name(kind, idx)} ({p.cells_name(cm)}) rules out "
                            f"{p.cells_name(common)}",
                            eliminate=common)
        return None

    def t_subset(self, st: State, depth: int):
        p = self.p
        n = p.n
        open_rows = [(r, p.row_mask[r] & st.cand) for r in range(n) if not p.row_mask[r] & st.queens]
        open_cols = [(c, p.col_mask[c] & st.cand) for c in range(n) if not p.col_mask[c] & st.queens]
        open_regs = [(k, p.reg_mask[k] & st.cand) for k in range(n) if not p.reg_mask[k] & st.queens]
        # Pairs of families: (A, B). k members of A whose candidates cover exactly
        # k members of B => the cells of those B members outside the A members go.
        families = [
            ("region", open_regs, "row", open_rows),
            ("region", open_regs, "col", open_cols),
            ("row", open_rows, "region", open_regs),
            ("col", open_cols, "region", open_regs),
        ]
        for akind, A, bkind, B in families:
            top = min(self.max_subset, len(A) - 1)
            for k in range(2, top + 1):
                for combo in itertools.combinations(A, k):
                    amask = 0
                    for _, cm in combo:
                        amask |= cm
                    covered = [(j, bm) for j, bm in B if bm & amask]
                    if len(covered) != k:
                        continue
                    bmask = 0
                    for _, bm in covered:
                        bmask |= bm
                    elim = bmask & ~amask
                    if elim:
                        an = "+".join(p.unit_name(akind, j) for j, _ in combo)
                        bn = "+".join(p.unit_name(bkind, j) for j, _ in covered)
                        return Step("subset",
                                    f"{an} fit exactly into {bn}, so {p.cells_name(elim)} are out",
                                    eliminate=elim)
        return None

    def _propagate_singles(self, st: State) -> None:
        """Place forced queens until nothing is forced; raises on contradiction."""
        while True:
            self.check(st)
            step = self.t_single(st, 0)
            if step is None:
                return
            self.apply(st, step)

    def t_chain(self, st: State, depth: int):
        p = self.p
        elim = 0
        reasons = []
        for i in bits(st.cand):
            s2 = st.copy()
            self.place(s2, i)
            try:
                self._propagate_singles(s2)
            except Contradiction as e:
                elim |= 1 << i
                reasons.append(f"{p.name(i)} leads via forced queens to empty {e}")
        if elim:
            return Step("chain", "; ".join(reasons), eliminate=elim)
        return None

    def t_guess(self, st: State, depth: int):
        if depth >= self.max_guess_depth:
            return None
        p = self.p
        # Try the open unit with the fewest candidates.
        units = [u for u in self.open_units(st) if u[2]]
        units.sort(key=lambda u: popcount(u[2]))
        for kind, idx, cm in units:
            for i in bits(cm):
                s2 = st.copy()
                self.place(s2, i)
                status, inner = self._deduce(s2, depth + 1)
                inner_cost = sum(s.cost for s in inner)
                if status == "contradiction":
                    step = Step("guess",
                                f"trying {p.name(i)} in {p.unit_name(kind, idx)} fails after {len(inner)} steps",
                                eliminate=1 << i, inner=inner)
                    step.cost = TECHNIQUES["guess"]["cost"] + GUESS_INNER_WEIGHT * inner_cost
                    return step
                if status == "solved":
                    step = Step("guess",
                                f"trying {p.name(i)} in {p.unit_name(kind, idx)} solves the board",
                                place=i, inner=inner)
                    step.cost = TECHNIQUES["guess"]["cost"] + GUESS_INNER_WEIGHT * inner_cost
                    step.final_state = s2   # adopt the branch's finished state
                    return step
        return None

    # -- main loop -----------------------------------------------------------
    def _deduce(self, st: State, depth: int):
        """Returns (status, steps) with status in solved / stuck / contradiction."""
        steps: list[Step] = []
        techs = [(name, getattr(self, "t_" + name)) for name in ORDER if name in self.techniques]
        while True:
            try:
                self.check(st)
            except Contradiction:
                return "contradiction", steps
            if self.solved(st):
                return "solved", steps
            for name, fn in techs:
                step = fn(st, depth)
                if step is None:
                    continue
                step.depth = depth
                if step.cost == 0.0:
                    step.cost = TECHNIQUES[name]["cost"]
                if step.final_state is not None:
                    st.cand, st.queens = step.final_state.cand, step.final_state.queens
                else:
                    self.apply(st, step)
                steps.append(step)
                break
            else:
                return "stuck", steps

    def solve(self):
        st = State(self.p.all, 0)
        status, steps = self._deduce(st, 0)
        return status, steps, st


# ---------------------------------------------------------------------------
# Rating
# ---------------------------------------------------------------------------
def rate(n: int, region, max_guess_depth: int = 3, techniques=None) -> dict:
    """Solve a board with human-style deductions and return a rating dict.

    Keys: solved (bool), unique (bool), score (float), stars (1..5), hardest
    (technique name), counts (technique -> number of main-line steps),
    solution (queen column per row, or None), steps (list of Step).
    """
    p = Puzzle(n, region)
    sols = p.brute_force(limit=2)
    solver = Solver(p, max_guess_depth=max_guess_depth, techniques=techniques)
    status, steps, st = solver.solve()
    counts = {t: 0 for t in ORDER}
    for s in steps:
        counts[s.technique] += 1
    score = sum(s.cost for s in steps)
    hardest = max((s.technique for s in steps), key=ORDER.index, default="single")
    stars = TECHNIQUES[hardest]["stars"]
    solution = None
    if status == "solved":
        solution = [0] * n
        for i in bits(st.queens):
            r, c = p.rc(i)
            solution[r] = c
        if len(sols) == 1 and solution != sols[0]:
            raise AssertionError("deductive solver disagrees with brute force")
    return {
        "solved": status == "solved",
        "status": status,
        "unique": len(sols) == 1,
        "score": round(score, 1),
        "stars": stars,
        "hardest": hardest,
        "counts": counts,
        "solution": solution,
        "steps": steps,
    }


# ---------------------------------------------------------------------------
# Input formats
# ---------------------------------------------------------------------------
def load_levels(path: str) -> list:
    """(size, regions) per level of a JSON level file written by gen_boards.py."""
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return [(lv["size"], lv["regions"]) for lv in data["levels"]]


def load_board_text(text: str):
    rows = [ln.strip() for ln in text.splitlines()]
    rows = [ln.replace(" ", "") for ln in rows if ln and not ln.startswith("#")]
    n = len(rows)
    if any(len(r) != n for r in rows):
        raise ValueError("board must be square, one character per cell")
    return n, [list(r) for r in rows]


def render(p: Puzzle, st: State | None = None) -> str:
    lines = []
    for r in range(p.n):
        row = []
        for c in range(p.n):
            i = r * p.n + c
            ch = str(p.region[r][c])
            if st is not None:
                if st.queens >> i & 1:
                    ch = "Q"
                elif not st.cand >> i & 1:
                    ch = "."
            row.append(ch)
        lines.append(" ".join(row))
    return "\n".join(lines)


def print_steps(p: Puzzle, steps, indent: int = 0, show_boards: bool = False) -> None:
    st = State(p.all, 0)
    solver = Solver(p)
    pad = "  " * indent
    for k, s in enumerate(steps, 1):
        what = []
        if s.place >= 0:
            what.append(f"queen at {p.name(s.place)}")
        if s.eliminate:
            what.append(f"remove {p.cells_name(s.eliminate)}")
        print(f"{pad}{k:3d}. [{s.technique:8s} cost {s.cost:5.1f}] {'; '.join(what)}")
        print(f"{pad}       {s.why}")
        if s.inner:
            print_steps(p, s.inner, indent + 2, show_boards=False)
        if s.final_state is not None:
            st = s.final_state
        else:
            solver.apply(st, s)
        if show_boards:
            for ln in render(p, st).splitlines():
                print(f"{pad}       {ln}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("levels", nargs="?", help="JSON level file to rate")
    ap.add_argument("--board", help="text board file (one char per cell)")
    ap.add_argument("-l", "--level", type=int, help="only this level (1-based)")
    ap.add_argument("-v", "--verbose", action="store_true", help="print every step")
    ap.add_argument("--boards", action="store_true", help="with -v: print the board after every step")
    ap.add_argument("--json", action="store_true", help="machine readable output")
    ap.add_argument("--depth", type=int, default=3, help="max nesting of trial and error (default 3)")
    args = ap.parse_args(argv)

    boards = []
    if args.board:
        with open(args.board, encoding="utf-8") as f:
            boards.append(load_board_text(f.read()))
    elif args.levels:
        boards = load_levels(args.levels)
    else:
        boards.append(load_board_text(sys.stdin.read()))
    if args.level:
        boards = [boards[args.level - 1]]
        offset = args.level
    else:
        offset = 1

    results = []
    for idx, (n, region) in enumerate(boards, offset):
        info = rate(n, region, max_guess_depth=args.depth)
        info["level"] = idx
        info["size"] = n
        results.append(info)

    if args.json:
        out = []
        for info in results:
            d = {k: v for k, v in info.items() if k != "steps"}
            d["steps"] = [dict(technique=s.technique, cost=s.cost, why=s.why,
                               place=s.place, eliminate=list(bits(s.eliminate))) for s in info["steps"]]
            out.append(d)
        print(json.dumps(out, indent=2))
        return 0

    header = f"{'level':>5} {'size':>4} {'score':>7} {'stars':>5} {'hardest':>9} {'status':>8} {'unique':>6}  steps"
    print(header)
    for info in results:
        counts = " ".join(f"{t}={c}" for t, c in info["counts"].items() if c)
        print(f"{info['level']:>5} {info['size']:>4} {info['score']:>7.1f} {info['stars']:>5} "
              f"{info['hardest']:>9} {info['status']:>8} {str(info['unique']):>6}  {counts}")
        if args.verbose:
            p = Puzzle(info["size"], boards[info["level"] - offset][1])
            print(render(p))
            print_steps(p, info["steps"], show_boards=args.boards)
            print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
