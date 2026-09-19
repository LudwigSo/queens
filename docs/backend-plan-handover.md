# Queens backend — architecture plan, handover

**Superseded on 2026-09-19 by [`backend-plan.md`](backend-plan.md), which closes every OPEN item below. This file stays as the rationale record for the SETTLED sections.**

**Status: design ~75 % done, not started in code. This document is the handover.**

It is written for an AI agent (or a person) who will finish the architecture plan
and then implement it, without access to the conversation that produced it.
Everything below is either **SETTLED** (decided, do not relitigate) or **OPEN**
(listed in §9 with what has to be decided and why).

---

## 1. What this is about

`logic-games` is a Godot 4.7 Android puzzle game — *Queens*, the LinkedIn-style
one-queen-per-row/column/region puzzle. It is fully offline today: progress,
scores, the league and "friends" all live in `user://save.json` and
`user://backend_local.json` on the device. Scores are per-device, unverified and
unshareable.

The goal is a Go + SQLite service so scores become authoritative, per-level
leaderboards and the league are shared, and identity survives a reinstall.

### The finding that shapes everything

**This is a port, not a greenfield design.** The client already contains the
whole backend contract and a working reference implementation of it:

| File | What it is |
| --- | --- |
| `queens/scripts/backend/backend.gd` | The abstract `Backend` class: 14 methods, all record shapes documented in the header. Every call returns `{ok, data, error}`; every caller `await`s, explicitly so "an HTTP implementation can be a coroutine". |
| `queens/scripts/backend/local_backend.gd` | 702-line offline implementation. **The behavioural reference for the server.** Uses deterministic bots, which the server will not have. |
| `queens/scripts/scoring.gd` | Pure static scoring. Its own doc comment: shared by "the client, the local backend stub **and a future server**". |
| `queens/scripts/league_rules.gd` + `league` dict in `queens/scripts/config.gd` | League maths: tiers, rounds, promotion, relegation. Same intent. |
| `queens/scripts/game_result.gd` | The exact submit payload, `SCHEMA := 1`. |
| `queens/scripts/app.gd:112` `_start_backend()` | The single client switch point — its comment says a networked backend would be chosen here. |
| `queens/levels/queens.json` | 100 levels: `{id (uuid), size, regions, solution, difficulty, stars, seed}`. 20 each of sizes 6–10, difficulty 6–61, 37 KB. Ships in the APK. |
| `queens/tests/run_tests.gd` | Homegrown headless runner (1409 lines). Golden scoring fixtures at line 638. |
| `queens/README.md:86–137` | The product spec for scoring and the league. Ends with "There is no server yet." |

The server implements a contract that is already written. The client change is
one new `HttpBackend extends Backend` plus one line in `app.gd`. **No UI code
changes.**

---

## 2. Decisions locked by the user — SETTLED, do not revisit

| | Decision | Note |
| --- | --- | --- |
| Language / storage | **Go + SQLite**, data access behind repository interfaces so the engine can be swapped (Postgres is the likely successor) | |
| API docs | **Huma v2, code-first.** Go structs generate OpenAPI 3.1 and Huma serves rendered docs. Dump to a checked-in `openapi.yaml` so it is diffable. | Rejected: swaggo (Swagger 2.0 only, drifts), spec-first oapi-codegen (more ceremony) |
| Anti-cheat depth | **"Recompute + timed session."** Server recomputes every score from its own level table; `POST /games` issues a signed session token with a server timestamp; submit requires it and clamps elapsed; plus per-level cooldown, rate limits, idempotency, bearer auth. | Explicitly rejected for now: move-log replay |
| League population | **Real players only.** No server-side bots. | Consequence: an early league looks empty. Accepted. |
| Deployment | **Single static binary, `server/` directory in this repo, no Docker yet.** | |

### The user's own security idea, and why it was redirected

The user proposed sending the grid and the player's solution so the server can
evaluate it. **This adds nothing**, and the reasoning must be preserved because
it is the foundation of §7:

All 100 levels — regions *and* `solution` — ship inside the APK, and the server
holds the same table. A client that returns "the solution I found" is returning a
value both sides already know. `unzip` + `grep` produces a perfect submission
without playing. Verifying it proves only that the sender can read a JSON file.

The fields that genuinely cannot be verified are `elapsed_seconds`,
`wrong_placements` and `hint_count` — and those are what the score turns on. The
security design therefore targets those, plus *volume*, not the board.

---

## 3. SETTLED — the Go service shape

```
server/
  go.mod                        module …/queens-server   (go 1.24)
  gen.go                        //go:generate go run ./cmd/queensd openapi -o openapi.yaml
  openapi.yaml                  generated, checked in, drift-tested
  cmd/queensd/
    main.go openapi.go migrate.go     (also: admin subcommands, §7.6)
  internal/
    config/      env -> Config, validation, defaults
    domain/      scoring.go league.go types.go errors.go clock.go
                 ^ zero imports outside stdlib, so parity tests are trivial
    store/       store.go (Store, Repos, repository interfaces), filters.go
      sqlite/    db.go migrate.go players.go levels.go sessions.go results.go
                 bests.go league.go friends.go  + migrations/*.sql (embedded)
    levelset/    embedded queens.json copy, parse, sync-to-DB, hash guard
    auth/        opaque token mint / hash / verify
    service/     identity.go play.go boards.go league.go friends.go
    api/         api.go errors.go middleware.go auth.go dto_*.go
    testutil/    newTestStore(t), fixed clocks, seeded levels
```

Five layers is the floor for "swappable DB + generated OpenAPI". No `pkg/`, no DI
container, no repository factory registry.

### Transactions without leaking `*sql.Tx`

```go
type Repos struct {
    Players PlayerRepo; Levels LevelRepo; Sessions SessionRepo
    Results ResultRepo; Bests LevelBestRepo; League LeagueRepo; Friends FriendRepo
}

type Store interface {
    Repos() Repos
    // InTx runs fn in one write transaction; every repo handed to fn — reads
    // included — is bound to that tx. Non-nil return rolls back.
    InTx(ctx context.Context, fn func(context.Context, Repos) error) error
    Ping(context.Context) error
    Close() error
}
```

The sqlite implementation is ~30 lines: each repo holds a read handle and a write
handle (`dbtx` interface); inside a transaction both point at the `*sql.Tx`.

### Driver and pragmas — SETTLED

**`modernc.org/sqlite`** (pure Go, no cgo). The decisive constraint is the user's:
Windows dev box, no Docker, single static binary, `GOOS=linux GOARCH=arm64 go build`
must just work. `mattn/go-sqlite3` is faster on writes and irrelevant at this scale.

```go
writeDSN = "file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)" +
    "&_pragma=foreign_keys(1)&_pragma=synchronous(NORMAL)" +
    "&_pragma=temp_store(MEMORY)&_txlock=immediate"
readDSN  = "file:%s?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)" +
    "&_pragma=synchronous(NORMAL)&mode=ro"

wdb.SetMaxOpenConns(1)   // ← the single-writer constraint, made explicit
wdb.SetConnMaxLifetime(0) // never recycle: reconnecting re-runs pragmas
rdb.SetMaxOpenConns(max(4, runtime.NumCPU()))
```

**This is the single most important operational detail in the server.**
`MaxOpenConns(1)` serialises writes through Go's connection pool (a clean FIFO
with context cancellation) instead of through `SQLITE_BUSY` retries.
`_txlock=immediate` removes the read-then-write upgrade deadlock
(`SQLITE_BUSY_SNAPSHOT`). Reads never queue behind a slow submit.

### Portability rules (the swap promise is kept by the *interface*, not by shared SQL)

`internal/store/postgres` would get its own hand-written SQL and DDL. What must
stay disciplined:

| Do | Don't |
| --- | --- |
| `INSERT … ON CONFLICT (cols) DO UPDATE/NOTHING` | `INSERT OR REPLACE`, `REPLACE INTO` |
| App-generated UUID `TEXT` PKs | `AUTOINCREMENT`, `rowid`, `last_insert_rowid()` |
| Unix seconds in `INTEGER`, clock injected from Go | `datetime('now')`, `CURRENT_TIMESTAMP` |
| `COALESCE`, standard aggregates | `IFNULL`, `GROUP_CONCAT` |
| `0`/`1` ints for booleans | `BOOLEAN` columns (also illegal in `STRICT`) |
| Explicit `ORDER BY` everywhere | implicit rowid order |
| Counter bumps as `SET x = x + 1` | read-modify-write in Go |

All tables `STRICT`. Two spots designed now for a Postgres move:
`JoinOpenGroup` (conditional `UPDATE … WHERE size < capacity`, check
`RowsAffected`, retry once) and `AddGameStats`.

No `sqlx`, no `sqlc`, no ORM — plain `database/sql` with hand-rolled scanners.

### Migrations and level seeding — SETTLED

- Schema: embedded `migrations/NNNN_name.sql` + a ~60-line forward-only runner,
  one transaction per file, tracked in `schema_migrations`. Not goose, not
  golang-migrate — one environment does not need down-migrations or dialects.
- **Levels are data, not schema.** `internal/levelset.Sync()` upserts on every
  boot (~100 rows, milliseconds):
  - new id → insert
  - identical `content_hash` → skip
  - cosmetic change (`stars`, `seed`, `regions`) → update
  - **`size` or `difficulty` changed → refuse to start**, naming the id. `base`
    and `par_seconds` derive from both; changing one silently invalidates every
    past score on that level.
  - id in DB but not in the file → keep forever, never delete, log at warn
  - then write a `level_sets` row keyed by the hash of the sorted
    `(id, content_hash)` list → that hash is the ETag for `GET /levels/meta`
- `server/internal/levelset/queens.json` is a **copy** (Go `embed` cannot reach
  outside the module). Guard with `//go:generate` copier **plus**
  `TestLevelFileInSync` reading `../../../queens/levels/queens.json` — the test is
  the enforcement, `go generate` is the fix.
- **Release ordering rule:** deploy the server before shipping a client with new
  levels. An old server returns `ERR_LEVEL_UNKNOWN` and the client must fall back
  to offline play for that level rather than blocking the game.

### HTTP layer — SETTLED

`chi` + `humachi` adapter under Huma v2. Middleware, outermost first:
`RealIP` (gated on a trust-proxy flag) → `RequestID` → `Recoverer` (logged via
slog) → `Timeout(10s)` → `serverTime` (stamps `X-Server-Time`) → `accessLog` →
`rateLimit` (`golang.org/x/time/rate`, sharded map, janitor) → `maxBytes(32 KiB)`
→ Huma. Auth is a Huma **input resolver** embedded in every authenticated request
struct, so handlers start with business logic and the header is documented as
required in the spec.

`openapi.yaml` is emitted by a `queensd openapi -o` subcommand and enforced by
`TestOpenAPISpecUpToDate` (a Go test, not a CI-only step, so drift fails locally).

Config: environment variables only, no file, no Viper. `QUEENS_ADDR`,
`QUEENS_DB`, `QUEENS_TOKEN_PEPPER` (hard fail outside dev), `QUEENS_ENV`,
`QUEENS_LOG_LEVEL`, `QUEENS_TRUST_PROXY`, `QUEENS_COOLDOWN_SECONDS`,
`QUEENS_SESSION_TTL`, `QUEENS_RATE_*`, `QUEENS_BACKUP_DIR`. Flags only for
subcommands (`migrate`, `openapi`, `backup`, `admin …`).

Logging `log/slog` (JSON in prod, text in dev). Graceful shutdown:
`signal.NotifyContext` → `srv.Shutdown(15s)` → cancel background goroutines →
`Close()` running `PRAGMA wal_checkpoint(TRUNCATE)`. Health `GET /healthz`,
`GET /readyz`, both registered on chi directly so they stay out of the spec.
Backups: nightly `VACUUM INTO '<dir>/queens-<date>.db'`, keep 14 (no cgo needed,
unlike `sqlite3 .backup`).

---

## 4. SETTLED — the endpoint map

Mapping every `Backend` method. **Note: the two design passes disagreed on path
style (`/v1/me` vs `/players/me`) — see OPEN-3.** The shape below is the
recommended one.

| `Backend` method | HTTP | Notes |
| --- | --- | --- |
| `init()` | `GET /v1/bootstrap` | `{server_time, profile, league_config, level_set_hash, standing, pending_summary}` |
| `now_utc()` | `X-Server-Time` header on every response, + `GET /v1/time` | see below |
| `register_player` | `POST /v1/players` | 201 new / 200 known device |
| `set_nickname` | `PATCH /v1/me` | |
| `get_profile` | `GET /v1/me` | |
| `start_game` | `POST /v1/games` | returns the session token — **additive** to `{round_index, group_id, joined}` |
| `submit_result` | `POST /v1/results` | 201 accepted / 200 idempotent replay |
| `get_level_leaderboard` | `GET /v1/levels/{id}/leaderboard?scope=&limit=` | `private, max-age=30` |
| `get_level_meta` | `GET /v1/levels/meta` | **strong ETag = level-set hash**, 304. The only endpoint worth real caching. |
| `get_league_standing` | `GET /v1/league/standing` | `private, max-age=15` |
| `get_round_summary` | `GET /v1/league/summary` | 200 body / **204 nothing pending** |
| `ack_round_summary` | `POST /v1/league/summary/ack` | 204 |
| `get_friends` | `GET /v1/friends` | |
| `add_friend` | `POST /v1/friends` | 201 |
| `remove_friend` | `DELETE /v1/friends/{player_id}` | 204 |
| — | `GET /healthz`, `/readyz`, `/docs`, `/openapi.yaml` | |

Statuses: 400 malformed · 401 bad bearer · 403 banned · 404 unknown · 409
cooldown / session used / already friends · 410 session expired · 422 impossible
result · 429 rate limited · 500 · 503 shutting down.

**The `{ok, data, error}` envelope does not go on the wire.** The server speaks
idiomatic HTTP; a ~40-line `HttpBackend` re-wraps into the envelope. Putting the
envelope on the wire would make every operation a 200 with a discriminated union,
destroying the generated OpenAPI, caching and 304s. The envelope exists so the
*caller* has one shape — it is not a transport format.

### How `now_utc()` is served

`Backend.now_utc()` is **synchronous** and cannot await. So: every response
carries `X-Server-Time: <unix>`; `HttpBackend` keeps `_offset = server_time -
local_time` and `now_utc()` returns `local + _offset`. `GET /v1/time` exists for
an explicit resync on resume. `app.gd:183` is already labelled "the single place
to swap in server time later" — take it, and `App.now()` becomes
`backend.now_utc()`. Everything downstream already takes `now` as a parameter.

### Errors carry codes, never prose

The client localises. Reuse verbatim: `ERR_NICKNAME_LENGTH`,
`ERR_FRIEND_CODE_FORMAT`, `ERR_FRIEND_OWN_CODE`, `ERR_FRIEND_ALREADY`,
`ERR_FRIEND_UNKNOWN`. New keys needed in `queens/i18n/strings.csv` (en, de):

`ERR_NETWORK` (client-side) · `ERR_SERVER` (also the unknown-code fallback) ·
`ERR_UNAUTHORIZED` · `ERR_BANNED` · `ERR_BAD_REQUEST` · `ERR_RATE_LIMITED`
(params: retry_after) · `ERR_LEVEL_UNKNOWN` · `ERR_LEVEL_LOCKED` (params:
remaining) · `ERR_SESSION_INVALID` · `ERR_SESSION_EXPIRED` · `ERR_SESSION_USED` ·
`ERR_SESSION_MISMATCH` · `ERR_RESULT_INVALID` · `ERR_FRIEND_CODE_UNKNOWN`
(**distinct from** `ERR_FRIEND_UNKNOWN`, which means "not in your list") ·
`ERR_FRIEND_LIMIT` · `ERR_SUMMARY_UNKNOWN` · `ERR_ID_TAKEN`

Client side this is one function; `Loc.has()` already exists so an unknown code
from a newer server degrades to a generic message instead of showing a raw key.

---

## 5. SETTLED — porting the maths (the part where being wrong is silent)

### `scoring.gd` → `internal/domain/scoring.go`

```
base     = round(60 + 10*size + 200*(difficulty/20)^1.6)
par      = 30 + 3*difficulty + 0.5*size^2                 seconds
accuracy = max(1/(1 + 0.5*wrong), 0.1)
speed    = clamp((par/elapsed)^0.6309297535714574, 0.5, 2.0)
hint     = clamp(1 - 0.2*hints, 0.1, 1.0)
score    = round(base * accuracy * speed * hint)          0 if not completed
flawless = completed && wrong == 0 && hints == 0
```

**Verified independently: all seven checked-in fixtures reproduce exactly with
plain IEEE-754 doubles and half-away-from-zero rounding.** GDScript `round()` and
Go `math.Round` both round half away from zero — they match. GDScript `float` is a
C double; never `float32`.

Traps, each of which has silently broken a port before:

1. **Associativity is load-bearing.** Fixture `(10, 55.0, wrong 12, 900 s) → 84`
   is a knife edge. `base=1169`, `accuracy=1/7`, `speed` clamps to `0.5`.
   Left-associative: `1169 * (1/7) = 166.99999999999999073…` which is within half
   a ULP of `167.0`, so it *is* `167.0`; `167.0 * 0.5 = 83.5` → `84`. ✔
   Reassociated as `float64(b) * (accuracy*speed)` you get `83.4999999999999953` →
   **83**. Write literally
   `int(math.Round(float64(b) * accuracy * speed * hint))` — no parentheses, no
   intermediate `factor`, and put a comment citing this fixture.
2. `SPEED_EXPONENT` — copy the literal `0.6309297535714574`. **Do not** write
   `math.Log(2)/math.Log(3)`; the comment "log2/log3" is documentation, not a
   formula.
3. `base()` returns an `int` and *that integer* is multiplied by the factors.
   `base := int(math.Round(...))` then `float64(base) * …`.
4. `par` term is `((0.5 * size) * size)` in source order; exact for 6–10 either
   way but write it as written.
5. `maxi(wrong, 0)` clamps in **int** space before conversion.
6. `clampf` is `if v<lo {lo}; if v>hi {hi}; v` — not `min(max(…))`.
7. `hint_factor(2)` is `0.5999999999999999778`, not `0.6`, in both. Don't "fix" it.
8. `week_index` / `round_index`: port as **integer floor division**, not
   `int(floor(float(...)))`. Provably identical below 2^53 and removes the
   question. Fixtures: `week_index(0) == -1`, `week_index(345600) == 0`.
9. `speed_factor(0, par)` returns `SPEED_MAX = 2.0`. Keep the branch byte-identical
   (the fixture at `run_tests.gd:667` exercises it, and historic
   `pending_results` rows may carry `elapsed == 0`), but it is unreachable on the
   submit path because the clamp in §7.3 raises elapsed to a human floor first.
10. `math.Pow` vs libm `pow` is the one unfixable risk — Go's is ~1 ULP, glibc's
    is correctly rounded. Mitigations: **make the client display the server's
    breakdown** (two lines in `main.gd:601`), give the anti-cheat score comparison
    a **±1 tolerance**, and prove parity empirically with the sweep test below.

**`par_seconds` must never come from the client.** `breakdown()` prefers
`result.par_seconds` over the formula — correct for the client, catastrophic for
the server: `par` is the numerator of `(par/elapsed)^0.63`, so `par_seconds: 1e9`
pins `speed` at 2.0 for any elapsed. Resolution: the server computes par from its
own `levels` row, **writes it into the results row**, and any later recompute
reads the stored value — which preserves the docstring's reproducibility intent.
A submitted/computed mismatch is a weight-1 flag (fires legitimately on an older
client), not an error. Same rule for `size`, `difficulty`, `stars`, `base`.
Optional `levels.par_override REAL` keeps per-level tuning possible
**server → client only**.

### `league_rules.gd` → `internal/domain/league.go`

- `Tier.MaxSlots` must be a **pointer** — `is_capped()` tests *presence*, not value.
- `RoundBestN` default 15 must be applied at decode time, not via
  `if n == 0 { n = 15 }`, or a deliberate `0` silently becomes 15.
- Round epoch is Monday 1970-01-05 00:00 UTC (`345600`). Bronze rounds are 3 days,
  everything else 7, so **round indices are only comparable within one tier** —
  make `(tier, round_index)` the key everywhere; never a bare `round_index`.
- `counts()`: port the branch order literally. `up_count` is a **sentinel** —
  `-1` = use the percentage, `0` = promote nobody. The tiny-group branch
  (`n < min_group_size`) **returns before** the `up+down > n` fixup and always
  reports `down: 0`. Percentage rounding is half-away-from-zero and lands on
  exact halves (Platinum on 30: `4.5 → 5`, `7.5 → 8`), so banker's rounding would
  be wrong. Preserve `(pct/100.0) * n` association.
- `evaluate()` has two deliberate asymmetries to keep: `promote_count` is the
  number *actually* promoted (a zero round_score in the promote band falls
  through — pinned by `run_tests.gd:786`), while `relegate_count` is the
  *intended* `c.Down`. And a zero-score member in a small group can end up marked
  `relegate`. Do not "fix" either.
- Gold floor: `relegate_tier` returns the same tier **and** `inactive_outcome`
  returns frozen. Redundant, both tested, port both. Consequence: nobody drops
  below Gold, so Platinum/Diamond/Challenger grow monotonically and Challenger
  inflates toward its 50 cap over years — `players_per_slot` is the production knob.
- **`Openings()` is a pure function of two population counts**, so it already
  accounts for the capped tier's own relegation analytically. **Tier close order
  therefore does not matter.** Close in config order for log readability and put a
  comment saying why the order is irrelevant, because the next reader will assume
  it is not.
- `tier_index` returning 0 for an unknown tier is a fine client fallback and a
  data-corruption amplifier on a server. Go returns `(Tier, bool)`; `false` → 500
  with the id logged.
- **Add a fourth sort key, `player_id ASC`.** Godot's `sort_custom` is introsort
  and *not stable*, so members with an identical `(score, games, last_submit_at)`
  triple get an arbitrary order — invisible with bots, but with real players a
  rank can flip between two identical standing calls and move someone across a
  promote/relegate boundary. It is a strict refinement (only orders pairs the
  GDScript comparator calls equivalent), so no existing test changes. Mirror it
  back into `league_rules.gd`.

### The parity harness — SETTLED, and it is the highest-value test

GDScript is the oracle, a committed fixture file is the contract, Go conforms,
CI closes the loop in both directions.

```
shared/fixtures/scoring_cases.json     generated, checked in
shared/fixtures/league_cases.json
shared/fixtures/sweep.sha256
queens/tools/gen_fixtures.gd           Godot headless generator
queens/tests/run_tests.gd              READS the fixture (replaces the inline rows at :640)
server/internal/domain/parity_test.go  READS the same fixture
```

- **Floats are compared by IEEE-754 bit pattern in hex, not decimal text** —
  Godot's `JSON.stringify` does not round-trip doubles. GDScript:
  `PackedFloat64Array([v]).to_byte_array().hex_encode()`. Go:
  `fmt.Sprintf("%016x", math.Float64bits(v))`. Inputs stay exactly-representable
  decimals (the existing fixtures already are).
- Integers (`score`, `base`) compare exactly and a mismatch is unconditionally fatal.
- **CI regenerates and diffs:** `godot --headless --path queens --script
  tools/gen_fixtures.gd` then `git diff --exit-code shared/fixtures/`. To change
  scoring you must regenerate in the same commit, putting every changed expected
  value in front of a reviewer next to the formula change.
- **The sweep test is the real proof:** all 100 real levels × `wrong` 0–25 ×
  `hints` 0–6 × ~215 elapsed values ≈ 3.9 M cases; both runtimes hash the score
  stream and the test asserts the digests match. Seconds in Go, a minute in
  Godot. This answers the `math.Pow` ULP question empirically instead of by
  argument.

Existing golden rows (`run_tests.gd:640`), `(size, difficulty, wrong, seconds) → score`:
`(6,8,0,45)→223` `(6,8,0,72)→166` `(6,8,3,150)→42` `(10,55,0,180)→1420`
`(10,55,0,245)→1169` `(10,55,5,600)→190` `(10,55,12,900)→84`;
`par(8,6)=72` `par(55,10)=245` `base(8,6)=166` `base(55,10)=1169`.

---

## 6. SETTLED — league mechanics the stub faked

### Group assignment

`(player_id, tier, round_index)` is the **primary key** of `league_members` —
that is the structural guarantee a player cannot be in two groups of one round.
It is an invariant, not a check.

Inside one `BEGIN IMMEDIATE` transaction on `POST /games`:
1. Existing membership? return it (idempotent; every later start is one read).
2. `SELECT id FROM league_groups WHERE tier=? AND round_index=? AND state='open'
   AND member_count < capacity ORDER BY member_count DESC, id ASC LIMIT 1`
3. None → insert a new group `lg_<tier>_<round>_<seq>`.
4. Insert the member, bump `member_count`.

**Fill-first, not spread.** Packing to 30 leaves exactly one partial group per
(tier, round). With a spread policy, 47 players give two groups of ~23 and the
percentage rules are diluted; fill-first gives 30 + 17, both above the
`min_group_size` cliff of 5, and the 30 behaves exactly like the tested case.

`global: true` tiers (Diamond, Challenger) get **one group with `capacity = NULL`**.
Special-case the *data*, not the code. Member lists are truncated to top 100 + a
±5 window around me + me — `league_screen.gd:125` already caps rendering at 100
and shows a `LEAGUE_TOP_100` note. Ranks come from a `COUNT(*)` of strictly-better
rows, never from position in the truncated slice. Diamond's `up_count` is
`openings(challenger, |diamond|, |challenger|)` — two counts, cached per round
with a 60 s TTL while open, frozen at close.

### Round rollover

**Both a ticker and lazy-on-access, ticker primary.** Ticker every 60 s closes
every round past its end. Lazy catch-up runs first in `GET /league/standing`,
`POST /games` and `POST /results` for that player's tier — it makes a cold start,
a crashed ticker and a suspended machine all self-heal, and after the ticker has
run it is one indexed SELECT returning nothing.

Exactly-once by conditional claim:
```sql
UPDATE league_rounds SET state='closing', closed_at=?
 WHERE tier=? AND round_index=? AND state='open'
```
`RowsAffected == 1` → you own it. Then close **per group, in separate
transactions** (a Diamond round must not hold the write lock for a minute), each
skipping already-closed groups, so a crash resumes exactly where it stopped.
Before closing any group, **freeze** `below_players`, `members_in_tier` and the
derived `up_count` onto the round row, so every group sees the same numbers and a
resumed close promotes the same count.

**Promotion does not auto-join the new tier's round.** On any tier change the
server sets `players.tier` and resets `tier_points = 0`, and stops. The membership
in the new tier's running round is created lazily by the next `POST /games`. This
is the stub's behaviour and it is tested (`run_tests.gd:943` asserts
`not standing["joined"]` right after a Bronze→Silver promotion). Auto-joining
would create phantom zero-score members who then get relegated for inactivity.
⚠️ Product wart to flag to the user: a player promoted on Sunday evening joins a
week ending in hours and will likely be relegated. A "joined with <24 h left →
frozen instead of relegated" grace rule is the obvious later fix.

**Players who never come back — collapse, do not iterate.** The stub loops one
round per missed round; three years away is 156 iterations (365 in Bronze). Instead:
compute `missed` from `last_round_settled`; if the outcome is frozen write **one**
summary; if relegate, walk down — bounded to ≤2 steps because the Gold floor
turns every further miss into a no-op — and write **one** summary with
`tier_before` = original, `tier_after` = final. The client only ever shows the
latest unseen summary anyway. This is a deliberate, documented divergence from the
stub; scope the league parity fixture to the **pure functions** and test rollover
*orchestration* with Go integration tests only (the stub's rollover is inseparable
from its bots).

Summaries are written inside the group-close transaction, so "round closed" and
"summary exists" are one atomic fact. `ack_round_summary(round_index)` keeps its
signature and marks the newest unseen summary seen **if its index matches** —
exactly `local_backend.gd:540-546`.

### Per-level leaderboards

Sort orders differ per scope and both must be exact:

- **global / friends** (`_entry_before`, `local_backend.gd:579`):
  `score DESC, wrong_placements ASC, time_seconds ASC, achieved_at ASC, player_id ASC`
- **flawless** (`_entry_faster`, `:589`), over `wrong_placements == 0`:
  `time_seconds ASC, achieved_at ASC, player_id ASC`

`my_rank` is `COUNT(*) + 1` of strictly-better rows, written as an **explicit
lexicographic OR-chain**. Do *not* use SQLite row-value comparison `(a,b,c)<(x,y,z)`
— the mixed ASC/DESC directions make it wrong, which is exactly the sort of bug
nobody notices for months.

**A stub bug to fix deliberately:** `get_level_leaderboard` takes each player's
*score-best* entry and then filters `wrong == 0`, so a player whose top-scoring run
had one mistake is absent from the flawless board even with a clean run of the
same level. The server should keep each player's **fastest clean run**
independently. The visible effect is that more players appear on the flawless
board — strictly better, but it is a behaviour change the user should consciously
accept. Related: `Scoring.breakdown().flawless` means `wrong == 0 && hints == 0`,
while the flawless *scope* filters on `wrong == 0` only. Keep the scope as-is
(it matches shipped behaviour and the fields `LeaderboardEntry` carries); tightening
it later is additive.

### Presentation stays on the client

`tier_name` and `rules_text` come from `Loc.t()`/`Loc.f()` in the player's
language; the server has no locale and must not grow a copy of `i18n/*.csv`.
**Server sends ids and numbers only.** `rules.up_to` changes from a display name
to a **tier id**. `tier_name` and `rules_text` stop being sent. `is_bot`
disappears (send constant `false` for one release if a zero-diff client is wanted).

Client already derives names in `views.gd:21`, `:186` and `main.gd:244-245`. Only
`league_screen.gd` reads the prose fields — **four lines** (`:59`, `:67`/`:72`,
`:79`, `:114`).

---

## 7. SETTLED — the security model

### 7.1 Threat model, stated plainly

The attacker owns the hardware. They have: `queens.json` with every `solution`
inside the APK; the decompilable `.pck` including `scoring.gd`; plaintext
`user://save.json` including whatever token you put there; a hooked clock,
network and input; and the option to skip the game and speak HTTP directly.

**Undefendable:** any claim about *how* a board was solved. `completed`,
`wrong_placements`, `queens_placed`, `queens_removed`, `clear_count`,
`hint_count`, `taps` are numbers the client asserts about events only the client
witnessed. Short of server-side move-log replay, nothing makes a self-reported
counter trustworthy on hardware the reporter controls.

**A patient cheater cannot be stopped.** The best attack is not exotic: open a
session, wait until `elapsed >= par/3` (where `speed_factor` saturates at 2.0),
submit `completed, wrong 0, hints 0` with plausible `taps`. That is the
theoretical maximum for the level and it is *indistinguishable from an excellent
human*, because an excellent human genuinely solves a 6×6 in under 24 s.

**Defensible:** the arithmetic (server recomputes); the level's intrinsic worth
(`base` spans 149–1351, a 9× range — the largest multiplier in the formula — and
comes from the server's table); **volume**; time bounds; identity; and other
players' data.

**The ceiling — a free hard check.** Max per game is `2 × base` (accuracy and
hint cap at 1.0, speed at 2.0) ≈ 2702 points. Round score is the best 15, and the
7-day cooldown caps a player at 100 distinct levels per week, so
`max_round_score = 2 × Σ(15 largest base values among levels whose cooldown
allows a start this round)` — computable exactly per player from the server's own
tables. A round score above it is **impossible, not suspicious**. One query, a
422, and maximum flag weight. It catches replaying one high-value level and
forging `base` by lying about `size`.

**The framing to promise:** not "nobody cheats" but **a cheater's ceiling equals
the best honest player's ceiling.** They cannot produce a visibly impossible
number, cannot make the game look broken, and can only claim a place among the
small set at the top. For the 99 % in Bronze–Gold, a cheater is one row in a group
of 30, for one round. That is worth ~2 weeks; more costs 5–10×.

### 7.2 Identity and auth

Registration `POST /players` is unauthenticated and IP-rate-limited; returns the
profile plus a token.

**Token: opaque random, hashed at rest. Not JWT.** `base64url(32 random bytes)`
on the wire, `sha256(token)` as the `auth_tokens` primary key. Rationale:
revocation is a DELETE (a JWT needs a denylist = the same lookup, minus the
simplicity); the interesting claims (`tier`, `tier_points`, `shadow_excluded`)
change every round so a JWT carrying them is stale in minutes; no `alg` confusion,
no rotation ceremony, no library CVEs. SHA-256 not bcrypt — 256 bits of CSPRNG has
nothing to brute force, so a slow KDF costs latency and buys nothing.
`last_seen_at` updated at most hourly (a write per request would serialise the
whole server behind the SQLite write lock).

Client storage: `save.json` in the clear, behind `SaveData.VERSION := 2` and a new
arm in the existing `migrate()` ladder (`save_data.gd:140-149` is already built for
this). Plaintext is right — the token is exactly as strong as the device, and §7.1
already concedes the device. Android Keystore would need a plugin and a JNI bridge
to defend against an attacker who by assumption owns the machine.

**Account recovery and multi-device are explicitly out of scope for v1** — lose
the device, lose the account, and say so in one sentence in the settings screen.
Add `players.auth_provider` / `auth_external_id` (nullable, unique index) now so
Play Games Services sign-in or a transfer code drops in later without a migration.

### 7.3 The timed session

`POST /games`, in one transaction: resolve token → lazy round catch-up → validate
level → **server-authoritative cooldown check** → rate limit → record
`player_levels.last_started_at = now` → join/create league membership → mint
session. The response is **additive** to `{round_index, group_id, joined}`:
`session: {token, issued_at, expires_at, level: {size, difficulty, stars, par_seconds}}`
plus `server_time`.

Token: `base64url(session_id) + "." + base64url(HMAC-SHA256(secret, session_id)[:16])`,
backed by a `game_sessions` row. Single-use enforcement is a conditional update
(`… WHERE consumed_at IS NULL`); `RowsAffected == 0` → if `result_id` matches,
fall through to the idempotency path, else 409 + flag. The HMAC's value is
rejecting garbage *before* it touches the database — on SQLite, where reads and
writes share a lock, that is a real DoS difference.

**Two lifetimes, because one number cannot serve both:**
- `expires_at = issued_at + 6h` governs **freshness**; an older session is still
  accepted but scores a weight-1 signal.
- **A session is accepted for submission for 30 days.** Non-negotiable:
  `pending_results` is an offline queue replayed by `flush_pending_results()`, a
  player can be offline for weeks, and hard-rejecting would silently destroy the
  scores of everyone who plays on a plane — *shipped behaviour you would be
  breaking*.

**The clamp:**
```
wall  = now_server - session.issued_at
upper = min(wall + 2s, 24h)
floor = 1.5 + 0.45*size + 0.010*size²        # 6×6 → 4.56 s, 10×10 → 7.00 s
elapsed = clamp(client_elapsed, floor, upper)
```
Floor terms: 1.5 s screen transition + first look; 0.45 s per *deliberate* tap
(~2.2/s with a decision between taps); 0.010 s per cell (~100 cells/s visual search).

**Be honest about which bound does the work.** A cheater wants a *small* elapsed.
The upper bound only prevents physically impossible values that would *hurt* the
submitter — keep it for data sanity, do not oversell it. And the floor **does not
protect the score**: `speed_factor` saturates at `par/3`, which for a 6×6 at
difficulty 8 is 24 s — five times the floor. A cheater claiming 24 s gets the
maximum multiplier untouched. The floor catches `elapsed: 0.1` automation and
feeds the flag column, nothing more.

**The corollary that should drive effort allocation: time is not the cheat lever
— volume is.** The real controls are the cooldown, the rate limits, the best-15
round cap and the ceiling check.

A sub-floor elapsed should **clamp and fire a weight-5 flag** — a real
`GameSession` accumulates frame deltas and cannot produce one.

### 7.4 Cooldown, rate limits, idempotency, validation

**Cooldown** moves server-side (`player_levels` table), replacing the
clock-defeatable client one. `Cooldown` in GDScript stays as a pure formula; only
the source of `last_started_at` changes. Surfaced in bulk via `get_level_meta()` →
`{par_seconds, locked_until}`. **Seed once** from the client's local
`last_started_at` values at registration, capped to `now`; never take
`max(client, server)` on later syncs — that is a permanent cheat surface.

**Rate limits** (in-process token buckets + DB daily counters so a restart does
not reset long windows):

| Endpoint | Per player | Per IP |
| --- | --- | --- |
| `POST /players` | — | **5/hour, 20/day** |
| `POST /games` | 30/hour, 200/day | 200/hour |
| `POST /results` | 40/hour, 250/day, burst 10/min | 300/hour |
| `POST /friends` | 20/hour, 100/day | 60/hour |
| reads | 600/hour | 3000/hour |

- **Do not charge idempotent replays against the bucket** — a player returning
  from two weeks offline with 40 queued results must not be 429'd on their own
  history.
- **Registration is the limit that actually matters** — it is what stops account
  farming, which is what stops someone filling a 30-player Bronze group with
  sockpuppets.
- IP limits must be generous and must **never ban or flag a player** — carriers
  NAT tens of thousands behind one address. Honour `X-Forwarded-For` only from a
  trusted proxy, or every limit is spoofable with a header.

**The idempotency conflict you will actually hit.** `results.result_id` is the PK
and the response JSON is stored beside it. But the same id can legitimately arrive
twice with *different bodies*:

1. `App.record_result` appends to `results` and `pending_results` and clears
   `current_game` **in memory**;
2. it `await`s `submit_result`;
3. `App.save_now()` only runs *after* the await (`app.gd:162`);
4. if the process dies during (2) the **disk** still holds the old `current_game`;
5. next launch `_forfeit_dangling_game()` rebuilds a **forfeit** with the **same
   `result_id`** (`game_session.gd:109`) and submits it.

Rules: **`completed: true` wins over `completed: false` regardless of arrival
order**; otherwise return the stored response and log a weight-1 signal; never
409 (this path is a client crash, not a cheat). Store a `payload_hash` so
"different body" is cheap to detect. **And fix the client:** move
`App.save_now()` to immediately *after* `save.record_result(...)` and before the
await in `app.gd:150-163`. One line moved, and the race mostly disappears.

**Validation — the server overwrites rather than trusts:** `size`, `difficulty`,
`stars`, `par_seconds` from the `levels` row; `level_id` from the **session**, not
the payload; `player_id` from the token (a mismatch is 403 + weight-8);
`elapsed_seconds` clamped; `finished_at = min(payload, now)`; `score` recomputed
(the payload value kept only as `client_score` for the flag comparison);
`week_index` ignored entirely.

A `size`/`difficulty`/`stars` mismatch is **accepted with an override plus a
weight-1 flag, not rejected** — a client on a slightly older `queens.json` would
otherwise be locked out of submitting, turning a content update into an outage.

Hard 422s (physically impossible, not suspicious): `queens_placed < size` on a
completed board · `taps < queens_placed` · `wrong_placements > queens_placed` ·
`hint_count > size` · any negative counter · `elapsed > wall + grace` ·
`finished_at - started_at < elapsed - grace` · round score above the §7.1 ceiling.

### 7.5 Flag, don't ban

`players.anomaly_score REAL` with a **30-day half-life** applied lazily on read,
plus an append-only `player_flags` audit log (you will want it the first time
someone emails "I was excluded and I didn't cheat").

Signals, all cheaply available from fields already submitted and currently unused:

| Signal | Weight |
| --- | --- |
| `score_mismatch` (\|client − server\| > 1; ±1 is the `math.Pow` tolerance and must not fire) | 3 |
| `elapsed_below_floor` | 5 |
| `no_exploration` (`queens_removed==0 && clear_count==0 && wrong==0 && elapsed<par/3`) — the signature of reading the solution out of the APK | 4 |
| `taps == queens_placed` on a completed board | 2 |
| `no_session` (allow a grace window at rollout for pre-server `pending_results`) | 8 |
| `session_stale` (>6 h) | 1 |
| `cooldown_violation_attempt` | 3 |
| `finished_before_started` | 4 |
| `friend_code_probing` (>50 unknown codes/hour) | 2 |
| `impossible_round_score` | 20 |
| `perfect_streak` (N consecutive `wrong==0 && hints==0 && elapsed<par/3`) — the only signal that catches the *patient* cheater, and it also catches the world's best player, which is exactly why it flags | 0.5×N, cap 6 |

**Shadow exclusion at `anomaly_score >= 15`:** omitted from `global` and
`flawless` leaderboards; moved into a **quarantine group** — a separate
`league_groups` row for the same `(tier, round_index)` holding only excluded
players, evaluated by the identical code path, with real promotions and
relegations among themselves. Still visible to their own friends (hiding them
there generates support mail from the *friend*). Their own `my_entry`, `my_rank`,
summaries and progression are unchanged.

**Never** reject a result for a soft signal (a rejection tells the cheater which
check fired and lets them binary-search your detection — silence does not),
**never** show a UI difference, **never** auto-ban (there is no appeal process).

Operations: an **admin CLI subcommand on the same binary** reading the same DB
(`queensd admin flags list --player X`, `exclude`, `unexclude`, `rescore`). No
admin HTTP surface in v1 — that is an authn, authz and audit problem you do not
need on day one.

### 7.6 Out of scope, with the hook to add today

| Deferred | Buys | Costs | Hook now (all free) |
| --- | --- | --- | --- |
| Play Integrity | kills modded-APK cheating | GCP project, JNI bridge; fails on emulators/root so you still need §7.5 | optional `integrity_token` on `POST /games`; `game_sessions.integrity_verdict` |
| **Move-log replay** | **the only thing that actually closes the hole** — every self-reported counter becomes derived | recorder in `BoardModel`, a Go replayer that must match board rules exactly, 2–3 weeks | `results.move_log BLOB NULL`, `results.verified`; bump `GameResult.SCHEMA` |
| Server-generated puzzles | kills "the APK has every answer" at the root | port `tools/gen_boards.py`, `level_id` stops being a stable leaderboard key, offline play dies | `levels` is a server table from day one |
| Account recovery / multi-device | obvious | §7.2 | `auth_provider` / `auth_external_id` |
| **Play Billing receipt validation** | the unlimited-energy IAP is client-asserted today (`energy.set_unlimited(token)`), so **energy is free to anyone who patches the client** | Play Developer API service account, energy ledger moves server-side | `players.entitlements`, a `purchases` table; store `purchase_token` unvalidated now |

⚠️ **Say this to the user plainly: the IAP hole is probably worth more money than
the leaderboard hole is worth pride.** A third week of security effort is better
spent on receipt validation than on move logs.

---

## 8. SETTLED — client-side changes

The `{ok, data, error}` envelope stays byte-identical. Every field change is
additive except two (`rules.up_to` becomes an id; `tier_name`/`rules_text` stop
being sent), both absorbed by four lines in `league_screen.gd`.

1. **New `queens/scripts/backend/http_backend.gd`** — `class_name HttpBackend
   extends Backend`, a small pool of `HTTPRequest` children (Godot's is
   single-request; 4 with a queue is enough), one `_call()` helper that maps 2xx →
   `ok(...)`, a coded error → `fail(Loc.f(code, params))`, an unknown code →
   `fail(Loc.t("ERR_SERVER"))`, transport failure → `fail(Loc.t("ERR_NETWORK"))`.
   `provider_name()` → `"http"`. Must emit `standing_changed` after `start_game`,
   `submit_result`, `add_friend`, `remove_friend` — `main.gd:96` already listens,
   and forgetting it silently stops the league screen refreshing.
2. **`app.gd:112`** picks `HttpBackend` when a new `GameConfig.server_url != ""`,
   else `LocalBackend` (empty default keeps every test and the screenshot runner
   working untouched). **`_ready()` must become a coroutine** — `init()` and
   `register_player()` are awaited now. Note `flush_pending_results()` is
   *already* a coroutine called without `await` at `app.gd:41` — a latent bug that
   works only because the stub returns synchronously, and becomes real the moment
   the backend is networked. Same for `_forfeit_dangling_game` → `record_result`.
3. **`save_data.gd`** — `VERSION := 2`, `"auth": {player_id, token, issued_at}`,
   one new arm in the existing `migrate()` ladder, accessors.
4. **`Cooldown` stays a pure module.** Add `App.level_locks` (`level_id →
   locked_until`) from `get_level_meta()` and one `App.lock_remaining(level_id)`
   helper that prefers the server value and falls back to the local formula
   offline. Call sites: `main.gd:181,199,413,467`, `views.gd:94,132`.
   `Views.level_card`/`level_detail` take `remaining: int` instead of
   `(now, cooldown_seconds)` — cleaner and easier to test.
5. **`App.now()` → `backend.now_utc()`**, with `HttpBackend` holding a server-time
   offset refreshed from every response. Track `Time.get_ticks_msec()` alongside
   so a mid-session device clock jump is detectable. `Backend.now_utc()` already
   defaults to the system clock, so `LocalBackend` is unaffected.
6. **`GameResult` gains `session_token`** (`SCHEMA := 2`), `GameSession.start()`
   accepts it, and **`to_marker()`/`forfeit_from_marker()` must carry it** —
   otherwise a crash-forfeit arrives with no session and scores a weight-8 flag on
   an honest player. *This is the single easiest thing to forget.*
7. **`main.gd:488` — `start_game` must be awaited and allowed to fail.** Three
   outcomes: ok → stash the token, refresh locks, proceed; `ERR_LEVEL_LOCKED` →
   abort, refresh locks, show the existing dialog, **refund the energy** (the
   charge at `main.gd:481` already ran — move it after a successful start);
   offline → proceed with an empty token and let the result queue, which is the
   behaviour players already have and must not regress. Also restructure: today
   `session.start()` and `save.begin_game()` run *before* the backend is told
   anything, so a rejected start leaves a marker that gets forfeited next launch.
8. **`main.gd:601`** — prefer the server's breakdown over the local recompute.
   Two lines, and it makes the `math.Pow` ±1 question invisible forever.
9. **`league_screen.gd`** — the four prose lines (`:59`, `:67`/`:72`, `:79`, `:114`).
10. **`config.gd`** — the `league` dict moves to a shared file (see OPEN-2).
11. **Tests** — `run_tests.gd:640` reads the shared fixture; add a
    `BackendContract` helper (the assertion body of `_test_local_backend` minus
    bot specifics) runnable against any `Backend`, mirrored by a Go integration
    test against the real server. Ensure `use_save_path()` sets `server_url = ""`
    so a screenshot run never talks to a real server.

**Unchanged:** `board.gd`, `board_model.gd`, `hint_finder.gd`, `level_picker.gd`,
`energy_ledger.gd`, every screen except those four lines, router, theme, `Loc`,
`Fmt`, `Motion`.

---

## 9. OPEN — what is still missing

Ordered roughly by how much they block implementation.

### OPEN-1 (blocking): the two schema drafts must be merged

Two design passes produced **overlapping but non-identical schemas**. Neither is
complete on its own. Reconcile into one `0001_init.sql`:

| Concern | Pass A | Pass B | Note |
| --- | --- | --- | --- |
| sessions | `sessions` | `game_sessions` | pick one name |
| cooldown | an index on `sessions(player_id, level_id, issued_at DESC)` | an explicit `player_levels` table with `plays` | **B is needed** — cooldown must survive session GC |
| flawless board | partial index on `level_bests WHERE wrong_placements = 0` | a separate `level_flawless_bests` table | **B is needed** for the bug fix in §6 |
| anti-cheat | absent | `player_flags`, `anomaly_score`, `shadow_excluded` | **B only** |
| round state | `closed_at` | `state` open/closing/closed + frozen `up_count`, `below_players`, `members_in_tier` | **B is needed** for crash-resumable closes |
| levels | `solution_json` + `regions_json` stored | recommends **stripping `solution` at import** | see OPEN-6 |
| everything else (`players`, `auth_tokens`, `levels`, `level_sets`, `results`, `level_bests`, `league_rounds`, `league_groups`, `league_members`, `round_summaries`, `friends`, `schema_migrations`) | full `STRICT` DDL with index rationale | partial | A is the base |

Pass A's index choices are worth keeping verbatim: `level_bests_rank` in exactly
the leaderboard order (a pure index range scan), a *partial* index for flawless,
`results_round_player … WHERE completed = 1`, `league_members_standing` matching
`sort_members`, and `round_summaries_once` as a unique key making the closer
idempotent. Partial indexes are identical in SQLite ≥3.8 and Postgres.

### OPEN-2 (blocking): four direct contradictions to decide

1. **Player identity.** Pass A: the server issues a *new* `player_id`, the
   client's UUID becomes `device_id`, and `GameResult.player_id` is deleted from
   the DTO. Pass B: **keep the client's UUID as the account key**, because the
   whole save is already keyed by it (`save.data.player.id`, every queued
   `pending_results` row) and re-keying means migrating the offline queue.
   → *Recommendation: B.* The UUID is 122 bits of CSPRNG, unguessable; it is a
   **name, not an authenticator** — the token authenticates. Handle the
   astronomically unlikely squat with `409 ERR_ID_TAKEN` and a client that
   regenerates and retries once (~15 lines).
2. **League config location.** A: embedded in Go and served in `/bootstrap`.
   B: **one `shared/league.json`**, `go:embed`-ed and loaded by the client from
   `res://`, plus a `config_hash` in every standing so drift is visible and
   self-healing, plus a CI golden asserting derived values.
   → *Recommendation: B*, with A's "serve it in bootstrap" as the runtime
   reconciliation. Not a DB table — a league rule change is a behaviour change
   that must go through code review and re-run the golden fixtures.
3. **Error body shape.** A: RFC 9457 `application/problem+json` with a `code`
   field, installed via `huma.NewError` so Huma's own validation errors carry
   codes too. B: `{"error_key": ..., "params": [...]}`.
   → *Recommendation: A's envelope with B's `params`.* A's `huma.NewError` hook is
   the part that matters.
4. **Path style.** A: `/v1/players`, `/v1/me`, `/v1/games`. B: `/players/me`, no
   version prefix. → *Recommendation: A.* Version the API; the client will outlive
   the server's first schema.

### OPEN-3 (blocking): friend codes are under-specified

Today `LocalBackend.friend_code_for()` derives `QN-XXXXXX` from GDScript's
`hash()`, which is **not portable** — the server must own codes. Still to decide
and write down:
- generation (random over `ABCDEFGHIJKLMNOPQRSTUVWXYZ234567`, 6 chars = 32⁶ ≈
  1.07 B) vs derivation; collision retry loop; stored `UNIQUE` on `players`
- **directed (I follow you) vs mutual.** Directed is far simpler and matches the
  current UI, which has no accept flow. Recommend directed, note it in
  `backend.gd`'s header.
- a friend-list cap (`ERR_FRIEND_LIMIT` is already reserved)
- enumeration defence beyond the weight-2 probing flag: codes are 1.07 B, so a
  rate limit is sufficient, but say so explicitly
- the client's local `friend_code_for()` becomes dead once codes come from the
  server — decide whether to delete it or keep it as an offline placeholder

### OPEN-4 (blocking before launch, not before coding): no hosting decision

"Single binary, no Docker" is decided; **where it runs is not.** Nothing in either
pass covers:
- **TLS.** Bearer tokens and nicknames go over the wire. Caddy or nginx in front,
  or `autocert` in-process? A reverse proxy also changes the `X-Forwarded-For`
  trust decision in §7.4.
- a domain name, and how `GameConfig.server_url` is configured per build
  (debug → localhost, release → production) given the CI `sed`-patches
  `version/code` already
- systemd unit, volume/backup location, restore drill
- what happens when the server is down: the client must degrade to offline, which
  §8.7 covers for `start_game` but not for the league and leaderboard screens

### OPEN-5: the OpenAPI spec itself does not exist

The user's explicit ask — "the API should be documented with an OpenAPI spec" — is
currently an endpoint *table* (§4). Still missing: field-by-field request and
response DTOs for all 15 operations, matching the record shapes in
`backend.gd`'s header comment exactly. Pass A proposes **contract snapshot tests**
(`internal/api/testdata/*.json`) precisely because GDScript reads payloads by
string key with no compile-time checking, so a renamed field is a silent runtime
break the Go CI would otherwise miss. Write the DTOs, then the golden files.

### OPEN-6: keep or strip `solution` server-side?

Pass A stores `solution_json`; Pass B recommends stripping it at import so it
cannot leak through the API layer. → *Recommendation: store it, never expose it.*
It is required for the move-log replay upgrade path (§7.6), it is already public
in the APK so storing it leaks nothing new, and re-importing later is a migration.
Put the decision in a comment so nobody "cleans it up".

### OPEN-7: existing players' local progress is stranded

Neither pass covers migration of **existing local data** into the server. A player
with 50 local games, per-level bests and a tier appears as a brand-new Bronze
player with zero. Options: import `save.json`'s `levels` map as `level_bests` at
registration (trivially forgeable — every field is client-asserted, so it would
have to be flagged or capped); import only cooldowns (B's §7.4 seeding, already
planned) and let scores start fresh; or start fresh entirely and say so.
→ Needs a product decision. Cooldown-only is the safe default.

### OPEN-8: account deletion / data retention

Not covered at all. The service stores a nickname (user-authored, shown to
others), play history and IP-derived rate-limit state. At minimum: a deletion path
(`DELETE /v1/me`, cascading — the FKs already say `ON DELETE CASCADE`), a
retention policy for `player_flags` and `results`, and a line in the app about
what is stored. Google Play's data-safety form will ask for this regardless.

### OPEN-9: nickname moderation

Mentioned ("Unicode normalization pass and a profanity denylist") but not
designed. It is the one piece of user-controlled text with a blast radius —
rendered to every other player in a group. Decide: denylist source, homoglyph
normalisation, whether renames are rate-limited, and whether an admin CLI rename
exists.

### OPEN-10: the empty-league product risk is unresolved

"Real players only" means Diamond with 6 players reads "Diamond · 6 players", and
Gold-and-above groups of three behave oddly (`counts()` handles `n <
min_group_size` gracefully — at most the leader promotes, nobody relegates — and
Bronze/Silver are score-mode so the on-ramp is fine). Fill-first group packing is
the cheap mitigation. If the user later wants it to *look* populated, re-adding
bots must be a clearly-labelled `synthetic` flag on the member row that the league
maths never sees. Flag this for a launch-time decision.

### OPEN-11: smaller gaps

- **Go is not installed on this machine** (`go: command not found`; not in
  `C:\Program Files\Go` or `G:\tools`). Install a toolchain before M0.
- **`.github/workflows/server.yml` does not exist.** The only workflow is
  `android.yml`, and **it does not run the test suite** — worth fixing in the same
  pass (`godot --headless --path queens --script tests/run_tests.gd`).
  Godot 4.7.1 lives at `G:\tools\godot`, not on PATH.
- **No metrics/observability** beyond slog. Probably fine; decide consciously.
- **No load estimate.** Sizing SQLite, the rate limits and the backup cadence is
  currently guesswork.
- **Huma v2 / chi / Go version pinning** not fixed.
- **`GET /v1/bootstrap`** appears in Pass A's endpoint map as the mapping for
  `init()` but is not in Pass B's. Fold it in or drop it.
- The **grace window for `no_session`** at rollout (pre-server `pending_results`)
  needs a concrete duration and an end date.

---

## 10. Build order

| # | Milestone | Verifiable by |
| --- | --- | --- |
| M0 | Skeleton: module, config, slog, chi + Huma, `/healthz`, `/v1/time`, `queensd openapi -o`, `TestOpenAPISpecUpToDate` | `/docs` renders; `openapi.yaml` committed |
| M1 | Store: modernc driver, DSN pragmas, dual pools, migration runner, merged `0001_init.sql` (OPEN-1), `levelset.Sync` with the size/difficulty guard, `testutil` | `queensd migrate`; level repo tests |
| **M2** | **`domain/scoring.go` + the shared fixture + the sweep digest, both runners green** | `go test ./internal/domain` **and** the Godot suite pass on the same file |
| M3 | `domain/league.go` pure functions + parity | league fixture green |
| M4 | Identity: players, auth tokens, `POST /players`, `GET|PATCH /me`, the auth resolver, the Problem type + code map | humatest: register → token → `/me` |
| M5 | Play loop: `POST /games` (session, cooldown, group join) and `POST /results` (recompute, clamp, idempotency incl. the forfeit conflict, level bests, stats, tier points, mid-round promotion) | the service test list below |
| M6 | Boards: `/levels/meta` with ETag/304, `/levels/{id}/leaderboard` all three scopes with real `my_rank` and `total_players` | seeded multi-player tests; `If-None-Match` → 304 |
| M7 | League: standings, round closer (ticker + lazy), summaries, ack | clock-driven tests across a Bronze *and* a Silver boundary; re-run is idempotent |
| M8 | Friends (OPEN-3), the `friends` leaderboard scope | all friend error codes |
| M9 | Hardening: rate limits, flags, shadow exclusion + quarantine groups, session sweeper, backups, graceful shutdown, `server.yml` CI | `kill -TERM` drains; a backup appears |
| M10 | Client: `http_backend.gd` + everything in §8, behind `server_url` | play a level against localhost, see the standing move; kill the server, confirm fallback |

**M2 and M3 come before everything except the skeleton and the store.** They are
the foundation, and they are the part where being wrong is silent — a player's
score is simply a different number and nothing errors.

Service tests that carry the weight (M5–M7): duplicate `result_id` returns a
byte-identical response · a forfeit and a completed result sharing an id resolve
to completed · submit without a session is accepted but unverified and stays off
the leaderboard · a consumed token → `ERR_SESSION_USED` · sub-floor elapsed clamps
up and the score drops · above-wall elapsed clamps down · cooldown blocks a second
start and 7 days unblocks it · tier points crossing `promo_score` promotes,
writes a `reason:"score"` summary and does *not* auto-join · the round closer over
a Bronze boundary with three players produces the right ranks, zones, tier moves
and one summary each, and is idempotent when re-run.

---

## 11. Verification

```bash
# Godot suite (Godot 4.7.1 is at G:\tools\godot, not on PATH)
G:/tools/godot/Godot_v4.7.1-stable_win64_console.exe --headless --path queens --script tests/run_tests.gd
```
```bash
# Go suite, from server/
go vet ./... && go test -race ./... && go build ./...
```
```bash
# Cross-language parity: regenerate the fixtures and assert nothing moved
G:/tools/godot/Godot_v4.7.1-stable_win64_console.exe --headless --path queens --script tools/gen_fixtures.gd
git diff --exit-code shared/fixtures/
```
End-to-end: run `queensd` on localhost, set `GameConfig.server_url`, play a level
in the editor, confirm the win overlay shows the *server's* breakdown and the
league standing moves; then kill the server and confirm play continues offline and
`pending_results` drains on the next start.

Known environment quirks (from prior sessions in this repo): scripted Godot runs
hang at exit unless an adb server is already running — start adb first. Python
`open()` defaults to cp1252 here and the tree is CRLF — pass `encoding='utf-8'`
and normalise before matching.
