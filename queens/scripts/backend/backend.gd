class_name Backend
extends Node
## Contract between the game and the online part: identity, results,
## per-level leaderboards, the league and friends.
##
## Every call returns {"ok": bool, "data": ..., "error": String}. Callers
## always `await` the call so a networked implementation can be a
## coroutine while LocalBackend answers synchronously. A Node so that an
## HTTP implementation can own request nodes.
##
## A failure from HttpBackend adds `code` (the ERR_* key), `status`,
## `permanent` and `params`. Read calls also put the last known value, or an
## empty shape, in `data`, so a screen that indexes ["data"] without checking
## ["ok"] keeps working offline.
##
## Record shapes (all Dictionaries):
##   PlayerProfile   {player_id, nickname, friend_code, tier, tier_points,
##                    created_at, stats}
##   ScoreBreakdown  see Scoring.breakdown()
##   LeaderboardEntry {rank, player_id, nickname, score, time_seconds,
##                    wrong_placements, achieved_at, is_me, is_friend}
##   LeagueGroup     {group_id, tier, round_index, size, promote_count,
##                    relegate_count, members: [member + rank + zone]}
##   LeagueStanding  {tier, round_index, round_days, round_ends_at,
##                    joined, group, my_rank, my_round_score, my_games, zone,
##                    my_tier_points, rules}
##                    rules: {up_pct, down_pct, up_count, up_mode, promo_score,
##                    up_to, best_n, round_mode, round_days, global, floor,
##                    online_required, online_grace_s}
##                    round_days 0 (Bronze, Silver): no timer and no group;
##                    round_ends_at is 0 and joined stays false.
##                    `up_to` is a tier *id*. Names and rule sentences are
##                    presentation: Views builds them, because a server has no
##                    locale and must not carry a copy of the translations.
##   RoundSummary    {round_index, tier_before, tier_after, outcome, reason,
##                    rank, group_size, round_score, tier_points, best_game,
##                    seen, join_options}; reason "round" (a round ended) or
##                    "score" (the tier points reached promo_score);
##                    join_options counts the friends' groups the player could
##                    join in the new tier (get_join_options)
##   RoundRuns       {tier, round_index, has_rounds, round_ends_at, best_n,
##                    round_score, tier_points, cut_score, runs: [Run]}
##   Run             {result_id, level_id, size, difficulty, stars, score,
##                    counted, in_best, verified, finished_at, elapsed_seconds,
##                    par_seconds, wrong_placements, hint_count, breakdown,
##                    pending}; best first. `counted` false: the game missed
##                    the online rule. `pending`: played offline, not synced.
##   JoinOptions     {tier, round_index, joined, options: [{group_id, members,
##                    friends: [{player_id, nickname}]}]}
##   FriendEntry     {player_id, nickname, tier, round_score, friend_since,
##                    friend_code}; following is directed (I follow you), with
##                    no accept step, and is capped per player.
##   LevelBoard      {id, position, size, regions, solution, difficulty,
##                    stars, seed}: a downloadable level, in the shape of
##                    res://levels/queens.json (see LevelSync)
##   LevelState      {last_started_at, plays, completions, last_completed_at,
##                    best_time, best_score, best_score_time, best_wrong,
##                    best_result_id, best_at}: the server's copy of a save.json
##                    `levels` entry, which it derives from accepted results
##
## A round is the scoring period of a tier (a week; Bronze and Silver have
## none, see LeagueRules). Round indices are only comparable within one tier.
## Tier points are the sum of every counted game's score since the player
## entered the tier; they restart at 0 with every tier change.
##
## Connectivity: is_online() is false from the first request that could not
## reach the server until the next one that does, and connectivity_changed
## fires on every flip. The offline stub is always online, unless a test sets
## simulate_offline.

signal standing_changed
signal connectivity_changed(online: bool)

## The server's bound on get_levels (service.MaxLevelsPerRequest).
const MAX_LEVELS_PER_REQUEST := 50

var _online := true


func is_online() -> bool:
	return _online


## True once the server knows this player. A player who installed the game
## offline is not, and registers when the connection comes back.
func is_registered() -> bool:
	return true


func _set_online(online: bool) -> void:
	if online == _online:
		return
	_online = online
	connectivity_changed.emit(online)


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


## Called when a game starts; joins the open round's league group lazily.
func start_game(_level_id: String) -> Dictionary:
	return fail("not implemented")


## Idempotent per result_id. Returns {breakdown, round_score, group_rank,
## group_size, zone, tier, round_index, tier_points, promo_score,
## promoted_to}; `promoted_to` is the id of the new tier when this game
## reached the tier's promo_score, else "".
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


## The latest unseen RoundSummary, or {} when there is none.
func get_round_summary() -> Dictionary:
	return fail("not implemented")


func ack_round_summary(_round_index: int) -> Dictionary:
	return fail("not implemented")


## The games of the current round, best first (see RoundRuns).
func get_round_runs() -> Dictionary:
	return fail("not implemented")


## Friends' groups of the current round that still have room (JoinOptions).
func get_join_options() -> Dictionary:
	return fail("not implemented")


## Joins the current round now: into `group_id` from get_join_options, or by
## the normal placement when it is "". Returns the new LeagueStanding.
func join_group(_group_id: String) -> Dictionary:
	return fail("not implemented")


func get_friends() -> Dictionary:
	return fail("not implemented")


func add_friend(_code: String) -> Dictionary:
	return fail("not implemented")


func remove_friend(_player_id: String) -> Dictionary:
	return fail("not implemented")


## Erases the account on the server. There is no recovery: the credential
## lives on this device only.
func delete_account() -> Dictionary:
	return fail("not implemented")


## How many levels the server publishes. Levels are append-only, so the same
## count as the device's means the same set (LevelSync).
func get_level_count() -> Dictionary:
	return fail("not implemented")


## Every published level id, in game order.
func get_level_ids() -> Dictionary:
	return fail("not implemented")


## The LevelBoards among `ids` (at most MAX_LEVELS_PER_REQUEST), in game
## order; unknown ids are left out.
func get_levels(_ids: Array) -> Dictionary:
	return fail("not implemented")


## level id -> LevelState for every level the player ever started, or null
## when there is no server to hold them (then the save file is the truth).
func get_level_states() -> Dictionary:
	return fail("not implemented")
