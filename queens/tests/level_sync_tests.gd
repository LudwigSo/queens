extends RefCounted
## Tests for server-delivered levels and server-held level state: the level
## cache (Levels), LevelCatalog.add_levels, LevelSync and
## SaveData.apply_server_level_states. Run from run_tests.gd, which owns the
## check counter.

const Levels := preload("res://scripts/levels.gd")
const DIR := "user://test_tmp"

var _check: Callable
var _bundled: Array


## A backend that answers like the server, synchronously, and records calls.
class FakeLevelBackend extends Backend:
	var boards: Array = []          ## raw LevelBoards the "server" publishes beyond the bundle
	var bundled_ids: Array = []
	var calls: Array = []
	var offline := false
	var fail_levels_after := -1     ## get_levels fails from this call on (0-based); -1 never
	var levels_calls := 0
	var states: Variant = null

	func get_level_count() -> Dictionary:
		calls.append("count")
		if offline:
			return {"ok": false, "data": null, "error": "offline", "code": "ERR_NETWORK"}
		return ok(bundled_ids.size() + boards.size())

	func get_level_ids() -> Dictionary:
		calls.append("ids")
		var ids: Array = bundled_ids.duplicate()
		for b in boards:
			ids.append(b["id"])
		return ok(ids)

	func get_levels(ids: Array) -> Dictionary:
		calls.append("levels:%d" % ids.size())
		levels_calls += 1
		if fail_levels_after >= 0 and levels_calls > fail_levels_after:
			return {"ok": false, "data": [], "error": "offline", "code": "ERR_NETWORK"}
		var want := {}
		for id in ids:
			want[id] = true
		var out: Array = []
		# Reverse order on purpose: LevelSync must sort by position itself.
		for i in range(boards.size() - 1, -1, -1):
			if want.has(boards[i]["id"]):
				out.append(boards[i])
		return ok(out)

	func get_level_states() -> Dictionary:
		return ok(states)


func run(check: Callable, bundled: Array) -> void:
	_check = check
	_bundled = bundled
	DirAccess.make_dir_recursive_absolute(DIR)
	_test_validate()
	_test_cache()
	_test_catalog_add()
	await _test_sync()
	_test_state_merge()


func _ok(cond: bool, msg: String) -> void:
	_check.call(cond, msg)


func _remove(path: String) -> void:
	for p in [path, path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


## A bundled board under a new id, as the server sends it: JSON numbers are
## floats, and it carries a position.
func _download(src: Dictionary, position: int) -> Dictionary:
	var raw := {
		"id": SaveData.new_uuid(), "position": position, "size": src["size"], "regions": src["regions"],
		"solution": src["solution"], "difficulty": src["difficulty"], "stars": src["stars"], "seed": src.get("seed", 0),
	}
	return JSON.parse_string(JSON.stringify(raw))


func _test_validate() -> void:
	var good := _download(_bundled[0], 101)
	_ok(Levels.validate(good) == "", "a valid download passes: %s" % Levels.validate(good))
	for lv in _bundled:
		if Levels.validate(lv) != "":
			_ok(false, "bundled level %s fails validate: %s" % [lv["id"], Levels.validate(lv)])
			break
	var swapped: Dictionary = good.duplicate(true)
	var sol: Array = swapped["solution"]
	var t: Variant = sol[0]
	sol[0] = sol[1]
	sol[1] = t
	_ok(Levels.validate(swapped) != "", "a broken solution is rejected")
	var short: Dictionary = good.duplicate(true)
	(short["regions"] as Array).pop_back()
	_ok(Levels.validate(short) != "", "missing region rows are rejected")
	var bad_id: Dictionary = good.duplicate(true)
	bad_id["id"] = "level-1"
	_ok(Levels.validate(bad_id) != "", "a non-uuid id is rejected")
	var bad_region: Dictionary = good.duplicate(true)
	bad_region["regions"][0][0] = 99
	_ok(Levels.validate(bad_region) != "", "a region id outside the board is rejected")
	var no_stars: Dictionary = good.duplicate(true)
	no_stars["stars"] = 0
	_ok(Levels.validate(no_stars) != "", "stars outside 1..5 are rejected")


func _test_cache() -> void:
	var path := DIR + "/levels_cache.json"
	_remove(path)
	_ok(Levels.load_all(path).size() == _bundled.size(), "no cache: just the bundle")
	_ok(Levels.load_all("").size() == _bundled.size(), "an empty cache path reads no cache")
	var a := Levels.normalize(_download(_bundled[3], 101))
	var b := Levels.normalize(_download(_bundled[7], 102))
	_ok(not a.has("position"), "normalize drops the server-only position")
	_ok(a["size"] is int and a["solution"][0] is int and a["stars"] is int, "normalize makes ints")
	_ok(Levels.append_to_cache([a, b], path) == OK, "cache written")
	_ok(not FileAccess.file_exists(path + ".tmp"), "cache temp file renamed away")
	var all := Levels.load_all(path)
	_ok(all.size() == _bundled.size() + 2, "bundle plus two cached levels")
	_ok(all[all.size() - 2]["id"] == a["id"] and all[all.size() - 1]["id"] == b["id"], "cached levels follow the bundle in download order")
	_ok(all[all.size() - 1]["regions"] == b["regions"], "a cached board round-trips")
	Levels.append_to_cache([b, Levels.normalize(_download(_bundled[1], 103))], path)
	_ok(Levels.read_cache(path).size() == 3, "appending keeps what is cached and skips duplicates")
	# A cached copy of a bundled level never doubles it.
	Levels.append_to_cache([_bundled[0]], path)
	_ok(Levels.load_all(path).size() == _bundled.size() + 3, "a bundled id in the cache is not added twice")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	_ok(Levels.load_all(path).size() == _bundled.size(), "an unreadable cache is ignored")
	_remove(path)


func _test_catalog_add() -> void:
	var cat := LevelCatalog.new(_bundled.duplicate())
	var held: Array = cat.levels
	var n := cat.size()
	var a := Levels.normalize(_download(_bundled[2], 101))
	var b := Levels.normalize(_download(_bundled[5], 102))
	_ok(cat.add_levels([a, b, _bundled[0]]) == 2, "add_levels adds only unknown ids")
	_ok(held.size() == n + 2 and cat.size() == n + 2, "the levels array grows in place")
	_ok(cat.display_index(a["id"]) == n and cat.display_index(b["id"]) == n + 1, "new levels go to the end of the game order")
	_ok(cat.ranked.size() == n + 2 and cat.rank_of(b["id"]) == cat.ranked.find(b), "new levels are ranked")
	var monotone := true
	for i in range(1, cat.ranked.size()):
		if float(cat.ranked[i - 1]["difficulty"]) > float(cat.ranked[i]["difficulty"]):
			monotone = false
	_ok(monotone, "the ranking stays sorted after add_levels")
	_ok(cat.add_levels([a]) == 0 and cat.size() == n + 2, "adding a known level is a no-op")


func _fake(extra: int) -> FakeLevelBackend:
	var fake := FakeLevelBackend.new()
	for lv in _bundled:
		fake.bundled_ids.append(lv["id"])
	for i in extra:
		fake.boards.append(_download(_bundled[i % _bundled.size()], _bundled.size() + i + 1))
	return fake


func _test_sync() -> void:
	var path := DIR + "/levels_sync_cache.json"
	_remove(path)

	# Same count: one request, nothing else.
	var fake := _fake(0)
	var cat := LevelCatalog.new(_bundled.duplicate())
	var added: Array = await LevelSync.sync_levels(fake, cat, path)
	_ok(added.is_empty() and fake.calls == ["count"], "equal counts stop after the count: %s" % [fake.calls])
	fake.free()

	# Offline: nothing happens.
	fake = _fake(3)
	fake.offline = true
	added = await LevelSync.sync_levels(fake, cat, path)
	_ok(added.is_empty() and fake.calls == ["count"] and cat.size() == _bundled.size(), "offline: no sync")
	fake.free()

	# 60 new levels, one of them broken: two chunks, only missing ids asked for.
	fake = _fake(60)
	var broken: Dictionary = fake.boards[10]
	var sol: Array = broken["solution"]
	var t: Variant = sol[0]
	sol[0] = sol[1]
	sol[1] = t
	added = await LevelSync.sync_levels(fake, cat, path)
	_ok(fake.calls == ["count", "ids", "levels:50", "levels:10"], "missing ids fetched in chunks of 50: %s" % [fake.calls])
	_ok(added.size() == 59 and cat.size() == _bundled.size() + 59, "every valid download is added, the broken one dropped")
	_ok(not cat.has(broken["id"]), "the broken board is not in the catalog")
	_ok(cat.display_index(fake.boards[0]["id"]) == _bundled.size(), "downloads are added in position order")
	_ok(cat.display_index(fake.boards[59]["id"]) == cat.size() - 1, "the last position is the last level")
	_ok(Levels.load_all(path).size() == _bundled.size() + 59, "downloads are cached for the next launch")
	fake.free()

	# Cut off after the first chunk: what arrived is kept, the rest comes next time.
	_remove(path)
	cat = LevelCatalog.new(_bundled.duplicate())
	fake = _fake(70)
	fake.fail_levels_after = 1
	added = await LevelSync.sync_levels(fake, cat, path)
	_ok(added.size() == 50 and Levels.read_cache(path).size() == 50, "a cut-off sync keeps the first chunk")
	fake.calls.clear()
	fake.fail_levels_after = -1
	added = await LevelSync.sync_levels(fake, cat, path)
	_ok(added.size() == 20 and fake.calls == ["count", "ids", "levels:20"], "the next sync fetches only the rest: %s" % [fake.calls])
	_ok(cat.size() == _bundled.size() + 70, "the catalog is complete after the second sync")
	fake.free()
	_remove(path)

	# The offline backend never finds anything to fetch.
	var cfg := GameConfig.new()
	var local := LocalBackend.new(cfg, cat, func() -> int: return 0, DIR + "/levels_local_backend.json")
	added = await LevelSync.sync_levels(local, cat, path)
	_ok(added.is_empty(), "LocalBackend: nothing to sync")
	var states: Dictionary = await local.get_level_states()
	_ok(states["ok"] and states["data"] == null, "LocalBackend has no level states to merge")
	local.free()


func _result(level_id: String, token: String, completed: bool, started: int, finished: int, elapsed: float, score: int, wrong: int) -> Dictionary:
	return {
		"result_id": SaveData.new_uuid(), "level_id": level_id, "session_token": token, "completed": completed,
		"started_at": started, "finished_at": finished, "elapsed_seconds": elapsed, "score": score,
		"wrong_placements": wrong,
	}


func _test_state_merge() -> void:
	var cfg := GameConfig.new()
	cfg.save_path = DIR + "/merge_save.json"
	cfg.legacy_cfg_path = DIR + "/merge_progress.cfg"
	_remove(cfg.save_path)
	var save := SaveData.load_or_create(cfg)
	_ok(save.level_entry("fresh").has("last_completed_at"), "level entries carry last_completed_at")

	# Local history the server corrected (it rejected a run), a level only this
	# device knows, and two results not yet sent.
	var a := "aaaaaaaa-0000-4000-8000-000000000001"
	var b := "bbbbbbbb-0000-4000-8000-000000000002"
	var local_only := "cccccccc-0000-4000-8000-000000000003"
	var e := save.level_entry(a)
	e["plays"] = 9
	e["completions"] = 9
	e["best_time"] = 5.0
	e["best_score"] = 9999
	e["best_result_id"] = "rejected"
	save.level_entry(local_only)["plays"] = 4
	var offline_win := _result(a, "", true, 5000, 5100, 90.0, 700, 0)
	var online_win := _result(b, "tok", true, 6000, 6050, 40.0, 300, 1)
	save.data["pending_results"] = [offline_win, online_win]
	save.data["current_game"] = {"level_id": b, "started_at": 7000, "session_token": ""}

	var server := {
		a: HttpBackend.normalize_level_state({"last_started_at": 4000.0, "plays": 2.0, "completions": 1.0,
			"last_completed_at": 4100.0, "best_time": 120.0, "best_score": 500.0, "best_score_time": 120.0,
			"best_wrong": 2.0, "best_result_id": "r-a", "best_at": 4100.0}),
		b: HttpBackend.normalize_level_state({"last_started_at": 6000.0, "plays": 1.0}),
	}
	_ok(server[a]["plays"] is int and server[a]["best_time"] is float, "server state numbers are normalised")
	save.apply_server_level_states(server)

	var ea := save.level_entry(a)
	_ok(ea["plays"] == 3 and ea["last_started_at"] == 5000, "an unsent offline game adds its play: %s" % [ea])
	_ok(ea["completions"] == 2 and ea["last_completed_at"] == 5100, "and its completion")
	_ok(ea["best_time"] == 90.0, "and a better time")
	_ok(ea["best_score"] == 700 and ea["best_result_id"] == offline_win["result_id"], "and a better run")
	_ok(not str(ea["best_result_id"]) == "rejected", "the server's state replaces what it never accepted")

	var eb := save.level_entry(b)
	_ok(eb["plays"] == 2, "a session game's play is already on the server; the running offline game adds one: %s" % [eb])
	_ok(eb["last_started_at"] == 7000, "the running game is the last start")
	_ok(eb["completions"] == 1 and eb["best_result_id"] == online_win["result_id"] and eb["best_time"] == 40.0, "the unsent session game's completion is replayed")

	_ok(save.level_entry(local_only)["plays"] == 4, "a level the server has no row for keeps its local entry")

	# Applied twice, the same answer: the replay starts from the server's copy.
	save.apply_server_level_states(server)
	_ok(save.level_entry(a)["plays"] == 3 and save.level_entry(a)["completions"] == 2, "applying twice is idempotent")
	_remove(cfg.save_path)
