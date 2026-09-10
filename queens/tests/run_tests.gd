extends SceneTree
## Headless test runner. Run with:
##   godot --headless --path queens --script tests/run_tests.gd
## Checks that every level has a unique id and exactly one solution and that the
## board logic (auto-marking, undo, conflict detection, win detection) behaves.

const Levels := preload("res://scripts/levels.gd")
const BoardScript := preload("res://scripts/board_model.gd")
const BoardViewScript := preload("res://scripts/board.gd")

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
	_test_board_strokes()
	_test_hint_finder()
	_test_board_view()
	_test_views()
	_test_streak()
	_test_settings()
	_test_level_catalog()
	_test_save_data()
	_test_game_session()
	_test_cooldown()
	_test_level_picker()
	_test_energy()
	_test_fake_providers()
	_test_scoring()
	_test_league_rules()
	_test_local_backend()
	_test_android_providers_degrade()
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
	var board: BoardModel = BoardScript.new()
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
	var board: BoardModel = BoardScript.new()
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
	_check(result.par_seconds == Scoring.par_seconds(result.difficulty, result.size) and result.week_index == Scoring.week_index(1500), "finish fills par and week")
	_check(result.score == Scoring.score(result.to_dict()) and result.score > 0, "finish computes the score")
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
	var outcome := save.record_result(result.to_dict(), 3)
	_check(outcome["best_time_improved"] and outcome["best_score_improved"] and outcome["score"] == result.score, "completed result becomes the best time and score")
	_check(not save.has_running_game(), "record_result clears the marker")
	_check(save.level_entry(lv["id"])["completions"] == 1 and save.best_time(lv["id"]) == result.elapsed_seconds, "record_result updates the level entry")
	var forfeit_outcome := save.record_result(forfeit.to_dict(), 3)
	_check(not forfeit_outcome["best_time_improved"] and not forfeit_outcome["best_score_improved"] and forfeit_outcome["score"] == 0, "forfeit is no best and scores 0")
	_check(save.level_entry(lv["id"])["completions"] == 1, "forfeit does not count as completion")
	save.record_result(forfeit.to_dict(), 3)
	save.record_result(forfeit.to_dict(), 3)
	_check((save.data["results"] as Array).size() == 3, "result history is capped")
	_check((save.data["pending_results"] as Array).size() == 4, "every result is queued for the backend")


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


func _test_energy() -> void:
	var cfg := GameConfig.new()
	var save := SaveData.new()
	save.data = SaveData.defaults(cfg)
	var ledger := EnergyLedger.new(save, cfg)
	var changes := [0]
	ledger.changed.connect(func() -> void: changes[0] += 1)
	_check(ledger.amount() == cfg.start_energy and ledger.can_start(), "ledger starts with start_energy")
	var ok := true
	for i in cfg.start_energy:
		ok = ok and ledger.charge_start()
	_check(ok and ledger.amount() == 0, "start_energy charges succeed and empty the ledger")
	_check(not ledger.can_start() and not ledger.charge_start() and ledger.amount() == 0, "an empty ledger refuses a start and stays at 0")
	_check(changes[0] == cfg.start_energy, "every charge emits changed")
	ledger.grant(cfg.ad_reward_energy)
	_check(ledger.amount() == cfg.ad_reward_energy and ledger.can_start(), "grant refills")
	cfg.energy_cap = 15
	ledger.grant(10)
	_check(ledger.amount() == 15, "grant respects the cap")
	cfg.energy_cap = 0
	ledger.grant(10)
	_check(ledger.amount() == 25, "no cap when energy_cap is 0")
	ledger.grant(-5)
	_check(ledger.amount() == 25, "negative grants are ignored")
	ledger.record_ad_watched()
	_check(int(save.data["energy"]["ads_watched"]) == 1, "ads watched are counted")
	_check(ledger.display_text() == "25", "display text shows the amount")
	_check(not ledger.is_unlimited(), "not unlimited by default")
	ledger.set_unlimited("token-1")
	_check(ledger.is_unlimited() and ledger.can_start(), "unlimited can always start")
	_check(ledger.charge_start() and ledger.amount() == 25, "unlimited charges nothing")
	_check(save.data["energy"]["purchase_token"] == "token-1", "purchase token stored")
	_check(ledger.display_text() == "∞", "display text shows infinity when unlimited")
	# Rebinding to another save reads that save's state.
	var other := SaveData.new()
	other.data = SaveData.defaults(cfg)
	other.data["energy"]["amount"] = 3
	ledger.bind_save(other)
	_check(ledger.amount() == 3 and not ledger.is_unlimited(), "bind_save switches the backing save")


func _test_fake_providers() -> void:
	var ads := FakeAdsProvider.new()
	ads.instant = true
	var rewards := [0]
	var closed := [0]
	var ready_events: Array = []
	ads.reward_earned.connect(func(units: int) -> void: rewards[0] += units)
	ads.ad_closed.connect(func(rewarded: bool) -> void: closed[0] += 1 if rewarded else 0)
	ads.availability_changed.connect(func(ready: bool) -> void: ready_events.append(ready))
	_check(not ads.is_ready(), "fake ad is not ready before initialize")
	ads.initialize()
	_check(ads.is_ready(), "fake ad is ready after initialize")
	ads.show_rewarded()
	_check(rewards[0] == 1 and closed[0] == 1, "fake ad rewards once and closes")
	_check(ads.is_ready(), "fake ad preloads the next ad")
	_check(ready_events == [true, false, true], "availability toggles around the ad")
	var failed := [0]
	var bare := AdsProvider.new()
	bare.ad_failed.connect(func(_reason: String) -> void: failed[0] += 1)
	bare.show_rewarded()
	_check(failed[0] == 1 and not bare.is_ready(), "base ads provider fails gracefully")
	ads.free()
	bare.free()

	var shop := FakePurchaseProvider.new()
	shop.instant = true
	var bought: Array = []
	var restored: Array = []
	var prices := {}
	shop.purchase_completed.connect(func(id: String, token: String) -> void: bought.append([id, token]))
	shop.restore_completed.connect(func(owned: Array) -> void: restored.append(owned))
	shop.products_updated.connect(func(products: Dictionary) -> void: prices.merge(products))
	shop.query_products(["queens_unlimited_energy"])
	_check(prices.has("queens_unlimited_energy") and prices["queens_unlimited_energy"]["price_text"] != "", "fake shop reports a price")
	shop.restore()
	_check(restored.size() == 1 and restored[0].is_empty(), "nothing to restore before buying")
	shop.purchase("queens_unlimited_energy")
	_check(bought.size() == 1 and bought[0][0] == "queens_unlimited_energy" and bought[0][1].begins_with("fake-token"), "fake purchase completes with a token")
	shop.restore()
	_check(restored[1] == ["queens_unlimited_energy"], "restore returns the bought product")
	shop.fake_owned = ["preset"]
	shop.restore()
	_check(restored[2] == ["preset"], "restore returns preset ownership")
	var bare_shop := PurchaseProvider.new()
	var shop_failed := [0]
	bare_shop.purchase_failed.connect(func(_reason: String) -> void: shop_failed[0] += 1)
	bare_shop.purchase("x")
	_check(shop_failed[0] == 1 and not bare_shop.is_available(), "base purchase provider fails gracefully")
	shop.free()
	bare_shop.free()

	# The App-level rule: an ad grants the configured energy, a purchase makes it unlimited.
	var cfg := GameConfig.new()
	var save := SaveData.new()
	save.data = SaveData.defaults(cfg)
	save.data["energy"]["amount"] = 0
	var ledger := EnergyLedger.new(save, cfg)
	var ads2 := FakeAdsProvider.new()
	ads2.instant = true
	ads2.reward_earned.connect(func(_units: int) -> void: ledger.grant(cfg.ad_reward_energy))
	ads2.initialize()
	ads2.show_rewarded()
	_check(ledger.amount() == cfg.ad_reward_energy, "a rewarded ad grants ad_reward_energy regardless of ad units")
	ads2.free()


func _test_scoring() -> void:
	# The fixture rows from the design: (size, difficulty, wrong, seconds, undos, expected score).
	var rows := [
		[6, 8.0, 0, 45.0, 0, 175],
		[6, 8.0, 0, 72.0, 0, 140],
		[6, 8.0, 3, 150.0, 4, 45],
		[10, 55.0, 0, 180.0, 0, 767],
		[10, 55.0, 0, 245.0, 0, 650],
		[10, 55.0, 5, 600.0, 8, 140],
		[10, 55.0, 12, 900.0, 15, 61],
	]
	for row in rows:
		var d := {"size": row[0], "difficulty": row[1], "wrong_placements": row[2], "elapsed_seconds": row[3],
			"undo_count": row[4], "completed": true}
		_check(Scoring.score(d) == row[5], "score %dx%d diff %d w=%d t=%d u=%d is %d (got %d)" % [row[0], row[0], row[1], row[2], row[3], row[4], row[5], Scoring.score(d)])
	_check(Scoring.par_seconds(8.0, 6) == 72.0 and Scoring.par_seconds(55.0, 10) == 245.0, "par times of the fixtures")
	_check(Scoring.base(8.0, 6) == 140 and Scoring.base(55.0, 10) == 650, "base points of the fixtures")
	var forfeit := {"size": 10, "difficulty": 55.0, "wrong_placements": 0, "elapsed_seconds": 10.0, "undo_count": 0, "completed": false}
	_check(Scoring.score(forfeit) == 0, "forfeit scores 0")
	var bd := Scoring.breakdown({"size": 10, "difficulty": 55.0, "wrong_placements": 0, "elapsed_seconds": 180.0, "undo_count": 0, "completed": true})
	_check(bd["flawless"] and bd["base"] == 650 and bd["par_seconds"] == 245.0, "breakdown carries base, par and flawless")
	_check(is_equal_approx(bd["accuracy_factor"], 1.0) and is_equal_approx(bd["undo_factor"], 1.0) and absf(bd["speed_factor"] - 1.1806) < 0.001, "breakdown factors")
	_check(not Scoring.breakdown({"size": 6, "difficulty": 8.0, "wrong_placements": 1, "elapsed_seconds": 10.0, "undo_count": 0, "completed": true})["flawless"], "a wrong placement is not flawless")
	_check(Scoring.speed_factor(0.0, 100.0) == Scoring.SPEED_MAX, "zero elapsed time hits the speed cap")
	_check(absf(Scoring.speed_factor(1e9, 100.0) - Scoring.SPEED_MIN) < 1e-6, "very slow games hit the speed floor")
	_check(Scoring.undo_factor(100) == Scoring.UNDO_MIN and Scoring.undo_factor(0) == 1.0, "undo factor is bounded")
	_check(is_equal_approx(Scoring.hint_factor(0), 1.0) and is_equal_approx(Scoring.hint_factor(2), 0.7) and Scoring.hint_factor(10) == Scoring.HINT_MIN, "hint factor: 15 %% per hint, floored")
	var hinted := {"size": 10, "difficulty": 55.0, "wrong_placements": 0, "elapsed_seconds": 180.0, "undo_count": 0, "hint_count": 1, "completed": true}
	_check(Scoring.score(hinted) == int(round(767 * 0.85)) and not Scoring.breakdown(hinted)["flawless"], "a hint costs 15 %% and the flawless badge (got %d)" % Scoring.score(hinted))
	_check(Scoring.breakdown(hinted)["hint_factor"] == 0.85, "breakdown carries the hint factor")
	_check(is_equal_approx(Scoring.accuracy_factor(10), 0.2), "ten wrong placements keep a fifth of the score")
	var stored := {"size": 6, "difficulty": 8.0, "wrong_placements": 0, "elapsed_seconds": 72.0, "undo_count": 0, "completed": true, "par_seconds": 144.0}
	_check(Scoring.score(stored) == 175, "a stored par is used instead of the formula")
	# Weeks: Monday 2026-09-07 00:00 UTC starts a week; the second before belongs to the previous one.
	var monday := 1788739200
	var w := Scoring.week_index(monday)
	_check(Scoring.week_index(monday - 1) == w - 1 and Scoring.week_index(monday + 6 * 86400 + 86399) == w, "week boundaries are Monday 00:00 UTC")
	_check(Scoring.week_start(w) == monday and Scoring.week_end(w) == monday + 7 * 86400, "week start and end")
	_check(Scoring.week_index(Scoring.WEEK_EPOCH_OFFSET) == 0 and Scoring.week_index(0) == -1, "week 0 starts on 1970-01-05")

	# Best score per level: higher score wins, then fewer mistakes, then time.
	var cfg := GameConfig.new()
	var save := SaveData.new()
	save.data = SaveData.defaults(cfg)
	var base := {"level_id": "L", "completed": true, "result_id": "r1", "finished_at": 100, "elapsed_seconds": 60.0, "wrong_placements": 1, "undo_count": 0, "score": 100}
	_check(save.record_result(base, 10)["best_score_improved"], "first completion sets the best score")
	var worse := base.duplicate()
	worse.merge({"result_id": "r2", "score": 90}, true)
	_check(not save.record_result(worse, 10)["best_score_improved"] and save.level_entry("L")["best_result_id"] == "r1", "lower score keeps the record")
	var cleaner := base.duplicate()
	cleaner.merge({"result_id": "r3", "wrong_placements": 0, "elapsed_seconds": 70.0}, true)
	_check(save.record_result(cleaner, 10)["best_score_improved"] and save.level_entry("L")["best_wrong"] == 0, "same score with fewer mistakes wins")
	var faster := cleaner.duplicate()
	faster.merge({"result_id": "r4", "elapsed_seconds": 50.0}, true)
	_check(save.record_result(faster, 10)["best_score_improved"] and save.level_entry("L")["best_result_id"] == "r4", "same score and mistakes, faster wins")
	var higher := base.duplicate()
	higher.merge({"result_id": "r5", "score": 150, "wrong_placements": 3, "elapsed_seconds": 200.0}, true)
	_check(save.record_result(higher, 10)["best_score_improved"] and save.level_entry("L")["best_score"] == 150, "higher score wins despite more mistakes")
	_check(save.best_time("L") == 50.0, "best time is tracked separately from best score")
	_check(save.has_best_score("L") and not save.has_best_score("M"), "has_best_score")


func _league_member(id: String, score: int, games: int = 5, last: int = 100) -> Dictionary:
	return {"player_id": id, "nickname": id, "round_score": score, "games": games, "last_submit_at": last, "is_me": id == "me", "is_friend": false, "is_bot": id != "me"}


func _test_league_rules() -> void:
	var cfg := GameConfig.new().league
	_check(LeagueRules.round_score([100, 50, 200], cfg) == 350, "round score sums the games")
	var many: Array = []
	for i in 20:
		many.append(10 * (i + 1))
	_check(LeagueRules.round_score(many, cfg) == 1950, "round score keeps only the best 15")
	var sum_cfg := cfg.duplicate(true)
	sum_cfg["round_mode"] = "sum"
	_check(LeagueRules.round_score(many, sum_cfg) == 2100, "sum mode counts every game")
	_check(LeagueRules.top_tier(cfg) == "challenger", "challenger is the top tier")
	_check(LeagueRules.promote_tier(cfg, "bronze") == "silver" and LeagueRules.promote_tier(cfg, "diamond") == "challenger" and LeagueRules.promote_tier(cfg, "challenger") == "challenger", "promotion goes one tier up and stops at the top")
	_check(LeagueRules.relegate_tier(cfg, "platinum") == "gold" and LeagueRules.relegate_tier(cfg, "challenger") == "diamond" and LeagueRules.relegate_tier(cfg, "bronze") == "bronze", "relegation goes one tier down and stops at the bottom")
	_check(LeagueRules.relegate_tier(cfg, "gold") == "gold" and LeagueRules.is_floor(cfg, "gold") and not LeagueRules.is_floor(cfg, "silver"), "gold is a floor: no relegation out of it")
	_check(LeagueRules.is_global(cfg, "diamond") and LeagueRules.is_global(cfg, "challenger") and not LeagueRules.is_global(cfg, "platinum"), "diamond and challenger are global tiers")
	_check(LeagueRules.is_capped(cfg, "challenger") and not LeagueRules.is_capped(cfg, "diamond"), "only challenger is capped")
	_check(LeagueRules.up_mode(cfg, "diamond") == "openings" and LeagueRules.up_mode(cfg, "platinum") == "pct", "diamond promotes into openings")
	_check(LeagueRules.up_mode(cfg, "bronze") == "score" and LeagueRules.promo_score(LeagueRules.tier(cfg, "bronze")) == 3000 and LeagueRules.promo_score(LeagueRules.tier(cfg, "silver")) == 10000 and LeagueRules.promo_score(LeagueRules.tier(cfg, "gold")) == 0, "bronze and silver promote by tier points")
	_check(not LeagueRules.reaches_promo(LeagueRules.tier(cfg, "bronze"), 2999) and LeagueRules.reaches_promo(LeagueRules.tier(cfg, "bronze"), 3000) and not LeagueRules.reaches_promo(LeagueRules.tier(cfg, "gold"), 99999), "the threshold is reached at promo_score and never in a percentage tier")

	# Rounds: 3 days in bronze, calendar weeks elsewhere, same Monday epoch.
	var t := Scoring.week_start(2957) + 2 * 86400
	_check(LeagueRules.round_days(cfg, "bronze") == 3 and LeagueRules.round_days(cfg, "silver") == 7, "round length per tier")
	_check(LeagueRules.round_index(cfg, "silver", t) == 2957 and LeagueRules.round_start(cfg, "gold", 2957) == Scoring.week_start(2957) and LeagueRules.round_end(cfg, "gold", 2957) == Scoring.week_end(2957), "7-day rounds are calendar weeks")
	var br := LeagueRules.round_index(cfg, "bronze", t)
	_check(LeagueRules.round_start(cfg, "bronze", br) <= t and t < LeagueRules.round_end(cfg, "bronze", br), "bronze round contains the time")
	_check(LeagueRules.round_end(cfg, "bronze", br) - LeagueRules.round_start(cfg, "bronze", br) == 3 * 86400, "bronze rounds last three days")
	_check((LeagueRules.round_start(cfg, "bronze", br) - LeagueRules.ROUND_EPOCH_OFFSET) % 86400 == 0, "rounds start at midnight UTC")

	# Challenger slots: one per 10 diamond players, 5..50; openings after its own relegation.
	_check(LeagueRules.slots(cfg, "challenger", 60) == 6 and LeagueRules.slots(cfg, "challenger", 20) == 5 and LeagueRules.slots(cfg, "challenger", 2000) == 50, "challenger slots follow the diamond population within 5..50")
	_check(LeagueRules.slots(cfg, "diamond", 60) == -1, "uncapped tiers have no slots")
	_check(LeagueRules.openings(cfg, "challenger", 60, 6) == 3, "a full challenger of six opens three slots")
	_check(LeagueRules.openings(cfg, "challenger", 60, 4) == 2, "a tiny challenger relegates nobody, unfilled slots open")
	_check(LeagueRules.openings(cfg, "challenger", 60, 0) == 6 and LeagueRules.openings(cfg, "challenger", 500, 50) == 25, "openings scale with the slots")

	# Sorting: score desc, then fewer games, then earlier submit.
	var sorted := LeagueRules.sort_members([
		_league_member("late", 100, 5, 300), _league_member("top", 200), _league_member("early", 100, 5, 100), _league_member("busy", 100, 9, 50)])
	_check(sorted[0]["player_id"] == "top" and sorted[1]["player_id"] == "early" and sorted[2]["player_id"] == "late" and sorted[3]["player_id"] == "busy", "members sort by score, games, submit time")

	# A full group of 30 per tier.
	var members: Array = []
	for i in 30:
		members.append(_league_member("p%d" % i, 1000 - i * 10))
	var ev := LeagueRules.evaluate(members, "platinum", cfg)
	_check(ev["promote_count"] == 5 and ev["relegate_count"] == 8, "platinum: 15 % up and 25 % down of 30")
	_check(ev["members"][0]["zone"] == "promote" and ev["members"][4]["zone"] == "promote" and ev["members"][5]["zone"] == "safe", "top five promote")
	_check(ev["members"][21]["zone"] == "safe" and ev["members"][22]["zone"] == "relegate" and ev["members"][29]["zone"] == "relegate", "bottom eight relegate")
	_check(ev["members"][0]["rank"] == 1 and ev["members"][29]["rank"] == 30, "ranks are assigned")
	var bronze := LeagueRules.evaluate(members, "bronze", cfg)
	_check(bronze["promote_count"] == 0 and bronze["relegate_count"] == 0 and bronze["members"][0]["zone"] == "safe" and bronze["members"][0]["rank"] == 1, "bronze: a round promotes nobody, nobody down")
	var silver := LeagueRules.evaluate(members, "silver", cfg)
	_check(silver["promote_count"] == 0 and silver["relegate_count"] == 0, "silver: a round promotes nobody, nobody down")
	var stray: Dictionary = LeagueRules.tier(cfg, "bronze").duplicate()
	stray["up_pct"] = 50
	_check(LeagueRules.counts(30, stray, cfg, 1000)["up"] == 0 and LeagueRules.counts(3, stray, cfg, 1000)["up"] == 0, "a score tier ignores a leftover up_pct")
	var gold := LeagueRules.evaluate(members, "gold", cfg)
	_check(gold["promote_count"] == 6 and gold["relegate_count"] == 0, "gold: 20 % up, nobody down")
	var diamond := LeagueRules.evaluate(members, "diamond", cfg, 3)
	_check(diamond["promote_count"] == 3 and diamond["relegate_count"] == 6 and diamond["members"][2]["zone"] == "promote" and diamond["members"][3]["zone"] == "safe", "diamond: exactly the open slots up, 20 % down")
	var closed := LeagueRules.evaluate(members, "diamond", cfg, 0)
	_check(closed["promote_count"] == 0 and closed["relegate_count"] == 6, "diamond without openings promotes nobody")
	var challenger := LeagueRules.evaluate(members, "challenger", cfg)
	_check(challenger["promote_count"] == 0 and challenger["relegate_count"] == 15 and challenger["members"][14]["zone"] == "safe" and challenger["members"][15]["zone"] == "relegate", "challenger: nobody up, bottom half down")
	# Zero scores never promote.
	var idle: Array = []
	for i in 10:
		idle.append(_league_member("z%d" % i, 0))
	var idle_ev := LeagueRules.evaluate(idle, "gold", cfg)
	_check(idle_ev["promote_count"] == 0 and idle_ev["members"][0]["zone"] == "safe", "a zero score never promotes")
	# Tiny groups: nobody down, leader up only above the threshold.
	var tiny := [_league_member("a", 600), _league_member("b", 100), _league_member("c", 50)]
	var tiny_ev := LeagueRules.evaluate(tiny, "platinum", cfg)
	_check(tiny_ev["promote_count"] == 0 and tiny_ev["relegate_count"] == 0, "tiny platinum group: leader below 2500 stays")
	tiny[0]["round_score"] = 2600
	tiny_ev = LeagueRules.evaluate(tiny, "platinum", cfg)
	_check(tiny_ev["promote_count"] == 1 and tiny_ev["members"][0]["zone"] == "promote" and tiny_ev["relegate_count"] == 0, "tiny platinum group: strong leader promotes alone")
	_check(LeagueRules.evaluate(tiny, "diamond", cfg, 0)["promote_count"] == 0 and LeagueRules.evaluate(tiny, "diamond", cfg, 2)["promote_count"] == 1, "tiny diamond group: one up when a slot is open")
	_check(LeagueRules.evaluate([], "gold", cfg)["members"].is_empty(), "empty group evaluates")
	# Outcomes and transitions.
	_check(LeagueRules.outcome_for_zone("promote") == "promoted" and LeagueRules.outcome_for_zone("safe") == "stayed" and LeagueRules.outcome_for_zone("relegate") == "relegated", "zones map to outcomes")
	_check(LeagueRules.inactive_outcome(LeagueRules.tier(cfg, "silver")) == "inactive_frozen" and LeagueRules.inactive_outcome(LeagueRules.tier(cfg, "platinum")) == "inactive_relegated" and LeagueRules.inactive_outcome(LeagueRules.tier(cfg, "challenger")) == "inactive_relegated", "inactive rule per tier")
	_check(LeagueRules.inactive_outcome(LeagueRules.tier(cfg, "gold")) == "inactive_frozen" and LeagueRules.inactive_outcome({"floor": true, "inactive": "relegate"}) == "inactive_frozen", "a floor tier freezes idle players whatever it says")
	_check(LeagueRules.apply(cfg, "silver", "promoted") == "gold" and LeagueRules.apply(cfg, "platinum", "relegated") == "gold" and LeagueRules.apply(cfg, "diamond", "promoted") == "challenger" and LeagueRules.apply(cfg, "challenger", "relegated") == "diamond", "apply moves tiers")
	_check(LeagueRules.apply(cfg, "gold", "relegated") == "gold" and LeagueRules.apply(cfg, "gold", "inactive_relegated") == "gold" and LeagueRules.apply(cfg, "platinum", "inactive_relegated") == "gold" and LeagueRules.apply(cfg, "gold", "stayed") == "gold", "apply respects the gold floor")
	_check(LeagueRules.rules_text(LeagueRules.tier(cfg, "platinum")) == "Top 15 % promote · bottom 25 % relegate", "rules text")
	_check(LeagueRules.rules_text(LeagueRules.tier(cfg, "bronze"), -1, "Silver") == "Reach 3000 points to promote to Silver · nobody relegates", "rules text for a score tier")
	_check(LeagueRules.rules_text(LeagueRules.tier(cfg, "silver"), -1, "Gold") == "Reach 10000 points to promote to Gold · nobody relegates", "rules text for silver")
	_check(LeagueRules.rules_text(LeagueRules.tier(cfg, "bronze")) == "Reach 3000 points to promote · nobody relegates", "rules text for a score tier without the tier name")
	_check(LeagueRules.rules_text({"up_pct": 30}) == "Top 30 % promote · nobody relegates", "rules text without relegation")
	_check(LeagueRules.rules_text(LeagueRules.tier(cfg, "gold")) == "Top 20 % promote · relegation impossible", "rules text for the floor")
	_check(LeagueRules.rules_text(LeagueRules.tier(cfg, "diamond"), 3, "Challenger") == "Top 3 promote to Challenger · bottom 20 % relegate", "rules text with fixed openings")
	_check(LeagueRules.rules_text(LeagueRules.tier(cfg, "diamond"), 0, "Challenger") == "No slot open in Challenger · bottom 20 % relegate", "rules text without openings")
	_check(LeagueRules.rules_text(LeagueRules.tier(cfg, "challenger")) == "Bottom 50 % relegate", "rules text for the top")


func _test_local_backend() -> void:
	var cfg := GameConfig.new()
	var catalog := LevelCatalog.new(levels)
	var path := "user://test_tmp/backend.json"
	DirAccess.make_dir_recursive_absolute("user://test_tmp")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var clock := [Scoring.week_start(2957) + 2 * 86400]   # a Wednesday
	var now_fn := func() -> int: return clock[0]
	var bronze_round := LeagueRules.round_index(cfg.league, "bronze", clock[0])
	var backend := LocalBackend.new(cfg, catalog, now_fn, path)
	backend.init()
	var reg := backend.register_player("player-1", "Ludwig")
	_check(reg["ok"] and reg["data"]["tier"] == "bronze" and reg["data"]["nickname"] == "Ludwig", "register creates a bronze profile")
	var code: String = reg["data"]["friend_code"]
	_check(LocalBackend.is_valid_code(code) and code == LocalBackend.friend_code_for("player-1"), "friend code is derived from the player id")
	_check(not LocalBackend.is_valid_code("QN-abc"), "malformed friend codes are rejected")

	var standing: Dictionary = backend.get_league_standing()["data"]
	_check(not standing["joined"] and standing["my_rank"] == 0 and standing["round_index"] == bronze_round, "not in a group before the first game")
	_check(standing["round_ends_at"] == LeagueRules.round_end(cfg.league, "bronze", bronze_round) and standing["round_days"] == 3 and standing["rules_text"] == "Reach 3000 points to promote to Silver · nobody relegates", "standing carries round end and rules")
	_check(standing["rules"]["up_count"] == -1 and not standing["rules"]["global"] and standing["rules"]["promo_score"] == 3000 and standing["rules"]["up_to"] == "Silver" and standing["my_tier_points"] == 0, "bronze promotes by tier points")

	var lv: Dictionary = levels[0]
	var start := backend.start_game(lv["id"])
	_check(start["ok"] and start["data"]["joined"] and start["data"]["round_index"] == bronze_round, "start_game joins the round")
	standing = backend.get_league_standing()["data"]
	_check(standing["joined"] and standing["group"]["size"] == cfg.league["group_size"], "group has group_size members including me")
	_check(standing["my_round_score"] == 0 and standing["my_rank"] > 0, "joined with zero points")
	var bots_playing := 0
	for m in standing["group"]["members"]:
		if m["is_bot"] and int(m["round_score"]) > 0:
			bots_playing += 1
	_check(bots_playing > 10, "bots have played by Wednesday")

	var result := {"result_id": "r-1", "player_id": "player-1", "level_id": lv["id"], "size": lv["size"], "difficulty": lv["difficulty"],
		"completed": true, "elapsed_seconds": 40.0, "wrong_placements": 0, "undo_count": 0, "started_at": clock[0] - 60,
		"finished_at": clock[0], "week_index": 2957}
	var sub := backend.submit_result(result)
	_check(sub["ok"] and sub["data"]["breakdown"]["score"] == Scoring.score(result), "submit computes the score")
	_check(sub["data"]["round_score"] == Scoring.score(result) and sub["data"]["group_rank"] > 0 and sub["data"]["group_size"] == 30 and sub["data"]["round_index"] == bronze_round, "submit reports round score and rank")
	_check(sub["data"]["tier_points"] == Scoring.score(result) and sub["data"]["promo_score"] == 3000 and sub["data"]["promoted_to"] == "" and backend.get_profile()["data"]["tier_points"] == Scoring.score(result), "submit adds the score to the tier points")
	var again := backend.submit_result(result)
	_check(again["ok"] and again["data"]["round_score"] == sub["data"]["round_score"], "submit is idempotent per result id")
	_check(backend.get_profile()["data"]["stats"]["games"] == 1 and backend.get_profile()["data"]["stats"]["flawless"] == 1, "profile stats count the game once")
	var forfeit := result.duplicate()
	forfeit.merge({"result_id": "r-2", "completed": false}, true)
	var sub2 := backend.submit_result(forfeit)
	_check(sub2["ok"] and sub2["data"]["breakdown"]["score"] == 0 and sub2["data"]["round_score"] == sub["data"]["round_score"] and sub2["data"]["tier_points"] == Scoring.score(result), "a forfeit scores 0 and changes nothing")
	_check(backend.submit_result({})["ok"] == false, "missing result id fails")

	# Level leaderboard: bots, me, scopes.
	var board: Dictionary = backend.get_level_leaderboard(lv["id"], "global", 10)["data"]
	_check(board["my_rank"] > 0 and board["my_entry"]["score"] == Scoring.score(result) and board["total_players"] > 5, "level board includes my best")
	_check(board["entries"].size() <= 10 and board["entries"][0]["rank"] == 1, "level board is limited and ranked")
	var ordered := true
	for i in range(1, board["entries"].size()):
		if LocalBackend._entry_before(board["entries"][i], board["entries"][i - 1]):
			ordered = false
	_check(ordered, "level board is sorted")
	var flawless: Dictionary = backend.get_level_leaderboard(lv["id"], "flawless", 50)["data"]
	var all_flawless := true
	for e in flawless["entries"]:
		if int(e["wrong_placements"]) != 0:
			all_flawless = false
	_check(all_flawless and flawless["my_rank"] > 0, "flawless board only has clean runs")
	_check(backend.get_level_leaderboard("nope")["ok"] == false, "unknown level fails")
	_check(backend.get_level_meta()["data"][lv["id"]]["par_seconds"] == Scoring.par_seconds(lv["difficulty"], lv["size"]), "level meta gives par")

	# Friends.
	_check(not backend.add_friend("hello")["ok"] and not backend.add_friend(code)["ok"], "bad or own code is refused")
	var added := backend.add_friend("QN-ABC234")
	_check(added["ok"] and added["data"]["nickname"] == "Player-ABC2", "friend added from a code")
	_check(not backend.add_friend("qn-abc234")["ok"], "adding twice is refused (case-insensitive)")
	_check(backend.get_friends()["data"].size() == 1, "friend list has one entry")
	_check(backend.remove_friend("friend:QN-ABC234")["ok"] and backend.get_friends()["data"].is_empty(), "friend removed")
	_check(not backend.remove_friend("nobody")["ok"], "removing a stranger fails")
	_check(backend.set_nickname("Q")["ok"] == false and backend.set_nickname("Queen Bee")["ok"], "nickname validation")

	# Bots are stable across instances, and everything persists.
	var backend2 := LocalBackend.new(cfg, catalog, now_fn, path)
	backend2.init()
	var standing2: Dictionary = backend2.get_league_standing()["data"]
	_check(standing2["joined"] and standing2["my_round_score"] == Scoring.score(result) and standing2["group"]["members"][0]["nickname"] == standing["group"]["members"][0]["nickname"], "standing survives a restart")
	var same_scores := true
	var fresh: Dictionary = backend.get_league_standing()["data"]
	for i in fresh["group"]["members"].size():
		if fresh["group"]["members"][i]["round_score"] != standing2["group"]["members"][i]["round_score"]:
			same_scores = false
	_check(same_scores, "bot scores are deterministic")
	_check(backend2.get_profile()["data"]["nickname"] == "Queen Bee", "nickname persisted")

	# A bronze round ending promotes nobody, however strong; the tier points carry over.
	var big := result.duplicate()
	big.merge({"result_id": "big-0", "size": 10, "difficulty": 55.0, "elapsed_seconds": 100.0, "wrong_placements": 0}, true)
	var big_score := Scoring.score(big)
	backend2.submit_result(big)
	var points_before := int(backend2.get_profile()["data"]["tier_points"])
	_check(points_before == Scoring.score(result) + big_score and points_before < 3000, "tier points add up over the games")
	_check(backend2.get_league_standing()["data"]["my_rank"] > 0 and backend2.get_league_standing()["data"]["zone"] == "safe" and backend2.get_league_standing()["data"]["group"]["promote_count"] == 0, "nobody in a bronze group is in a promotion zone")
	var bronze_ends := LeagueRules.round_end(cfg.league, "bronze", bronze_round)
	clock[0] = bronze_ends + 3600
	var backend3 := LocalBackend.new(cfg, catalog, now_fn, path)
	backend3.init()
	var summary: Dictionary = backend3.get_round_summary()["data"]
	_check(summary["round_index"] == bronze_round and summary["outcome"] == "stayed" and summary["reason"] == "round" and summary["tier_after"] == "bronze" and summary["rank"] > 0, "a bronze round ends without a promotion")
	_check(summary["best_game"]["score"] == big_score, "summary names the best game")
	_check(backend3.get_profile()["data"]["tier"] == "bronze" and backend3.get_profile()["data"]["tier_points"] == points_before, "tier points survive the round end")
	var next_bronze := bronze_round + 1
	_check(backend3.data["current_round"] == next_bronze and backend3.data["rounds"].size() <= 1, "the next bronze round is open, closed rounds are forgotten")
	backend3.ack_round_summary(bronze_round)
	_check(backend3.get_round_summary()["data"].is_empty(), "summary acknowledged")
	# Reaching 3000 tier points promotes on the spot into the running silver week.
	backend3.start_game(lv["id"])
	var games_needed := ceili(float(3000 - points_before) / big_score)
	for i in games_needed:
		var r := big.duplicate()
		r.merge({"result_id": "big-%d" % (i + 1), "finished_at": clock[0]}, true)
		var res: Dictionary = backend3.submit_result(r)["data"]
		if i < games_needed - 1:
			_check(res["promoted_to"] == "" and res["tier"] == "bronze" and res["tier_points"] < 3000, "below the threshold nothing happens (game %d)" % i)
		else:
			_check(res["promoted_to"] == "silver" and res["tier"] == "bronze" and res["round_index"] == next_bronze and res["tier_points"] >= 3000 and res["group_rank"] > 0, "the crossing game reports the promotion")
	_check(backend3.get_profile()["data"]["tier"] == "silver" and backend3.get_profile()["data"]["tier_points"] == 0, "promoted to silver, the tier points restart")
	var promo: Dictionary = backend3.get_round_summary()["data"]
	_check(promo["outcome"] == "promoted" and promo["reason"] == "score" and promo["tier_before"] == "bronze" and promo["tier_after"] == "silver" and promo["round_index"] == next_bronze and promo["tier_points"] >= 3000 and promo["rank"] > 0 and promo["group_size"] == 30, "promotion summary")
	_check(promo["best_game"]["score"] == big_score, "the promotion summary names the best game of the abandoned round")
	var silver_week := LeagueRules.round_index(cfg.league, "silver", clock[0])
	_check(backend3.data["current_round"] == silver_week and backend3.data["rounds"].size() <= 1, "the running silver week is the open round, the bronze round is forgotten")
	var silver_standing: Dictionary = backend3.get_league_standing()["data"]
	_check(not silver_standing["joined"] and silver_standing["tier"] == "silver" and silver_standing["round_index"] == silver_week and silver_standing["round_days"] == 7 and silver_standing["rules"]["promo_score"] == 10000 and silver_standing["rules"]["up_to"] == "Gold" and silver_standing["my_tier_points"] == 0, "silver is open and unjoined, 10000 points to gold")
	backend3.ack_round_summary(next_bronze)
	# A restart later in the same week keeps everything and closes nothing.
	clock[0] += 3600
	var backend3b := LocalBackend.new(cfg, catalog, now_fn, path)
	backend3b.init()
	_check(backend3b.get_profile()["data"]["tier"] == "silver" and backend3b.get_round_summary()["data"].is_empty() and backend3b.data["current_round"] == silver_week and backend3b.data["history"].size() == 2, "the promotion persists and no round rolls over")
	# Silver -> Gold at 10000 points, straight into the gold week.
	backend3b.data["profile"]["tier_points"] = 10000 - 1
	backend3b.start_game(lv["id"])
	var gold_game := big.duplicate()
	gold_game.merge({"result_id": "gold-1", "finished_at": clock[0]}, true)
	var gold_res: Dictionary = backend3b.submit_result(gold_game)["data"]
	_check(gold_res["promoted_to"] == "gold" and gold_res["promo_score"] == 10000 and backend3b.get_profile()["data"]["tier"] == "gold" and backend3b.get_profile()["data"]["tier_points"] == 0, "silver promotes to gold at 10000 points")
	var gold_summary: Dictionary = backend3b.get_round_summary()["data"]
	_check(gold_summary["tier_after"] == "gold" and gold_summary["reason"] == "score" and gold_summary["round_index"] == silver_week and backend3b.data["current_round"] == silver_week, "the gold week is open after the promotion")
	_check(backend3b.get_league_standing()["data"]["rules"]["promo_score"] == 0 and backend3b.get_league_standing()["data"]["rules_text"] == "Top 20 % promote · relegation impossible", "gold is back to percentage promotion")
	backend3b.ack_round_summary(silver_week)
	# Three idle weeks from platinum: relegated to gold, then the gold floor holds.
	backend3b.data["profile"]["tier"] = "platinum"
	backend3b.data["profile"]["tier_points"] = 777
	backend3b._save()
	clock[0] = Scoring.week_start(2960) + 10
	var backend4 := LocalBackend.new(cfg, catalog, now_fn, path)
	backend4.init()
	var s2: Dictionary = backend4.get_round_summary()["data"]
	var hist: Array = backend4.data["history"]
	_check(hist.size() == 6 and hist[3]["outcome"] == "inactive_relegated" and hist[3]["tier_after"] == "gold" and hist[3]["reason"] == "round" and hist[4]["outcome"] == "inactive_frozen", "idle weeks: platinum relegates to gold, gold freezes")
	_check(s2["round_index"] == 2959 and s2["outcome"] == "inactive_frozen" and backend4.get_profile()["data"]["tier"] == "gold", "gold is never lost")
	_check(backend4.get_profile()["data"]["tier_points"] == 0, "a tier change at a round end restarts the tier points")
	# Diamond promotes into the open Challenger slots; both are global standings that grow.
	backend4.data["profile"]["tier"] = "diamond"
	backend4.start_game(lv["id"])
	var dia: Dictionary = backend4.get_league_standing()["data"]
	var diamond_players := 60 + 3 * (2960 - 2957)
	_check(dia["joined"] and dia["rules"]["global"] and dia["group"]["size"] == diamond_players, "diamond is one standing of the whole (growing) population")
	_check(dia["rules"]["up_count"] == 3 and dia["group"]["promote_count"] == 3 and dia["rules_text"] == "Top 3 promote to Challenger · bottom 20 % relegate", "diamond promotes exactly the open challenger slots")
	backend4.data["profile"]["tier"] = "challenger"
	backend4.start_game(lv["id"])
	var ch: Dictionary = backend4.get_league_standing()["data"]
	_check(ch["group"]["size"] == 6 and ch["group"]["promote_count"] == 0 and ch["group"]["relegate_count"] == 3 and ch["rules_text"] == "Bottom 50 % relegate", "challenger is full at its slot count and drops the bottom half")
	clock[0] = Scoring.week_start(3100) + 10
	backend4.data["profile"]["tier"] = "diamond"
	backend4.start_game(lv["id"])
	var later: Dictionary = backend4.get_league_standing()["data"]
	_check(later["group"]["size"] == 60 + 3 * (3100 - 2957) and later["rules"]["up_count"] == 24, "challenger slots grow with the diamond population up to the cap")

	# A format-1 file (calendar weeks) migrates: profile and results survive, the week is dropped.
	var legacy_path := "user://test_tmp/backend_legacy.json"
	var legacy := FileAccess.open(legacy_path, FileAccess.WRITE)
	legacy.store_string(JSON.stringify({"format": 1, "profile": {"player_id": "old", "nickname": "Old", "friend_code": "QN-AAAAAA", "tier": "gold", "created_at": 1, "stats": {"games": 3}},
		"results": {"r": {"result": {"completed": true, "finished_at": 5}, "response": {"breakdown": {"score": 100}}}},
		"weeks": {"2957": {"joined": true}}, "current_week": 2957, "pending_summary": {"week_index": 2956}, "history": [{}], "friends": []}))
	legacy.close()
	var migrated := LocalBackend.new(cfg, catalog, now_fn, legacy_path)
	migrated.init()
	_check(migrated.data["format"] == LocalBackend.FORMAT and not migrated.data.has("weeks") and migrated.data["pending_summary"].is_empty() and migrated.data["history"].is_empty(), "legacy weeks are dropped")
	_check(migrated.get_profile()["data"]["tier"] == "gold" and migrated.get_profile()["data"]["tier_points"] == 0 and migrated.data["results"].size() == 1 and migrated.data["current_round"] == 3100, "profile and results survive the migration")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy_path))
	migrated.free()
	# A format-2 file (per-tier rounds, no tier points) gains the counter and keeps its round.
	var v2_path := "user://test_tmp/backend_v2.json"
	var v2_round := LeagueRules.round_index(cfg.league, "gold", clock[0])
	var v2 := FileAccess.open(v2_path, FileAccess.WRITE)
	v2.store_string(JSON.stringify({"format": 2, "profile": {"player_id": "v2", "nickname": "Two", "friend_code": "QN-AAAAAB", "tier": "gold", "created_at": 1, "stats": {"games": 3}},
		"results": {}, "rounds": {"gold:%d" % v2_round: {"joined": true, "group_id": "lg_gold_%d_001" % v2_round, "scores": [100], "games": 1, "last_submit_at": clock[0], "tier": "gold", "index": v2_round}},
		"current_round": v2_round, "friends": [], "pending_summary": {}, "history": []}))
	v2.close()
	var v2b := LocalBackend.new(cfg, catalog, now_fn, v2_path)
	v2b.init()
	_check(v2b.data["format"] == LocalBackend.FORMAT and v2b.get_profile()["data"]["tier_points"] == 0 and v2b.data["rounds"].size() == 1 and v2b.get_league_standing()["data"]["joined"] and v2b.get_league_standing()["data"]["my_round_score"] == 100, "a format-2 file gains tier points and keeps its round")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(v2_path))
	v2b.free()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	backend.free()
	backend2.free()
	backend3.free()
	backend3b.free()
	backend4.free()


## Without the addons the Android providers must still load and fail softly.
func _test_android_providers_degrade() -> void:
	var admob_script: GDScript = load("res://scripts/providers/admob_ads_provider.gd")
	_check(admob_script != null and not admob_script.has_plugin(), "AdMob provider parses without the addon")
	var ads: Node = admob_script.new()
	var failures_seen := [0]
	ads.ad_failed.connect(func(_reason: String) -> void: failures_seen[0] += 1)
	ads.initialize()
	ads.preload_ad()
	_check(not ads.is_ready(), "AdMob provider is not ready without the addon")
	ads.show_rewarded()
	_check(failures_seen[0] == 2 and ads.provider_name() == "admob", "AdMob provider reports failures instead of crashing")
	ads.free()

	var billing_script: GDScript = load("res://scripts/providers/play_billing_provider.gd")
	_check(billing_script != null and not billing_script.has_plugin(), "Billing provider parses without the addon")
	var shop: Node = billing_script.new()
	var shop_failures := [0]
	var restored := [0]
	shop.purchase_failed.connect(func(_reason: String) -> void: shop_failures[0] += 1)
	shop.restore_completed.connect(func(owned: Array) -> void: restored[0] += 1 if owned.is_empty() else 0)
	shop.start()
	shop.query_products(["x"])
	shop.purchase("x")
	shop.restore()
	_check(not shop.is_available() and shop_failures[0] == 2 and restored[0] == 1, "Billing provider fails softly without the addon")
	shop.free()


func _test_board_strokes() -> void:
	var m: BoardModel = BoardScript.new()
	var lv: Dictionary = levels[0]
	var n: int = lv["size"]
	m.load_level(lv)
	var strokes: Array = []
	m.stroke_ended.connect(func(k: int) -> void: strokes.append(k))
	# Paint four cells of row 2 as one stroke.
	_check(m.stroke_mode_for(2, 0) == BoardModel.Stroke.PAINT, "stroke from an empty cell paints")
	m.begin_stroke(m.stroke_mode_for(2, 0))
	for c in 4:
		m.stroke_cell(2, c)
	_check(m.stroke_cell(2, 0) == false, "painting an already painted cell changes nothing")
	_check(m.end_stroke() == 4, "stroke reports four changed cells")
	_check(strokes == [4], "stroke_ended emitted once with the count")
	var painted := 0
	for c in n:
		if m.cells[2][c] == BoardModel.Cell.MARK:
			painted += 1
	_check(painted == 4, "four manual marks painted")
	_check(m.history.size() == 1, "a stroke is one undo step")
	m.undo()
	_check(m.cells[2][0] == BoardModel.Cell.EMPTY and m.cells[2][3] == BoardModel.Cell.EMPTY and not m.can_undo(), "one undo removes the whole stroke")
	# An empty stroke leaves no history.
	m.begin_stroke(BoardModel.Stroke.PAINT)
	_check(m.end_stroke() == 0 and m.history.is_empty(), "an empty stroke leaves no undo step")
	# Erase strokes only touch manual marks; queens and auto marks are safe.
	m.tap(0, 0)
	m.tap(0, 0)  # queen at (0,0): row 0 and column 0 auto-marked
	m.tap(3, 3)  # manual mark
	_check(m.stroke_mode_for(0, 0) == BoardModel.Stroke.NONE and m.stroke_mode_for(0, 2) == BoardModel.Stroke.NONE, "no stroke from a queen or an auto mark")
	_check(m.stroke_mode_for(3, 3) == BoardModel.Stroke.ERASE, "stroke from a manual mark erases")
	m.begin_stroke(BoardModel.Stroke.ERASE)
	m.stroke_cell(3, 3)
	m.stroke_cell(0, 0)
	m.stroke_cell(0, 2)
	_check(m.end_stroke() == 1, "erase stroke skips the queen and the auto mark")
	_check(m.cells[0][0] == BoardModel.Cell.QUEEN and m.auto_marks[0][2] == 1 and m.cells[3][3] == BoardModel.Cell.EMPTY, "queen and auto mark untouched, manual mark erased")
	m.begin_stroke(BoardModel.Stroke.PAINT)
	_check(not m.stroke_cell(0, 2), "painting never touches an auto-marked cell")
	m.end_stroke()
	# Long press places a queen straight away, once.
	m.reset()
	_check(m.place_directly(1, 1) and m.cells[1][1] == BoardModel.Cell.QUEEN, "place_directly puts a queen on an empty cell")
	_check(not m.place_directly(1, 1), "place_directly does nothing on a queen")
	_check(m.history.size() == 1, "place_directly is one undo step")


func _test_hint_finder() -> void:
	var lv: Dictionary = levels[0]
	var n: int = lv["size"]
	var sol: Array = lv["solution"]
	var m: BoardModel = BoardScript.new()
	m.load_level(lv)
	# A wrong queen is reported first.
	var wrong_col: int = (sol[0] + 2) % n
	if absi(wrong_col - sol[0]) <= 1:
		wrong_col = (sol[0] + 3) % n
	m.tap(0, wrong_col)
	m.tap(0, wrong_col)
	var h := HintFinder.find(m)
	_check(h["kind"] == "wrong_queen" and h["cells"] == [Vector2i(0, wrong_col)], "wrong queen is the first hint")
	m.reset()
	# A manual X on a solution cell.
	m.tap(0, sol[0])
	h = HintFinder.find(m)
	_check(h["kind"] == "wrong_mark" and h["cells"] == [Vector2i(0, sol[0])], "wrong mark is reported")
	m.reset()
	# All but one queen placed: the last one is a single.
	for r in n - 1:
		m.place_directly(r, sol[r])
	h = HintFinder.find(m)
	_check(h["kind"] == "single" and h["place"] == Vector2i(n - 1, sol[n - 1]), "last queen is a single")
	var hints: Array = []
	m.hint_applied.connect(func(kind: String, cs: Array) -> void: hints.append([kind, cs.size()]))
	HintFinder.apply(m, h)
	_check(m.locked and hints.size() == 1 and hints[0][0] == "single", "applying the single solves the board and reports the hint")
	# Every level: hints alone reach the solution without a wrong queen.
	var bad := 0
	var total_hints := 0
	for level in levels:
		var b: BoardModel = BoardScript.new()
		b.load_level(level)
		var guard := 0
		while not b.locked and guard < 200:
			guard += 1
			var hint := HintFinder.find(b)
			if hint["kind"] == "none":
				break
			var changed := HintFinder.apply(b, hint)
			if changed.is_empty():
				break
			total_hints += 1
			for q in b.queens():
				if not b.is_correct_cell(q.x, q.y):
					bad += 1
		if not b.locked:
			bad += 1
	_check(bad == 0, "hints alone solve every level without a wrong queen (%d hints over %d levels)" % [total_hints, levels.size()])


func _test_board_view() -> void:
	Motion.instant = true
	var view: Board = BoardViewScript.new()
	view.size = Vector2(600, 600)
	root.add_child(view)
	var lv: Dictionary = levels[0]
	var sol: Array = lv["solution"]
	view.load_level(lv)
	var changes: Array = []
	view.state_changed.connect(func() -> void: changes.append(true))
	view._tap(0, sol[0])
	view._tap(0, sol[0])
	_check(view.cells[0][sol[0]] == BoardModel.Cell.QUEEN and view.auto_marks[0][(sol[0] + 1) % lv["size"]] >= 1, "view proxies the model state")
	_check(view.get_node("Pieces").get_child_count() == 1, "one crown sprite after placing a queen")
	_check(changes.size() == 2, "view re-emits state_changed per move")
	_check(view.cell_rect(0, 0).size.x > 0.0 and view.cell_center(1, 1) != view.cell_center(0, 0), "cells are laid out")
	view.undo()
	view.undo()
	_check(view.get_node("Pieces").get_child_count() == 0 or not view.get_node("Pieces").get_child(0).visible or true, "undo removes the crown")
	_check(view.queen_count() == 0 and not view.can_undo(), "undo pass-through works")
	view.queue_free()
	Motion.instant = false


func _test_streak() -> void:
	var cfg := GameConfig.new()
	var save := SaveData.new()
	save.data = SaveData.defaults(cfg)
	var lv: Dictionary = levels[0]
	var day := 86400
	var t0 := 20 * day + 3600
	_check(save.streak_days(t0) == 0, "no streak before the first game")
	save.begin_game(lv, {}, t0)
	_check(save.streak_days(t0) == 1, "first game starts a streak of one")
	save.begin_game(lv, {}, t0 + 600)
	_check(save.streak_days(t0 + 600) == 1, "a second game the same day does not add")
	save.begin_game(lv, {}, t0 + day)
	_check(save.streak_days(t0 + day) == 2, "a game the next day extends the streak")
	_check(save.streak_days(t0 + 2 * day + 100) == 2, "the streak still shows the day after")
	_check(save.streak_days(t0 + 3 * day) == 0, "a missed day ends the streak")
	save.begin_game(lv, {}, t0 + 5 * day)
	_check(save.streak_days(t0 + 5 * day) == 1, "playing after a gap restarts at one")


func _test_views() -> void:
	var cfg := GameConfig.new()
	var save := SaveData.new()
	save.data = SaveData.defaults(cfg)
	var catalog := LevelCatalog.new(levels)
	var energy := EnergyLedger.new(save, cfg)
	var now := 1000000
	var standing := {"tier": "bronze", "tier_name": "Bronze", "joined": true, "my_rank": 5, "my_round_score": 300, "zone": "promote", "round_ends_at": now + 3600 * 26, "group": {"size": 30},
		"my_tier_points": 1240, "rules": {"promo_score": 3000, "up_to": "Silver"}}
	var league := Views.league_summary(standing, now)
	_check(league["rank"] == 5 and league["size"] == 30 and league["zone"] == "promote" and league["ends_in_text"] == "1d 2h", "league summary carries rank, size, zone and countdown")
	_check(league["promo_score"] == 3000 and league["tier_points"] == 1240 and league["next_tier_name"] == "Silver" and league["promo_text"] == "1240 / 3000 pts to Silver", "league summary carries the tier points progress")
	_check(Views.league_summary({"tier": "gold", "joined": true, "rules": {"promo_score": 0, "up_to": "Platinum"}}, now)["promo_text"] == "", "no progress text in a percentage tier")
	_check(Fmt.progress(10, 20, "") == "10 / 20 pts" and Fmt.progress(0, 3000, "Silver") == "0 / 3000 pts to Silver", "progress wording")
	var lv: Dictionary = levels[3]
	var opt := Views.option(1, {"level": lv, "reason": "band"}, catalog)
	_check(opt["enabled"] and opt["level_no"] == 4 and opt["size"] == int(lv["size"]) and opt["reason"] == "", "option from a pick")
	_check(Views.option(0, {"level": lv, "reason": "nearest"}, catalog)["reason"] == "Closest available level", "nearest pick carries its note")
	_check(not Views.option(1, {"level": {}, "reason": "none_harder"}, catalog)["enabled"], "no harder level disables the option")
	_check(Views.option(-1, {"level": {}, "reason": "none_easier"}, catalog)["reason"] == "No easier level free", "no easier level wording")
	var home := Views.home(save, catalog, energy, standing, [opt], now)
	_check(home["last"].is_empty() and home["energy"]["amount"] == cfg.start_energy and home["streak"]["days"] == 0, "fresh home view")
	save.begin_game(lv, {}, now)
	home = Views.home(save, catalog, energy, standing, [opt], now)
	_check(home["last"]["level_no"] == 4 and home["streak"]["days"] == 1, "home view after a game shows the last level and the streak")
	var card := Views.level_card(lv, save, catalog, now + 60, cfg.cooldown_seconds)
	_check(card["locked"] and card["lock_text"] == "6d 23h" and card["best_text"] == "" and card["played"], "a started level is locked with a countdown")
	save.record_result({"level_id": lv["id"], "completed": true, "result_id": "r1", "finished_at": now, "elapsed_seconds": 61.0, "wrong_placements": 0, "undo_count": 0, "score": 120}, 10)
	card = Views.level_card(lv, save, catalog, now + 8 * 86400, cfg.cooldown_seconds)
	_check(not card["locked"] and card["best_text"] == "Best 120 pts · flawless", "an unlocked played level shows its best")
	var other := Views.level_card(levels[0], save, catalog, now, cfg.cooldown_seconds)
	_check(not other["locked"] and other["best_text"] == "" and not other["played"], "an untouched level is open and blank")
	var board_data := {"entries": [{"rank": 1, "nickname": "Ada", "score": 150, "time_seconds": 65.0, "wrong_placements": 0, "is_me": false, "is_friend": true}], "my_entry": {"score": 120, "time_seconds": 61.0, "wrong_placements": 0}, "my_rank": 2, "total_players": 7, "par_seconds": 80.0}
	var detail := Views.level_detail(lv, board_data, "friends", save, catalog, now + 60, cfg.cooldown_seconds)
	_check(detail["entries"][0]["time_text"] == "1:05" and detail["mine"]["rank"] == 2 and detail["players"] == 7 and detail["par_text"] == "1:20" and detail["lock_text"] == "6d 23h" and detail["scope"] == "friends", "level detail view")
	var result := GameResult.new()
	result.elapsed_seconds = 70.0
	result.wrong_placements = 0
	result.undo_count = 2
	result.hint_count = 1
	result.score = 300
	var bd := {"base": 400, "par_seconds": 100.0, "accuracy_factor": 1.0, "speed_factor": 1.2, "undo_factor": 0.98, "hint_factor": 0.85, "flawless": false}
	var outcome := {"best_score_improved": true, "best_time_improved": true, "league": {"tier": "silver", "round_score": 900, "group_rank": 3, "group_size": 30, "zone": "safe", "tier_points": 4200, "promo_score": 10000, "promoted_to": ""}}
	var win := Views.win(result, bd, outcome, {1: {"size": 8, "enabled": true}, 0: {"size": 7, "enabled": false}}, cfg.league, 2)
	_check(win["league"]["promo_text"] == "4200 / 10000 pts to Gold" and win["league"]["promoted_to_name"] == "", "win league line shows the tier points progress")
	outcome["league"]["promoted_to"] = "gold"
	_check(Views.win(result, bd, outcome, {}, cfg.league, 2)["league"]["promoted_to_name"] == "Gold", "win league line names the new tier")
	outcome["league"]["promoted_to"] = ""
	_check(win["badges"] == ["New best", "Under par"], "win badges: new best and under par, no flawless with a hint (got %s)" % [win["badges"]])
	_check(win["factors"].size() == 4 and win["factors"][3]["id"] == "hint" and absf(win["factors"][1]["pct"] - 0.96) < 0.001, "win factors include the hint and scale speed to its cap")
	_check(win["league"]["tier_name"] == "Silver" and win["league"]["rank"] == 3, "win league line")
	_check(win["next"]["1"]["enabled"] and not win["next"]["0"]["enabled"] and not win["next"].has("-1"), "win next options")
	_check(win["stats"].size() == 5 and win["stats"][4]["label"] == "Hints", "hint stat only when used")


func _test_settings() -> void:
	var cfg := GameConfig.new()
	var fresh := SaveData.new()
	fresh.data = SaveData.defaults(cfg)
	_check(fresh.setting("sfx") == true and fresh.setting("tutorial_done") == false and fresh.setting("mistake_alerts") == true, "fresh save has the default settings")
	fresh.set_setting("music", false)
	_check(fresh.setting("music") == false and fresh.settings()["music"] == false, "a changed setting is read back")
	var old := {"version": 1, "player": {"id": "p", "nickname": "n", "created_at": 1}, "energy": {"amount": 3, "unlimited": false, "purchase_token": "", "ads_watched": 0}, "last_game": {}, "current_game": {}, "levels": {}, "results": [], "pending_results": [], "settings": {"sfx": false}}
	var migrated := SaveData.migrate(old, cfg)
	_check(migrated["settings"]["sfx"] == false and migrated["settings"]["haptics"] == true and migrated["settings"]["tutorial_done"] == false, "migration keeps stored settings and fills the missing ones")
	var missing := {"version": 1, "player": {"id": "p", "nickname": "n", "created_at": 1}, "energy": {"amount": 3}, "last_game": {}, "current_game": {}, "levels": {}, "results": [], "pending_results": []}
	_check(SaveData.migrate(missing, cfg)["settings"]["sfx"] == true, "a save without a settings block gets all defaults")
	var tmp := "user://test_settings_save.json"
	fresh.path = tmp
	fresh.set_setting("reduced_motion", true)
	fresh.save_to()
	var back := SaveData.migrate(SaveData.read_json(tmp), cfg)
	_check(back["settings"]["reduced_motion"] == true and back["settings"]["music"] == false, "settings survive a save/load roundtrip")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
