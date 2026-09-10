extends Node
## Visual smoke test: instantiates the main scene, plays part of a level and
## writes screenshots. Uses its own save file so real progress is untouched.
## Run with:
##   godot --path queens res://tests/screenshot.tscn -- <output_dir> [locale]
## With a locale ("de") the shots are taken in that language and the files
## get a "_de" suffix.
##
## The window is resized to the design resolution first, so the shots come
## out at 720x1280 whatever the window override in project.godot says.

const MainScene := preload("res://scenes/main.tscn")
const SAVE_PATH := "user://screenshot_save.json"

var _locale: String = ""   ## "" keeps the device language (English in CI).


func _ready() -> void:
	_use_design_resolution()
	var out_dir := "user://"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].trim_suffix("/").trim_suffix("\\") + "/"
	if args.size() > 1:
		_locale = args[1]
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	App.use_save_path(SAVE_PATH)
	App.save.set_setting("tutorial_done", true)
	# use_save_path does not re-apply settings, so the language is pushed here.
	App.save.set_setting("language", _locale)
	App.apply_settings()
	Motion.instant = true

	var main: Control = MainScene.instantiate()
	add_child(main)
	await _frames(3)
	_save(out_dir + "01_home_fresh.png")

	var index := 0  # first 7x7 board
	for i in main.levels.size():
		if int(main.levels[i]["size"]) == 7:
			index = i
			break
	main.debug.start_level(index)
	await _frames(2)
	var board: Control = main.board
	var sol: Array = board.solution

	# Verify the real input path: a synthetic touch on cell (2, 2) must mark it.
	_touch(board.cell_center(2, 2), true)
	await _frames(1)
	_touch(board.cell_center(2, 2), false)
	await _frames(1)
	print("touch test: cell (2,2) state = %s (expected MARK=1)" % board.cells[2][2])
	# A drag across three cells of row 5 paints three marks as one stroke.
	_touch(board.cell_center(5, 0), true)
	await _frames(1)
	for c in [1, 2]:
		_drag(board.cell_center(5, c))
		await _frames(1)
	_touch(board.cell_center(5, 2), false)
	await _frames(1)
	print("drag test: row 5 marks = %s %s %s (expected 1 1 1)" % [board.cells[5][0], board.cells[5][1], board.cells[5][2]])
	board.reset()
	# Place the first two solution queens and one deliberately conflicting queen.
	board._tap(0, sol[0])
	board._tap(0, sol[0])
	board._tap(1, sol[1])
	board._tap(1, sol[1])
	board._tap(3, sol[1])  # same column as row 1 -> conflict, auto-marked so one tap
	board._tap(6, 0)  # a manual X
	await _frames(2)
	_save(out_dir + "02_game_conflict.png")

	# Pause menu, then the give-up dialog on top of it, then keep playing.
	main.debug.open_pause()
	await _frames(2)
	print("pause menu visible = %s, timer paused = %s" % [main.pause_menu.visible, not main.session.running])
	_save(out_dir + "03_pause_menu.png")
	main.debug.give_up()
	await _frames(2)
	print("give up dialog visible = %s" % main.message_dialog.visible)
	_save(out_dir + "03b_give_up_dialog.png")
	main.message_dialog.cancel()
	await _frames(1)
	main.pause_menu.close()
	await _frames(1)
	print("after cancel: timer running = %s" % main.session.running)

	# A hint on a fresh board places a queen or marks cells.
	board.reset()
	main.debug.hint()
	await _frames(3)
	print("hint: queens = %d, hints used = %d" % [board.queen_count(), main.session.result.hint_count])
	_save(out_dir + "03c_hint.png")

	board.reset()
	for r in sol.size():
		if board.auto_marks[r][sol[r]] == 0:
			board._tap(r, sol[r])
		board._tap(r, sol[r])
	await _frames(2)
	_save(out_dir + "04_solved.png")
	await _frames(3)
	print("win overlay visible = %s" % main.win_overlay.visible)
	_save(out_dir + "04b_win_overlay.png")

	# Easier / Same / Harder: a harder level than the one just played.
	var last_difficulty: float = main.levels[index]["difficulty"]
	main.debug.play_step(1)
	await _frames(2)
	print("harder pick: diff %d after diff %d, game visible = %s" % [main.levels[main.current_level]["difficulty"], last_difficulty, main.game_screen.visible])
	_save(out_dir + "05_game_harder.png")
	main.end_game(false)
	main.debug.show_home()
	await _frames(2)
	_save(out_dir + "06_home_after_game.png")

	# Energy: dialog, blocked start, fake ad refill, fake unlimited purchase.
	main.debug.open_shop(false)
	await _frames(2)
	_save(out_dir + "07_energy_dialog.png")
	main.energy_dialog.close()
	App.save.data["energy"]["amount"] = 0
	App.energy.grant(0)
	main.debug.play_step(0)
	await _frames(2)
	print("blocked start: dialog visible = %s, hint shown = %s, game visible = %s" % [main.energy_dialog.visible, main.energy_dialog.hint_label.visible, main.game_screen.visible])
	_save(out_dir + "08_energy_blocked.png")
	App.ads.instant = true
	main._on_watch_ad()
	await _frames(1)
	print("after fake ad: energy = %d, hint shown = %s" % [App.energy.amount(), main.energy_dialog.hint_label.visible])
	App.purchases.instant = true
	main._on_buy_unlimited()
	await _frames(1)
	print("after fake purchase: unlimited = %s, buy button visible = %s" % [App.energy.is_unlimited(), main.energy_dialog.buy_button.visible])
	_save(out_dir + "09_energy_unlimited.png")
	main.energy_dialog.close()
	await _frames(1)

	main.debug.show_levels()
	await _frames(2)
	var played: Dictionary = main.debug.level_card(index)
	print("played level card: locked = %s, text = %s" % [played.get("locked"), played.get("text")])
	main.debug.scroll_levels_to(index)
	await _frames(2)
	_save(out_dir + "10_level_select_locked.png")
	print("screen = %s" % main.debug.screen())

	# League: standings with bots, friends tab, adding a friend.
	main.debug.show_league()
	await _frames(2)
	var standing: Dictionary = (await App.backend.get_league_standing())["data"]
	print("league: joined = %s, rank %d of %d, round score %d, zone %s, tier points %d / %d" % [standing["joined"], standing["my_rank"], standing["group"]["size"], standing["my_round_score"], standing["zone"], standing["my_tier_points"], standing["rules"]["promo_score"]])
	_save(out_dir + "11_league_standings.png")
	main.league.show_tab("friends")
	main._on_add_friend("QN-ABC234")
	await _frames(2)
	print("friends after add: %d" % (await App.backend.get_friends())["data"].size())
	_save(out_dir + "12_league_friends.png")

	# Level detail with the leaderboard of the level just played.
	main.debug.show_level_detail(main.levels[index]["id"])
	await _frames(2)
	var lb: Dictionary = (await App.backend.get_level_leaderboard(main.levels[index]["id"], "global", 25))["data"]
	print("level board: %d players, my rank %d" % [lb["total_players"], lb["my_rank"]])
	_save(out_dir + "13_level_detail.png")

	# Settings, then the tutorial at its third step.
	main.debug.open_settings()
	await _frames(2)
	print("settings screen = %s" % main.debug.screen())
	_save(out_dir + "15_settings.png")
	main.debug.open_tutorial(2)
	await _frames(2)
	print("tutorial step = %d, screen = %s" % [main.debug.tutorial_step(), main.debug.screen()])
	_save(out_dir + "16_tutorial.png")
	main.tutorial.skip()
	await _frames(2)

	# Round summary modal (fabricated: the real one only appears after a round).
	main.debug.show_home()
	await _frames(1)
	main.round_summary.open({"round_index": 1, "outcome": "promoted", "rank": 4, "group_size": 30, "round_score": 4120, "best_game": {"score": 540}}, LeagueRules.tier_label("gold"), LeagueRules.tier_label("platinum"))
	await _frames(2)
	_save(out_dir + "14_round_summary.png")
	main.round_summary.close()
	await _frames(1)
	# A promotion by tier points (Bronze -> Silver, mid-round).
	main.round_summary.open({"round_index": 1, "outcome": "promoted", "reason": "score", "rank": 3, "group_size": 30, "round_score": 1850, "tier_points": 3120, "best_game": {"score": 540}}, LeagueRules.tier_label("bronze"), LeagueRules.tier_label("silver"))
	await _frames(2)
	_save(out_dir + "14b_promotion.png")
	main.round_summary.close()
	get_tree().quit()


## Godot's design resolution, so a window override cannot shrink the shots
## or move the synthetic touches off their cells.
func _use_design_resolution() -> void:
	var design := Vector2i(
		int(ProjectSettings.get_setting("display/window/size/viewport_width", 720)),
		int(ProjectSettings.get_setting("display/window/size/viewport_height", 1280)))
	if DisplayServer.window_get_size() != design:
		DisplayServer.window_set_size(design)
		get_window().size = design


## Input arrives in window coordinates; the board reports canvas ones.
func _to_window(pos: Vector2) -> Vector2:
	return get_viewport().get_screen_transform() * pos


func _touch(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = 0
	ev.pressed = pressed
	ev.position = _to_window(pos)
	Input.parse_input_event(ev)


func _drag(pos: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = 0
	ev.position = _to_window(pos)
	Input.parse_input_event(ev)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _save(path: String) -> void:
	if _locale != "":
		path = path.get_basename() + "_" + _locale + "." + path.get_extension()
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("screenshot %s -> %s" % [path, error_string(err)])
