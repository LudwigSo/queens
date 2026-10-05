-- 0002_league_rework.sql -- games that do not count, and friend-aware groups.
--
-- Diamond and Challenger count a game only when it was played online: started
-- with a session and synced within league.json's online_grace_s. A game that
-- misses that is still stored -- it is the player's history, it can still set a
-- level best when it is verified -- but it never enters a round score.
ALTER TABLE results ADD COLUMN counted INTEGER NOT NULL DEFAULT 1 CHECK (counted IN (0, 1));

-- Friend-aware placement asks "which open groups of this round hold someone I
-- follow or who follows me". league_members has no index that starts with the
-- player and reaches the round; this one does.
CREATE INDEX league_members_player_round ON league_members (player_id, tier, round_index, group_id);
