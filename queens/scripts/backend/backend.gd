class_name Backend
extends Node
## Contract between the game and the online part: identity, results,
## per-level leaderboards, the weekly league and friends.
##
## Every call returns {"ok": bool, "data": ..., "error": String}. Callers
## always `await` the call so a networked implementation can be a
## coroutine while LocalBackend answers synchronously. A Node so that an
## HTTP implementation can own request nodes.
##
## Record shapes (all Dictionaries):
##   PlayerProfile   {player_id, nickname, friend_code, tier, created_at, stats}
##   ScoreBreakdown  see Scoring.breakdown()
##   LeaderboardEntry {rank, player_id, nickname, score, time_seconds,
##                    wrong_placements, undo_count, achieved_at, is_me, is_friend}
##   LeagueGroup     {group_id, tier, week_index, size, promote_count,
##                    relegate_count, members: [member + rank + zone]}
##   LeagueStanding  {tier, tier_name, week_index, week_ends_at, joined, group,
##                    my_rank, my_weekly_score, my_games, zone, rules, rules_text}
##   WeekSummary     {week_index, tier_before, tier_after, outcome, rank,
##                    group_size, weekly_score, best_game, seen}
##   FriendEntry     {player_id, nickname, tier, weekly_score, friend_since}

signal standing_changed


static func ok(data: Variant = null) -> Dictionary:
	return {"ok": true, "data": data, "error": ""}


static func fail(error: String) -> Dictionary:
	return {"ok": false, "data": null, "error": error}


func provider_name() -> String:
	return "none"


func init() -> Dictionary:
	return fail("not implemented")


func now_utc() -> int:
	return int(Time.get_unix_time_from_system())


func register_player(_player_id: String, _nickname: String) -> Dictionary:
	return fail("not implemented")


func set_nickname(_nickname: String) -> Dictionary:
	return fail("not implemented")


func get_profile() -> Dictionary:
	return fail("not implemented")


## Called when a game starts; joins this week's league group lazily.
func start_game(_level_id: String) -> Dictionary:
	return fail("not implemented")


## Idempotent per result_id. Returns {breakdown, weekly_score, group_rank,
## group_size, zone, tier}.
func submit_result(_result: Dictionary) -> Dictionary:
	return fail("not implemented")


## scope: "global" | "friends" | "flawless". Returns {entries, my_entry,
## my_rank, total_players, par_seconds}.
func get_level_leaderboard(_level_id: String, _scope: String = "global", _limit: int = 10) -> Dictionary:
	return fail("not implemented")


## level id -> {par_seconds}
func get_level_meta() -> Dictionary:
	return fail("not implemented")


func get_league_standing() -> Dictionary:
	return fail("not implemented")


## The latest unseen WeekSummary, or {} when there is none.
func get_week_summary() -> Dictionary:
	return fail("not implemented")


func ack_week_summary(_week_index: int) -> Dictionary:
	return fail("not implemented")


func get_friends() -> Dictionary:
	return fail("not implemented")


func add_friend(_code: String) -> Dictionary:
	return fail("not implemented")


func remove_friend(_player_id: String) -> Dictionary:
	return fail("not implemented")
