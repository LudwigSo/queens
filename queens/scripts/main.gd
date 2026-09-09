extends Control
## Screen flow: level select -> game -> solved overlay.

const SAVE_PATH := "user://progress.cfg"
const Levels := preload("res://scripts/levels.gd")
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
@onready var next_button: Button = $WinOverlay/Panel/Margin/VBox/NextButton
@onready var levels_button: Button = $WinOverlay/Panel/Margin/VBox/LevelsButton

var levels: Array = []          ## Level dictionaries, see scripts/levels.gd.
var current_level: int = -1
var elapsed: float = 0.0
var running: bool = false
var best_times: Dictionary = {}  ## Level id -> best time in seconds.


func _ready() -> void:
	levels = Levels.load_all()
	_load_progress()
	board.state_changed.connect(_on_board_changed)
	board.solved.connect(_on_solved)
	undo_button.pressed.connect(board.undo)
	clear_button.pressed.connect(board.reset)
	back_button.pressed.connect(_show_level_select)
	next_button.pressed.connect(_on_next)
	levels_button.pressed.connect(_show_level_select)
	_show_level_select()


func _process(delta: float) -> void:
	if running:
		elapsed += delta
		timer_label.text = _format_time(elapsed)


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
		if best_times.has(lv["id"]):
			text += "\nBest %s" % _format_time(best_times[lv["id"]])
		btn.text = text
		btn.custom_minimum_size = Vector2(0, 150)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 30)
		btn.pressed.connect(_start_level.bind(i))
		level_grid.add_child(btn)


func _show_level_select() -> void:
	running = false
	_build_level_buttons()
	win_overlay.visible = false
	game.visible = false
	level_select.visible = true


func _start_level(index: int) -> void:
	current_level = index
	var lv: Dictionary = levels[index]
	board.load_level(lv)
	level_label.text = "Level %d  (%d x %d)" % [index + 1, lv["size"], lv["size"]]
	elapsed = 0.0
	timer_label.text = _format_time(0.0)
	running = true
	win_overlay.visible = false
	level_select.visible = false
	game.visible = true


func _on_board_changed() -> void:
	undo_button.disabled = not board.can_undo()


func _on_solved() -> void:
	running = false
	undo_button.disabled = true
	var id: String = levels[current_level]["id"]
	if not best_times.has(id) or elapsed < float(best_times[id]):
		best_times[id] = elapsed
		_save_progress()
	win_time_label.text = "Time: %s" % _format_time(elapsed)
	next_button.visible = current_level + 1 < levels.size()
	win_overlay.visible = true


func _on_next() -> void:
	if current_level + 1 < levels.size():
		_start_level(current_level + 1)


func _format_time(seconds: float) -> String:
	var total := int(seconds)
	@warning_ignore("integer_division")
	return "%d:%02d" % [total / 60, total % 60]


func _load_progress() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK or not cfg.has_section("best_times"):
		return
	for key in cfg.get_section_keys("best_times"):
		best_times[key] = cfg.get_value("best_times", key)


func _save_progress() -> void:
	var cfg := ConfigFile.new()
	for key in best_times:
		cfg.set_value("best_times", key, best_times[key])
	cfg.save(SAVE_PATH)
