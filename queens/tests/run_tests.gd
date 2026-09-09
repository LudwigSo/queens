extends SceneTree
## Headless test runner. Run with:
##   godot --headless --path queens --script tests/run_tests.gd
## Checks that every level has a unique id and exactly one solution and that the
## board logic (auto-marking, undo, conflict detection, win detection) behaves.

const Levels := preload("res://scripts/levels.gd")
const BoardScript := preload("res://scripts/board.gd")

var failures: int = 0
var checks: int = 0


var levels: Array = []


func _initialize() -> void:
	levels = Levels.load_all()
	_check(levels.size() > 0, "level file has levels")
	var ids: Dictionary = {}
	var uuid := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
	for i in levels.size():
		var id: String = str(levels[i].get("id", ""))
		_check(uuid.search(id) != null, "level %d: id %s is a uuid" % [i + 1, id])
		_check(not ids.has(id), "level %d: id %s is unique" % [i + 1, id])
		ids[id] = true
		_test_level(i, levels[i])
	_test_board_logic()
	_test_level_catalog()
	_test_save_data()
	_test_game_session()
	_test_cooldown()
	_test_level_picker()
	print("%d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)


func _test_level(index: int, lv: Dictionary) -> void:
	var n: int = lv["size"]
	var regions: Array = lv["regions"]
	var sol: Array = lv["solution"]
	_check(regions.size() == n, "level %d: region rows" % (index + 1))
	for row in regions:
		_check(row.size() == n, "level %d: region cols" % (index + 1))
	var ids: Dictionary = {}
	for row in regions:
		for v in row:
			ids[v] = true
	_check(ids.size() == n, "level %d: has %d regions" % [index + 1, n])
	for rid in ids:
		_check(_region_connected(n, regions, rid), "level %d: region %d is connected" % [index + 1, rid])
	_check(_is_valid(n, regions, sol), "level %d: stored solution is valid" % (index + 1))
	var count := _count_solutions(n, regions, 2)
	_check(count == 1, "level %d: unique solution (found %d)" % [index + 1, count])


func _region_connected(n: int, regions: Array, rid: int) -> bool:
	var cells: Array[Vector2i] = []
	for r in n:
		for c in n:
			if regions[r][c] == rid:
				cells.append(Vector2i(r, c))
	if cells.is_empty():
		return false
	var seen: Dictionary = {cells[0]: true}
	var stack: Array[Vector2i] = [cells[0]]
	while not stack.is_empty():
		var p: Vector2i = stack.pop_back()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q: Vector2i = p + d
			if q.x < 0 or q.x >= n or q.y < 0 or q.y >= n:
				continue
			if regions[q.x][q.y] == rid and not seen.has(q):
				seen[q] = true
				stack.append(q)
	return seen.size() == cells.size()


func _is_valid(n: int, regions: Array, sol: Array) -> bool:
	if sol.size() != n:
		return false
	var cols: Dictionary = {}
	var regs: Dictionary = {}
	for r in n:
		var c: int = sol[r]
		if cols.has(c) or regs.has(regions[r][c]):
			return false
		if r > 0 and absi(sol[r - 1] - c) <= 1:
			return false
		cols[c] = true
		regs[regions[r][c]] = true
	return true


func _count_solutions(n: int, regions: Array, limit: int) -> int:
	var state := {"count": 0, "cols": {}, "regs": {}, "placed": []}
	_solve_rec(0, n, regions, limit, state)
	return state["count"]


func _solve_rec(r: int, n: int, regions: Array, limit: int, s: Dictionary) -> void:
	if s["count"] >= limit:
		return
	if r == n:
		s["count"] += 1
		return
	for c in n:
		var reg: int = regions[r][c]
		if s["cols"].has(c) or s["regs"].has(reg):
			continue
		if r > 0 and absi(s["placed"][r - 1] - c) <= 1:
			continue
		s["cols"][c] = true
		s["regs"][reg] = true
		s["placed"].append(c)
		_solve_rec(r + 1, n, regions, limit, s)
		s["placed"].pop_back()
		s["cols"].erase(c)
		s["regs"].erase(reg)


func _test_board_logic() -> void:
	var board: Control = BoardScript.new()
	var lv: Dictionary = levels[0]
	var n: int = lv["size"]
	var sol: Array = lv["solution"]
	var solved_count := [0]
	board.solved.connect(func() -> void: solved_count[0] += 1)
	board.load_level(lv)

	# Manual mark cycle: empty -> mark -> queen -> empty.
	board._tap(0, 0)
	_check(board.cells[0][0] == BoardScript.Cell.MARK, "first tap marks X")
	board._tap(0, 0)
	_check(board.cells[0][0] == BoardScript.Cell.QUEEN, "second tap places queen")
	_check(board.auto_marks[0][1] == 1 and board.auto_marks[1][0] == 1 and board.auto_marks[4][0] == 1,
		"queen auto-marks row, column and neighbours")
	_check(board.auto_marks[0][0] == 0, "queen cell itself is not auto-marked")
	var reg0: int = lv["regions"][0][0]
	var all_region_marked := true
	for r in n:
		for c in n:
			if (r != 0 or c != 0) and lv["regions"][r][c] == reg0 and board.auto_marks[r][c] == 0:
				all_region_marked = false
	_check(all_region_marked, "queen auto-marks its whole region")
	board._tap(0, 0)
	_check(board.cells[0][0] == BoardScript.Cell.EMPTY, "third tap removes queen")
	var any_auto := false
	for row in board.auto_marks:
		for v in row:
			if v > 0:
				any_auto = true
	_check(not any_auto, "removing queen clears its auto marks")

	# Undo restores previous state.
	board.undo()
	_check(board.cells[0][0] == BoardScript.Cell.QUEEN and board.auto_marks[0][1] == 1, "undo restores queen and auto marks")
	board.reset()
	_check(not board.can_undo(), "reset clears history")

	# Two queens in the same row conflict; auto marks stack and unstack.
	board._tap(0, 0)
	board._tap(0, 0)
	board._tap(0, 3)  # auto-marked cell -> queen directly
	_check(board.cells[0][3] == BoardScript.Cell.QUEEN, "tapping an auto-marked cell places a queen")
	_check(board.conflicts.has(Vector2i(0, 0)) and board.conflicts.has(Vector2i(0, 3)), "same-row queens conflict")
	_check(board.auto_marks[0][1] == 2, "auto marks count both queens")
	board._tap(0, 3)
	_check(board.auto_marks[0][1] == 1 and board.conflicts.is_empty(), "removing one queen keeps the other's marks")
	board.reset()

	# Playing the stored solution solves the level, and the board locks.
	for r in n:
		var c: int = sol[r]
		if board.auto_marks[r][c] == 0:
			board._tap(r, c)  # mark
		board._tap(r, c)  # queen
	_check(board.queen_count() == n, "all queens placed")
	_check(board.conflicts.is_empty(), "solution has no conflicts")
	_check(solved_count[0] == 1, "solved signal emitted once")
	_check(board.locked, "board locks after solving")
	board.free()


func _test_level_catalog() -> void:
	var catalog := LevelCatalog.new(levels)
	_check(catalog.size() == levels.size(), "catalog holds every level")
	_check(catalog.ranked.size() == levels.size(), "ranking holds every level")
	var monotone := true
	for i in range(1, catalog.ranked.size()):
		if float(catalog.ranked[i - 1]["difficulty"]) > float(catalog.ranked[i]["difficulty"]):
			monotone = false
	_check(monotone, "ranking is sorted by difficulty")
	var first: Dictionary = levels[0]
	_check(catalog.get_level(first["id"]) == first, "lookup by id")
	_check(catalog.display_index(first["id"]) == 0, "display index follows game order")
	_check(catalog.rank_of(first["id"]) == catalog.ranked.find(first), "rank_of matches ranked position")
	_check(catalog.rank_of("missing") == -1, "unknown id has rank -1")
	_check(catalog.rank_for_difficulty(0.0) == 0, "rank for difficulty below all is 0")
	_check(catalog.rank_for_difficulty(1e9) == levels.size(), "rank for difficulty above all is size")
	var easiest: float = float(catalog.ranked[0]["difficulty"])
	_check(catalog.rank_for_difficulty(easiest) == 0, "rank for the easiest difficulty is 0")
	_check(catalog.rank_for_difficulty(easiest + 0.5) >= 1, "rank just above the easiest is at least 1")
	# Same input always gives the same ranking.
	var again := LevelCatalog.new(levels)
	var same := true
	for i in catalog.ranked.size():
		if catalog.ranked[i]["id"] != again.ranked[i]["id"]:
			same = false
	_check(same, "ranking is deterministic")


func _test_save_data() -> void:
	var dir := "user://test_tmp"
	DirAccess.make_dir_recursive_absolute(dir)
	var cfg := GameConfig.new()
	cfg.save_path = dir + "/save.json"
	cfg.legacy_cfg_path = dir + "/progress.cfg"
	for f in [cfg.save_path, cfg.legacy_cfg_path, cfg.legacy_cfg_path + ".migrated"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	var uuid := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

	# Fresh install.
	var fresh := SaveData.load_or_create(cfg)
	_check(FileAccess.file_exists(cfg.save_path), "fresh save is written")
	_check(uuid.search(fresh.player_id()) != null, "fresh save has a uuid4 player id")
	_check(fresh.nickname().begins_with("Player-"), "fresh save has a default nickname")
	_check(int(fresh.data["energy"]["amount"]) == cfg.start_energy, "fresh save starts with start_energy")
	_check(not fresh.has_best("x"), "unknown level has no best")
	_check(fresh.level_entry("x")["plays"] == 0, "level_entry creates defaults")
	_check(fresh.update_best_time("x", 30.0), "first completion is a best")
	_check(not fresh.update_best_time("x", 40.0), "slower completion is not a best")
	_check(fresh.update_best_time("x", 20.0), "faster completion is a best")
	_check(fresh.best_time("x") == 20.0 and fresh.level_entry("x")["completions"] == 3, "best time and completions recorded")
	var changed := [0]
	fresh.changed.connect(func() -> void: changed[0] += 1)
	fresh.update_best_time("x", 50.0)
	_check(changed[0] == 1, "update_best_time emits changed")

	# Round trip through the file.
	fresh.save_to()
	var again := SaveData.load_or_create(cfg)
	_check(again.player_id() == fresh.player_id(), "player id survives a round trip")
	_check(again.best_time("x") == 20.0, "best time survives a round trip")
	_check(not FileAccess.file_exists(cfg.save_path + ".tmp"), "temp file is renamed away")

	# Legacy ConfigFile import.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(cfg.save_path))
	var legacy := ConfigFile.new()
	legacy.set_value("best_times", "level-a", 83.5)
	legacy.set_value("best_times", "level-b", 12.0)
	legacy.save(cfg.legacy_cfg_path)
	var migrated := SaveData.load_or_create(cfg)
	_check(migrated.best_time("level-a") == 83.5 and migrated.best_time("level-b") == 12.0, "legacy best times imported")
	_check(migrated.level_entry("level-a")["last_started_at"] == 0, "imported levels carry no cooldown")
	_check(migrated.level_entry("level-a")["completions"] == 1 and migrated.level_entry("level-a")["plays"] == 1, "imported levels count one play")
	_check(uuid.search(migrated.player_id()) != null, "migrated save gets a player id")
	_check(int(migrated.data["energy"]["amount"]) == cfg.start_energy, "migrated save starts with start_energy")
	_check(FileAccess.file_exists(cfg.save_path), "migrated save is written")
	_check(not FileAccess.file_exists(cfg.legacy_cfg_path), "legacy file is renamed")
	_check(FileAccess.file_exists(cfg.legacy_cfg_path + ".migrated"), "legacy file kept as .migrated")

	# Version handling.
	var v0 := SaveData.migrate({"levels": {"old": {"best_time": 5.0}}}, cfg)
	_check(int(v0["version"]) == SaveData.VERSION, "version 0 dict is migrated to current")
	_check(v0.has("player") and v0.has("energy"), "migration fills missing sections")
	_check(v0["levels"]["old"]["plays"] == 0 and v0["levels"]["old"]["best_time"] == 5.0, "migration fills missing level fields")
	var newer := {"version": SaveData.VERSION + 1, "player": {"id": "keep"}, "levels": {}}
	var kept := SaveData.migrate(newer, cfg)
	_check(int(kept["version"]) == SaveData.VERSION + 1 and kept["player"]["id"] == "keep", "newer version loads untouched")

	# Clean up.
	for f in [cfg.save_path, cfg.legacy_cfg_path + ".migrated"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


func _test_game_session() -> void:
	var board: Control = BoardScript.new()
	var lv: Dictionary = levels[0]
	var n: int = lv["size"]
	var sol: Array = lv["solution"]
	board.load_level(lv)
	var session := GameSession.new()
	session.start(lv, "player-1", 1000, "test")
	session.attach(board)
	_check(session.result.level_id == lv["id"] and session.result.size == n, "session copies level id and size")
	_check(session.result.result_id.length() == 36, "session has a result id")
	_check(not session.running, "session starts paused")

	# Stopwatch rules.
	session.tick(0.5)
	_check(session.elapsed_seconds() == 0.0, "no time counted while paused")
	session.resume()
	session.tick(0.5)
	session.tick(0.25)
	_check(is_equal_approx(session.elapsed_seconds(), 0.75), "time counted while running")
	session.tick(5.0)
	_check(is_equal_approx(session.elapsed_seconds(), 0.75), "frames longer than a second are ignored")
	session.pause()
	session.tick(0.5)
	_check(is_equal_approx(session.elapsed_seconds(), 0.75), "pause stops the clock")
	session.resume()

	# Counters from board signals.
	var wrong_col: int = (sol[0] + 2) % n
	if absi(wrong_col - sol[0]) <= 1:
		wrong_col = (sol[0] + 3) % n
	board._tap(0, wrong_col)  # mark
	board._tap(0, wrong_col)  # wrong queen
	_check(session.result.taps == 2, "taps are counted")
	_check(session.result.queens_placed == 1 and session.result.wrong_placements == 1, "wrong queen counted")
	board._tap(0, wrong_col)  # remove
	_check(session.result.queens_removed == 1 and session.result.wrong_placements == 1, "removal keeps the mistake")
	board.undo()
	_check(session.result.undo_count == 1, "undo counted")
	board.undo()
	board.undo()
	board.undo()  # history exhausted: only three real undos in total
	_check(session.result.undo_count == 3, "only effective undos are counted")
	board._tap(0, sol[0])
	board._tap(0, sol[0])
	_check(session.result.queens_placed == 2 and session.result.wrong_placements == 1, "correct queen is not a mistake")
	board.clear()
	_check(session.result.clear_count == 1, "clear counted")
	board.reset()
	_check(session.result.clear_count == 1, "reset does not count as clear")

	# Marker round trip.
	var marker := session.to_marker()
	_check(marker["result_id"] == session.result.result_id and marker["wrong_placements"] == 1, "marker carries id and counters")
	var forfeit := GameSession.forfeit_from_marker(marker, lv, "player-1", 2000, "test")
	_check(not forfeit.completed and forfeit.result_id == session.result.result_id, "marker forfeit keeps the id")
	_check(forfeit.finished_at == 2000 and forfeit.started_at == 1000 and forfeit.wrong_placements == 1, "marker forfeit carries times and counters")
	_check(forfeit.size == n and forfeit.level_id == lv["id"], "marker forfeit resolves the level")

	# Solving completes the session and detaches it from the board.
	for r in n:
		if board.auto_marks[r][sol[r]] == 0:
			board._tap(r, sol[r])
		board._tap(r, sol[r])
	_check(board.locked, "board solved")
	var result := session.finish(true, 1500)
	_check(result.completed and result.finished_at == 1500 and session.finished, "finish marks completion")
	_check(result.wrong_placements == 1 and result.queens_placed == 2 + n, "result carries the counters")
	session.resume()
	session.tick(0.5)
	_check(not session.running and is_equal_approx(result.elapsed_seconds, 0.75), "finished session cannot resume")
	board.reset()
	board._tap(0, wrong_col)
	board._tap(0, wrong_col)
	_check(result.queens_placed == 2 + n, "finished session no longer counts board moves")
	var forfeit2 := GameSession.new()
	forfeit2.start(lv, "p", 10, "")
	_check(not forfeit2.finish(false, 5).completed and forfeit2.result.finished_at == 10, "forfeit result; finished_at never precedes started_at")

	# Dictionary round trip.
	var back := GameResult.from_dict(result.to_dict())
	_check(back.to_dict() == result.to_dict(), "GameResult survives to_dict/from_dict")

	# Recording into the save file.
	var cfg := GameConfig.new()
	var save := SaveData.new()
	save.data = SaveData.defaults(cfg)
	save.begin_game(lv, marker, 1000)
	_check(save.has_running_game() and save.level_entry(lv["id"])["plays"] == 1, "begin_game stores marker and play")
	_check(save.level_entry(lv["id"])["last_started_at"] == 1000, "begin_game starts the cooldown")
	_check(save.last_game()["level_id"] == lv["id"] and save.last_game()["difficulty"] == float(lv["difficulty"]), "begin_game remembers the last game")
	_check(save.record_result(result.to_dict(), 3), "completed result becomes the best time")
	_check(not save.has_running_game(), "record_result clears the marker")
	_check(save.level_entry(lv["id"])["completions"] == 1 and save.best_time(lv["id"]) == result.elapsed_seconds, "record_result updates the level entry")
	_check(not save.record_result(forfeit.to_dict(), 3), "forfeit is no best")
	_check(save.level_entry(lv["id"])["completions"] == 1, "forfeit does not count as completion")
	save.record_result(forfeit.to_dict(), 3)
	save.record_result(forfeit.to_dict(), 3)
	_check((save.data["results"] as Array).size() == 3, "result history is capped")
	_check((save.data["pending_results"] as Array).size() == 4, "every result is queued for the backend")
	board.free()


func _test_cooldown() -> void:
	var week := 7 * 86400
	var entry := {"last_started_at": 1000}
	_check(Cooldown.is_locked(entry, 1000, week), "locked right after start")
	_check(Cooldown.is_locked(entry, 1000 + week - 1, week), "locked one second before the period ends")
	_check(not Cooldown.is_locked(entry, 1000 + week, week), "unlocked when the period ends")
	_check(Cooldown.remaining(entry, 1000 + 3600, week) == week - 3600, "remaining counts down")
	_check(Cooldown.remaining(entry, 500, week) == week, "a clock moved backwards never locks longer than one period")
	_check(Cooldown.remaining(entry, 1000 + 2 * week, week) == 0, "remaining never goes negative")
	_check(not Cooldown.is_locked({"last_started_at": 0}, 5000, week), "never started (or migrated) is unlocked")
	_check(not Cooldown.is_locked({}, 5000, week), "missing field is unlocked")
	_check(not Cooldown.is_locked(entry, 1001, 0), "zero cooldown never locks")
	_check(Cooldown.format_remaining(6 * 86400 + 23 * 3600 + 59 * 60) == "6d 23h", "format days and hours")
	_check(Cooldown.format_remaining(3 * 3600 + 12 * 60 + 5) == "3h 12m", "format hours and minutes")
	_check(Cooldown.format_remaining(45 * 60) == "45m", "format minutes")
	_check(Cooldown.format_remaining(30) == "<1m", "format under a minute")
	_check(Cooldown.format_remaining(-5) == "<1m", "negative formats as under a minute")
	_check(Cooldown.format_period(week) == "7 days" and Cooldown.format_period(86400) == "1 day", "format period in days")
	_check(Cooldown.format_period(12 * 3600) == "12 hours" and Cooldown.format_period(3600) == "1 hour", "format period in hours")
	_check(Cooldown.format_period(90) == "1 minute" and Cooldown.format_period(1800) == "30 minutes", "format period in minutes")


func _test_level_picker() -> void:
	var catalog := LevelCatalog.new(levels)
	var cfg := GameConfig.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var picker := LevelPicker.new(catalog, cfg, rng)
	var n := catalog.ranked.size()
	var step_ranks := ceili(n * cfg.step_fraction)
	var half := ceili(n * cfg.band_fraction)
	@warning_ignore("integer_division")
	var median: Dictionary = catalog.ranked[n / 2]
	var last := {"level_id": median["id"], "difficulty": median["difficulty"]}
	var i0 := catalog.rank_of(median["id"])

	# First launch: an easy level from the low end of the ranking.
	var first := picker.pick(1, {}, {})
	var first_center := int(floor(n * cfg.initial_quartile / 2.0))
	_check(first["reason"] == "band" and first["step"] == 0, "first launch picks from the band and ignores the step")
	var first_rank := catalog.rank_of(first["level"]["id"])
	_check(first_rank >= first_center - half and first_rank <= first_center + half, "first launch picks near the easy quantile")

	# Stepping from the median level.
	var harder := picker.pick(1, last, {})
	var hr := catalog.rank_of(harder["level"]["id"])
	_check(harder["reason"] == "band", "harder finds a band level")
	_check(hr >= i0 + step_ranks - half and hr <= i0 + step_ranks + half, "harder lands one step up")
	_check(float(harder["level"]["difficulty"]) > float(median["difficulty"]), "harder is strictly harder")
	var easier := picker.pick(-1, last, {})
	var er := catalog.rank_of(easier["level"]["id"])
	_check(er >= i0 - step_ranks - half and er <= i0 - step_ranks + half, "easier lands one step down")
	_check(float(easier["level"]["difficulty"]) < float(median["difficulty"]), "easier is strictly easier")
	var same := picker.pick(0, last, {})
	var sr := catalog.rank_of(same["level"]["id"])
	_check(same["level"]["id"] != median["id"], "same never repeats the last level")
	_check(sr >= i0 - half and sr <= i0 + half, "same stays in the band")

	# Band fully locked: nearest allowed level on the right side.
	var locked := {}
	for i in range(i0 + step_ranks - half, i0 + step_ranks + half + 1):
		locked[catalog.ranked[i]["id"]] = true
	var nearest := picker.pick(1, last, locked)
	_check(nearest["reason"] == "nearest", "locked band falls back to nearest")
	_check(not locked.has(nearest["level"]["id"]), "nearest is not locked")
	_check(float(nearest["level"]["difficulty"]) > float(median["difficulty"]), "nearest keeps the side rule")
	var nr := catalog.rank_of(nearest["level"]["id"])
	_check(absi(nr - (i0 + step_ranks)) <= half + 3, "nearest is adjacent to the band")

	# No level on that side at all.
	var hardest: Dictionary = catalog.ranked[n - 1]
	var none_harder := picker.pick(1, {"level_id": hardest["id"]}, {})
	_check(none_harder["level"].is_empty() and none_harder["reason"] == "none_harder", "nothing harder than the hardest level")
	var easiest: Dictionary = catalog.ranked[0]
	var none_easier := picker.pick(-1, {"level_id": easiest["id"]}, {})
	_check(none_easier["level"].is_empty() and none_easier["reason"] == "none_easier", "nothing easier than the easiest level")
	var all_locked := {}
	for lv in levels:
		all_locked[lv["id"]] = true
	var none := picker.pick(0, last, all_locked)
	_check(none["level"].is_empty() and none["reason"] == "none", "everything locked gives none")
	_check(picker.pick(0, {}, all_locked)["reason"] == "none", "first launch with everything locked gives none")

	# Locked levels are never returned, whatever the seed.
	var violations := 0
	var random_rng := RandomNumberGenerator.new()
	random_rng.seed = 777
	for trial in 500:
		var some_locked := {}
		for lv in levels:
			if random_rng.randf() < 0.6:
				some_locked[lv["id"]] = true
		var anchor: Dictionary = catalog.ranked[random_rng.randi_range(0, n - 1)]
		var res := picker.pick(random_rng.randi_range(-1, 1), {"level_id": anchor["id"]}, some_locked)
		if not res["level"].is_empty() and some_locked.has(res["level"]["id"]):
			violations += 1
	_check(violations == 0, "500 random picks never return a locked level")

	# A last level that vanished from the file still anchors by difficulty.
	var gone := picker.pick(1, {"level_id": "gone", "difficulty": median["difficulty"]}, {})
	_check(float(gone["level"]["difficulty"]) > float(median["difficulty"]), "missing last level anchors by difficulty")

	# Never-played levels are preferred within a band.
	var played := {}
	for i in range(i0 - half, i0 + half + 1):
		if i % 2 == 0:
			played[catalog.ranked[i]["id"]] = true
	var unplayed_hits := 0
	for trial in 400:
		var res := picker.pick(0, last, {}, played)
		if not played.has(res["level"]["id"]):
			unplayed_hits += 1
	_check(unplayed_hits > 220, "unplayed levels are picked more often (%d of 400)" % unplayed_hits)

	# Tiny synthetic catalog: edge clamps.
	var tiny := LevelCatalog.new([
		{"id": "a", "size": 6, "difficulty": 1.0, "stars": 1},
		{"id": "b", "size": 6, "difficulty": 2.0, "stars": 1},
		{"id": "c", "size": 6, "difficulty": 3.0, "stars": 1},
	])
	var tiny_picker := LevelPicker.new(tiny, cfg, rng)
	_check(tiny_picker.pick(1, {"level_id": "b"}, {})["level"]["id"] == "c", "tiny: harder from the middle")
	_check(tiny_picker.pick(-1, {"level_id": "b"}, {})["level"]["id"] == "a", "tiny: easier from the middle")
	_check(tiny_picker.pick(1, {"level_id": "c"}, {})["reason"] == "none_harder", "tiny: nothing above the top")
	_check(tiny_picker.pick(0, {"level_id": "b"}, {"a": true, "c": true})["reason"] == "none", "tiny: same with everything else locked")
	_check(tiny_picker.pick(1, {"level_id": "a"}, {"b": true})["level"]["id"] == "c", "tiny: harder skips a locked level")
	_check(tiny_picker.pick(0, {}, {})["reason"] == "band", "tiny: first launch works")
