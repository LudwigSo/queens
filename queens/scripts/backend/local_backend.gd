class_name LocalBackend
extends Backend
## Offline stand-in for the server: everything lives in one JSON file under
## user://, the other players are deterministic bots and the round rollover
## runs on init() whenever the player's current round has ended.
##
## Bots are anchored to the player: their per-game score is the player's
## median game score times a fixed skill (0.5..1.4), so the group always
## straddles the player. They "play" through the round, so the standings
## move even when the player does not, and everything is derived from hashes
## so it is stable across restarts.
##
## The global tiers are simulated as populations: Diamond starts at
## DIAMOND_BASE players and grows by DIAMOND_GROWTH_PER_WEEK every calendar
## week since LAUNCH_WEEK, Challenger is always full at its slot count, so
## the Challenger slots (and with them the Diamond promotions) grow slowly.

const FORMAT := 3
const BOT_NAMES := [
	"Mira", "Jonas", "Aiko", "Luca", "Priya", "Noah", "Zara", "Elias", "Ines", "Theo",
	"Nadia", "Oskar", "Lena", "Mateo", "Sofia", "Emil", "Yara", "Finn", "Alma", "Kai",
	"Rosa", "Ivan", "Hana", "Milo", "Vera", "Arlo", "Nina", "Otto", "Suki", "Bram",
	"Cleo", "Dario", "Esme", "Faris", "Greta", "Hugo", "Ida", "Jules", "Kira", "Leo",
]
const HISTORY_CAP := 20
const ANCHOR_GAMES := 15
const ANCHOR_DEFAULT := 150
const DIAMOND_BASE := 60
const DIAMOND_GROWTH_PER_WEEK := 3
const DIAMOND_MAX := 1000
const LAUNCH_WEEK := 2957   ## calendar week of Monday 2026-09-07
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
		"rounds": {},
		"current_round": -1,
		"friends": [],
		"pending_summary": {},
		"history": [],
	}


func init() -> Dictionary:
	data = defaults()
	if FileAccess.file_exists(path):
		var loaded := SaveData.read_json(path)
		var format := int(loaded.get("format", 1))
		if format < 2:
			# Format 2 replaced calendar weeks with per-tier rounds: the open
			# week and the old summaries are dropped, profile and results stay.
			for key in ["weeks", "current_week", "pending_summary", "history"]:
				loaded.erase(key)
		if format < 3 and not (loaded.get("profile", {}) as Dictionary).is_empty():
			# Format 3 added the tier points counter.
			loaded["profile"]["tier_points"] = int(loaded["profile"].get("tier_points", 0))
		loaded["format"] = FORMAT
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
			"tier_points": 0,
			"created_at": now_utc(),
			"stats": {"games": 0, "flawless": 0, "best_score": 0, "rounds_played": 0},
		}
	elif nickname != "" and nickname != str(profile.get("nickname", "")):
		profile["nickname"] = nickname
	_save()
	return ok(data["profile"].duplicate(true))


func set_nickname(nickname: String) -> Dictionary:
	nickname = nickname.strip_edges()
	if nickname.length() < 2 or nickname.length() > 16:
		return fail(Loc.t("ERR_NICKNAME_LENGTH"))
	data["profile"]["nickname"] = nickname
	_save()
	return ok(data["profile"].duplicate(true))


func get_profile() -> Dictionary:
	return ok(data["profile"].duplicate(true))


func player_id() -> String:
	return str(data["profile"].get("player_id", ""))


func tier_id() -> String:
	return str(data["profile"].get("tier", league_cfg()["tiers"][0]["id"]))


## Sum of every solved game's score since the player entered the tier.
func tier_points() -> int:
	return int(data["profile"].get("tier_points", 0))


## Moves the player; the tier points restart with a new tier.
func _set_tier(new_tier: String) -> void:
	if new_tier != tier_id():
		data["profile"]["tier_points"] = 0
	data["profile"]["tier"] = new_tier


func _record_summary(summary: Dictionary) -> void:
	data["pending_summary"] = summary
	var history: Array = data["history"]
	history.append(summary)
	while history.size() > HISTORY_CAP:
		history.pop_front()


# --- rounds and results -----------------------------------------------------

## Index of the round of the player's tier that is open right now.
func current_round() -> int:
	return LeagueRules.round_index(league_cfg(), tier_id(), now_utc())


static func _round_key(tier: String, index: int) -> String:
	return "%s:%d" % [tier, index]


func _round(index: int, tier: String = "") -> Dictionary:
	if tier == "":
		tier = tier_id()
	var rounds: Dictionary = data["rounds"]
	var key := _round_key(tier, index)
	if not rounds.has(key):
		rounds[key] = {"joined": false, "group_id": "", "scores": [], "games": 0, "last_submit_at": 0, "tier": tier, "index": index}
	return rounds[key]


func _join(index: int) -> Dictionary:
	var rd := _round(index)
	if not rd["joined"]:
		rd["joined"] = true
		rd["group_id"] = "lg_%s_%d_001" % [tier_id(), index]
		var stats: Dictionary = data["profile"]["stats"]
		stats["rounds_played"] = int(stats.get("rounds_played", 0)) + 1
	return rd


func start_game(_level_id: String) -> Dictionary:
	var index := current_round()
	var rd := _join(index)
	_save()
	standing_changed.emit()
	return ok({"round_index": index, "group_id": rd["group_id"], "joined": true})


func submit_result(result: Dictionary) -> Dictionary:
	var id := str(result.get("result_id", ""))
	if id == "":
		return fail("result_id missing")
	var results: Dictionary = data["results"]
	if results.has(id):
		return ok(results[id]["response"])
	var bd := Scoring.breakdown(result)
	# A game finished in a round that has already closed still counts, in the open round.
	var finished := int(result.get("finished_at", now_utc()))
	var index := maxi(current_round(), LeagueRules.round_index(league_cfg(), tier_id(), finished))
	var completed := bool(result.get("completed", false))
	var response := {"breakdown": bd, "round_score": 0, "group_rank": 0, "group_size": 0, "zone": "", "tier": tier_id(), "round_index": index,
		"tier_points": 0, "promo_score": 0, "promoted_to": ""}
	var rd := _join(index)
	if completed:
		(rd["scores"] as Array).append(int(bd["score"]))
		rd["games"] = int(rd["games"]) + 1
		rd["last_submit_at"] = finished
		var stats: Dictionary = data["profile"]["stats"]
		stats["games"] = int(stats.get("games", 0)) + 1
		if bd["flawless"]:
			stats["flawless"] = int(stats.get("flawless", 0)) + 1
		stats["best_score"] = maxi(int(stats.get("best_score", 0)), int(bd["score"]))
		data["profile"]["tier_points"] = tier_points() + int(bd["score"])
	var standing := _standing_for(index)
	response["round_score"] = standing["my_round_score"]
	response["group_rank"] = standing["my_rank"]
	response["group_size"] = standing["group"]["size"]
	response["zone"] = standing["zone"]
	response["tier_points"] = tier_points()
	response["promo_score"] = int(standing["rules"]["promo_score"])
	if completed and LeagueRules.reaches_promo(LeagueRules.tier(league_cfg(), tier_id()), tier_points()):
		response["promoted_to"] = _promote_by_score(index, standing)
	results[id] = {"result": result.duplicate(true), "response": response}
	_save()
	standing_changed.emit()
	return ok(response)


## The tier points reached the tier's promo_score: the player moves up right
## now and joins the round of the new tier that is already running. The
## abandoned round is forgotten; the summary shows the final standing in it.
## Returns the new tier id, or "" when there is no tier above.
func _promote_by_score(index: int, standing: Dictionary) -> String:
	var cfg := league_cfg()
	var tier := tier_id()
	var above := LeagueRules.promote_tier(cfg, tier)
	if above == tier:
		return ""
	var summary := {
		"round_index": index, "tier_before": tier, "tier_after": above,
		"outcome": LeagueRules.OUTCOME_PROMOTED, "reason": "score",
		"rank": int(standing["my_rank"]), "group_size": int(standing["group"].get("size", 0)),
		"round_score": int(standing["my_round_score"]), "tier_points": tier_points(),
		"best_game": _best_game_between(LeagueRules.round_start(cfg, tier, index), LeagueRules.round_end(cfg, tier, index)),
		"seen": false,
	}
	_record_summary(summary)
	_set_tier(above)
	data["current_round"] = LeagueRules.round_index(cfg, above, now_utc())
	var rounds: Dictionary = data["rounds"]
	var keep := _round_key(above, int(data["current_round"]))
	for key in rounds.keys():
		if key != keep:
			rounds.erase(key)
	return above


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


## Round score of a synthetic player at `frac` of a round of `days` days,
## given how many games it plays in a full week.
func _synthetic_round(seed_key: String, skill: float, games_per_week: int, frac: float, anchor: int, days: int) -> Dictionary:
	var best_n := int(league_cfg().get("round_best_n", 15))
	var games_in_round := maxi(1, ceili(games_per_week * days / 7.0))
	var games_so_far := mini(games_in_round, ceili(games_in_round * frac))
	var counted := mini(games_so_far, best_n) if str(league_cfg().get("round_mode", "best_n")) == "best_n" else games_so_far
	var noise := 0.9 + 0.2 * _hash01(seed_key + ":" + str(games_so_far))
	var score := int(round(anchor * skill * counted * noise)) if games_so_far > 0 else 0
	return {"round_score": score, "games": games_so_far}


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


## Simulated Diamond population: grows a little every calendar week.
func _diamond_players(at_time: int) -> int:
	var weeks_live := maxi(0, Scoring.week_index(at_time) - LAUNCH_WEEK)
	return mini(DIAMOND_BASE + DIAMOND_GROWTH_PER_WEEK * weeks_live, DIAMOND_MAX)


## Players in the standing of `tier` (me included): the group size, the
## Diamond population for the global tier, every slot for the capped tier.
func _population(tier: String, at_time: int) -> int:
	var cfg := league_cfg()
	if LeagueRules.is_capped(cfg, tier):
		return LeagueRules.slots(cfg, tier, _population(LeagueRules.relegate_tier(cfg, tier), at_time))
	if LeagueRules.is_global(cfg, tier):
		return _diamond_players(at_time)
	return int(cfg.get("group_size", 30))


## Fixed number of promotions for a tier that feeds a capped tier, else -1.
func _up_count(tier: String, at_time: int) -> int:
	var cfg := league_cfg()
	if LeagueRules.up_mode(cfg, tier) != LeagueRules.UP_MODE_OPENINGS:
		return -1
	var above := LeagueRules.promote_tier(cfg, tier)
	return LeagueRules.openings(cfg, above, _population(tier, at_time), _population(above, at_time))


func _members(index: int, at_time: int, final: bool) -> Array:
	var cfg := league_cfg()
	var rd := _round(index)
	var tier := str(rd.get("tier", tier_id()))
	var group_id := str(rd.get("group_id", "lg_%s_%d_001" % [tier, index]))
	var anchor := _anchor()
	var days := LeagueRules.round_days(cfg, tier)
	var starts := LeagueRules.round_start(cfg, tier, index)
	var length := LeagueRules.round_seconds(cfg, tier)
	var frac := 1.0 if final else clampf(float(at_time - starts) / length, 0.0, 1.0)
	var pool := _population(tier, at_time) - 1
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
		var played := _synthetic_round("%s:%s" % [group_id, who["player_id"]], float(who["skill"]), int(who["games_per_week"]), frac, anchor, days)
		var seed_offset := absi(hash(str(who["player_id"]))) % 3600
		members.append({
			"player_id": who["player_id"],
			"nickname": who["nickname"],
			"round_score": played["round_score"],
			"games": played["games"],
			"last_submit_at": starts + int(frac * length) - seed_offset,
			"is_me": false,
			"is_friend": is_friend,
			"is_bot": not is_friend,
		})
	members.append({
		"player_id": player_id(),
		"nickname": str(data["profile"].get("nickname", "")),
		"round_score": LeagueRules.round_score(rd["scores"], cfg),
		"games": int(rd["games"]),
		"last_submit_at": int(rd["last_submit_at"]),
		"is_me": true,
		"is_friend": false,
		"is_bot": false,
	})
	return members


func _standing_for(index: int) -> Dictionary:
	var cfg := league_cfg()
	var rd := _round(index)
	var tier := str(rd.get("tier", tier_id())) if rd["joined"] else tier_id()
	var tier_cfg := LeagueRules.tier(cfg, tier)
	var up_count := _up_count(tier, now_utc())
	var above := LeagueRules.promote_tier(cfg, tier)
	var standing := {
		"tier": tier,
		"tier_name": LeagueRules.tier_name(cfg, tier),
		"round_index": index,
		"round_days": LeagueRules.round_days(cfg, tier),
		"round_ends_at": LeagueRules.round_end(cfg, tier, index),
		"joined": bool(rd["joined"]),
		"group": {},
		"my_rank": 0,
		"my_round_score": 0,
		"my_games": 0,
		"zone": "",
		"my_tier_points": tier_points(),
		"rules": {"up_pct": tier_cfg.get("up_pct", 0), "down_pct": tier_cfg.get("down_pct", 0), "up_count": up_count,
			"up_mode": LeagueRules.up_mode(cfg, tier), "promo_score": LeagueRules.promo_score(tier_cfg),
			"up_to": LeagueRules.tier_name(cfg, above) if above != tier else "",
			"best_n": cfg.get("round_best_n", 15), "round_mode": cfg.get("round_mode", "best_n"),
			"round_days": LeagueRules.round_days(cfg, tier),
			"global": LeagueRules.is_global(cfg, tier), "floor": LeagueRules.is_floor(cfg, tier)},
		"rules_text": LeagueRules.rules_text(tier_cfg, up_count, LeagueRules.tier_name(cfg, above) if above != tier else ""),
	}
	if not rd["joined"]:
		return standing
	var ev := LeagueRules.evaluate(_members(index, now_utc(), false), tier, cfg, up_count)
	var members: Array = ev["members"]
	for m in members:
		if m["is_me"]:
			standing["my_rank"] = m["rank"]
			standing["my_round_score"] = m["round_score"]
			standing["my_games"] = m["games"]
			standing["zone"] = m["zone"]
	standing["group"] = {
		"group_id": rd["group_id"],
		"tier": tier,
		"round_index": index,
		"size": members.size(),
		"promote_count": ev["promote_count"],
		"relegate_count": ev["relegate_count"],
		"members": members,
	}
	return standing


func get_league_standing() -> Dictionary:
	return ok(_standing_for(current_round()))


## Closes every round that has ended since the last processed one. A tier
## change moves the player into the round of the new tier that contains the
## boundary, so a promotion out of a 3-day Bronze round joins the running
## Silver week.
func _rollover() -> void:
	var cfg := league_cfg()
	if int(data.get("current_round", -1)) < 0 or data["profile"].is_empty():
		data["current_round"] = current_round()
		return
	while true:
		var tier := tier_id()
		var index := int(data["current_round"])
		var ends := LeagueRules.round_end(cfg, tier, index)
		if ends > now_utc():
			break
		_record_summary(_close_round(tier, index))
		data["current_round"] = LeagueRules.round_index(cfg, tier_id(), ends)
	# Forget rounds that are no longer open.
	var rounds: Dictionary = data["rounds"]
	var open_key := _round_key(tier_id(), int(data["current_round"]))
	for key in rounds.keys():
		if key != open_key:
			rounds.erase(key)


func _close_round(tier: String, index: int) -> Dictionary:
	var cfg := league_cfg()
	var rd: Dictionary = (data["rounds"] as Dictionary).get(_round_key(tier, index), {})
	var tier_cfg := LeagueRules.tier(cfg, tier)
	var ends := LeagueRules.round_end(cfg, tier, index)
	var summary := {
		"round_index": index, "tier_before": tier, "tier_after": tier,
		"outcome": LeagueRules.OUTCOME_STAYED, "reason": "round", "rank": 0, "group_size": 0, "round_score": 0,
		"tier_points": tier_points(), "best_game": {}, "seen": false,
	}
	if rd.is_empty() or not bool(rd.get("joined", false)):
		summary["outcome"] = LeagueRules.inactive_outcome(tier_cfg)
	else:
		var ev := LeagueRules.evaluate(_members(index, ends, true), tier, cfg, _up_count(tier, ends))
		for m in ev["members"]:
			if m["is_me"]:
				summary["outcome"] = LeagueRules.outcome_for_zone(m["zone"])
				summary["rank"] = m["rank"]
				summary["round_score"] = m["round_score"]
		summary["group_size"] = (ev["members"] as Array).size()
		summary["best_game"] = _best_game_between(LeagueRules.round_start(cfg, tier, index), ends)
	summary["tier_after"] = LeagueRules.apply(cfg, tier, summary["outcome"])
	_set_tier(summary["tier_after"])
	return summary


func _best_game_between(from_time: int, to_time: int) -> Dictionary:
	var best := {}
	for entry in data["results"].values():
		var r: Dictionary = entry["result"]
		var finished := int(r.get("finished_at", -1))
		if finished < from_time or finished >= to_time or not bool(r.get("completed", false)):
			continue
		var score := int(entry["response"]["breakdown"]["score"])
		if best.is_empty() or score > int(best["score"]):
			best = {"level_id": r.get("level_id", ""), "score": score}
	return best


func get_round_summary() -> Dictionary:
	return ok((data["pending_summary"] as Dictionary).duplicate(true))


func ack_round_summary(round_index: int) -> Dictionary:
	var pending: Dictionary = data["pending_summary"]
	if not pending.is_empty() and int(pending.get("round_index", -1)) == round_index:
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
	var cfg := league_cfg()
	var tier := str(fr["tier"])
	var index := LeagueRules.round_index(cfg, tier, now_utc())
	var frac := clampf(float(now_utc() - LeagueRules.round_start(cfg, tier, index)) / LeagueRules.round_seconds(cfg, tier), 0.0, 1.0)
	var played := _synthetic_round("friend:%s:%d:%s" % [tier, index, fr["player_id"]], float(fr["skill"]), int(fr["games_per_week"]), frac, _anchor(), LeagueRules.round_days(cfg, tier))
	return {
		"player_id": fr["player_id"], "nickname": fr["nickname"], "tier": tier,
		"tier_name": LeagueRules.tier_name(cfg, tier),
		"round_score": played["round_score"], "friend_since": fr["friend_since"], "friend_code": fr["friend_code"],
	}


func get_friends() -> Dictionary:
	var views: Array = []
	for fr in data["friends"]:
		views.append(_friend_view(fr))
	return ok(views)


func add_friend(code: String) -> Dictionary:
	code = code.strip_edges().to_upper()
	if not is_valid_code(code):
		return fail(Loc.t("ERR_FRIEND_CODE_FORMAT"))
	if code == str(data["profile"].get("friend_code", "")):
		return fail(Loc.t("ERR_FRIEND_OWN_CODE"))
	for fr in data["friends"]:
		if fr["friend_code"] == code:
			return fail(Loc.t("ERR_FRIEND_ALREADY"))
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
	return fail(Loc.t("ERR_FRIEND_UNKNOWN"))
