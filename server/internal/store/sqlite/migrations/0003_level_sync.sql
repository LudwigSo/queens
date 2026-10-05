-- 0003_level_sync.sql -- levels delivered by the server, and per-level state per
-- player held by the server.
--
-- Levels became append-only data that clients download (GET /v1/levels/...).
-- `position` is their order on the client: 1, 2, ... in import order. 0 means
-- "never published": a row dropped from the file before imports became
-- additive. levelset.Import numbers the existing rows in file order on the first
-- boot after this migration, which reproduces the order bundled in the APK.
ALTER TABLE levels ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
CREATE INDEX levels_position ON levels (position, id);

-- player_levels grows from "cooldown anchor" into the player's whole state on a
-- level, mirroring the `levels` entry of the client's save.json. The server is
-- the source of truth; the client caches it and replays its unsent results on
-- top. Every column is defaulted so binary N-1 keeps working against this schema.
ALTER TABLE player_levels ADD COLUMN completions       INTEGER NOT NULL DEFAULT 0;
ALTER TABLE player_levels ADD COLUMN last_completed_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE player_levels ADD COLUMN best_time         REAL    NOT NULL DEFAULT 0;   -- fastest completed run; 0 = none
ALTER TABLE player_levels ADD COLUMN best_score        INTEGER NOT NULL DEFAULT 0;   -- best run: score DESC, wrong ASC, time ASC
ALTER TABLE player_levels ADD COLUMN best_score_time   REAL    NOT NULL DEFAULT 0;
ALTER TABLE player_levels ADD COLUMN best_wrong        INTEGER NOT NULL DEFAULT 0;
ALTER TABLE player_levels ADD COLUMN best_result_id    TEXT    NOT NULL DEFAULT '';
ALTER TABLE player_levels ADD COLUMN best_at           INTEGER NOT NULL DEFAULT 0;

-- Backfill from the results already stored. ----------------------------------

-- A game played offline never went through POST /games, so it has no row and
-- no play counted. verified = 0 marks exactly those (session_id alone would
-- not: the sweeper nulls it once a session is old).
INSERT OR IGNORE INTO player_levels (player_id, level_id, last_started_at, plays)
SELECT player_id, level_id, 0, 0 FROM results GROUP BY player_id, level_id;

UPDATE player_levels
   SET plays = plays + agg.offline,
       last_started_at = MAX(last_started_at, agg.last_offline_start)
  FROM (SELECT player_id, level_id,
               SUM(CASE WHEN verified = 0 THEN 1 ELSE 0 END) AS offline,
               MAX(CASE WHEN verified = 0 THEN started_at ELSE 0 END) AS last_offline_start
          FROM results GROUP BY player_id, level_id) AS agg
 WHERE player_levels.player_id = agg.player_id AND player_levels.level_id = agg.level_id;

UPDATE player_levels
   SET completions = agg.n, last_completed_at = agg.last_done, best_time = agg.fastest
  FROM (SELECT player_id, level_id, COUNT(*) AS n, MAX(finished_at) AS last_done,
               MIN(elapsed_seconds) AS fastest
          FROM results WHERE completed = 1 GROUP BY player_id, level_id) AS agg
 WHERE player_levels.player_id = agg.player_id AND player_levels.level_id = agg.level_id;

UPDATE player_levels
   SET best_score = b.score, best_score_time = b.elapsed_seconds, best_wrong = b.wrong_placements,
       best_result_id = b.result_id, best_at = b.finished_at
  FROM (SELECT player_id, level_id, score, elapsed_seconds, wrong_placements, result_id, finished_at,
               ROW_NUMBER() OVER (PARTITION BY player_id, level_id
                                  ORDER BY score DESC, wrong_placements ASC, elapsed_seconds ASC,
                                           finished_at ASC, result_id ASC) AS rn
          FROM results WHERE completed = 1) AS b
 WHERE b.rn = 1 AND player_levels.player_id = b.player_id AND player_levels.level_id = b.level_id;
