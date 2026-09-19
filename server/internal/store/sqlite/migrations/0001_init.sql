-- 0001_init.sql -- Queens server, initial schema.
--
-- Conventions: STRICT tables; unix seconds as INTEGER written by Go (never
-- datetime('now')); booleans as INTEGER 0/1 with CHECK; app-generated TEXT
-- primary keys (no AUTOINCREMENT, no rowid, no last_insert_rowid); INSERT ...
-- ON CONFLICT only (never INSERT OR REPLACE); explicit ORDER BY everywhere;
-- counter bumps as SET x = x + 1. The Postgres port gets its own hand-written
-- DDL -- the swap promise is kept by the repository interface, not by this file.
--
-- Every foreign-key child column is indexed: SQLite does not do it for you and
-- ON DELETE CASCADE would otherwise table-scan.

-- schema_migrations is created by the migration runner itself, before it
-- applies anything, so it is deliberately not declared here.

-- ---------------------------------------------------------------- identity

CREATE TABLE players (
  id                 TEXT    NOT NULL PRIMARY KEY,   -- client-generated v4 UUID: a name, not an authenticator
  nickname           TEXT    NOT NULL,               -- NFKC-trimmed, 2..16 runes, denylist-checked in Go
  friend_code        TEXT    NOT NULL,               -- 'QN-' + 6 of [A-Z2-7], server-generated
  tier               TEXT    NOT NULL,
  tier_points        INTEGER NOT NULL DEFAULT 0,     -- scores since entering `tier`; reset on every tier change
  tier_since         INTEGER NOT NULL,
  settled_round_end  INTEGER NOT NULL,               -- league outcomes applied for every round of `tier` ending <= this
  games              INTEGER NOT NULL DEFAULT 0,
  flawless           INTEGER NOT NULL DEFAULT 0,
  best_score         INTEGER NOT NULL DEFAULT 0,
  rounds_played      INTEGER NOT NULL DEFAULT 0,
  perfect_streak     INTEGER NOT NULL DEFAULT 0,
  anomaly_score      REAL    NOT NULL DEFAULT 0,     -- decayed lazily on read, 30-day half-life
  anomaly_updated_at INTEGER NOT NULL DEFAULT 0,
  shadow_excluded    INTEGER NOT NULL DEFAULT 0,
  banned_at          INTEGER,                        -- admin CLI only; 403 ERR_BANNED
  auth_provider      TEXT,                           -- hook for Play Games / transfer code, so no migration is needed later
  auth_external_id   TEXT,
  client_version     TEXT    NOT NULL DEFAULT '',
  created_at         INTEGER NOT NULL,
  updated_at         INTEGER NOT NULL,
  last_seen_at       INTEGER NOT NULL,
  CHECK (shadow_excluded IN (0, 1))
) STRICT;
-- add_friend resolves a code to a player; UNIQUE also makes the generation retry loop correct.
CREATE UNIQUE INDEX players_friend_code ON players (friend_code);
-- Future external sign-in must map to exactly one account; partial so NULL rows do not collide.
CREATE UNIQUE INDEX players_external ON players (auth_provider, auth_external_id) WHERE auth_provider IS NOT NULL;
-- Population counts per tier: the two inputs of Openings().
CREATE INDEX players_tier ON players (tier);

CREATE TABLE auth_tokens (
  token_hash   TEXT    NOT NULL PRIMARY KEY,         -- hex sha256 of the opaque wire token; the token itself is never stored
  player_id    TEXT    NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  created_at   INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,                     -- bumped at most hourly: a write per request would serialise the server
  revoked_at   INTEGER
) STRICT;
CREATE INDEX auth_tokens_player ON auth_tokens (player_id);

-- ------------------------------------------------------------------ levels

CREATE TABLE levels (
  id             TEXT    NOT NULL PRIMARY KEY,       -- uuid from queens.json
  size           INTEGER NOT NULL,                   -- a change refuses boot: base and par derive from it
  difficulty     INTEGER NOT NULL,                   -- likewise
  stars          INTEGER NOT NULL,
  seed           INTEGER NOT NULL,
  regions_json   TEXT    NOT NULL,
  -- Stored, and NEVER serialised by the API layer. It is required for the
  -- move-log replay upgrade path, and it is already public inside the APK, so
  -- keeping it here leaks nothing new. Re-importing later would be a migration.
  -- Do not "clean this up".
  solution_json  TEXT    NOT NULL,
  content_hash   TEXT    NOT NULL,                   -- sha256 of the canonical level JSON
  par_override   REAL,                               -- optional per-level tuning, server -> client only
  in_current_set INTEGER NOT NULL DEFAULT 1,         -- 0 = gone from the shipped file; rows are kept forever
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  CHECK (in_current_set IN (0, 1))
) STRICT;

CREATE TABLE level_sets (
  hash        TEXT    NOT NULL PRIMARY KEY,          -- sha256 of the sorted (id, content_hash) list = ETag of GET /levels/meta
  level_count INTEGER NOT NULL,
  imported_at INTEGER NOT NULL
) STRICT;
CREATE INDEX level_sets_latest ON level_sets (imported_at DESC);

CREATE TABLE player_levels (
  player_id       TEXT    NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  level_id        TEXT    NOT NULL REFERENCES levels (id),
  last_started_at INTEGER NOT NULL,                  -- server-authoritative cooldown anchor
  plays           INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (player_id, level_id)
) STRICT;
CREATE INDEX player_levels_level ON player_levels (level_id);

-- ---------------------------------------------------------------- sessions

CREATE TABLE game_sessions (
  id                   TEXT    NOT NULL PRIMARY KEY, -- base64url(16 random bytes); the HMAC lives only in the wire token
  player_id            TEXT    NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  level_id             TEXT    NOT NULL REFERENCES levels (id),
  issued_at            INTEGER NOT NULL,             -- server clock; the wall-time anchor for the elapsed clamp
  expires_at           INTEGER NOT NULL,             -- issued_at + 6h: freshness only, NOT acceptance (30 days)
  consumed_at          INTEGER,                      -- single use: UPDATE ... WHERE consumed_at IS NULL
  result_id            TEXT,
  tier_at_issue        TEXT    NOT NULL,
  round_index_at_issue INTEGER NOT NULL,
  group_id             TEXT    NOT NULL,
  integrity_verdict    TEXT,                         -- hook for Play Integrity
  client_version       TEXT    NOT NULL DEFAULT ''
) STRICT;
CREATE INDEX game_sessions_player ON game_sessions (player_id, issued_at DESC);
-- Sweeper: unconsumed sessions past the 30-day acceptance window.
CREATE INDEX game_sessions_unconsumed ON game_sessions (issued_at) WHERE consumed_at IS NULL;
-- Sweeper: consumed sessions past retention.
CREATE INDEX game_sessions_consumed ON game_sessions (consumed_at) WHERE consumed_at IS NOT NULL;
CREATE INDEX game_sessions_level ON game_sessions (level_id);

-- ----------------------------------------------------------------- results

CREATE TABLE results (
  result_id              TEXT    NOT NULL PRIMARY KEY, -- client v4 UUID: the idempotency key
  player_id              TEXT    NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  level_id               TEXT    NOT NULL REFERENCES levels (id),
  session_id             TEXT    REFERENCES game_sessions (id) ON DELETE SET NULL,
  tier                   TEXT    NOT NULL,             -- the (tier, round_index) this result was credited to
  round_index            INTEGER NOT NULL,
  completed              INTEGER NOT NULL,
  verified               INTEGER NOT NULL,             -- 1 = a valid session covered this result; 0 never reaches a leaderboard
  schema                 INTEGER NOT NULL,
  size                   INTEGER NOT NULL,             -- server values from `levels`, not the payload's
  difficulty             INTEGER NOT NULL,
  stars                  INTEGER NOT NULL,
  par_seconds            REAL    NOT NULL,             -- server par at submit time; a later recompute reads THIS
  base                   INTEGER NOT NULL,
  started_at             INTEGER NOT NULL,             -- payload
  finished_at            INTEGER NOT NULL,             -- min(payload, now)
  received_at            INTEGER NOT NULL,
  elapsed_seconds        REAL    NOT NULL,             -- clamped
  client_elapsed_seconds REAL    NOT NULL,             -- as submitted
  queens_placed          INTEGER NOT NULL,
  wrong_placements       INTEGER NOT NULL,
  queens_removed         INTEGER NOT NULL,
  clear_count            INTEGER NOT NULL,
  hint_count             INTEGER NOT NULL,
  taps                   INTEGER NOT NULL,
  score                  INTEGER NOT NULL,             -- server recompute
  client_score           INTEGER NOT NULL,             -- kept only for the score_mismatch comparison
  flawless               INTEGER NOT NULL,
  client_version         TEXT    NOT NULL DEFAULT '',
  payload_hash           TEXT    NOT NULL,             -- sha256 of the canonical payload: a cheap "different body" test
  response_json          TEXT    NOT NULL,             -- the exact 201 body; replays return it verbatim
  move_log               BLOB,                         -- hook for move-log replay; NULL until a client sends one
  CHECK (completed IN (0, 1)),
  CHECK (verified IN (0, 1)),
  CHECK (flawless IN (0, 1))
) STRICT;
-- Best-N round score and best_game in one index range; partial because forfeits never score.
CREATE INDEX results_round_player ON results (player_id, tier, round_index, score DESC) WHERE completed = 1;
CREATE INDEX results_player_time ON results (player_id, finished_at DESC);
CREATE INDEX results_session ON results (session_id);
CREATE INDEX results_level ON results (level_id);

-- ------------------------------------------------------------ leaderboards

CREATE TABLE level_bests (                            -- the score-best run per (player, level)
  player_id        TEXT    NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  level_id         TEXT    NOT NULL REFERENCES levels (id),
  result_id        TEXT    NOT NULL,                  -- deliberately no FK: results retention must not delete a board row
  score            INTEGER NOT NULL,
  wrong_placements INTEGER NOT NULL,
  time_seconds     REAL    NOT NULL,
  achieved_at      INTEGER NOT NULL,
  PRIMARY KEY (player_id, level_id)
) STRICT;
-- Exactly the global/friends board order, so the board is a pure index range scan
-- and the rank OR-chain is answered from the same index.
CREATE INDEX level_bests_rank ON level_bests (level_id, score DESC, wrong_placements ASC, time_seconds ASC, achieved_at ASC, player_id ASC);

CREATE TABLE level_flawless_bests (                   -- the fastest run with wrong == 0 per (player, level)
  player_id    TEXT    NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  level_id     TEXT    NOT NULL REFERENCES levels (id),
  result_id    TEXT    NOT NULL,
  score        INTEGER NOT NULL,                      -- displayed, not a sort key on this board
  time_seconds REAL    NOT NULL,
  achieved_at  INTEGER NOT NULL,
  PRIMARY KEY (player_id, level_id)
) STRICT;
CREATE INDEX level_flawless_bests_rank ON level_flawless_bests (level_id, time_seconds ASC, achieved_at ASC, player_id ASC);

-- ------------------------------------------------------------------ league

CREATE TABLE league_rounds (
  tier               TEXT    NOT NULL,
  round_index        INTEGER NOT NULL,                -- only comparable within one tier
  starts_at          INTEGER NOT NULL,
  ends_at            INTEGER NOT NULL,
  state              TEXT    NOT NULL DEFAULT 'open', -- open -> closing -> closed; the claim is UPDATE ... WHERE state = 'open'
  group_seq          INTEGER NOT NULL DEFAULT 0,
  -- Frozen at claim so every group of the round, and every resumed close, see
  -- the same numbers. up_count NULL means -1, "use the percentage".
  up_count           INTEGER,
  below_players      INTEGER,
  members_in_tier    INTEGER,
  closing_started_at INTEGER,
  closed_at          INTEGER,
  created_at         INTEGER NOT NULL,
  PRIMARY KEY (tier, round_index),
  CHECK (state IN ('open', 'closing', 'closed'))
) STRICT;
-- The ticker and the lazy catch-up both ask "rounds past their end that are not closed".
CREATE INDEX league_rounds_due ON league_rounds (state, ends_at);

CREATE TABLE league_groups (
  id           TEXT    NOT NULL PRIMARY KEY,          -- lg_<tier>_<round>_<seq>; a quarantine group looks identical from outside
  tier         TEXT    NOT NULL,
  round_index  INTEGER NOT NULL,
  quarantine   INTEGER NOT NULL DEFAULT 0,            -- 1 = holds only shadow-excluded players, evaluated by the same code
  capacity     INTEGER,                               -- NULL for global tiers (Diamond, Challenger): one unbounded group
  member_count INTEGER NOT NULL DEFAULT 0,
  state        TEXT    NOT NULL DEFAULT 'open',
  closed_at    INTEGER,
  created_at   INTEGER NOT NULL,
  FOREIGN KEY (tier, round_index) REFERENCES league_rounds (tier, round_index) ON DELETE CASCADE,
  CHECK (quarantine IN (0, 1)),
  CHECK (state IN ('open', 'closed'))
) STRICT;
-- Fill-first join: the partial group of a (tier, round, quarantine) with the most members.
CREATE INDEX league_groups_open ON league_groups (tier, round_index, quarantine, state, member_count DESC, id ASC);

CREATE TABLE league_members (
  player_id      TEXT    NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  tier           TEXT    NOT NULL,
  round_index    INTEGER NOT NULL,
  group_id       TEXT    NOT NULL REFERENCES league_groups (id) ON DELETE CASCADE,
  joined_at      INTEGER NOT NULL,
  round_score    INTEGER NOT NULL DEFAULT 0,          -- denormalised best-N sum, rewritten on every completed submit
  games          INTEGER NOT NULL DEFAULT 0,
  last_submit_at INTEGER NOT NULL DEFAULT 0,
  synthetic      INTEGER NOT NULL DEFAULT 0,          -- always 0; reserved so bots could return without the maths seeing them
  left_at        INTEGER,                             -- promoted by score mid-round: still ranked, never settled by the closer
  final_rank     INTEGER,
  final_zone     TEXT,
  outcome        TEXT,
  -- The structural guarantee that a player cannot be in two groups of one round.
  -- It is an invariant, not a check.
  PRIMARY KEY (player_id, tier, round_index),
  CHECK (synthetic IN (0, 1))
) STRICT;
-- Exactly SortMembers(): standings, the ROW_NUMBER window and the rank OR-chain all run on this index.
CREATE INDEX league_members_standing ON league_members (group_id, round_score DESC, games ASC, last_submit_at ASC, player_id ASC);

CREATE TABLE round_summaries (
  id            TEXT    NOT NULL PRIMARY KEY,
  player_id     TEXT    NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  tier_before   TEXT    NOT NULL,
  round_index   INTEGER NOT NULL,                     -- an index in tier_before's calendar
  tier_after    TEXT    NOT NULL,
  outcome       TEXT    NOT NULL,
  reason        TEXT    NOT NULL,                     -- 'round' or 'score'
  rank          INTEGER NOT NULL DEFAULT 0,
  group_size    INTEGER NOT NULL DEFAULT 0,
  round_score   INTEGER NOT NULL DEFAULT 0,
  tier_points   INTEGER NOT NULL DEFAULT 0,           -- the value BEFORE any reset, like the stub
  best_level_id TEXT,                                 -- NULL means best_game is {}
  best_score    INTEGER,
  seen          INTEGER NOT NULL DEFAULT 0,
  seen_at       INTEGER,
  created_at    INTEGER NOT NULL,
  CHECK (seen IN (0, 1)),
  CHECK (reason IN ('round', 'score')),
  CHECK (outcome IN ('promoted', 'stayed', 'relegated', 'inactive_frozen', 'inactive_relegated'))
) STRICT;
-- Makes the closer idempotent: a re-run's INSERT ... ON CONFLICT DO NOTHING is a no-op.
CREATE UNIQUE INDEX round_summaries_once ON round_summaries (player_id, tier_before, round_index, reason);
CREATE INDEX round_summaries_pending ON round_summaries (player_id, created_at DESC) WHERE seen = 0;

-- ----------------------------------------------------------------- friends

CREATE TABLE friends (                                -- directed: player_id follows friend_id
  player_id  TEXT    NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  friend_id  TEXT    NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,                        -- friend_since
  PRIMARY KEY (player_id, friend_id),
  CHECK (player_id <> friend_id)
) STRICT;
-- Reverse cascade when the followed player deletes their account.
CREATE INDEX friends_reverse ON friends (friend_id, player_id);

-- -------------------------------------------------------------- anti-cheat

CREATE TABLE player_flags (                           -- append-only audit log
  id          TEXT    NOT NULL PRIMARY KEY,
  player_id   TEXT    NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  signal      TEXT    NOT NULL,
  weight      REAL    NOT NULL,
  result_id   TEXT,                                   -- no FK: a flag outlives result retention
  session_id  TEXT,
  detail_json TEXT,
  created_at  INTEGER NOT NULL
) STRICT;
CREATE INDEX player_flags_player ON player_flags (player_id, created_at DESC);
CREATE INDEX player_flags_created ON player_flags (created_at);

-- ------------------------------------------------------------- rate limits

CREATE TABLE rate_counters (                          -- daily DB counters; the hourly buckets live in memory
  key   TEXT    NOT NULL,                             -- 'p:<player_id>:results' | 'ip:<ip>:register' ...
  day   INTEGER NOT NULL,                             -- now / 86400
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (key, day)
) STRICT;
CREATE INDEX rate_counters_day ON rate_counters (day);
