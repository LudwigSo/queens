extends Node
## Visual smoke test: instantiates the main scene, plays part of a level and
## writes screenshots. Uses its own save file so real progress is untouched.
## Run with:
##   godot --path queens res://tests/screenshot.tscn -- <output_dir>

const MainScene := preload("res://scenes/main.tscn")
const SAVE_PATH := "user://screenshot_save.json"


func _ready() -> void:
	var out_dir := "user://"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].trim_suffix("/").trim_suffix("\\") + "/"
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	App.use_save_path(SAVE_PATH)

	var main: Control = MainScene.instantiate()
	add_child(main)
	await _frames(3)
	_save(out_dir + "01_home_fresh.png")

	var index := 0  # first 7x7 board
	for i in main.levels.size():
		if int(main.levels[i]["size"]) == 7:
			index = i
			break
	main._start_level(index)
	await _frames(2)
	var board: Control = main.board
	var sol: Array = board.solution

	# Verify the real input path: a synthetic click on cell (2, 2) must mark it.
	var cell_center: Vector2 = board.get_global_position() + board._cell_rect(2, 2).get_center()
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = cell_center
		ev.global_position = cell_center
		Input.parse_input_event(ev)
		await _frames(1)
	print("click test: cell (2,2) state = %s (expected MARK=1)" % board.cells[2][2])
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

	# Give-up dialog, then keep playing.
	main._on_give_up()
	await _frames(2)
	print("give up dialog visible = %s, timer paused = %s" % [main.message_dialog.visible, not main.session.running])
	_save(out_dir + "03_give_up_dialog.png")
	main.message_dialog.cancel()
	await _frames(1)
	print("after cancel: timer running = %s" % main.session.running)

	board.reset()
	for r in sol.size():
		if board.auto_marks[r][sol[r]] == 0:
			board._tap(r, sol[r])
		board._tap(r, sol[r])
	await _frames(2)
	_save(out_dir + "04_solved.png")

	# Easier / Same / Harder: a harder level than the one just played.
	var last_difficulty: float = main.levels[index]["difficulty"]
	main._play_step(1)
	await _frames(2)
	print("harder pick: diff %d after diff %d, game visible = %s" % [main.levels[main.current_level]["difficulty"], last_difficulty, main.game_screen.visible])
	_save(out_dir + "05_game_harder.png")
	main.end_game(false)
	main._show_home()
	await _frames(2)
	_save(out_dir + "06_home_after_game.png")

	# Energy: dialog, blocked start, fake ad refill, fake unlimited purchase.
	main._open_energy_dialog(false)
	await _frames(2)
	_save(out_dir + "07_energy_dialog.png")
	main.energy_dialog.close()
	App.save.data["energy"]["amount"] = 0
	App.energy.grant(0)
	main._play_step(0)
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

	main._show_level_select()
	await _frames(2)
	var played: Button = main.level_select.grid.get_child(index).get_child(0)
	print("played level button: disabled = %s, shows lock = %s" % [played.disabled, played.text.contains("Locked")])
	main.level_select.grid.get_parent().scroll_vertical = int(played.position.y)
	await _frames(2)
	_save(out_dir + "10_level_select_locked.png")

	# League: standings with bots, friends tab, adding a friend.
	main._show_league()
	await _frames(2)
	var standing: Dictionary = (await App.backend.get_league_standing())["data"]
	print("league: joined = %s, rank %d of %d, weekly %d, zone %s" % [standing["joined"], standing["my_rank"], standing["group"]["size"], standing["my_weekly_score"], standing["zone"]])
	_save(out_dir + "11_league_standings.png")
	main.league.show_tab("friends")
	main._on_add_friend("QN-ABC234")
	await _frames(2)
	print("friends after add: %d" % (await App.backend.get_friends())["data"].size())
	_save(out_dir + "12_league_friends.png")

	# Level detail with the leaderboard of the level just played.
	main._show_level_detail(main.levels[index]["id"])
	await _frames(2)
	var lb: Dictionary = (await App.backend.get_level_leaderboard(main.levels[index]["id"], "global", 25))["data"]
	print("level board: %d players, my rank %d" % [lb["total_players"], lb["my_rank"]])
	_save(out_dir + "13_level_detail.png")

	# Week summary modal (fabricated: the real one only appears after a week).
	main._show_home()
	await _frames(1)
	main.week_summary.open({"week_index": 1, "outcome": "promoted", "rank": 4, "group_size": 30, "weekly_score": 4120, "best_game": {"score": 540}}, "Bronze", "Silver")
	await _frames(2)
	_save(out_dir + "14_week_summary.png")
	main.week_summary.close()
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _save(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("screenshot %s -> %s" % [path, error_string(err)])
