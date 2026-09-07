extends Node
## Visual smoke test: instantiates the main scene, plays part of a level and
## writes screenshots. Run with:
##   godot --path queens res://tests/screenshot.tscn -- <output_dir>

const MainScene := preload("res://scenes/main.tscn")


func _ready() -> void:
	var out_dir := "user://"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0].trim_suffix("/").trim_suffix("\\") + "/"
	var main: Control = MainScene.instantiate()
	add_child(main)
	await _frames(3)
	_save(out_dir + "01_level_select.png")

	main._start_level(3)  # 7x7 board
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

	board.reset()
	for r in sol.size():
		if board.auto_marks[r][sol[r]] == 0:
			board._tap(r, sol[r])
		board._tap(r, sol[r])
	await _frames(2)
	_save(out_dir + "03_solved.png")
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _save(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("screenshot %s -> %s" % [path, error_string(err)])
