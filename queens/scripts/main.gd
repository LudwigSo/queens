extends Control
## Screen flow: level select -> game -> solved overlay.
## Progress lives in the App autoload's save file; a running game is tracked
## by a GameSession (stopwatch + move counters) that becomes a GameResult.

const BoardScript := preload("res://scripts/board.gd")

@onready var level_select: Control = $LevelSelect
@onready var level_grid: GridContainer = $LevelSelect/Margin/VBox/Scroll/Grid
@onready var game: Control = $Game
@onready var board: BoardScript = $Game/Margin/VBox/Board
@onready var level_label: Label = $Game/Margin/VBox/Header/LevelLabel
@onready var timer_label: Label = $Game/Margin/VBox/Header/TimerLabel
@onready var undo_button: Button = $Game/Margin/VBox/Actions/UndoButton
@onready var clear_button: Button = $Game/Margin/VBox/Actions/ClearButton
@onready var back_button: Button = $Game/Margin/VBox/Header/BackButton
@onready var win_overlay: Control = $WinOverlay
@onready var win_time_label: Label = $WinOverlay/Panel/Margin/VBox/TimeLabel
@onready var win_stats_label: Label = $WinOverlay/Panel/Margin/VBox/StatsLabel
@onready var next_button: Button = $WinOverlay/Panel/Margin/VBox/NextButton
@onready var levels_button: Button = $WinOverlay/Panel/Margin/VBox/LevelsButton

var levels: Array = []          ## Level dictionaries, see scripts/levels.gd.
var current_level: int = -1
var session: GameSession = null ## The running game, null between games.


func _ready() -> void:
	levels = App.catalog.levels
	board.state_changed.connect(_on_board_changed)
	board.solved.connect(_on_solved)
	undo_button.pressed.connect(board.undo)
	clear_button.pressed.connect(board.clear)
	back_button.pressed.connect(_on_back)
	next_button.pressed.connect(_on_next)
	levels_button.pressed.connect(_show_level_select)
	_show_level_select()


func _process(delta: float) -> void:
	if session != null and session.running:
		session.tick(delta)
		timer_label.text = _format_time(session.elapsed_seconds())


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_pause_game(true)
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_resume_game()
		NOTIFICATION_WM_GO_BACK_REQUEST:
			if game.visible and not win_overlay.visible:
				_on_back()


func _build_level_buttons() -> void:
	for child in level_grid.get_children():
		level_grid.remove_child(child)
		child.queue_free()
	for i in levels.size():
		var lv: Dictionary = levels[i]
		var btn := Button.new()
		var text := "Level %d\n%d x %d" % [i + 1, lv["size"], lv["size"]]
		if lv["stars"] > 0:
			text += "\n" + "★".repeat(lv["stars"])
		if App.save.has_best(lv["id"]):
			text += "\nBest %s" % _format_time(App.save.best_time(lv["id"]))
		btn.text = text
		btn.custom_minimum_size = Vector2(0, 150)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 30)
		btn.pressed.connect(_start_level.bind(i))
		level_grid.add_child(btn)


func _show_level_select() -> void:
	_pause_game(false)
	_build_level_buttons()
	win_overlay.visible = false
	game.visible = false
	level_select.visible = true


func _start_level(index: int) -> void:
	start_game(levels[index])


## Starts a game on `level`: records the start in the save, loads the board
## and runs the stopwatch. A game still running is forfeited first.
func start_game(level: Dictionary) -> void:
	if session != null and not session.finished:
		end_game(false)
	current_level = levels.find(level)
	session = GameSession.new()
	session.start(level, App.save.player_id(), App.now(), App.config.client_version)
	session.attach(board)
	App.save.begin_game(level["id"], session.to_marker())
	App.save_now()
	board.load_level(level)
	level_label.text = "Level %d  (%d x %d)" % [current_level + 1, level["size"], level["size"]]
	timer_label.text = _format_time(0.0)
	win_overlay.visible = false
	level_select.visible = false
	game.visible = true
	session.resume()


## Ends the running game as completed or forfeited and stores the result.
func end_game(completed: bool) -> GameResult:
	if session == null or session.finished:
		return null
	var result := session.finish(completed, App.now())
	App.record_result(result)
	return result


func _pause_game(persist: bool) -> void:
	if session == null or session.finished:
		return
	session.pause()
	if persist:
		App.save.update_marker(session.to_marker())
		App.save_now()


func _resume_game() -> void:
	if session == null or session.finished:
		return
	if game.visible and not win_overlay.visible:
		session.resume()


func _on_back() -> void:
	end_game(false)
	_show_level_select()


func _on_board_changed() -> void:
	undo_button.disabled = not board.can_undo()


func _on_solved() -> void:
	undo_button.disabled = true
	var result := end_game(true)
	if result == null:
		return
	win_time_label.text = "Time: %s" % _format_time(result.elapsed_seconds)
	win_stats_label.text = "Mistakes %d · Undos %d" % [result.wrong_placements, result.undo_count]
	next_button.visible = current_level + 1 < levels.size()
	win_overlay.visible = true


func _on_next() -> void:
	if current_level + 1 < levels.size():
		_start_level(current_level + 1)


func _format_time(seconds: float) -> String:
	var total := int(seconds)
	@warning_ignore("integer_division")
	return "%d:%02d" % [total / 60, total % 60]
