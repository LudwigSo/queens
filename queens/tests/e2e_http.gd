extends SceneTree
## Drives the real HttpBackend against a running queensd, end to end.
##
## Not part of the normal suite: it needs a server. Run it with
##   QUEENS_SERVER_URL=http://127.0.0.1:8098 godot --headless --path queens \
##     --script tests/e2e_http.gd

const Levels := preload("res://scripts/levels.gd")

var checks := 0
var failures := 0


func _check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)


func _initialize() -> void:
	Loc.load_csv()
	TranslationServer.set_locale("en")
	_run()


func _run() -> void:
	var url := OS.get_environment("QUEENS_SERVER_URL")
	if url == "":
		print("QUEENS_SERVER_URL is not set; nothing to talk to")
		quit(0)
		return
	var cfg := GameConfig.new()
	cfg.server_url = url
	cfg.save_path = "user://e2e_save.json"
	if FileAccess.file_exists(cfg.save_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(cfg.save_path))
	var save := SaveData.load_or_create(cfg)
	var backend := HttpBackend.new(cfg, save)
	root.add_child(backend)
	await process_frame

	var init_res: Dictionary = await backend.init()
	_check(init_res["ok"], "init on a fresh save")

	var reg: Dictionary = await backend.register_player(save.player_id(), save.nickname())
	_check(reg["ok"], "register: %s" % str(reg.get("error", "")))
	var profile: Dictionary = reg["data"]
	_check(str(profile.get("tier", "")) == "bronze", "a new player is bronze")
	_check(str(profile.get("friend_code", "")).begins_with("QN-"), "the server issued a friend code")
	_check(save.auth_token() != "", "the credential was stored")

	# The clock now comes from the server.
	_check(absi(backend.now_utc() - int(Time.get_unix_time_from_system())) < 120, "server time is close to ours")

	var meta: Dictionary = (await backend.get_level_meta())["data"]
	_check(meta.size() == 100, "level meta covers every level (%d)" % meta.size())
	var level_id := ""
	for id in meta:
		level_id = id
		break
	_check(float(meta[level_id]["par_seconds"]) > 0.0, "par comes from the server")

	# Second call must hit the ETag and come back from the cache.
	var meta2: Dictionary = (await backend.get_level_meta())["data"]
	_check(meta2.size() == meta.size(), "a 304 still yields the level meta")

	var level := _level_by_id(level_id)
	var start: Dictionary = await backend.start_game(level_id)
	_check(start["ok"], "start game: %s" % str(start.get("error", "")))
	var token := str((start["data"].get("session", {}) as Dictionary).get("token", ""))
	_check(token != "", "a session token came back")
	_check(bool(start["data"]["joined"]), "the round was joined")

	# Starting the same level again while the session is still open hands back
	# the same session rather than refusing: a lost response must not cost the
	# player a seven-day lock.
	var again: Dictionary = await backend.start_game(level_id)
	_check(again["ok"], "an open session is handed back rather than refused")
	_check(str((again["data"].get("session", {}) as Dictionary).get("token", "")) == token, "and it is the same session")

	# Let real time pass: the server clamps a claimed elapsed to the wall clock
	# since it issued the session, and rejects one that could not have happened.
	await create_timer_wait(4.0)

	var session := GameSession.new()
	session.start(level, save.player_id(), backend.now_utc() - 4, cfg.client_version, token)
	session.result.elapsed_seconds = 3.0
	session.result.queens_placed = int(level["size"])
	session.result.queens_removed = 2
	session.result.taps = int(level["size"]) * 3
	var result := session.finish(true, backend.now_utc())
	var submitted: Dictionary = await backend.submit_result(result.to_dict())
	_check(submitted["ok"], "submit: %s" % str(submitted.get("error", "")))
	var data: Dictionary = submitted["data"]
	_check(int(data["breakdown"]["score"]) > 0, "the server scored the game")
	_check(bool(data["verified"]), "a session-backed result is verified")
	_check(str(data["tier"]) == "bronze" and int(data["round_score"]) == int(data["breakdown"]["score"]), "the round score is the one game")

	var replay: Dictionary = await backend.submit_result(result.to_dict())
	_check(replay["ok"] and int(replay["data"]["breakdown"]["score"]) == int(data["breakdown"]["score"]), "a replay returns the stored answer")

	var standing: Dictionary = (await backend.get_league_standing())["data"]
	# No assumption that this is the only player: the same server may already
	# hold games from a manual run.
	_check(bool(standing["joined"]) and int(standing["my_rank"]) >= 1, "the standing shows the game")
	_check(int(standing["my_round_score"]) == int(data["breakdown"]["score"]), "the round score is the game just played")
	_check(int(standing["my_games"]) == 1, "one game this round")
	_check(str(standing["rules"]["up_to"]) == "silver", "up_to is a tier id")
	_check(not standing.has("rules_text") and not standing.has("tier_name"), "no prose on the wire")
	var view := Views.league_screen(standing, [], cfg.league)
	_check(str(view["standing"]["tier_name"]) == "Bronze", "the presenter names the tier")
	_check(str(view["standing"]["rules_text"]).contains("3000"), "the presenter builds the rule sentence")

	var board: Dictionary = (await backend.get_level_leaderboard(level_id, "global", 10))["data"]
	_check((board["entries"] as Array).size() == 1 and int(board["my_rank"]) == 1, "I am on my own leaderboard")

	var summary: Dictionary = (await backend.get_round_summary())["data"]
	_check(summary.is_empty(), "204 becomes an empty summary")

	var friends: Dictionary = await backend.get_friends()
	_check(friends["ok"] and (friends["data"] as Array).is_empty(), "no friends yet")
	var bad: Dictionary = await backend.add_friend("QN-ZZZZZZ")
	_check(not bad["ok"] and str(bad.get("code", "")) == "ERR_FRIEND_CODE_UNKNOWN", "an unknown code is reported")
	_check(bad["error"] == Loc.t("ERR_FRIEND_CODE_UNKNOWN"), "the error is localised for the player")
	var own: Dictionary = await backend.add_friend(str(profile["friend_code"]))
	_check(not own["ok"] and str(own.get("code", "")) == "ERR_FRIEND_OWN_CODE", "my own code is refused")

	var renamed: Dictionary = await backend.set_nickname("Ludwig")
	_check(renamed["ok"] and str(renamed["data"]["nickname"]) == "Ludwig", "rename")
	var too_short: Dictionary = await backend.set_nickname("x")
	_check(not too_short["ok"] and str(too_short.get("code", "")) == "ERR_NICKNAME_LENGTH", "a one-character name is refused")

	var gone: Dictionary = await backend.delete_account()
	_check(gone["ok"] and save.auth_token() == "", "the account was deleted")

	print("%d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func create_timer_wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _level_by_id(id: String) -> Dictionary:
	for lv in Levels.load_all():
		if str(lv["id"]) == id:
			return lv
	return {}
