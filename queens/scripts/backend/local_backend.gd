class_name LocalBackend
extends Backend
## Offline stand-in for the server: everything lives in one JSON file under
## user://, the other players are deterministic bots and the weekly rollover
## runs on init() whenever the calendar week has moved on.
##
## Bots are anchored to the player: their per-game score is the player's
## median game score times a fixed skill (0.5..1.4), so the group always
## straddles the player. They "play" through the week, so the standings
## move even when the player does not, and everything is derived from hashes
## so it is stable across restarts.

const FORMAT := 1
const BOT_NAMES := [
	"Mira", "Jonas", "Aiko", "Luca", "Priya", "Noah", "Zara", "Elias", "Ines", "Theo",
	"Nadia", "Oskar", "Lena", "Mateo", "Sofia", "Emil", "Yara", "Finn", "Alma", "Kai",
	"Rosa", "Ivan", "Hana", "Milo", "Vera", "Arlo", "Nina", "Otto", "Suki", "Bram",
	"Cleo", "Dario", "Esme", "Faris", "Greta", "Hugo", "Ida", "Jules", "Kira", "Leo",
]
const HISTORY_CAP := 20
const ANCHOR_GAMES := 15
const ANCHOR_DEFAULT := 150
const DIAMOND_POOL := 99
const LEVEL_BOT_POOL := 50
const LEVEL_BOT_SHARE := 0.4
const CODE_ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

var config: GameConfig
var catalog: LevelCatalog
var clock: Callable
var path: String
var data: Dictionary = {}


func _init(game_config: GameConfig, level_catalog: LevelCatalog, clock_fn: Callable, file_path: String = "") -> void:
	config = game_config
	catalog = level_catalog
	clock = clock_fn
	path = file_path if file_path != "" else game_config.backend_path


func provider_name() -> String:
	return "local"


func now_utc() -> int:
	return int(clock.call())


func league_cfg() -> Dictionary:
	return config.league


# --- persistence -------------------------------------------------------------

static func defaults() -> Dictionary:
	return {
		"format": FORMAT,
		"profile": {},
		"results": {},
		"weeks": {},
		"current_week": -1,
		"friends": [],
		"pending_summary": {},
		"history": [],
	}


func init() -> Dictionary:
	data = defaults()
	if FileAccess.file_exists(path):
		var loaded := SaveData.read_json(path)
		for key in loaded:
			data[key] = loaded[key]
	_rollover()
	_save()
	return ok(get_profile()["data"])


func _save() -> void:
	var dir_path := path.get_base_dir()
	if dir_path != "" and not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("cannot write %s" % path)
		return
	f.store_string(JSON.stringify(data))
	f.close()


# --- identity ---------------------------------------------------------------

static func friend_code_for(player_id: String) -> String:
	var h := absi(hash(player_id))
	var code := ""
	for i in 6:
		code += CODE_ALPHABET[(h >> (i * 5)) & 31]
	return "QN-" + code


static func is_valid_code(code: String) -> bool:
	return RegEx.create_from_string("^QN-[A-Z2-7]{6}$").search(code) != null


func register_player(player_id: String, nickname: String) -> Dictionary:
	var profile: Dictionary = data["profile"]
	if profile.is_empty() or str(profile.get("player_id", "")) != player_id:
		data["profile"] = {
			"player_id": player_id,
			"nickname": nickname,
			"friend_code": friend_code_for(player_id),
			"tier": league_cfg()["tiers"][0]["id"],
			"created_at": now_utc(),
			"stats": {"games": 0, "flawless": 0, "best_score": 0, "weeks_played": 0},
		}
	elif nickname != "" and nickname != str(profile.get("nickname", "")):
		profile["nickname"] = nickname
	_save()
	return ok(data["profile"].duplicate(true))


func set_nickname(nickname: String) -> Dictionary:
	nickname = nickname.strip_edges()
	if nickname.length() < 2 or nickname.length() > 16:
		return fail("Nickname must be 2 to 16 characters")
	data["profile"]["nickname"] = nickname
	_save()
	return ok(data["profile"].duplicate(true))


func get_profile() -> Dictionary:
	return ok(data["profile"].duplicate(true))


func player_id() -> String:
	return str(data["profile"].get("player_id", ""))


func tier_id() -> String:
	return str(data["profile"].get("tier", league_cfg()["tiers"][0]["id"]))


# --- weeks and results ------------------------------------------------------

func current_week() -> int:
	return Scoring.week_index(now_utc())


func _week(index: int) -> Dictionary:
	var weeks: Dictionary = data["weeks"]
	var key := str(index)
	if not weeks.has(key):
		weeks[key] = {"joined": false, "group_id": "", "scores": [], "games": 0, "last_submit_at": 0, "tier": tier_id()}
	return weeks[key]


func _join(week: int) -> Dictionary:
	var wk := _week(week)
	if not wk["joined"]:
		wk["joined"] = true
		wk["tier"] = tier_id()
		wk["group_id"] = "lg_%d_%s_001" % [week, tier_id()]
		var stats: Dictionary = data["profile"]["stats"]
		stats["weeks_played"] = int(stats.get("weeks_played", 0)) + 1
	return wk


func start_game(_level_id: String) -> Dictionary:
	var week := current_week()
	var wk := _join(week)
	_save()
	standing_changed.emit()
	return ok({"week_index": week, "group_id": wk["group_id"], "joined": true})


func submit_result(result: Dictionary) -> Dictionary:
	var id := str(result.get("result_id", ""))
	if id == "":
		return fail("result_id missing")
	var results: Dictionary = data["results"]
	if results.has(id):
		return ok(results[id]["response"])
	var bd := Scoring.breakdown(result)
	var week := int(result.get("week_index", current_week()))
	if week <= 0:
		week = current_week()
	var response := {"breakdown": bd, "weekly_score": 0, "group_rank": 0, "group_size": 0, "zone": "", "tier": tier_id(), "week_index": week}
	var wk := _join(week)
	if bool(result.get("completed", false)):
		(wk["scores"] as Array).append(int(bd["score"]))
		wk["games"] = int(wk["games"]) + 1
		wk["last_submit_at"] = int(result.get("finished_at", now_utc()))
		var stats: Dictionary = data["profile"]["stats"]
		stats["games"] = int(stats.get("games", 0)) + 1
		if bd["flawless"]:
			stats["flawless"] = int(stats.get("flawless", 0)) + 1
		stats["best_score"] = maxi(int(stats.get("best_score", 0)), int(bd["score"]))
	var standing := _standing_for(week)
	response["weekly_score"] = standing["my_weekly_score"]
	response["group_rank"] = standing["my_rank"]
	response["group_size"] = standing["group"]["size"]
	response["zone"] = standing["zone"]
	results[id] = {"result": result.duplicate(true), "response": response}
	_save()
	standing_changed.emit()
	return ok(response)


## Median score of the player's last completed games; what the bots aim at.
func _anchor() -> int:
	var scores: Array = []
	var results: Dictionary = data["results"]
	var ordered: Array = results.values()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["result"].get("finished_at", 0)) > int(b["result"].get("finished_at", 0)))
	for entry in ordered:
		if bool(entry["result"].get("completed", false)):
			scores.append(int(entry["response"]["breakdown"]["score"]))
		if scores.size() >= ANCHOR_GAMES:
			break
	if scores.is_empty():
		return ANCHOR_DEFAULT
	scores.sort()
	@warning_ignore("integer_division")
	return int(scores[scores.size() / 2])


static func _hash01(key: String) -> float:
	return float(absi(hash(key)) % 10007) / 10007.0


## Weekly score of a synthetic player at `frac` of the week.
func _synthetic_weekly(seed_key: String, skill: float, games_per_week: int, frac: float, anchor: int) -> Dictionary:
	var best_n := int(league_cfg().get("weekly_best_n", 15))
	var games_so_far := mini(games_per_week, ceili(games_per_week * frac))
	var counted := mini(games_so_far, best_n) if str(league_cfg().get("weekly_mode", "best_n")) == "best_n" else games_so_far
	var noise := 0.9 + 0.2 * _hash01(seed_key + ":" + str(games_so_far))
	var score := int(round(anchor * skill * counted * noise)) if games_so_far > 0 else 0
	return {"weekly_score": score, "games": games_so_far}


func _bot(group_id: String, index: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s:%d" % [group_id, index])
	var name: String = BOT_NAMES[index % BOT_NAMES.size()]
	if index >= BOT_NAMES.size():
		@warning_ignore("integer_division")
		name += str(index / BOT_NAMES.size() + 1)
	return {
		"player_id": "bot:%s:%d" % [group_id, index],
		"nickname": name,
		"skill": 0.5 + rng.randf() * 0.9,
		"games_per_week": rng.randi_range(3, 25),
	}


func _members(week: int, at_time: int, final: bool) -> Array:
	var wk := _week(week)
	var tier := str(wk.get("tier", tier_id()))
	var group_id := str(wk.get("group_id", "lg_%d_%s_001" % [week, tier]))
	var anchor := _anchor()
	var frac := 1.0 if final else clampf(float(at_time - Scoring.week_start(week)) / Scoring.WEEK_SECONDS, 0.0, 1.0)
	var pool := DIAMOND_POOL if LeagueRules.is_global(league_cfg(), tier) else int(league_cfg().get("group_size", 30)) - 1
	var members: Array = []
	var same_tier_friends: Array = []
	for fr in data["friends"]:
		if str(fr.get("tier", "")) == tier:
			same_tier_friends.append(fr)
	for i in pool:
		var who: Dictionary
		var is_friend := false
		if i < same_tier_friends.size():
			who = same_tier_friends[i]
			is_friend = true
		else:
			who = _bot(group_id, i)
		var played := _synthetic_weekly("%s:%s" % [group_id, who["player_id"]], float(who["skill"]), int(who["games_per_week"]), frac, anchor)
		var seed_offset := absi(hash(str(who["player_id"]))) % 3600
		members.append({
			"player_id": who["player_id"],
			"nickname": who["nickname"],
			"weekly_score": played["weekly_score"],
			"games": played["games"],
			"last_submit_at": Scoring.week_start(week) + int(frac * Scoring.WEEK_SECONDS) - seed_offset,
			"is_me": false,
			"is_friend": is_friend,
			"is_bot": not is_friend,
		})
	members.append({
		"player_id": player_id(),
		"nickname": str(data["profile"].get("nickname", "")),
		"weekly_score": LeagueRules.weekly_score(wk["scores"], league_cfg()),
		"games": int(wk["games"]),
		"last_submit_at": int(wk["last_submit_at"]),
		"is_me": true,
		"is_friend": false,
		"is_bot": false,
	})
	return members


func _standing_for(week: int) -> Dictionary:
	var wk := _week(week)
	var tier := str(wk.get("tier", tier_id())) if wk["joined"] else tier_id()
	var tier_cfg := LeagueRules.tier(league_cfg(), tier)
	var standing := {
		"tier": tier,
		"tier_name": LeagueRules.tier_name(league_cfg(), tier),
		"week_index": week,
		"week_ends_at": Scoring.week_end(week),
		"joined": bool(wk["joined"]),
		"group": {},
		"my_rank": 0,
		"my_weekly_score": 0,
		"my_games": 0,
		"zone": "",
		"rules": {"up_pct": tier_cfg.get("up_pct", 0), "down_pct": tier_cfg.get("down_pct", 0),
			"best_n": league_cfg().get("weekly_best_n", 15), "weekly_mode": league_cfg().get("weekly_mode", "best_n"),
			"global": LeagueRules.is_global(league_cfg(), tier)},
		"rules_text": LeagueRules.rules_text(tier_cfg),
	}
	if not wk["joined"]:
		return standing
	var ev := LeagueRules.evaluate(_members(week, now_utc(), false), tier, league_cfg())
	var members: Array = ev["members"]
	for m in members:
		if m["is_me"]:
			standing["my_rank"] = m["rank"]
			standing["my_weekly_score"] = m["weekly_score"]
			standing["my_games"] = m["games"]
			standing["zone"] = m["zone"]
	standing["group"] = {
		"group_id": wk["group_id"],
		"tier": tier,
		"week_index": week,
		"size": members.size(),
		"promote_count": ev["promote_count"],
		"relegate_count": ev["relegate_count"],
		"members": members,
	}
	return standing


func get_league_standing() -> Dictionary:
	return ok(_standing_for(current_week()))


## Applies every finished week since the last processed one.
func _rollover() -> void:
	var current := current_week()
	if int(data.get("current_week", -1)) < 0 or data["profile"].is_empty():
		data["current_week"] = current
		return
	while int(data["current_week"]) < current:
		var w := int(data["current_week"])
		var summary := _close_week(w)
		data["pending_summary"] = summary
		var history: Array = data["history"]
		history.append(summary)
		while history.size() > HISTORY_CAP:
			history.pop_front()
		data["current_week"] = w + 1
	# Forget weeks that are no longer needed.
	var weeks: Dictionary = data["weeks"]
	for key in weeks.keys():
		if int(key) < current - 1:
			weeks.erase(key)


func _close_week(week: int) -> Dictionary:
	var weeks: Dictionary = data["weeks"]
	var wk: Dictionary = weeks.get(str(week), {})
	var tier_before := tier_id()
	var tier_cfg := LeagueRules.tier(league_cfg(), tier_before)
	var summary := {
		"week_index": week, "tier_before": tier_before, "tier_after": tier_before,
		"outcome": LeagueRules.OUTCOME_STAYED, "rank": 0, "group_size": 0, "weekly_score": 0,
		"best_game": {}, "seen": false,
	}
	if wk.is_empty() or not bool(wk.get("joined", false)):
		summary["outcome"] = LeagueRules.inactive_outcome(tier_cfg)
	else:
		var ev := LeagueRules.evaluate(_members(week, Scoring.week_end(week), true), tier_before, league_cfg())
		for m in ev["members"]:
			if m["is_me"]:
				summary["outcome"] = LeagueRules.outcome_for_zone(m["zone"])
				summary["rank"] = m["rank"]
				summary["weekly_score"] = m["weekly_score"]
		summary["group_size"] = (ev["members"] as Array).size()
		summary["best_game"] = _best_game_of_week(week)
	summary["tier_after"] = LeagueRules.apply(league_cfg(), tier_before, summary["outcome"])
	data["profile"]["tier"] = summary["tier_after"]
	return summary


func _best_game_of_week(week: int) -> Dictionary:
	var best := {}
	for entry in data["results"].values():
		var r: Dictionary = entry["result"]
		if int(r.get("week_index", -1)) != week or not bool(r.get("completed", false)):
			continue
		var score := int(entry["response"]["breakdown"]["score"])
		if best.is_empty() or score > int(best["score"]):
			best = {"level_id": r.get("level_id", ""), "score": score}
	return best


func get_week_summary() -> Dictionary:
	return ok((data["pending_summary"] as Dictionary).duplicate(true))


func ack_week_summary(week_index: int) -> Dictionary:
	var pending: Dictionary = data["pending_summary"]
	if not pending.is_empty() and int(pending.get("week_index", -1)) == week_index:
		pending["seen"] = true
		data["pending_summary"] = {}
		_save()
	return ok(null)


# --- level leaderboards -----------------------------------------------------

func get_level_meta() -> Dictionary:
	var meta := {}
	for lv in catalog.levels:
		meta[lv["id"]] = {"par_seconds": Scoring.par_seconds(float(lv["difficulty"]), int(lv["size"]))}
	return ok(meta)


func _my_level_best(level_id: String) -> Dictionary:
	var best := {}
	for entry in data["results"].values():
		var r: Dictionary = entry["result"]
		if str(r.get("level_id", "")) != level_id or not bool(r.get("completed", false)):
			continue
		var candidate := _entry_from_result(r, int(entry["response"]["breakdown"]["score"]))
		if best.is_empty() or _entry_before(candidate, best):
			best = candidate
	return best


func _entry_from_result(r: Dictionary, score: int) -> Dictionary:
	return {
		"rank": 0, "player_id": player_id(), "nickname": str(data["profile"].get("nickname", "")),
		"score": score, "time_seconds": float(r.get("elapsed_seconds", 0.0)),
		"wrong_placements": int(r.get("wrong_placements", 0)), "undo_count": int(r.get("undo_count", 0)),
		"achieved_at": int(r.get("finished_at", 0)), "is_me": true, "is_friend": false,
	}


static func _entry_before(a: Dictionary, b: Dictionary) -> bool:
	if int(a["score"]) != int(b["score"]):
		return int(a["score"]) > int(b["score"])
	if int(a["wrong_placements"]) != int(b["wrong_placements"]):
		return int(a["wrong_placements"]) < int(b["wrong_placements"])
	if float(a["time_seconds"]) != float(b["time_seconds"]):
		return float(a["time_seconds"]) < float(b["time_seconds"])
	return int(a["achieved_at"]) < int(b["achieved_at"])


static func _entry_faster(a: Dictionary, b: Dictionary) -> bool:
	if float(a["time_seconds"]) != float(b["time_seconds"]):
		return float(a["time_seconds"]) < float(b["time_seconds"])
	return int(a["achieved_at"]) < int(b["achieved_at"])


func _synthetic_level_entry(level: Dictionary, key: String, who_id: String, nickname: String, skill: float, is_friend: bool) -> Dictionary:
	var base := Scoring.base(float(level["difficulty"]), int(level["size"]))
	var par := Scoring.par_seconds(float(level["difficulty"]), int(level["size"]))
	var quality := clampf(skill * (0.7 + 0.6 * _hash01(key + ":q")), 0.3, 1.25)
	var wrong := 0 if _hash01(key + ":w") < 0.45 else 1 + int(_hash01(key + ":w2") * 3)
	var time := par * clampf(1.7 - 1.0 * quality, 0.55, 2.5)
	var score := int(round(base * Scoring.accuracy_factor(wrong) * Scoring.speed_factor(time, par)))
	return {
		"rank": 0, "player_id": who_id, "nickname": nickname, "score": score, "time_seconds": snappedf(time, 0.1),
		"wrong_placements": wrong, "undo_count": int(_hash01(key + ":u") * 4),
		"achieved_at": now_utc() - int(_hash01(key + ":t") * 30 * 86400), "is_me": false, "is_friend": is_friend,
	}


func get_level_leaderboard(level_id: String, scope: String = "global", limit: int = 10) -> Dictionary:
	var level := catalog.get_level(level_id)
	if level.is_empty():
		return fail("unknown level")
	var entries: Array = []
	if scope != "friends":
		for i in LEVEL_BOT_POOL:
			var key := "lvl:%s:%d" % [level_id, i]
			if _hash01(key) >= LEVEL_BOT_SHARE:
				continue
			var name: String = BOT_NAMES[i % BOT_NAMES.size()] + ("" if i < BOT_NAMES.size() else "2")
			entries.append(_synthetic_level_entry(level, key, "bot:lvl:%d" % i, name, 0.5 + 0.9 * _hash01(key + ":s"), false))
	for fr in data["friends"]:
		var key := "lvl:%s:%s" % [level_id, fr["player_id"]]
		if _hash01(key) < 0.6:
			entries.append(_synthetic_level_entry(level, key, fr["player_id"], fr["nickname"], float(fr["skill"]), true))
	var mine := _my_level_best(level_id)
	if not mine.is_empty():
		entries.append(mine)
	if scope == "flawless":
		entries = entries.filter(func(e: Dictionary) -> bool: return int(e["wrong_placements"]) == 0)
		entries.sort_custom(_entry_faster)
	else:
		entries.sort_custom(_entry_before)
	var my_rank := 0
	for i in entries.size():
		entries[i]["rank"] = i + 1
		if entries[i]["is_me"]:
			my_rank = i + 1
	return ok({
		"entries": entries.slice(0, limit),
		"my_entry": mine,
		"my_rank": my_rank,
		"total_players": entries.size(),
		"par_seconds": Scoring.par_seconds(float(level["difficulty"]), int(level["size"])),
	})


# --- friends ----------------------------------------------------------------

func _friend_view(fr: Dictionary) -> Dictionary:
	var week := current_week()
	var frac := clampf(float(now_utc() - Scoring.week_start(week)) / Scoring.WEEK_SECONDS, 0.0, 1.0)
	var played := _synthetic_weekly("friend:%d:%s" % [week, fr["player_id"]], float(fr["skill"]), int(fr["games_per_week"]), frac, _anchor())
	return {
		"player_id": fr["player_id"], "nickname": fr["nickname"], "tier": fr["tier"],
		"tier_name": LeagueRules.tier_name(league_cfg(), str(fr["tier"])),
		"weekly_score": played["weekly_score"], "friend_since": fr["friend_since"], "friend_code": fr["friend_code"],
	}


func get_friends() -> Dictionary:
	var views: Array = []
	for fr in data["friends"]:
		views.append(_friend_view(fr))
	return ok(views)


func add_friend(code: String) -> Dictionary:
	code = code.strip_edges().to_upper()
	if not is_valid_code(code):
		return fail("A friend code looks like QN-ABC234")
	if code == str(data["profile"].get("friend_code", "")):
		return fail("That is your own code")
	for fr in data["friends"]:
		if fr["friend_code"] == code:
			return fail("Already friends")
	var tiers: Array = league_cfg()["tiers"]
	var fr := {
		"player_id": "friend:" + code,
		"nickname": "Player-" + code.substr(3, 4),
		"tier": tiers[absi(hash(code + ":tier")) % tiers.size()]["id"],
		"friend_code": code,
		"friend_since": now_utc(),
		"skill": 0.6 + 0.8 * _hash01(code + ":skill"),
		"games_per_week": 5 + absi(hash(code + ":games")) % 15,
	}
	(data["friends"] as Array).append(fr)
	_save()
	standing_changed.emit()
	return ok(_friend_view(fr))


func remove_friend(friend_id: String) -> Dictionary:
	var friends: Array = data["friends"]
	for i in friends.size():
		if friends[i]["player_id"] == friend_id:
			friends.remove_at(i)
			_save()
			standing_changed.emit()
			return ok(null)
	return fail("Not a friend")
