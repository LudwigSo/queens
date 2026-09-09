extends Control
## The play screen: header chips, the board, a hint strip and the actions bar.
## Owns the Board node and wires undo/clear itself; pause and hint requests
## are reported to the main script.

signal pause_requested
signal hint_requested

const DEFAULT_HINT := "Tap to mark X, tap again for a queen. Drag to mark many."

@onready var board: Board = $Margin/VBox/Board
@onready var pause_button: Button = $Margin/VBox/Header/PauseButton
@onready var level_label: Label = $Margin/VBox/Header/Center/ChipRow/LevelChip/HBox/LevelLabel
@onready var stars: StarRow = $Margin/VBox/Header/Center/ChipRow/LevelChip/HBox/Stars
@onready var mistakes_chip: PanelContainer = $Margin/VBox/Header/Center/ChipRow/MistakesChip
@onready var mistakes_label: Label = $Margin/VBox/Header/Center/ChipRow/MistakesChip/HBox/MistakesLabel
@onready var timer_chip: PanelContainer = $Margin/VBox/Header/TimerChip
@onready var timer_label: Label = $Margin/VBox/Header/TimerChip/HBox/TimerLabel
@onready var hint_label: Label = $Margin/VBox/Hint
@onready var undo_button: Button = $Margin/VBox/Actions/UndoButton
@onready var hint_button: Button = $Margin/VBox/Actions/HintButton
@onready var clear_button: Button = $Margin/VBox/Actions/ClearButton

var _hint_tween: Tween = null


func _ready() -> void:
	pause_button.pressed.connect(pause_requested.emit)
	undo_button.pressed.connect(board.undo)
	clear_button.pressed.connect(board.clear)
	hint_button.pressed.connect(hint_requested.emit)
	board.state_changed.connect(_on_board_changed)


## Header for a new game.
func set_level(level_no: int, size: int, difficulty: int, star_count: int) -> void:
	level_label.text = "Level %d · %s · diff %d" % [level_no, Fmt.size_text(size), difficulty]
	stars.set_stars(star_count, 4)
	set_mistakes(0)
	set_hints_used(0)
	hint_label.text = DEFAULT_HINT
	hint_label.modulate.a = 1.0
	undo_button.disabled = true
	hint_button.disabled = false
	clear_button.disabled = false


## Kept for older callers: a preformatted header line.
func set_level_text(text: String) -> void:
	level_label.text = text


func set_timer_text(text: String) -> void:
	timer_label.text = text


## Replaces the strip text. `seconds` > 0 fades back to the default afterwards.
func set_hint(text: String, seconds: float = 0.0) -> void:
	if _hint_tween != null and _hint_tween.is_valid():
		_hint_tween.kill()
	hint_label.text = text
	hint_label.modulate.a = 0.0
	_hint_tween = create_tween()
	_hint_tween.tween_property(hint_label, "modulate:a", 1.0, Motion.d(Motion.FAST))
	if seconds > 0.0:
		_hint_tween.tween_interval(Motion.d(seconds))
		_hint_tween.tween_property(hint_label, "modulate:a", 0.0, Motion.d(Motion.BASE))
		_hint_tween.tween_callback(func() -> void: hint_label.text = DEFAULT_HINT)
		_hint_tween.tween_property(hint_label, "modulate:a", 1.0, Motion.d(Motion.BASE))


func set_mistakes(n: int) -> void:
	var was_visible := mistakes_chip.visible
	mistakes_label.text = str(n)
	mistakes_chip.visible = n > 0
	if n > 0 and is_inside_tree():
		if was_visible:
			Motion.bump(mistakes_chip, 1.25, Motion.SLOW)
		else:
			Motion.pop_in(mistakes_chip, Motion.BASE, 1.4)


func set_hints_used(n: int) -> void:
	hint_button.text = "Hint" if n == 0 else "Hint · %d" % n


func set_hint_enabled(enabled: bool) -> void:
	hint_button.disabled = not enabled


func bump_timer() -> void:
	Motion.bump(timer_chip, 1.08, Motion.BASE)


func _on_board_changed() -> void:
	undo_button.disabled = not board.can_undo()
	if board.locked:
		hint_button.disabled = true
		clear_button.disabled = true
