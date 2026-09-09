# Level tools

Python 3 scripts (no dependencies) that generate, solve and rate Queens
boards. Run them from the repository root.

## Level file

`queens/levels/queens.json`:

```json
{"format": 1, "game": "queens", "levels": [
    {"id": "9b6d…", "size": 6, "regions": [[0,0,1,…], …], "solution": [2,5,…],
     "difficulty": 20, "stars": 2, "seed": 1001},
    …
]}
```

* The array order is the order in the game.
* `id` is a random UUID that never changes. The game stores best times under
  it, so levels can be inserted anywhere, reordered or removed without
  breaking saved progress. Regenerating a file keeps the id of every board
  that is already in it (matched up to rotation, mirroring and region
  renaming).
* `regions` holds the region id of every cell, row-major; `solution` the
  queen's column for every row; `difficulty` and `stars` come from the
  solver; `seed` is what produced the board.

## Generator

```bash
python tools/gen_boards.py queens/levels/queens.json --count 100 --stars 1:30,2:30,3:20,4:15,5:5
```

| Option | Effect |
| --- | --- |
| `--count N` | number of levels, spread evenly from `--min-size` to `--max-size` (6 to 10); without it a built-in list of 10 sizes is used |
| `--seed S` | first random seed (default 1000); a different seed gives a different set |
| `--stars 1:30,2:30,...` | relative share of each star rating among the boards of every size |
| `--min-stars`, `--max-stars`, `--min-score`, `--max-score` | reject boards outside the difficulty window |
| `--max-tries N` | seeds to try per size before a star quota that cannot be met is handed down to the next easier rating (default 300) |
| `--sort size|score|none` | order of the new levels: by size then difficulty (default), by difficulty only, or as generated |
| `--append` | keep the levels already in the file and add the new ones after them |

Every board is checked for a unique solution, rated by the solver, and
rejected if it repeats a board of the same run (or, with `--append`, of the
file) up to symmetry. A 10x10 board costs about two seconds, so 100 levels
take a few minutes. 5-star boards are rare with this generator; their quota
usually falls back to 4 stars.

To add levels later without touching the existing ones:

```bash
python tools/gen_boards.py queens/levels/queens.json --append --count 20 --seed 5000 --stars 1:1,2:1,3:1
```

To insert a level between two others, move its object in the JSON array; ids
and progress stay valid.

## Solver and difficulty rating

`tools/queens_solver.py` solves a board the way a person would and rates how
hard that was. It applies the cheapest deduction that works, over and over,
and adds up the cost of every step:

| Technique | Cost | Stars | Meaning |
| --- | --- | --- | --- |
| single | 1 | 1 | a row, column or region has only one cell left |
| confined | 2 | 1 | a region fits in one row/column (or a row/column in one region), so the rest of that line is out |
| common | 3 | 2 | every remaining cell of a unit rules out the same cell |
| subset | 4 | 3 | k regions fit in k rows/columns (or the reverse), so other cells in those lines are out |
| chain | 9 | 4 | a queen on a cell forces a run of singles that ends in an empty unit |
| guess | 15 + half of the nested work | 5 | trial and error with the full technique set, nested up to 3 deep |

The **difficulty** is the total cost of the path the solver found; **stars**
is the rating of the hardest technique that was needed.

### How each technique is used

Throughout, a *unit* is a row, a column or a colour region, and a *candidate*
is a cell that has not been crossed out yet. Placing a queen crosses out its
row, its column, its region and the eight cells around it, which is exactly
what the game's auto-marking does.

**single.** Look for a unit with exactly one candidate left. That cell must
hold the queen: place it and cross out everything it rules out. This is the
only technique that ever places a queen; all the others only cross cells out
until a single appears.

**confined.** Look at a region whose candidates all sit in one row (or one
column). The region's queen will be in that row, so no other region may put
a queen there: cross out the rest of the row. The same works the other way
round: if all candidates of a row lie inside one region, that region's queen
is in this row, so cross out the region's cells in other rows.

**common.** Pick a unit and imagine the queen on each of its candidates in
turn. A cell that gets crossed out in every case can never hold a queen, so
cross it out for real. Typical shapes: a region that is left with two cells
side by side rules out the cells above and below both of them, and an L-shaped
region of three cells rules out the cell in the corner of the L. "confined"
is the easiest special case of this idea.

**subset.** Find k regions whose candidates together cover only k rows (the
solver tries k up to 4). Those k regions need k queens, one per row, so they
use up all k rows and no other region may have a queen there: cross out every
other region's cells in those rows. The same works with columns, and in
reverse: k rows whose candidates lie in only k regions use up those regions,
so cross out the regions' cells outside those rows.

**chain.** Pick a candidate cell and imagine a queen on it. Cross out what it
rules out, then keep placing forced queens (singles) as long as any appear.
If some unit ends up with no candidate at all, the imagined queen was wrong:
cross out the starting cell. The solver tries every candidate on the board
and crosses out all that fail in one step.

**guess.** Pick the open unit with the fewest candidates and imagine a queen on
each of its cells in turn, this time using every technique above (and further
guesses, up to three deep) inside the trial. A cell whose trial runs into a
contradiction is crossed out; a trial that completes the board is the
solution. The step costs 15 plus half of the work done inside the trials, so
long trials make the board score higher.

### Usage

Rate a level file, or a text board (one line per row, one character per
cell, piped on stdin or given with `--board`):

```bash
python tools/queens_solver.py queens/levels/queens.json
```

```bash
python tools/queens_solver.py queens/levels/queens.json -v -l 5
```

`-v` prints every deduction with its reason, `--boards` also draws the board
after each step, `--json` gives machine readable output. From Python,
`queens_solver.rate(n, regions)` returns the score, stars, hardest technique,
step list and the solution, and checks against a brute-force solver that the
board is unique.

## Tests

```bash
python -m unittest tools/test_queens_solver.py
```
