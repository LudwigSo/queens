# Queens backend — implementation plan

Source: `docs/backend-plan-handover.md` (design ~75 %). This plan closes every OPEN item there, verifies the handover against the code, and lays out the work milestone by milestone. Everything the handover marks SETTLED is taken as decided and only referenced here.

## Context

`queens/` is a Godot 4.7 Android puzzle game that is fully offline. Scores, the league and friends live in `user://save.json` and `user://backend_local.json`, so they are per-device, unverified and unshareable, and identity dies with a reinstall. The goal is a Go + SQLite service (`server/` in this repo, single static binary) that makes scores authoritative, shares per-level leaderboards and the league across players, and gives identity a server-side home.

The client already contains the contract: `queens/scripts/backend/backend.gd` (14 methods, `{ok, data, error}` envelope, record shapes in the header) and `queens/scripts/backend/local_backend.gd` (the behavioural reference, minus its bots). The server is a port of that contract; the client gets one new `HttpBackend` plus a small set of touch-ups.

## Verification of the handover against the code (done)

All claims checked. Corrections and additions that affect the design:

| Handover says | Code actually does | Consequence |
| --- | --- | --- |
| `FriendEntry {player_id, nickname, tier, round_score, friend_since}` | `_friend_view` also returns `tier_name` and `friend_code` (`local_backend.gd:649`) | DTO carries `friend_code`; `tier_name` dropped (client derives) |
| `get_round_summary` → `{}` or summary | Returns `ok({})`, never `null`; `ack` never errors (`:536-546`) | HTTP 204 → `ok({})`; ack always 204 |
| Errors "carry codes" | `Backend.fail()` returns **localised text** and `main.gd:439,458` shows `res["error"]` verbatim | `HttpBackend._call()` maps wire code → `Loc.f()` before returning |
| Level file is an array | `{format:1, game:"queens", levels:[...]}` (100 entries, all 7 keys present) | levelset parser |
| `round_index` uses float floor | `int(floor(float(t - 345600) / round_seconds))` | Go: integer floor-div helper, negative-aware |
| `submit_result` idempotent | Replays the **stored** response byte-for-byte, stale rank included (`:226-228`) | store `response_json`, never recompute on replay |
| `views.gd` reads `tier_name` | `views.gd:21` derives from `tier` id via `Loc`; only `league_screen.gd` reads the prose | four-line client change confirmed |
| Un-awaited coroutines | `app.gd:41,119,120,144`, `main.gd:250,488` | listed in client changes |
| `main.gd` checks `ok` | `:225`, `:238`, `:424-428` index `["data"]` unguarded | HttpBackend returns safe empty shapes on failure |
| Go toolchain absent | confirmed; Godot 4.7.1 **mono** console binary at `G:\tools\godot\4.7.1-mono\...\Godot_v4.7.1-stable_mono_win64_console.exe` | M0 prerequisite |
| `tools/gen_boards.py` in `queens/tools` | Lives at repo root `tools/`; `queens/tools/` is asset renderers | path in docs |
| `client_version` | hardcoded `"1.0"` in `config.gd:73`; CI patches only `export_presets.cfg` | CI also patches `client_version` and `server_url` |

## Decisions (closes handover §9)

| Item | Decision |
| --- | --- |
| OPEN-1 schema | Merged `0001_init.sql` below (Pass A DDL + Pass B tables) |
| OPEN-2.1 identity | Client UUID is the account key; `409 ERR_ID_TAKEN` → client regenerates once |
| OPEN-2.2 league config | `shared/league.json`, `go:embed`-ed and loaded by the client from `res://`; served in `/v1/bootstrap` with `config_hash` |
| OPEN-2.3 errors | RFC 9457 `application/problem+json` + `code` + `params`, via `huma.NewError` |
| OPEN-2.4 paths | `/v1/...` |
| OPEN-3 friends | Server-generated `QN-` + 6 × `[A-Z2-7]`, `UNIQUE`, retry on collision; **directed** follows; cap 50 (`ERR_FRIEND_LIMIT`); rate limit is the enumeration defence (32⁶ ≈ 1.07 B codes); `friend_code_for()` stays in `local_backend.gd` as the offline placeholder |
| OPEN-4 hosting | **Decide later** (user). Design assumes a TLS-terminating reverse proxy (`QUEENS_TRUST_PROXY`); no deployment files in this plan |
| OPEN-5 spec | DTOs below; `openapi.yaml` generated + drift-tested; contract snapshot tests |
| OPEN-6 solution | Store `solution_json`, never expose; comment says why |
| OPEN-7 local data | **Start fresh entirely** (user). No import, no cooldown seeding. Client keeps honouring its own pre-upgrade cooldowns via `max(server, local)` for display only |
| OPEN-8 deletion | `DELETE /v1/me` cascading; retention: `player_flags` 180 d, `results` unbounded (they are the leaderboard), rate counters 7 d; one settings-screen line |
| OPEN-9 nicknames | NFKC + casefold normalisation, embedded denylist (`server/internal/service/nickname_denylist.txt`), `ERR_NICKNAME_INVALID`; renames rate-limited (PATCH /me 5/day); `queensd admin rename` |
| OPEN-10 empty league | Fill-first packing is the mitigation; no bots; `league_members.synthetic` column reserved (always 0) so bots could be re-added later without the maths seeing them |
| §6 flawless fix + 4th sort key | **Accepted** (user): `level_flawless_bests` holds each player's fastest clean run; `player_id ASC` tiebreak mirrored into `league_rules.gd` |
| `no_session` grace | Results without a session are accepted, `verified = 0`, off the boards, weight-8 flag **suppressed** until `QUEENS_NO_SESSION_GRACE_UNTIL` (unix, default launch + 30 d) |
| Observability | slog only + `/healthz` `/readyz`; no metrics in v1 (conscious) |
| Pinning | Go 1.24, Huma v2 latest minor at M0 (record in `go.mod`), chi v5, `modernc.org/sqlite` latest, `golang.org/x/time` |

### Residual design decisions (not in the handover; an implementer would otherwise invent them)

| # | Decision | Why |
| --- | --- | --- |
| D1 | `players.settled_round_end` is the per-player cursor "league outcomes applied for every round of my tier ending ≤ this". Invariant after catch-up: equals `round_start(tier, round_index(tier, now))`. | Makes the "never came back" collapse a pure computation from one column. |
| D2 | `league_members.left_at` marks a member promoted by score mid-round. They stay ranked; the closer writes no summary and moves no tier for them. | The stub forgets the abandoned round; the server cannot delete a row other ranks depend on. Only score-mode tiers have mid-round departures and they promote/relegate nobody at close, so no one else's outcome changes. |
| D3 | Above-wall elapsed **clamps down** with a weight-2 flag; the hard 422 is reserved for `client_elapsed > 24h` and `finished_at − started_at < elapsed − 2`. | Handover §7.3 and §7.4 disagree; the §10 test list says "clamps down". |
| D4 | Freeze `(below_players, members_in_tier)` on **both** the Diamond and Challenger round rows at claim; whichever claims second reuses the pair from the sibling round with the same `ends_at`. | `Openings()` is order-independent only if both callers see the same inputs. This is what makes "close order is irrelevant" true. |
| D5 | The inactive-relegation walk is bounded by the tier count (Challenger→Diamond→Platinum→Gold is 3 steps), not by 2. | Correction to §6. |
| D6 | Results without a session are accepted, count for stats/tier points/round score, but never enter `level_bests`/`level_flawless_bests` (`verified = 0`). | §10: "accepted but unverified and stays off the leaderboard". |
| D7 | `POST /players` with a Bearer token resolving to the same id → 200 + profile (idempotent, nickname update). Without a token and id exists → 409 `ERR_ID_TAKEN`. | Gives "200 known device" a meaning under client-UUID identity. |
| D8 | Shadow exclusion set at decayed `anomaly_score ≥ 15`; cleared when `< 5` at the moment of a `POST /games` join, or by admin CLI. | Hysteresis; a player finishes the quarantined round they are in. |
| D9 | `level_bests.result_id` / `level_flawless_bests.result_id` have **no** FK to `results`. | A future results-retention job must not delete leaderboard rows. |
| D10 | `perfect_streak` is a counter on `players`; each qualifying game appends a 0.5 flag while `0.5·N ≤ 6`. | Makes "0.5×N, cap 6" append-only. |
| D11 | A forfeit and any submit both ensure league membership, like the stub's `_join(index)`. | Stub parity. |
| D12 | Result round index is `max(round_index(tier, now), round_index(tier, finished_at))`, kept literally; with `finished_at := min(payload, now)` the second term never wins after catch-up. Comment it. | Removes a "why is this here". |
| D13 | Nickname pipeline: `TrimSpace` → NFKC → reject if any rune is control/format/private-use → rune count 2..16 (`ERR_NICKNAME_LENGTH`) → casefold + strip non-letters → substring match against the embedded denylist (`ERR_NICKNAME_INVALID`). Stored as the NFKC-trimmed form. | OPEN-9. |

## Storage — `server/internal/store/sqlite/migrations/0001_init.sql`

Rules: every table `STRICT`; unix seconds `INTEGER` written by Go; booleans `0/1` with `CHECK`; app-generated `TEXT` PKs; `INSERT … ON CONFLICT` only; explicit `ORDER BY`; every FK child column indexed (SQLite does not do it and cascades otherwise scan). Migration runner wraps the file in one transaction and inserts `(1,'0001_init',now)` into `schema_migrations` in the same transaction. `PRAGMA foreign_keys` is a DSN pragma, not in the file.

```sql
CREATE TABLE schema_migrations (
  version INTEGER NOT NULL PRIMARY KEY, name TEXT NOT NULL, applied_at INTEGER NOT NULL) STRICT;

-- identity ------------------------------------------------------------------
CREATE TABLE players (
  id                 TEXT    NOT NULL PRIMARY KEY,   -- client v4 UUID: a name, not an authenticator
  nickname           TEXT    NOT NULL,               -- NFKC-trimmed, 2..16 runes, denylist-checked in Go
  friend_code        TEXT    NOT NULL,               -- 'QN-' + 6 of [A-Z2-7], server-generated
  tier               TEXT    NOT NULL,
  tier_points        INTEGER NOT NULL DEFAULT 0,     -- reset on every tier change
  tier_since         INTEGER NOT NULL,
  settled_round_end  INTEGER NOT NULL,               -- D1
  games              INTEGER NOT NULL DEFAULT 0,
  flawless           INTEGER NOT NULL DEFAULT 0,
  best_score         INTEGER NOT NULL DEFAULT 0,
  rounds_played      INTEGER NOT NULL DEFAULT 0,
  perfect_streak     INTEGER NOT NULL DEFAULT 0,     -- D10
  anomaly_score      REAL    NOT NULL DEFAULT 0,     -- decayed lazily, 30-day half-life
  anomaly_updated_at INTEGER NOT NULL DEFAULT 0,
  shadow_excluded    INTEGER NOT NULL DEFAULT 0,
  banned_at          INTEGER,                        -- admin CLI only → 403 ERR_BANNED
  auth_provider      TEXT,                           -- §7.2 hook
  auth_external_id   TEXT,
  client_version     TEXT    NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL,
  CHECK (shadow_excluded IN (0, 1))) STRICT;
CREATE UNIQUE INDEX players_friend_code ON players (friend_code);            -- add_friend lookup + generation retry
CREATE UNIQUE INDEX players_external ON players (auth_provider, auth_external_id) WHERE auth_provider IS NOT NULL;
CREATE INDEX players_tier ON players (tier);                                 -- openings() population counts

CREATE TABLE auth_tokens (
  token_hash TEXT NOT NULL PRIMARY KEY,               -- hex sha256 of the opaque wire token
  player_id  TEXT NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL, revoked_at INTEGER) STRICT;
CREATE INDEX auth_tokens_player ON auth_tokens (player_id);

-- levels --------------------------------------------------------------------
CREATE TABLE levels (
  id TEXT NOT NULL PRIMARY KEY, size INTEGER NOT NULL, difficulty INTEGER NOT NULL,  -- size/difficulty change refuses boot
  stars INTEGER NOT NULL, seed INTEGER NOT NULL, regions_json TEXT NOT NULL,
  -- OPEN-6: stored, NEVER serialised by the API. Kept for move-log replay; already public in the APK. Do not "clean up".
  solution_json TEXT NOT NULL,
  content_hash TEXT NOT NULL, par_override REAL, in_current_set INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, CHECK (in_current_set IN (0, 1))) STRICT;
CREATE TABLE level_sets (hash TEXT NOT NULL PRIMARY KEY, level_count INTEGER NOT NULL, imported_at INTEGER NOT NULL) STRICT;
CREATE INDEX level_sets_latest ON level_sets (imported_at DESC);

CREATE TABLE player_levels (                        -- server-authoritative cooldown anchor
  player_id TEXT NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  level_id  TEXT NOT NULL REFERENCES levels (id),
  last_started_at INTEGER NOT NULL, plays INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (player_id, level_id)) STRICT;
CREATE INDEX player_levels_level ON player_levels (level_id);

-- sessions ------------------------------------------------------------------
CREATE TABLE game_sessions (
  id TEXT NOT NULL PRIMARY KEY,                       -- base64url(16 random bytes); HMAC lives only in the wire token
  player_id TEXT NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  level_id  TEXT NOT NULL REFERENCES levels (id),
  issued_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,   -- +6h: freshness only, not acceptance
  consumed_at INTEGER, result_id TEXT,                        -- single-use: UPDATE … WHERE consumed_at IS NULL
  tier_at_issue TEXT NOT NULL, round_index_at_issue INTEGER NOT NULL, group_id TEXT NOT NULL,
  integrity_verdict TEXT, client_version TEXT NOT NULL DEFAULT '') STRICT;
CREATE INDEX game_sessions_player ON game_sessions (player_id, issued_at DESC);
CREATE INDEX game_sessions_unconsumed ON game_sessions (issued_at) WHERE consumed_at IS NULL;   -- sweeper
CREATE INDEX game_sessions_consumed ON game_sessions (consumed_at) WHERE consumed_at IS NOT NULL;
CREATE INDEX game_sessions_level ON game_sessions (level_id);

-- results -------------------------------------------------------------------
CREATE TABLE results (
  result_id TEXT NOT NULL PRIMARY KEY,                -- client v4 UUID = idempotency key
  player_id TEXT NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  level_id  TEXT NOT NULL REFERENCES levels (id),
  session_id TEXT REFERENCES game_sessions (id) ON DELETE SET NULL,
  tier TEXT NOT NULL, round_index INTEGER NOT NULL,   -- (tier, round_index) credited to
  completed INTEGER NOT NULL, verified INTEGER NOT NULL,        -- D6
  schema INTEGER NOT NULL,
  size INTEGER NOT NULL, difficulty INTEGER NOT NULL, stars INTEGER NOT NULL,   -- server values, not payload
  par_seconds REAL NOT NULL,                          -- server par at submit; recomputes read THIS (§5)
  base INTEGER NOT NULL,
  started_at INTEGER NOT NULL, finished_at INTEGER NOT NULL, received_at INTEGER NOT NULL,
  elapsed_seconds REAL NOT NULL, client_elapsed_seconds REAL NOT NULL,
  queens_placed INTEGER NOT NULL, wrong_placements INTEGER NOT NULL, queens_removed INTEGER NOT NULL,
  clear_count INTEGER NOT NULL, hint_count INTEGER NOT NULL, taps INTEGER NOT NULL,
  score INTEGER NOT NULL, client_score INTEGER NOT NULL, flawless INTEGER NOT NULL,
  client_version TEXT NOT NULL DEFAULT '',
  payload_hash TEXT NOT NULL,                         -- sha256 of canonical payload: cheap "different body" test
  response_json TEXT NOT NULL,                        -- exact 201 body; replays return it verbatim
  move_log BLOB,                                      -- §7.6 hook
  CHECK (completed IN (0, 1)), CHECK (verified IN (0, 1)), CHECK (flawless IN (0, 1))) STRICT;
CREATE INDEX results_round_player ON results (player_id, tier, round_index, score DESC) WHERE completed = 1;  -- best-N + best_game
CREATE INDEX results_player_time ON results (player_id, finished_at DESC);
CREATE INDEX results_session ON results (session_id);
CREATE INDEX results_level ON results (level_id);                            -- admin rescore

-- leaderboards --------------------------------------------------------------
CREATE TABLE level_bests (                          -- score-best run per (player, level)
  player_id TEXT NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  level_id TEXT NOT NULL REFERENCES levels (id),
  result_id TEXT NOT NULL,                            -- D9: no FK on purpose
  score INTEGER NOT NULL, wrong_placements INTEGER NOT NULL, time_seconds REAL NOT NULL, achieved_at INTEGER NOT NULL,
  PRIMARY KEY (player_id, level_id)) STRICT;
-- exactly the global/friends order: board = index range scan, rank OR-chain answered from the same index
CREATE INDEX level_bests_rank ON level_bests (level_id, score DESC, wrong_placements ASC, time_seconds ASC, achieved_at ASC, player_id ASC);

CREATE TABLE level_flawless_bests (                 -- fastest run with wrong == 0 per (player, level) (§6 fix)
  player_id TEXT NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  level_id TEXT NOT NULL REFERENCES levels (id),
  result_id TEXT NOT NULL, score INTEGER NOT NULL, time_seconds REAL NOT NULL, achieved_at INTEGER NOT NULL,
  PRIMARY KEY (player_id, level_id)) STRICT;
CREATE INDEX level_flawless_bests_rank ON level_flawless_bests (level_id, time_seconds ASC, achieved_at ASC, player_id ASC);

-- league --------------------------------------------------------------------
CREATE TABLE league_rounds (
  tier TEXT NOT NULL, round_index INTEGER NOT NULL, starts_at INTEGER NOT NULL, ends_at INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT 'open',                 -- open → closing → closed; claim = UPDATE … WHERE state='open'
  group_seq INTEGER NOT NULL DEFAULT 0,
  up_count INTEGER, below_players INTEGER, members_in_tier INTEGER,   -- frozen at claim (§6, D4); up_count NULL = -1
  closing_started_at INTEGER, closed_at INTEGER, created_at INTEGER NOT NULL,
  PRIMARY KEY (tier, round_index), CHECK (state IN ('open', 'closing', 'closed'))) STRICT;
CREATE INDEX league_rounds_due ON league_rounds (state, ends_at);           -- ticker + lazy catch-up

CREATE TABLE league_groups (
  id TEXT NOT NULL PRIMARY KEY,                       -- lg_<tier>_<round>_<seq %03d>; quarantine groups look identical
  tier TEXT NOT NULL, round_index INTEGER NOT NULL,
  quarantine INTEGER NOT NULL DEFAULT 0,
  capacity INTEGER,                                   -- NULL for global tiers: one unbounded group
  member_count INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'open', closed_at INTEGER, created_at INTEGER NOT NULL,
  FOREIGN KEY (tier, round_index) REFERENCES league_rounds (tier, round_index) ON DELETE CASCADE,
  CHECK (quarantine IN (0, 1)), CHECK (state IN ('open', 'closed'))) STRICT;
CREATE INDEX league_groups_open ON league_groups (tier, round_index, quarantine, state, member_count DESC, id ASC);  -- fill-first

CREATE TABLE league_members (
  player_id TEXT NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  tier TEXT NOT NULL, round_index INTEGER NOT NULL,
  group_id TEXT NOT NULL REFERENCES league_groups (id) ON DELETE CASCADE,
  joined_at INTEGER NOT NULL,
  round_score INTEGER NOT NULL DEFAULT 0,             -- denormalised best-N, rewritten on every completed submit
  games INTEGER NOT NULL DEFAULT 0, last_submit_at INTEGER NOT NULL DEFAULT 0,
  synthetic INTEGER NOT NULL DEFAULT 0,               -- OPEN-10 reservation, always 0 in v1
  left_at INTEGER,                                    -- D2
  final_rank INTEGER, final_zone TEXT, outcome TEXT,
  PRIMARY KEY (player_id, tier, round_index),         -- the structural one-group-per-round guarantee
  CHECK (synthetic IN (0, 1))) STRICT;
-- exactly sort_members() + player_id: standing, ROW_NUMBER windows and the rank OR-chain run on this index
CREATE INDEX league_members_standing ON league_members (group_id, round_score DESC, games ASC, last_submit_at ASC, player_id ASC);

CREATE TABLE round_summaries (
  id TEXT NOT NULL PRIMARY KEY,
  player_id TEXT NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  tier_before TEXT NOT NULL, round_index INTEGER NOT NULL,   -- index in tier_before's calendar
  tier_after TEXT NOT NULL, outcome TEXT NOT NULL, reason TEXT NOT NULL,
  rank INTEGER NOT NULL DEFAULT 0, group_size INTEGER NOT NULL DEFAULT 0, round_score INTEGER NOT NULL DEFAULT 0,
  tier_points INTEGER NOT NULL DEFAULT 0,             -- value BEFORE any reset, like the stub
  best_level_id TEXT, best_score INTEGER,             -- NULL → best_game {}
  seen INTEGER NOT NULL DEFAULT 0, seen_at INTEGER, created_at INTEGER NOT NULL,
  CHECK (seen IN (0, 1)), CHECK (reason IN ('round', 'score'))) STRICT;
CREATE UNIQUE INDEX round_summaries_once ON round_summaries (player_id, tier_before, round_index, reason);  -- idempotent closer
CREATE INDEX round_summaries_pending ON round_summaries (player_id, created_at DESC) WHERE seen = 0;

-- friends (directed: player_id follows friend_id) -----------------------------
CREATE TABLE friends (
  player_id TEXT NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  friend_id TEXT NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL, PRIMARY KEY (player_id, friend_id), CHECK (player_id <> friend_id)) STRICT;
CREATE INDEX friends_reverse ON friends (friend_id, player_id);

-- anti-cheat ------------------------------------------------------------------
CREATE TABLE player_flags (                         -- append-only audit log
  id TEXT NOT NULL PRIMARY KEY,
  player_id TEXT NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  signal TEXT NOT NULL, weight REAL NOT NULL, result_id TEXT, session_id TEXT, detail_json TEXT,
  created_at INTEGER NOT NULL) STRICT;
CREATE INDEX player_flags_player ON player_flags (player_id, created_at DESC);
CREATE INDEX player_flags_created ON player_flags (created_at);

-- rate limits (daily DB counters; hourly buckets are in memory) ---------------
CREATE TABLE rate_counters (
  key TEXT NOT NULL, day INTEGER NOT NULL, count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (key, day)) STRICT;
CREATE INDEX rate_counters_day ON rate_counters (day);
```

## Store and repositories — `server/internal/store/store.go`

```go
type Repos struct { Players PlayerRepo; Levels LevelRepo; Sessions SessionRepo; Results ResultRepo
                    Bests LevelBestRepo; League LeagueRepo; Friends FriendRepo; Flags FlagRepo; Rates RateRepo }
type Store interface {
    Repos() Repos
    InTx(ctx, fn func(context.Context, Repos) error) error   // one BEGIN IMMEDIATE tx; every repo bound to it
    Ping(ctx) error; Checkpoint(ctx) error; BackupTo(ctx, path string) error; Close() error
}
var ErrNotFound, ErrConflict  // sentinels mapped in api/errors.go
```

sqlite impl: `type dbtx interface{ ExecContext; QueryContext; QueryRowContext }`; each repo `{r, w dbtx}`; `Repos()` binds `r=rdb, w=wdb`; `InTx` binds both to the `*sql.Tx`. Two special error wrappers: `ErrRetry` (a conditional `SetTier` lost a race → re-run the closure once) and `ErrCommitAndFail{Err}` (commit the tx, then return `Err` — used only where a flag must persist while the request is rejected: `ERR_LEVEL_LOCKED` with a flag, `impossible_round_score`). `InTx` retries ≤ 3× with 20–80 ms jitter on `SQLITE_BUSY/LOCKED` only (admin CLI writer, Postgres later); in-process writers never see BUSY under `MaxOpenConns(1)`.

Repository method sets (signatures in `store.go`; all take `ctx`):

- **PlayerRepo**: `Get`, `GetByFriendCode`, `FriendCodeExists`, `Create` (ErrConflict), `UpdateNickname`, `AddGameStats(id, flawless, score, now)` (pure SQL bumps), `SetPerfectStreak`, `IncRoundsPlayed`, `SetTier(id, from, to, tierSince, settledRoundEnd) (bool, error)` (conditional on `tier = from`, resets points when `from != to`), `SetSettledRoundEnd`, `CountByTier`, `TouchLastSeen`, `Delete`, `InsertToken`, `GetToken` (joins banned_at), `TouchToken`, `RevokeTokens`.
- **LevelRepo**: `Get`, `All`, `Upsert`, `MarkNotInSet`, `InsertLevelSet`, `CurrentLevelSet`, `GetPlayerLevel`, `ListPlayerLevels`, `RecordStart` (upsert `last_started_at`, `plays+1`), `EligibleLevelIDs(player, roundStart, roundEnd, cooldown)`.
- **SessionRepo**: `Insert`, `Get`, `Consume(id, resultID, now) (bool, error)`, `DeleteUnconsumedBefore`, `DeleteConsumedBefore`.
- **ResultRepo**: `Get`, `Insert`, `ReplaceForfeit(r) (bool, error)`, `RoundScores(player, tier, idx, bestN)`, `CountRoundGames`, `BestGame`.
- **LevelBestRepo**: `UpsertBest`, `UpsertFlawless` (conditional `DO UPDATE … WHERE` in board order), `MyBest`, `MyFlawless`, `Board(q)`, `Rank(q)`, `Total(q)`.
- **LeagueRepo**: rounds `EnsureRound`, `GetRound`, `DueRounds(now, tier)`, `ClaimRound(tier, idx, now, frozen) (bool, error)`, `FinishRound`, `NextGroupSeq`, `RoundEndingAt(tier, endsAt)`; groups `FindOpenGroup(tier, idx, quarantine)`, `CreateGroup`, `IncGroupCount (bool)`, `DecGroupCountsForPlayer`, `OpenGroups`, `ClaimGroupClose (bool)`, `GetGroup`; members `GetMember`, `InsertMember`, `UpdateMemberScore`, `MarkMemberLeft`, `GroupMembersSorted`, `GroupLeaderScore`, `GroupPromoteCount(group, up)`, `MemberRank` (OR-chain), `StandingWindow(group, me, top, lo, hi)`, `SetMemberOutcome`; summaries `InsertSummary (inserted bool)`, `LatestUnseenSummary`, `AckSummary`.
- **FriendRepo**: `List`, `IDs`, `Count`, `Add (bool)`, `Remove (bool)`, `IsFriend`.
- **FlagRepo**: `Insert`, `ListByPlayer`, `ReadAnomaly`, `WriteAnomaly`, `DeleteBefore`.
- **RateRepo**: `Bump(key, day) (int, error)` (upsert `count+1 RETURNING`), `Peek`, `DeleteBefore`.

## Service algorithms — `server/internal/service/`

`now` injected via `domain.Clock`; `cfg` = embedded `shared/league.json`; `cd` = `QUEENS_COOLDOWN_SECONDS` (604800). "Flag(w, signal)" = `Flags.Insert` + anomaly update (§ Anomaly) in the same tx.

### identity.go — `POST /v1/players`

Request `{player_id, nickname, client_version}`; optional Bearer. **No local level data is accepted** (OPEN-7: start fresh).

1. Middleware: IP 5/h in memory; `Rates.Bump("ip:<ip>:register", day) > 20` → 429.
2. Validate `player_id` against the v4 UUID regex (lower-cased) → 400 `ERR_BAD_REQUEST`; nickname pipeline D13.
3. Bearer resolves to `player_id` (D7) → `InTx`: update nickname if changed → 200 profile, no new token.
4. `InTx`: `Players.Get(id)` found → 409 `ERR_ID_TAKEN`. Friend code loop ≤ 5 draws from `crypto/rand` over the alphabet until `FriendCodeExists` is false (UNIQUE index is the backstop; 5 collisions → 500). Insert player with `tier = tiers[0]`, `settled_round_end = RoundStart(bronze, RoundIndex(bronze, now))`. Mint token: 32 random bytes → `base64.RawURLEncoding` on the wire; `hex(sha256(wire))` stored.
5. 201 `{profile, token}`.

`PATCH /v1/me` runs D13, per-player 5/day via `Rates`, `UpdateNickname`. `GET /v1/me` reads. `DELETE /v1/me`: `InTx` → `DecGroupCountsForPlayer` (open groups only) → `Players.Delete` (cascades everything) → 204.

### Auth resolver (Huma input resolver on every authenticated request)

`hash = hex(sha256(bearer))`; `GetToken` on the read pool → missing/revoked → 401 `ERR_UNAUTHORIZED`; `banned_at` → 403 `ERR_BANNED`. If `now − last_seen_at > 3600`: best-effort `TouchToken` + `TouchLastSeen` on the write pool with a 2 s context.

### league.go — lazy catch-up `catchUp(repos, playerID)` (first step inside the tx of `POST /games`, `POST /results`; own tx before `GET /league/standing`, `/league/summary`, `/bootstrap`)

1. `p := Get(id)`. For each `DueRounds(now, p.Tier)` run the closer (below). Re-read `p` (it may have moved me).
2. Collapse absence (D1): `idxNow := RoundIndex(tier, now)`; `missed := idxNow − RoundIndex(tier, p.SettledRoundEnd)`; `missed ≤ 0` → done. Invariant: none of the missed rounds has a membership row for me (a membership needs `POST /games`, which ran this step first; an ended membership was settled in step 1).
   - `outcome := InactiveOutcome(tier)`; frozen → `tierAfter = tier`. Relegated → walk `tier = RelegateTier(tier)` while `missed > 0 && InactiveOutcome == relegated && !IsFloor` (D5).
   - One summary `{tier_before, round_index: RoundIndex(tierBefore, now) − 1, tier_after, outcome, reason 'round', rank 0, group_size 0, round_score 0, tier_points: p.TierPoints}` via `InsertSummary` (ON CONFLICT DO NOTHING).
   - `SetTier(id, tierBefore, tierAfter, now, RoundStart(tierAfter, RoundIndex(tierAfter, now)))` — also when unchanged (advances the cursor). `false` → `ErrRetry`.
   After the ticker has run this costs one indexed SELECT returning nothing plus one point read.

### play.go — `POST /v1/games`

1. Buckets: player 30/h, IP 200/h (memory).
2. `InTx`: `catchUp`; `Rates.Bump("p:<id>:games") > 200` → 429; `lv := Levels.Get` → 404 `ERR_LEVEL_UNKNOWN`.
3. Cooldown: `pl := GetPlayerLevel`; `remaining := clamp(cd − (now − pl.LastStartedAt), 0, cd)`; `> 0` → if `remaining > 60` Flag(3, `cooldown_violation_attempt`) via `ErrCommitAndFail` → 409 `ERR_LEVEL_LOCKED` params `[remaining]`.
4. `RecordStart`; `EnsureRound(tier, idx)`.
5. `joinRound` (shared with submit): existing member → done. Else: if `p.ShadowExcluded && decayedAnomaly < 5` → clear (D8); `q := p.ShadowExcluded`; `FindOpenGroup(tier, idx, q)`:
   ```sql
   SELECT id, capacity, member_count FROM league_groups
    WHERE tier=? AND round_index=? AND quarantine=? AND state='open' AND (capacity IS NULL OR member_count < capacity)
    ORDER BY member_count DESC, id ASC LIMIT 1
   ```
   found → `IncGroupCount` (false → fall through to create, once). Not found → `seq := NextGroupSeq`; `capacity := NULL if IsGlobal(tier) else cfg.GroupSize`; id `lg_<tier>_<idx>_<seq %03d>`; `CreateGroup(member_count 1)`. Then `InsertMember`, `IncRoundsPlayed`.
6. Session: `sid := base64url(16 random)`; insert with `expires_at = now + 21600`, `tier_at_issue`, `round_index_at_issue`, `group_id`. Wire token `sid + "." + base64url(HMAC-SHA256(pepper, sid)[:16])`.
7. 201 `{round_index, group_id, joined: true, server_time, session: {token, issued_at, expires_at, level: {size, difficulty, stars, par_seconds}}}` with `par_seconds = par_override ?? Par(difficulty, size)`.

### play.go — `POST /v1/results`

Pre-DB: decode; `result_id` v4 UUID; counters ≥ 0; else 400. Token present → split on `.`, `subtle.ConstantTimeCompare` on the HMAC → fail 401 `ERR_SESSION_INVALID` with no DB touched. `payloadHash := sha256(canonical DTO JSON)`.

Idempotency pre-read (read pool, before any bucket): `stored := Results.Get(result_id)`. Found: owner ≠ me → 403 + Flag(8). If not (stored is forfeit AND incoming completed) → return `stored.ResponseJSON` verbatim, **200**, uncharged; `payload_hash` differs → Flag(1, `replay_body_mismatch`) in a side tx. Else `replaceForfeit := true`, continue. Then buckets: player 40/h burst 10/min, IP 300/h.

`InTx`:
1. `catchUp`; `Rates.Bump("p:<me>:results") > 250` → 429.
2. Session: `Sessions.Get(sid)` missing → 401; owner ≠ me → 403 `ERR_SESSION_MISMATCH` + Flag(8); `now − issued_at > 30d` → 410 `ERR_SESSION_EXPIRED`; `Consume(sid, result_id, now)` false → `s.ResultID == result_id` continue (forfeit→completed) else 409 `ERR_SESSION_USED` + Flag(2). `verified := 1`; `lv` from **session**; level_id mismatch → Flag(2), use the session's; `> 6h` → Flag(1, `session_stale`). No token: `lv := Levels.Get(payload.level_id)` → 404; `verified := 0`; Flag(8, `no_session`) unless `payload.finished_at < QUEENS_NO_SESSION_GRACE_UNTIL`; cooldown side-check → Flag(3).
3. Overrides: `size, difficulty, stars` from `lv`; `par := par_override ?? Par()`; any payload mismatch → Flag(1, `level_meta_mismatch`), accepted. `finished := min(payload.finished_at, now)`; `week_index` ignored; payload `player_id ≠ me` → 403 + Flag(8).
4. Clamp: `floor := 1.5 + 0.45·size + 0.010·size²`; `wall := now − issued_at` (session) else `max(finished − started_at, 0)`; `upper := min(wall + 2, 86400)`; `elapsed := clamp(client, floor, upper)`; below → Flag(5, `elapsed_below_floor`); above → Flag(2, `elapsed_above_wall`) (D3).
5. Hard 422 `ERR_RESULT_INVALID`, completed only: `queens_placed < size` · `taps < queens_placed` · `wrong > queens_placed` · `hints > size` · `client_elapsed > 86400` · `finished − started_at < elapsed − 2`. Forfeit with `finished_at < started_at` → Flag(4).
6. `bd := domain.Breakdown(size, difficulty, par, elapsed, wrong, hints, completed)` (§5 port, literal associativity). `|client_score − bd.score| > 1` on completed → Flag(3, `score_mismatch`).
7. `idx := max(RoundIndex(tier, now), RoundIndex(tier, finished))` (D12); `EnsureRound`; `joinRound` (D11).
8. Ceiling, completed only: `candidate := RoundScore(RoundScores(me, tier, idx, bestN) + bd.score)`; eligible levels:
   ```sql
   SELECT l.id FROM levels l LEFT JOIN player_levels pl ON pl.player_id=? AND pl.level_id=l.id
    WHERE pl.level_id IS NULL OR pl.last_started_at + ? < ? /*round_end*/ OR pl.last_started_at >= ? /*round_start*/
   ```
   `ceiling := 2 · Σ top-bestN Base(l)` (in-memory level map); `candidate > ceiling` → Flag(20, `impossible_round_score`) via `ErrCommitAndFail` → 422.
9. `Results.Insert(r)` (or `ReplaceForfeit`; false → re-read, return stored 200) with `response_json = ''`.
10. Completed **and** `verified == 1` (D6): conditional upserts
    ```sql
    INSERT INTO level_bests (...) VALUES (...) ON CONFLICT (player_id, level_id) DO UPDATE SET ... WHERE
      excluded.score > level_bests.score
      OR (excluded.score = level_bests.score AND excluded.wrong_placements < level_bests.wrong_placements)
      OR (... = ... AND ... = ... AND excluded.time_seconds < level_bests.time_seconds)
      OR (... AND excluded.time_seconds = level_bests.time_seconds AND excluded.achieved_at < level_bests.achieved_at)
    ```
    and if `wrong == 0` (scope filter, not `bd.flawless`) the same for `level_flawless_bests` on `time_seconds, achieved_at`.
11. Completed only: `AddGameStats`; `UpdateMemberScore(RoundScore(best-N), CountRoundGames, finished)`; signals `no_exploration` (4), `taps == queens_placed` (2), perfect streak (D10).
12. Snapshot for the response inside the tx: fresh `p2`, `m`, `g`, `rank := MemberRank` (OR-chain), `zone` from `Counts(n, tierCfg, cfg, leader, up_count)`.
13. Mid-round promotion, completed only: `ReachesPromo(tierCfg, p2.TierPoints)` and `above := PromoteTier(tier) != tier` → `BestGame`; `InsertSummary{reason 'score', outcome promoted, rank, group_size, round_score, tier_points: p2.TierPoints (pre-reset), best}`; `SetTier(me, tier, above, now, RoundStart(above, RoundIndex(above, now)))` (resets points; false → `ErrRetry`); `MarkMemberLeft` (D2). **No membership in the new tier** (pinned by `run_tests.gd:943`).
14. Response `{breakdown, round_score, group_rank, group_size, zone, tier (old), round_index, tier_points (pre-reset), promo_score, promoted_to}`; marshal once; `UPDATE results SET response_json`; commit; 201.

### league.go — round closer `closeRound(tier, idx)` (ticker 60 s over `DueRounds(now, "")`; lazy over my tier)

Tiers processed in config order for log readability only; result is order-independent because `Openings()` is pure in the two frozen counts (D4). Put that comment on the loop.

- **Tx A claim + freeze**: `state == closed` → return; `closing` → skip to B. Frozen counts: Diamond (`up_mode openings`): sibling Challenger round with the same `ends_at` already claimed → reuse its `(below, in)`, else `(CountByTier(diamond), CountByTier(challenger))`; `up := Openings(challenger, below, in)`. Challenger (`is_capped`): mirror with `up := NULL`. Others: all NULL. `ClaimRound` false → someone else owns it.
- **Tx B per group** over `OpenGroups`: `ClaimGroupClose` false → skip. `members := GroupMembersSorted` (4-key order, includes `left_at` rows). `ev := Evaluate(members, tier, cfg, up_count)` (literal port). For each: `SetMemberOutcome(rank, zone, outcome)`; `left_at` set → continue (D2). `outcome := OutcomeForZone(zone)`; `after := Apply(tier, outcome)`; `InsertSummary{reason 'round', rank, group_size, round_score, tier_points, best_game}`; `inserted` → `SetTier(player, tier, after, r.EndsAt, RoundStart(after, RoundIndex(after, r.EndsAt)))` (false → warn, leave summary). Not inserted → already settled by a previous attempt. Summary + tier move are one atomic fact per member and idempotent across re-runs.
- **Tx C**: `OpenGroups` empty → `FinishRound`.

Players of the tier who never joined are handled by catch-up on return. Bronze (3 d) and Silver (7 d) rounds can be due at the same tick; they share nothing but the write lock, held per group.

### league.go — `GET /v1/league/standing`

1. `InTx(catchUp)`, then read pool. `tier, idx, above`. `up_count`: openings tiers → `Openings(above, CountByTier(tier), CountByTier(above))` from a 60 s TTL cache (frozen value if the round is already closing/closed); else −1.
2. `rules := {up_pct, down_pct, up_count, up_mode, promo_score, up_to: above-or-"", best_n, round_mode, round_days, global, floor}`; `round_ends_at`.
3. No member row → `{…, joined:false, group:{}, my_rank 0, my_round_score 0, my_games 0, zone ""}`.
4. Else `n := g.MemberCount`; `c := Counts(n, tierCfg, cfg, GroupLeaderScore, up_count)`; `promote_count` = count of `round_score > 0` among the top `c.Up` rows (subquery with LIMIT); `relegate_count := c.Down`.
5. `my_rank` OR-chain:
   ```sql
   SELECT COUNT(*)+1 FROM league_members WHERE group_id=? AND (round_score>? OR (round_score=? AND games<?)
     OR (round_score=? AND games=? AND last_submit_at<?) OR (round_score=? AND games=? AND last_submit_at=? AND player_id<?))
   ```
6. Window: `n ≤ 100` → all; else top 100 + `rn BETWEEN my_rank−5 AND my_rank+5` + me, via `ROW_NUMBER() OVER (ORDER BY <4 keys>)` joined to `players` for nickname and LEFT JOIN `friends` for `is_friend`. Zone per row from `(rn, c, round_score)`. A test asserts my `rn` equals the OR-chain rank.
7. `Cache-Control: private, max-age=15`.

### boards.go — `GET /v1/levels/{id}/leaderboard`

`limit` clamped 1..100 (default 10); unknown level → 404. Predicates: **global** `level_bests b JOIN players p … WHERE b.level_id=? AND (p.shadow_excluded=0 OR b.player_id=me)`; **friends** `… AND (b.player_id=me OR b.player_id IN (SELECT friend_id FROM friends WHERE player_id=me))` (excluded friends stay visible); **flawless** = `level_flawless_bests` with the global predicate. Entries via `ROW_NUMBER() OVER (ORDER BY <board order>) … LIMIT ?`; `my_rank` via the explicit OR-chain over the same predicate (5 terms global, 3 flawless); `total_players` = `COUNT(*)` over the predicate; `my_entry` from `MyBest/MyFlawless` with `rank = my_rank` or `{}`. Never row-value comparison. `Cache-Control: private, max-age=30`.

`GET /v1/levels/meta`: `{levels: {id: {par_seconds, locked_until}}, level_set_hash}`; strong `ETag` = current `level_sets.hash`; `If-None-Match` → 304. Note `locked_until` is per player, so the ETag is `hash + ":" + sha256(sorted player_levels rows)`; the level-set part still lets a client with no locks hit 304.

### friends.go

- `POST /v1/friends {code}` in `InTx`: normalise (`TrimSpace`, `ToUpper`), `^QN-[A-Z2-7]{6}$` → 400 `ERR_FRIEND_CODE_FORMAT`; own code → 400 `ERR_FRIEND_OWN_CODE`; `GetByFriendCode` missing → per-player unknown-code counter `> 50/h` → Flag(2, `friend_code_probing`) → 404 `ERR_FRIEND_CODE_UNKNOWN`; `Count ≥ 50` → 409 `ERR_FRIEND_LIMIT`; `Add` false → 409 `ERR_FRIEND_ALREADY`; 201 FriendEntry.
- `DELETE /v1/friends/{id}`: `Remove` false → 404 `ERR_FRIEND_UNKNOWN`; 204.
- `GET /v1/friends`: join `friends → players` ordered by `created_at, friend_id`; per row `round_score = COALESCE((SELECT round_score FROM league_members WHERE player_id=? AND tier=? AND round_index=?), 0)` with the friend's own tier's `RoundIndex(p.tier, now)` computed in Go (round lengths differ per tier). ≤ 51 point reads.

### Anomaly (`domain/anomaly.go`)

`decayed(now) = score · 0.5^((now − updated_at)/2592000)`. `Flag(w, signal)`: insert row; `s' := decayed + w`; `shadow' := shadow || s' ≥ 15`; write. Effects of shadow: hidden from others' global/flawless boards, routed to quarantine groups at join. Nothing else changes; no response field reveals it. Un-exclusion per D8.

### Background goroutines (cancelled by the shutdown context)

- Round ticker 60 s.
- Sweeper hourly: unconsumed sessions `< now − 30d`; consumed `< now − 90d` (results keep `verified`, FK sets `session_id` NULL); `rate_counters` days `< today − 1`; `player_flags` `< now − 180d`; revoked tokens `< now − 30d`. Batched `LIMIT 5000`.
- Backup daily at `QUEENS_BACKUP_HOUR_UTC` (default 03): `VACUUM INTO '<dir>/queens-YYYYMMDD.db.tmp'` on the write pool outside any tx, rename, keep newest 14.
- Diamond `up_count` cache: `sync.Map` with 60 s TTL, not a goroutine.

### Transaction map

| Operation | Tx | RowsAffected checks |
| --- | --- | --- |
| Register | one `InTx` | `Create` unique → 409 |
| Auth resolve | read pool; hourly touch on write pool | — |
| `POST /games` | one `InTx` (catch-up, lazy closer for my tier, join, session) | `IncGroupCount` (0 → create once); claim checks when the lazy closer runs; `SetTier` in collapse |
| `POST /results` | pre-read outside; one `InTx` | `Consume` (0 → same result_id continue, else 409); `SetTier` (0 → `ErrRetry`); `ReplaceForfeit` (0 → return stored) |
| Round claim / group close | Tx A / Tx B per group / Tx C | `ClaimRound == 1`; `ClaimGroupClose == 1`; `InsertSummary inserted` gates `SetTier` |
| Standing, boards, friends list, summary | catch-up in own `InTx`, then read pool | — |
| Ack | single conditional `UPDATE` on the latest unseen row `WHERE round_index = ?` | none; never errors |
| Add friend | one `InTx` (count + insert atomic) | `Add` 0 → 409 |
| Remove friend, rename | single statement | 0 → 404 for remove |
| `DELETE /me` | one `InTx` | — |
| Sweeper / backup | autocommit / `VACUUM INTO` | never inside `InTx` |

## HTTP API — `server/internal/api/`

### Conventions

| Topic | Rule |
| --- | --- |
| Paths | `/v1/...`; `/healthz`, `/readyz`, `/docs`, `/openapi.yaml` unversioned on chi directly |
| Media types | success `application/json`; errors `application/problem+json` |
| Auth | `Authorization: Bearer <43-char base64url>` via a Huma resolver `AuthInput` embedded in every authenticated input; bad/revoked → 401 `ERR_UNAUTHORIZED`; `banned_at` → 403 `ERR_BANNED` |
| Server time | middleware stamps `X-Server-Time: <unix>` on every response incl. Problems/204/304; documented once via `huma.Config.OnAddOperation`. Bodies that also carry `server_time` are additive |
| Client version | `X-Client-Version` on every request (logs only) |
| Nullable records | anything the stub returns as `{}` when absent (`group`, `my_entry`, `best_game`, `pending_summary`) is a Go pointer with `omitempty` → key **absent**, never `null` (`dict.get("group", {})` returns `null` for an explicit null and crashes downstream) |
| Numbers trap | after a save/load round-trip every int in `pending_results` is a GDScript float and `JSON.stringify` writes `6.0`, which Go rejects for an `int`. `HttpBackend.submit_result` normalises with `GameResult.from_dict(r).to_dict()` |
| Idempotency | `POST /results` by `result_id` (stored response replayed). `POST /games` re-issues a still-open session for `(player, level)` issued < 6 h ago with 200 (a timed-out-but-processed request must not lock the level for 7 days). Ack and friend delete idempotent by construction |
| Rate limits | handover §7.4 table; 429 carries `Retry-After` **and** `params: [seconds]`; replays uncharged |
| Body cap | 32 KiB → 413 `ERR_BAD_REQUEST` |
| Enums | `zone` promote/safe/relegate; `outcome` promoted/stayed/relegated/inactive_frozen/inactive_relegated; `reason` round/score; `up_mode` pct/openings/score; `round_mode` best_n/sum; `scope` global/friends/flawless. Tier ids validated against `league.json`, not an enum tag |

### Shared DTOs (`dto_shared.go`) — names byte-identical to `backend.gd`'s header minus `tier_name`, `rules_text`, `is_bot`

```go
type PlayerStats   struct { Games, Flawless, BestScore, RoundsPlayed int }                       // json: games, flawless, best_score, rounds_played
type PlayerProfile struct { PlayerID string `format:"uuid"`; Nickname string `minLength:"2" maxLength:"16"`
                            FriendCode string `pattern:"^QN-[A-Z2-7]{6}$"`; Tier string; TierPoints int `minimum:"0"`; CreatedAt int64; Stats PlayerStats }
type ScoreBreakdown struct { Score, Base int; ParSeconds, AccuracyFactor, SpeedFactor, HintFactor float64; Flawless bool }   // == Scoring.breakdown()
type LeaderboardEntry struct { Rank int `minimum:"1"`; PlayerID, Nickname string; Score int; TimeSeconds float64; WrongPlacements int; AchievedAt int64; IsMe, IsFriend bool }
type LeagueMember  struct { PlayerID, Nickname string; RoundScore, Games int; LastSubmitAt int64; IsMe, IsFriend bool; Rank int; Zone string `enum:"promote,safe,relegate"` }
type LeagueGroup   struct { GroupID, Tier string; RoundIndex int64; Size int `doc:"full count, not len(members)"`; PromoteCount, RelegateCount int
                            Members []LeagueMember `doc:"top 100 + ±5 around me + me; ranks absolute"` }
type LeagueRulesView struct { UpPct, DownPct int; UpCount int `doc:"-1 use up_pct, 0 nobody, n exactly n"`; UpMode string `enum:"pct,openings,score"`
                            PromoScore int; UpTo string `doc:"tier id above or \"\" (CHANGED: was a display name)"`; BestN int; RoundMode string `enum:"best_n,sum"`
                            RoundDays int; Global, Floor bool }
type LeagueStanding struct { Tier string; RoundIndex int64; RoundDays int; RoundEndsAt int64; Joined bool; Group *LeagueGroup `json:"group,omitempty"`
                            MyRank, MyRoundScore, MyGames int; Zone string `json:"zone,omitempty"`; MyTierPoints int; Rules LeagueRulesView; ConfigHash string `doc:"additive"` }
type BestGame      struct { LevelID string; Score int }
type RoundSummary  struct { RoundIndex int64; TierBefore, TierAfter, Outcome, Reason string; Rank, GroupSize, RoundScore, TierPoints int
                            BestGame *BestGame `json:"best_game,omitempty"`; Seen bool }
type FriendEntry   struct { PlayerID, Nickname, Tier string; RoundScore int; FriendSince int64; FriendCode string }
type LevelBrief    struct { Size int `minimum:"6" maximum:"10"`; Difficulty float64; Stars int; ParSeconds float64 }
type GameSessionView struct { Token string `maxLength:"64"`; IssuedAt, ExpiresAt int64 `doc:"issued_at+6h, freshness only; accepted 30 d"`; Level LevelBrief }
type LevelMeta     struct { ParSeconds float64; LockedUntil int64 `doc:"0 = never started; may be past"` }
type LeagueConfig  struct { Format, GroupSize, MinGroupSize int; RoundMode string; RoundBestN int; Tiers []TierConfig }   // mirrors league.json 1:1
type TierConfig    struct { ID, Name string; RoundDays int; UpMode string `omitempty`; PromoScore int `omitempty`; UpPct, DownPct int; Inactive string
                            Floor bool `omitempty`; MinPromoScore int `omitempty`; Global bool `omitempty`; MinSlots, MaxSlots, PlayersPerSlot *int `omitempty` }
type AuthInput     struct { Authorization string `header:"Authorization" required:"true"`; Player *domain.Player `json:"-"` }   // Resolve() fills Player
```

### Endpoints

Every authenticated endpoint can also return 401 `ERR_UNAUTHORIZED`, 403 `ERR_BANNED`, 429 `ERR_RATE_LIMITED`, 500/503 `ERR_SERVER`, 400/422 `ERR_BAD_REQUEST`.

| # | Method / path | `Backend` method | Auth · limits | Cache-Control | 2xx |
| --- | --- | --- | --- | --- | --- |
| 1 | `POST /v1/players` | `register_player` | no · IP 5/h, 20/d | `no-store` | 201 |
| 2 | `GET /v1/time` | `resync_time()` helper | no | `no-store` | 200 |
| 3 | `GET /v1/bootstrap` | `init` | yes | `private, no-store` | 200 |
| 4 | `GET /v1/me` | `get_profile` | yes | `private, no-store` | 200 |
| 5 | `PATCH /v1/me` | `set_nickname` | yes · 5/d | `no-store` | 200 |
| 6 | `DELETE /v1/me` | `delete_account` (new) | yes | `no-store` | 204 |
| 7 | `POST /v1/games` | `start_game` | yes · 30/h, 200/d | `no-store` | 201 new / 200 re-issue |
| 8 | `POST /v1/results` | `submit_result` | yes · 40/h, 250/d, burst 10/min | `no-store` | 201 / 200 replay |
| 9 | `GET /v1/levels/{id}/leaderboard` | `get_level_leaderboard` | yes | `private, max-age=30` | 200 |
| 10 | `GET /v1/levels/meta` | `get_level_meta` | yes | `private, no-cache` + `ETag`, `Vary: Authorization` | 200 / 304 |
| 11 | `GET /v1/league/standing` | `get_league_standing` | yes | `private, max-age=15` | 200 |
| 12 | `GET /v1/league/summary` | `get_round_summary` | yes | `private, no-store` | 200 / 204 |
| 13 | `POST /v1/league/summary/ack` | `ack_round_summary` | yes | `no-store` | 204 always |
| 14 | `GET /v1/friends` | `get_friends` | yes | `private, no-store` | 200 |
| 15 | `POST /v1/friends` | `add_friend` | yes · 20/h, 100/d | `no-store` | 201 |
| 16 | `DELETE /v1/friends/{player_id}` | `remove_friend` | yes | `no-store` | 204 |
| — | `/healthz`, `/readyz` | — | no | — | 200 / 503 Problem |

```go
// 1  RegisterInput.Body: PlayerID string `format:"uuid" pattern:"^[0-9a-f]{8}-…-4[0-9a-f]{3}-[89ab]…$"`; Nickname string `minLength:"2" maxLength:"16"`
//    ClientVersion string `maxLength:"32"`.   (No cooldowns/level data — OPEN-7 start fresh.)
//    RegisterOutput 201 Body: Profile PlayerProfile; Token string `doc:"shown once"`; IssuedAt, ServerTime int64
//    Errors: 409 ERR_ID_TAKEN · 422 ERR_NICKNAME_LENGTH · 422 ERR_NICKNAME_INVALID.  Deviation from "201 new / 200 known device":
//    there is no device id; an unauthenticated caller must never get a token for an existing UUID → 409 (D7 covers the token-bearing case).
// 2  TimeOutput.Body: ServerTime int64
// 3  BootstrapOutput.Body: ServerTime; Profile; LeagueConfig; ConfigHash; LevelSetHash; CooldownSeconds int; LevelMeta map[string]LevelMeta
//    (same map as /levels/meta so a cold start is one request); Standing LeagueStanding; PendingSummary *RoundSummary `omitempty`; FriendLimit int
// 4/5 MeOutput.Body PlayerProfile; PatchMeInput.Body: Nickname `minLength:"2" maxLength:"16"` → 422 ERR_NICKNAME_LENGTH / ERR_NICKNAME_INVALID
// 6  DeleteMeOutput Status 204; a second call is 401 (client treats as done)
// 7  StartGameInput.Body: LevelID `format:"uuid"`
//    StartGameOutput.Body: RoundIndex int64; GroupID string; Joined bool /*existing*/; Session GameSessionView; ServerTime, LockedUntil int64; Tier string /*additive*/
//    Errors: 404 ERR_LEVEL_UNKNOWN · 409 ERR_LEVEL_LOCKED params [remaining_seconds]
// 8  SubmitResultInput.Body == GameResult.to_dict() SCHEMA 2: Schema int `minimum:"1" maximum:"2"`; ResultID, PlayerID `format:"uuid"` (must equal bearer);
//    LevelID (overridden by session); Size `maximum:"10"`; Difficulty float64 `maximum:"100"`; Stars `maximum:"5"`; ParSeconds (IGNORED); StartedAt, FinishedAt;
//    ElapsedSeconds `maximum:"1000000"`; Completed bool; QueensPlaced, WrongPlacements, QueensRemoved, ClearCount `maximum:"100000"`; HintCount `maximum:"1000"`;
//    Taps `maximum:"1000000"`; WeekIndex (IGNORED); Score (kept as client_score); ClientVersion `maxLength:"32"`; SessionToken string `omitempty maxLength:"64"`
//    SubmitResultOutput.Body: Breakdown ScoreBreakdown; RoundScore, GroupRank, GroupSize int; Zone `omitempty`; Tier; RoundIndex int64; TierPoints, PromoScore int;
//    PromotedTo string /*existing*/; Verified bool; ServerTime int64 /*additive*/
// 9  LeaderboardInput: ID `path:"id"`; Scope `query enum:"global,friends,flawless" default:"global"`; Limit `query minimum:"1" maximum:"100" default:"10"`
//    Body: Entries []LeaderboardEntry; MyEntry *LeaderboardEntry `omitempty`; MyRank, TotalPlayers int; ParSeconds float64.  404 ERR_LEVEL_UNKNOWN
// 10 LevelMetaInput: IfNoneMatch `header`.  Output: ETag header; Body *{Levels map[string]LevelMeta; LevelSetHash; CooldownSeconds; ServerTime} (nil on 304)
//    Strong composite ETag "<level_set_hash[:16]>.<sha256(player_id ‖ sorted level_id:last_started_at)[:16]>" — changes only on a level-set change or this player's POST /games
// 11 Body LeagueStanding (catch-up first; Diamond up_count cached 60 s)
// 12 Status 200 Body *RoundSummary (newest unseen) | 204 no body
// 13 AckInput.Body: RoundIndex int64 `minimum:"0"` → UPDATE … WHERE player_id=? AND round_index=? AND seen=0; ALWAYS 204 (mirrors local_backend.gd:540-546).
//    ERR_SUMMARY_UNKNOWN from the handover is dropped: no code path raises it.
// 14 FriendsOutput.Body: Friends []FriendEntry (friend_since ASC); Limit int
// 15 AddFriendInput.Body: Code string `minLength:"9" maxLength:"9" pattern:"^QN-[A-Z2-7]{6}$"`; Output 201 FriendEntry
//    Errors: 404 ERR_FRIEND_CODE_UNKNOWN · 409 ERR_FRIEND_ALREADY · 409 ERR_FRIEND_LIMIT params [50] · 422 ERR_FRIEND_CODE_FORMAT · 422 ERR_FRIEND_OWN_CODE
// 16 RemoveFriendInput: PlayerID `path format:"uuid"` → 204 · 404 ERR_FRIEND_UNKNOWN
```

### Problem type and error catalogue (`errors.go`)

```go
type Problem struct { Type, Title string; Status int; Detail, Instance string   // Detail English, developers only; Instance = request id
                      Code string `doc:"ERR_* key; client does Loc.f(code, params)"`; Params []any `doc:"positional; [] when none"`; Errors []*huma.ErrorDetail `omitempty` }
// implements huma.StatusError; ContentType() = "application/problem+json"
var fieldCodes = map[string]string{"body.nickname": "ERR_NICKNAME_LENGTH", "body.code": "ERR_FRIEND_CODE_FORMAT"}
func codeForStatus(s int) string { 401→ERR_UNAUTHORIZED; 403→ERR_BANNED; 429→ERR_RATE_LIMITED; 5xx→ERR_SERVER; default→ERR_BAD_REQUEST }
huma.NewError = func(status int, msg string, errs ...error) huma.StatusError { /* build Problem; first mapped ErrorDetail.Location upgrades ERR_BAD_REQUEST */ }
// Handlers: return nil, api.Err(409, "ERR_LEVEL_LOCKED", remaining).  Middleware (rate limit, recoverer, chi NotFound/MethodNotAllowed) writes the same struct via api.WriteProblem.
```

| Code | Status | `params` | Where | Client `permanent` |
| --- | --- | --- | --- | --- |
| `ERR_BAD_REQUEST` | 400 / 404 route / 405 / 413 / 415 / 422 | `[]` | any | yes |
| `ERR_UNAUTHORIZED` | 401 | `[]` | all auth | no (clears token) |
| `ERR_BANNED` | 403 | `[]` | all auth | yes |
| `ERR_RATE_LIMITED` | 429 | `[retry_after_s]` | any | no |
| `ERR_SERVER` | 500 / 503 | `[]` | any; client fallback for unknown codes | no |
| `ERR_ID_TAKEN` | 409 | `[]` | POST /players | handled (regenerate UUID once) |
| `ERR_NICKNAME_LENGTH` | 422 | `[]` | POST /players, PATCH /me | yes |
| `ERR_NICKNAME_INVALID` | 422 | `[]` | POST /players, PATCH /me (denylist / forbidden runes) | yes |
| `ERR_LEVEL_UNKNOWN` | 404 | `[]` | POST /games, POST /results, GET leaderboard | **no** for results (an old server will learn the level) |
| `ERR_LEVEL_LOCKED` | 409 | `[remaining_s]` | POST /games | yes |
| `ERR_SESSION_INVALID` | 422 | `[]` | POST /results (bad HMAC / unknown id) | yes |
| `ERR_SESSION_EXPIRED` | 410 | `[]` | POST /results (> 30 d) | yes |
| `ERR_SESSION_USED` | 409 | `[]` | POST /results (consumed by another result_id) | yes |
| `ERR_SESSION_MISMATCH` | 403 | `[]` | POST /results (player/session/level mismatch) | yes |
| `ERR_RESULT_INVALID` | 422 | `[]` | POST /results hard 422s | yes |
| `ERR_FRIEND_CODE_FORMAT` · `ERR_FRIEND_OWN_CODE` | 422 | `[]` | POST /friends | yes |
| `ERR_FRIEND_ALREADY` | 409 | `[]` | POST /friends | yes |
| `ERR_FRIEND_CODE_UNKNOWN` | 404 | `[]` | POST /friends | yes |
| `ERR_FRIEND_LIMIT` | 409 | `[50]` | POST /friends | yes |
| `ERR_FRIEND_UNKNOWN` | 404 | `[]` | DELETE /friends/{id} | yes |
| `ERR_NETWORK` | — | `[]` | client only | no |

`permanent := status ∈ {400,403,405,409,410,413,415,422} && code != "ERR_LEVEL_UNKNOWN"`.

New `strings.csv` rows (en, de; existing `ERR_NICKNAME_LENGTH`, `ERR_FRIEND_CODE_FORMAT`, `ERR_FRIEND_OWN_CODE`, `ERR_FRIEND_ALREADY`, `ERR_FRIEND_UNKNOWN` reused verbatim):

```
ERR_NETWORK,No connection to the server,Keine Verbindung zum Server
ERR_SERVER,"Server error, please try again later","Serverfehler, bitte versuche es später noch einmal"
ERR_UNAUTHORIZED,Not signed in to the server,Nicht am Server angemeldet
ERR_BANNED,This account is blocked,Dieses Konto ist gesperrt
ERR_BAD_REQUEST,App and server do not understand each other. Please update the app.,App und Server verstehen sich nicht. Bitte aktualisiere die App.
ERR_RATE_LIMITED,Too many requests. Try again in %d s.,Zu viele Anfragen. Versuche es in %d s noch einmal.
ERR_ID_TAKEN,This player id is already taken,Diese Spieler-ID ist schon vergeben
ERR_NICKNAME_INVALID,This nickname is not allowed,Dieser Name ist nicht erlaubt
ERR_LEVEL_UNKNOWN,The server does not know this level yet,Der Server kennt dieses Level noch nicht
ERR_LEVEL_LOCKED,This level is locked for another %s,Dieses Level ist noch %s gesperrt
ERR_SESSION_INVALID,This game could not be verified,Dieses Spiel konnte nicht geprüft werden
ERR_SESSION_EXPIRED,This game is too old to count,Dieses Spiel ist zu alt und zählt nicht mehr
ERR_SESSION_USED,This game was already submitted,Dieses Spiel wurde schon übermittelt
ERR_SESSION_MISMATCH,This game does not belong to this account,Dieses Spiel gehört nicht zu diesem Konto
ERR_RESULT_INVALID,The server rejected this game,Der Server hat dieses Spiel abgelehnt
ERR_FRIEND_CODE_UNKNOWN,No player has this code,Kein Spieler hat diesen Code
ERR_FRIEND_LIMIT,You can follow at most %d players,Du kannst höchstens %d Spielern folgen
```

## `queens/scripts/backend/http_backend.gd`

**Node structure.** `class_name HttpBackend extends Backend`; `_init(config, save)`. `_ready()` adds 4 `HTTPRequest` children (`use_threads = true`, `accept_gzip = true`); `_free` stack + `signal _released`; `_acquire()` coroutine pops or awaits. `flush_pending_results` stays sequential.

**State.** `_base`, `_token`, `_player_id`, `_bootstrapped`, `_init_in_flight` + `signal _init_done`; caches `_profile`, `_standing` + `_standing_fresh_until`, `_friends`, `_meta` + `_meta_etag`, `_locks {level_id: locked_until}`, `_summary` (from bootstrap, returned once), `_ack_pending = -1`, `_league_config`, `_config_hash`, `_cooldown_seconds`; clock `_synced`, `_offset`, `_synced_local`, `_synced_ticks`, `_last_resync_at`.

**Token storage.** `save.data["auth"] = {player_id, token, issued_at}` (VERSION 2). Written by `register_player` via `save.set_auth()` followed by an immediate `save.save_to()` (a debounced save could lose a freshly minted token); cleared on 401 and `delete_account`.

**Envelope extension (additive; `Backend.fail` and `LocalBackend` untouched).** Failures: `{ok: false, data: <fallback shape>, error: <localised>, code, status, permanent, params}`. Decision: **read methods carry a last-known-or-empty `data` on failure rather than guarding `main.gd`**, so `main.gd:225/239/425-427` stay byte-identical and the league screen keeps showing the last standing offline.

**`_call(method, path, body = null, opts = {auth: true, retry: false, timeout: 10.0, etag: ""})`**
1. `auth and _init_in_flight` → `await _init_done` (a `_show_home` during bootstrap waits instead of rendering empty).
2. Acquire a request node; headers `Content-Type`, `Accept: application/json, application/problem+json`, `X-Client-Version`, `Authorization` when `auth and _token != ""`, `If-None-Match` when `etag`.
3. Transport failure → if `retry` and first attempt, wait `randf_range(0.5, 1.5)` s and retry once; else `{ok:false, data:null, error: Loc.t("ERR_NETWORK"), code: "ERR_NETWORK", status: 0, permanent: false}`.
4. Lower-case headers; `x-server-time` → `_sync_clock(int)`. Parse body when non-empty; 2xx with non-JSON → `ERR_SERVER`.
5. `304` → `{ok:true, data:null, status:304}`; `204` → `{ok:true, data:null, status:204}`; other 2xx → `ok(parsed)`.
6. `401` → `_token = ""`, `save.clear_auth()`, `_bootstrapped = false`.
7. 4xx/5xx: `code := problem.code`; `params := _coerce_params(problem.params)` (integral floats → int). Text: `ERR_LEVEL_LOCKED` → `Loc.f(code, [Cooldown.format_remaining(params[0])])`; else if `code.begins_with("ERR_") and Loc.has(code) and _placeholder_count(Loc.t(code)) == params.size()` → `Loc.f(code, params)`; else `Loc.t("ERR_SERVER")`. `permanent` per the rule above; `retry` and status ∈ {502,503,504} → retry once. `_localise()`/`_coerce_params()` are `static` for unit tests. The `"ERR_"` literal in `begins_with` satisfies the CSV prefix rule at `run_tests.gd:1492`.

**Server-time offset.** `_sync_clock(server)`: `_offset = server − local`, remember `_synced_local` and `Time.get_ticks_msec()`. `now_utc()`: unsynced → system clock; else `local + _offset`, and if `abs((local − _synced_local) − (ticks − _synced_ticks)/1000) > 5` (device clock moved, or the process was suspended — `get_ticks_msec` stalls in suspend) → fire-and-forget `GET /v1/time`, throttled to once per 60 s. `on_resume()` (from `App._notification`): resync; if `_token != "" and not _bootstrapped` → `init()` again.

| `Backend` method | HTTP | On 2xx | Failure `data` | `standing_changed` |
| --- | --- | --- | --- | --- |
| `provider_name` | — | `"http"` | | |
| `init` | `GET /v1/bootstrap` if `_token != ""` else `ok(null)` | cache profile / standing (15 s) / summary / meta + locks / league_config / config_hash / cooldown; `_bootstrapped = true` | `_profile` or `{}` | **emit** |
| `register_player` | `_token != ""` → no HTTP, `ok(_profile)`; else `POST /v1/players` (no auth, no retry, 15 s) | `save.set_auth` + `save.save_to()`; `await init()`; `ok(profile)`. 409 `ERR_ID_TAKEN` returned as-is for `App` | `{}` | via init |
| `set_nickname` | `PATCH /v1/me` | `_profile = body` | `null` | no |
| `get_profile` | `GET /v1/me` (retry) | `_profile = body` | `_profile` or `{}` | no |
| `delete_account` | `DELETE /v1/me` | `save.clear_auth(); _token = ""`; 401 counts as success | `null` | no |
| `start_game` | `POST /v1/games` (no retry, 10 s) | `_locks[id] = locked_until`; invalidate standing | on `ERR_LEVEL_LOCKED` also `_locks[id] = now_utc() + params[0]`; `null` | **emit** on success |
| `submit_result` | `POST /v1/results` with `GameResult.from_dict(r).to_dict()` (no retry, 8 s; the pending queue is the retry) | update `_profile.tier_points`; invalidate standing; 200 and 201 identical to the caller | `null` | **emit** on success |
| `get_level_leaderboard` | `GET …/leaderboard?scope=&limit=` (retry) | `ok(body)`; `my_entry` absent → `views.gd:123` already copes | `null` (`main.gd:404` guards) | no |
| `get_level_meta` | `GET /v1/levels/meta` with `If-None-Match` (retry) | 200: cache `_meta`, `_meta_etag`, `_locks`, `_cooldown_seconds`; `ok(body.levels)`; **304 → `ok(_meta.levels)`** | `_meta.levels` or `{}` | no |
| `get_league_standing` | cached while fresh; else `GET /v1/league/standing` (retry) | `_standing = body`, fresh 15 s | `_standing` or `{}` | no |
| `get_round_summary` | resend `_ack_pending` first if ≥ 0; return cached bootstrap `_summary` once; else `GET /v1/league/summary` (retry) | 200 `ok(body)`; **204 → `ok({})`** | `{}` (never a stale summary offline — it would reopen on every home visit) | no |
| `ack_round_summary` | `POST /v1/league/summary/ack` | 204 → `_ack_pending = −1` | failure → `_ack_pending = i`, drop cached `_summary` with that index; `null` | no |
| `get_friends` | `GET /v1/friends` (retry) | `_friends = body.friends`; `ok(body.friends)` | `_friends` or `[]` | no |
| `add_friend` | `POST /v1/friends {code: stripped upper}` | `ok(body)` | `null` | **emit** on success |
| `remove_friend` | `DELETE /v1/friends/{id}` | 204 → `ok(null)`; 404 → fail | `null` | **emit** on success |
| helpers | `resync_time()`, `level_locks()`, `server_config() -> {league, config_hash, cooldown_seconds}`, `on_resume()` | | | |

Timeouts: GETs 10 s with one retry on transport failure or 502/503/504; `POST /results` 8 s no retry; `POST /games` 10 s no retry (server re-issue covers lost responses); `POST /players` 15 s no retry; PATCH/DELETE/friends/ack 10 s no retry. Never auto-retry 429. `flush_pending_results` breaks on any non-permanent failure.

## Shared league config

Canonical file `queens/shared/league.json` (`{"format": 1, group_size, min_group_size, round_mode, round_best_n, tiers: [...]}` with exactly today's values from `config.gd:53-67`). It lives under `queens/` because Godot can only export files inside the project; Go embeds a copy at `server/internal/domain/league.json` written by `//go:generate` and enforced by `TestLeagueFileInSync` (same pattern as `queens.json`). Add `.gitattributes` with `*.json text eol=lf` so both sides hash identical bytes. `config_hash` = sha256 of the file text with `\r` stripped. New `queens/scripts/league_config_file.gd` (`class_name LeagueConfigFile`): `load_default()` via `load(PATH).data` like `levels.gd:15`, normalising integral floats to ints recursively; `hash_of_file()` via `HashingContext`. Go decodes into typed structs: `MaxSlots *int` (presence test), `RoundBestN` default 15 applied at decode, `UpMode` default `"pct"`, `RoundDays` default 7, `MinSlots` 1, `PlayersPerSlot` 10, `Inactive` `"stay"`, `MinPromoScore` 0; unknown tier id → `(Tier, false)` → 500.

## Client changes (file by file)

Envelope stays byte-identical. Behaviour changes visible to code: `rules.up_to` is a tier id; `tier_name`, `rules_text`, `is_bot` are no longer in payloads; a fifth prose line the handover missed is `league_screen.gd:243` (friend tier label).

**`queens/scripts/backend/backend.gd`** — add `delete_account() -> Dictionary` after `remove_friend()`; header comment: `up_to` is a tier id, friends are directed follows, `FriendEntry` gains `friend_code`.

**`queens/scripts/backend/http_backend.gd`** — new; see the HTTP section above.

**`queens/scripts/backend/local_backend.gd`** — `_standing_for()` (418-445): drop `tier_name`/`rules_text`, `up_to := above if above != tier else ""`. `_members()` (395-414): drop `is_bot`. `_friend_view()` (655-659): drop `tier_name`. `friend_code_for()`/`is_valid_code()` stay with a "placeholder; real codes are server-generated" comment. Add `delete_account()` (`data = defaults(); _save(); ok(null)`). `submit_result` line 225: `fail(Loc.t("ERR_RESULT_INVALID"))` instead of raw text. Mirror the 4th sort key `player_id ASC` into `league_rules.gd:181-189`.

**`queens/scripts/config.gd`** — `league` literal (53-67) → `LeagueConfigFile.load_default()`, doc comment kept and pointed at the JSON. Add `server_url` (mechanism below). `client_version` stays a var; CI seds it.

**`queens/scripts/save_data.gd`** — header documents `auth {player_id, token, issued_at}`; `VERSION := 2`; `defaults()` gets `"auth": auth_defaults()`; `migrate()` arm `1:` sets `dict["auth"] = auth_defaults(); version = 2`, plus a post-ladder key backfill like settings. Accessors: `auth()`, `auth_token()`, `set_auth(player_id, token, issued_at)`, `clear_auth()`, `rekey_player(new_id)` (rewrites `player.id`, every `results[].player_id` and `pending_results[].player_id`, clears auth), `abort_game()` (clears `current_game`; used when the server rejects a start). No cooldown export (OPEN-7).

**`queens/scripts/game_result.gd`** — `SCHEMA := 2`; `var session_token := ""`; `to_dict`/`from_dict` carry it. Comment: `from_dict` casts every int field and is the wire normaliser (JSON numbers arrive as floats).

**`queens/scripts/game_session.gd`** — `start(..., session_token := "")`; `set_session_token(token)`; `to_marker()` adds `session_token`; `forfeit_from_marker()` restores it. *The single easiest thing to forget.*

**`queens/scripts/app.gd`**
- `var level_locks: Dictionary = {}`; `signal backend_ready`.
- `_ready()` becomes a coroutine: unchanged up to `save.changed.connect`; `_start_backend()` creates and `add_child`s the node **synchronously** (so `main.gd:96` can connect) then awaits `init()` and `register_player()`; `await _forfeit_dangling_game()`; `await flush_pending_results()`; providers; `backend_ready.emit()`.
- `_start_backend()`: `HttpBackend.new(config, save) if config.server_url != "" else LocalBackend.new(config, catalog, now)`. On `ERR_ID_TAKEN`: `save.rekey_player(SaveData.new_uuid()); save_now()`; register once more. Then `_apply_server_config()`: replace `config.league` when the bootstrap `config_hash` differs, take `cooldown_seconds`, fill `level_locks`.
- `flush_pending_results()` (124-134): a `permanent` failure (4xx other than 401/429) logs and drops the item; a transport/401/429/5xx failure keeps it **and every remaining item** and breaks (no ordering loss). Cap `pending_results` at 200, oldest dropped.
- `_forfeit_dangling_game()`: `await record_result(result)`.
- `record_result()` (150-163): `save_now()` immediately after `save.record_result(...)` and before the `await`; keep the trailing one (persists the dequeue).
- `use_save_path()`: coroutine; force `config.server_url = ""` before `_start_backend()`.
- `now()`: `backend.now_utc() if backend != null else system clock`.
- `lock_remaining(level_id) -> int`: `maxi(server_remaining, Cooldown.remaining(save.level_entry(id), now(), config.cooldown_seconds))`, `server_remaining = maxi(level_locks.get(id, 0) - now(), 0)`. Display-only and conservative; the server enforces and never reads the local value.
- `_notification`: on `APPLICATION_RESUMED` call `backend.on_resume()` if present (time resync) then `flush_pending_results()`.

**`queens/scripts/main.gd`**
- 96-98: listener does `match router.current(): "league": _refresh_league(); "home": _refresh_home()` (extract 223-228 into `_refresh_home()`).
- 177-183, 194-202, 412-413, 465-470: use `App.lock_remaining(id)`.
- 383 / 404-405: `Views.level_cards(levels, save, catalog, App.lock_remaining)` / `Views.level_detail(..., App.lock_remaining(level_id))`.
- 424-428: `Views.league_screen(standing, friends, App.config.league)` injects presentation, then `league.refresh(...)`; on any `not ok` show `res["error"]` as status.
- 480-488: keep the optimistic order (charge, `session.start`, `begin_game`, `save_now`), replace line 488 with un-awaited `_request_session(session, level)`:
  - ok → `set_session_token`, `save.update_marker(to_marker()); save_now()` (a crash from here on forfeits **with** the token), `level_locks[id] = locked_until`.
  - `ERR_LEVEL_LOCKED` → `_abort_locked_start`: detach session, `save.abort_game()`, `energy.refund_start()` (new inverse of `charge_start`, no-op when unlimited), `level_locks[id] = now + remaining`, existing locked dialog, back to home. Marker cleared so no phantom forfeit next launch.
  - anything else (offline, unknown level) → play on with an empty token; the result queues as today.
  Decision: optimistic start rather than awaited — an awaited start would freeze the tap-to-board transition for up to 10 s on a hanging server, and the instant start is shipped behaviour. The abort path is ~15 lines.
- 599-601: `bd := lg["breakdown"] if lg.has("breakdown") else Scoring.breakdown(result.to_dict())`; if server breakdown present, `result.score = bd.score`.

**`queens/scripts/energy_ledger.gd`** — `refund_start()`.

**`queens/scripts/presenters/views.gd`** — `league_summary` (13-33): `next_tier := LeagueRules.tier_label(up_to) if up_to != ""`. `level_card/level_cards/level_detail` take `remaining: int` / `remaining_fn: Callable`; delete `Cooldown.remaining` at 94 and 132. New `league_screen(standing, friends, cfg)`: deep-copies and injects `standing.tier_name = tier_label(tier)`, `standing.rules_text = LeagueRules.rules_text(tier_cfg, rules.up_count, tier_label(up_to))`, `rules.up_to_name`, `friends[i].tier_name`. Presentation stays in the presenter; the server sends ids only.

**`queens/scripts/ui/league_screen.gd`** — 59 and 114: `LeagueRules.tier_label(tier_id)`; 67/72 unchanged (presenter injects `rules_text`); 79: `rules.up_to_name`; 243: `tier_label(fr.tier)`.

**`queens/i18n/strings.csv`** — the new `ERR_*` rows (catalogue above). The unused-key test at `run_tests.gd:1480-1532` already whitelists the `ERR_` prefix family.

**`queens/tests/run_tests.gd`** — register `_test_fixture_scoring`, `_test_fixture_league`, `_test_fixture_sweep` (skipped when `QUEENS_FAST_TESTS=1`), `_test_league_config_file`, `_test_http_backend_pure`, `_test_backend_contract`. 638-654 → fixture reader; keep qualitative checks 655-704. `_test_local_backend`: 833/834 → `rules.up_to == "silver"` and `LeagueRules.rules_text(...)` equals the old string; 844 `is_bot` → `not is_me and not is_friend`; 943 `up_to == "gold"`; 959/979/983 compute `rules_text` via `LeagueRules`. Extract bot-free assertions into `_test_backend_contract(backend, now_fn)`. `_test_save_data`: v1 → `auth` present; `rekey_player` rewrites queued `player_id`s. `_test_game_session`: marker carries `session_token`, forfeit restores it, `schema == 2`. `_test_views`: new signatures; `league_screen` injection. `_test_http_backend_pure`: `_localise(409, {code: ERR_LEVEL_LOCKED, params: [3600.0]})` gives the locked text; unknown code → `ERR_SERVER`; param-count mismatch → `ERR_SERVER`; `_coerce_params([50.0]) == [50]`; `permanent` rule.

**`queens/tests/screenshot.gd:28`** — `await App.use_save_path(SAVE_PATH)`.

**`queens/tools/gen_fixtures.gd`** — new (parity harness below).

## `GameConfig.server_url` per build

Feature tags in `config.gd`, sed for the two build-time strings:

```gdscript
const SERVER_URL_RELEASE := "https://queens-api.<domain>"   # not secret; committed once hosting is decided
const SERVER_URL_DEBUG := ""                                 # "" = LocalBackend; set http://127.0.0.1:8080 to develop against queensd
static func _default_server_url() -> String:
    var env := OS.get_environment("QUEENS_SERVER_URL")       # desktop/editor override
    if env != "": return env
    if OS.has_feature("editor") or OS.has_feature("debug"): return SERVER_URL_DEBUG
    return SERVER_URL_RELEASE
```

`--export-release` sets `release` and clears `debug`, so only the CI-published APK gets the production URL; editor, headless tests and debug APKs default to `LocalBackend`; `use_save_path()` forces `""` regardless. `android.yml` gains two seds beside the existing ones: `client_version` → `"1.0.<run_number>"`, and `SERVER_URL_RELEASE` ← repository variable `vars.QUEENS_SERVER_URL` when non-empty (staging without a commit). Until hosting is decided (OPEN-4) `SERVER_URL_RELEASE` stays `""` and release builds remain offline. Dev on device: Android 9+ blocks cleartext, so `adb reverse tcp:8080 tcp:8080` + `http://127.0.0.1:8080`.

## Parity harness

**Float encoding, both sides exactly**: 16 lowercase hex digits of the binary64 bit pattern, big-endian digit order. GDScript: `var b := StreamPeerBuffer.new(); b.big_endian = true; b.put_double(v); b.data_array.hex_encode()` (endian-explicit; `PackedFloat64Array.to_byte_array()` is host order). Go: `fmt.Sprintf("%016x", math.Float64bits(v))` / `strconv.ParseUint(s,16,64)` → `Float64frombits`. Self-check `1.0 → 3ff0000000000000`. Every float input and output has a `*_hex` twin; Go parses hex, never decimal. Ints compare exactly; mismatch is fatal.

**`shared/fixtures/scoring_cases.json`**: `{format, generator, constants{all Scoring consts as hex}, cases[], week[], week_bounds[]}`. Case order: the 7 golden rows (`run_tests.gd:641-647`, incl. the knife-edge `(10,55,12,900)→84`); forfeit → 0; hints 0..6 at `(10,55,0,180)`; stored par `(6,8,0,72, par 144)→257`; `elapsed 0` → speed 2.0; accuracy at wrong 10 and 100; speed clamps at `80/240, 79/240, 720/240, 240/240`; `(10,55,99,1e6,hints 99)`; then a grid size {6..10} × difficulty {6,20,40,61} × wrong {0,1,3,12} × hints {0,1,2} × elapsed {par/4, par/3, par/2, par, 2par, 3par, 4par} (elapsed computed in GDScript, stored as hex). 1704 cases. Each `expect` = `{score, base, par_hex, accuracy_hex, speed_hex, hint_hex, flawless}`.

**`shared/fixtures/league_cases.json`**: `{format, config_hash, round_index[], round_bounds[], slots[], openings[], counts[] (every tier × n 0..40 × leader {0,1499,1500,2500} × up_count {-1,0,3}), round_score[], evaluate[], transitions[], inactive_outcome[], promote_tier[], relegate_tier[]}`. `evaluate` inputs generated once by a seeded `RandomNumberGenerator` (seed 20260919) and **stored**, so Go never needs Godot's RNG; deliberate ties on `(round_score, games, last_submit_at)` pin the new 4th key; group sizes {0,1,3,4,5,6,29,30,31,47,100}; a zero-score-leader case pins the `promote_count` asymmetry.

**`shared/fixtures/sweep.sha256`**: `sha256:<64 hex>` / `cases:4004000` / `levels:<level_set_hash>`. Stream: for level in `queens.json` order; wrong 0..25; hints 0..6; elapsed in `ELAPSED_SET` order → `Scoring.score({size, difficulty, wrong_placements, hint_count, elapsed_seconds, completed: true})` (no `par_seconds` key), append ASCII decimal + `"\n"` to SHA-256. `ELAPSED_SET` (220 exactly-representable values): `0`; `1..60` step 1; `65..300` step 5; `310..600` step 10; `630..1200` step 30; `1260..3600` step 60; `3900..7200` step 300; `14400, 21600, 43200, 86400`; `0.5, 2.5, 12.25, 33.75, 99.5`. 100 × 26 × 7 × 220 = 4 004 000 cases.

**Readers**: `run_tests.gd` reads `res://../shared/fixtures` via `ProjectSettings.globalize_path`; `_test_fixture_sweep` ~1 min in GDScript. `server/internal/domain/parity_test.go` reads `../../../shared/fixtures/*.json`: `TestScoringConstants` (hex consts equal Go consts, catches a retyped `SPEED_EXPONENT`), `TestScoringCases`, `TestWeekIndex`, `TestLeagueCases` (subtest per section), `TestSweepDigest` (~3 s), `TestLeagueFileInSync`; `TestLevelFileInSync` lives in `levelset`. Generator `queens/tools/gen_fixtures.gd` (`extends SceneTree`) writes the three files with `JSON.stringify(data, "  ")`, LF only.

## CI

**`.github/workflows/server.yml`** (new): triggers `push main` and `pull_request` on `server/**, shared/**, queens/levels/**, queens/shared/**, scoring.gd, league_rules.gd, gen_fixtures.gd`. Job `go` (working dir `server`): `setup-go` from `go.mod`, `go vet`, `go build`, `go test -race -count=1 ./...` (covers OpenAPI drift, file-in-sync, parity, sweep, snapshots), belt-and-braces `queensd openapi -o $RUNNER_TEMP/openapi.yaml && diff -u`, cross-compile `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 -trimpath -ldflags "-s -w -X main.version=<sha>"`, upload artifact. Job `fixtures`: download Godot 4.7.1 linux editor (same pattern as `android.yml:49-57`), `--import`, run `gen_fixtures.gd`, `git diff --exit-code -- shared/fixtures/`, then `run_tests.gd`.

**`android.yml`**: add a `Run tests` step (`--import` then `run_tests.gd` with `QUEENS_FAST_TESTS=1`) before the export; the two extra seds; timeout 30 → 40.

## Contract snapshot tests — `server/internal/api/testdata/*.json`

`humatest` against `testutil.NewTestStore` with a fixed clock (Wed 2026-09-09 12:00 UTC = Bronze round 6900 / week 2957), three players (`me`, `friend`, `stranger`), levels 0 and 3, one completed result each, `me` follows `friend`. Volatile values scrubbed (`<uuid>`, `<unix>`, `<token>`, `<hash>`), canonical JSON compared, `-update` rewrites. `contract_keys.json` lists per record from `backend.gd`'s header the keys the client indexes; a test asserts every golden is a superset — the compile-time check GDScript lacks.

Goldens: `register_201`, `register_409_id_taken`, `bootstrap`, `me`, `me_patch`, `games_201`, `games_200_reissue` (same session id on a second start), `results_201`, `results_200_replay` (byte-identical), `results_forfeit_then_completed`, `leaderboard_{global,friends,flawless,empty}`, `levels_meta_200` + `levels_meta_304`, `standing_{unjoined,joined,diamond}` (Diamond: `up_count ≥ 0`, `global: true`, truncated members with absolute ranks), `summary_200` + `summary_204`, `friends`, `friend_201`, `time`, `problem_422_validation` (Huma validation → `ERR_BAD_REQUEST` with `errors[]`), `problem_422_nickname`, `problem_409_level_locked` (`params: [<int>]`), `problem_429` (+ `Retry-After`), `problem_401`, `problem_404_route`. `X-Server-Time` present on error responses too.

## First actions on approval

1. Save this plan as `docs/backend-plan.md` and mark `docs/backend-plan-handover.md` as superseded (one line at its top). The handover's SETTLED sections remain the rationale record.
2. Install Go 1.24 on this machine (not present; not in `G:\tools`). Update the Godot-binary memory note: the console binary is `G:\tools\godot\4.7.1-mono\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe`.
3. Start M0.

## Build order and verification

| # | Milestone | Done when |
| --- | --- | --- |
| M0 | Install Go 1.24 (not on this machine). `server/` skeleton: `go.mod`, config, slog, chi + Huma, middleware chain, `/healthz` `/readyz`, `GET /v1/time`, `queensd openapi -o`, `TestOpenAPISpecUpToDate`, Problem type + code map | `/docs` renders; `openapi.yaml` committed |
| M1 | Store: modernc driver, DSN pragmas, dual pools, migration runner, `0001_init.sql`, `levelset.Sync` with the size/difficulty guard and `TestLevelFileInSync`, `testutil` | `queensd migrate`; level repo tests |
| **M2** | `queens/shared/league.json` + `LeagueConfigFile`; `gen_fixtures.gd`; `domain/scoring.go` + `parity_test.go` incl. sweep; `run_tests.gd` reads the fixtures | Go and Godot suites green on the same files |
| M3 | `domain/league.go` pure functions + league fixture; 4th sort key mirrored into `league_rules.gd` | league fixture green both sides |
| M4 | Identity: players, tokens, nickname pipeline + denylist, `POST /players`, `GET/PATCH/DELETE /me`, auth resolver, `GET /v1/bootstrap` | humatest register → token → `/me`; goldens |
| M5 | Play loop: `POST /games`, `POST /results` (all steps above), level bests | the play-loop service tests |
| M6 | Boards: `/levels/meta` ETag/304, `/levels/{id}/leaderboard` three scopes | seeded multi-player tests |
| M7 | League: catch-up, closer (ticker + lazy), standing, summaries, ack | clock-driven tests over a Bronze **and** Silver boundary; re-run idempotent |
| M8 | Friends + `friends` scope | all friend codes |
| M9 | Hardening: rate limits, flags, shadow/quarantine, sweeper, backups, graceful shutdown, admin CLI (`flags list/exclude/unexclude/rescore/rename/ban`), `server.yml`, `android.yml` test step | `kill -TERM` drains; a backup appears; CI green |
| M10 | Client: `http_backend.gd` + every change above, behind `server_url` | play against localhost, standing moves, server breakdown shown; kill server → offline play, `pending_results` drains on restart |

Service tests that carry the weight (M5–M7), all in `internal/service/*_test.go` on a real SQLite via `testutil.NewTestStore`:

- Identity: new player 201 with token/bronze; existing id without token → `ERR_ID_TAKEN`; with own token → 200 nickname update; nickname 1/17 runes rejected, 2/16 accepted after trim; denylisted → `ERR_NICKNAME_INVALID`; unknown/revoked token 401; banned 403.
- Start: mints session and joins (`lg_bronze_<idx>_001`, `rounds_played 1`, `expires_at = +6h`); second start same round → no new membership; cooldown blocks and 7 d unblocks; violation flag only when `remaining > 60`; unknown level 404; fill-first 47 → 30 + 17; global tier single `capacity NULL` group; shadow-excluded → quarantine group with identical id format.
- Submit: recompute ignores `par_seconds: 1e9`, golden `(10,55,0,245)→1169`; meta mismatch accepted + weight-1; duplicate id → byte-identical 200, no stat change, no bucket charge; forfeit→completed same id resolves to completed, stats once; completed→forfeit returns stored + `replay_body_mismatch`; consumed session other id → `ERR_SESSION_USED`; bad HMAC 401 with zero DB rows touched; >30 d → 410; >6 h → stale flag; no session → `verified 0`, weight-8, off `level_bests`, counted in games/round; grace window suppresses flag; sub-floor clamps to 4.56 on 6×6 with weight-5 and lower score; above-wall clamps down (D3); the six hard 422s; 16 replays of the max-base level → `impossible_round_score` 422; payload/session player mismatch 403 + weight-8; score off by 1 → no flag, off by 2 → weight-3; stats + best-15-of-20 round score; level best keeps better row only; flawless board keeps fastest clean run independently; promo crossing → `promoted_to silver`, response `tier bronze`, profile silver with 0 points, summary `reason score` with pre-reset points + `best_game`, standing `joined false`, member `left_at` set; forfeit joins but changes no stats; perfect streak caps at 6.
- League: Bronze boundary with 3 players → ranks 1..3, all safe, `promote_count 0`, one `stayed/round` summary each, tier_points survive, re-run no-op; Silver closed independently at the same tick; Platinum 30 → 5 up / 8 down, relegated land in Gold with 0 points; Gold floor; zero-score leader does not promote (`run_tests.gd:786`); Diamond `up_count` frozen from Challenger openings, same for every group, Challenger-first gives the same result (D4); crash between groups resumes without double-applying; `left_at` member ranked but not settled; absent Bronze 5 rounds → one `inactive_frozen`; absent Platinum 3 weeks → one `platinum→gold inactive_relegated`; absent Challenger years → Gold in 3 steps (D5); catch-up idempotent and write-free after the ticker; unjoined standing shape with `up_to` id and `up_count −1`; sort ties broken by `player_id`; 150-member group: OR-chain rank == `rn`, window top 100 + ±5 + me; summaries: newest unseen, wrong-index ack keeps it, right-index ack → 204, ack never errors.
- Boards: global order/rank ties; flawless order/rank; friends scope directed (A follows B, B does not see A); shadow-excluded hidden globally, visible to friends and self; `my_rank 0` without entry; `total_players` counts all eligible; limit clamped 100; `levels/meta` `If-None-Match` → 304.
- Friends: every code path incl. limit 50; remove unknown 404; round_score from the friend's own tier round.
- Account/hardening: `DELETE /me` cascades and decrements open group; anomaly decay 15 → 7.5 at +30 d, shadow at ≥15, cleared <5 on join; sweeper deletes only expired sessions/old counters; `VACUUM INTO` produces an openable DB and keeps 14; 40 replays → no 429.
- Contract: `TestBackendContract_HTTP` mirrors the GDScript `_test_backend_contract` against an in-process server, asserting every header record key.

### Commands

```bash
# Godot suite (Godot 4.7.1 mono console binary; start adb first or the run hangs at exit)
G:/tools/godot/4.7.1-mono/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe --headless --path queens --script tests/run_tests.gd
```
```bash
# Go suite, from server/
go vet ./... && go test -race ./... && go build ./...
```
```bash
# Cross-language parity: regenerate and assert nothing moved
G:/tools/godot/4.7.1-mono/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe --headless --path queens --script tools/gen_fixtures.gd && git diff --exit-code shared/fixtures/
```

End-to-end (M10): run `queensd` on localhost with `QUEENS_ENV=dev`, set `QUEENS_SERVER_URL=http://127.0.0.1:8080` in the editor environment, play a level, confirm the win overlay shows the server's breakdown and the league standing moves; kill the server, confirm play continues offline; restart it, confirm `pending_results` drains on the next launch. Repeat the Godot suite and screenshot runner with `server_url = ""` to prove nothing regressed offline.

## Things to say plainly to the user (carried from the handover)

- The unlimited-energy IAP is client-asserted (`energy.set_unlimited(token)`, restore writes the literal `"restored"`). Receipt validation is worth more than move-log replay; hooks (`players.entitlements`, a `purchases` table) are cheap to add in a later migration, not in `0001`.
- A player promoted on Sunday evening joins a week ending in hours and will likely be relegated; a "joined with <24 h left → frozen" grace rule is the obvious later fix.
- With "start fresh", every existing player appears as a new Bronze player on first server launch. The client keeps honouring its own local cooldowns for display, but the server will allow an immediate replay of every level once.
- Hosting is undecided; release builds stay offline (`SERVER_URL_RELEASE = ""`) until it is.
