extends Control
## The play screen: a header, the board, a hint strip, the actions bar and the
## level chip below it. Owns the Board node and wires the eraser and Clear
## itself; pause and hint requests are reported to the main script.
##
## The top centre stays empty on purpose: a camera cutout sits there on many
## phones, so only the pause button (left) and the timer and mistakes chips
## (right) live in the header, and the level chip moved to the bottom.

signal pause_requested
signal hint_requested

const DEFAULT_HINT_KEY := "GAME_HINT_DEFAULT"

@onready var board: Board = $Margin/VBox/Board
@onready var pause_button: Button = $Margin/VBox/Header/PauseButton
@onready var level_label: Label = $Margin/VBox/Footer/LevelChip/HBox/LevelLabel
@onready var stars: StarRow = $Margin/VBox/Footer/LevelChip/HBox/Stars
@onready var mistakes_chip: PanelContainer = $Margin/VBox/Header/MistakesChip
@onready var mistakes_label: Label = $Margin/VBox/Header/MistakesChip/HBox/MistakesLabel
@onready var timer_chip: PanelContainer = $Margin/VBox/Header/TimerChip
@onready var timer_label: Label = $Margin/VBox/Header/TimerChip/HBox/TimerLabel
@onready var hint_label: Label = $Margin/VBox/Hint
@onready var hint_button: Button = $Margin/VBox/Actions/HintButton
@onready var erase_button: Button = $Margin/VBox/Actions/EraseButton
@onready var clear_button: Button = $Margin/VBox/Actions/ClearButton

var _hint_tween: Tween = null
var _level_args: Array = []      ## set_level's arguments, so a language switch can re-render
var _hints_used: int = 0
var _hint_is_default: bool = true


func _ready() -> void:
	pause_button.pressed.connect(pause_requested.emit)
	clear_button.pressed.connect(board.clear)
	erase_button.toggled.connect(_on_erase_toggled)
	hint_button.pressed.connect(hint_requested.emit)
	board.state_changed.connect(_on_board_changed)


## Header for a new game.
func set_level(level_no: int, size: int, difficulty: int, star_count: int) -> void:
	_level_args = [level_no, size, difficulty]
	_render_level()
	stars.set_stars(star_count, 4)
	set_mistakes(0)
	set_hints_used(0)
	hint_label.text = Loc.t(DEFAULT_HINT_KEY)
	_hint_is_default = true
	hint_label.modulate.a = 1.0
	hint_button.disabled = false
	clear_button.disabled = false
	erase_button.disabled = false
	erase_button.button_pressed = false
	board.erase_mode = false


## Kept for older callers: a preformatted header line.
func set_level_text(text: String) -> void:
	_level_args = []
	level_label.text = text


## The chip names the level and its difficulty; the stars beside it repeat the
## difficulty at a glance. The board size is visible on the board itself.
func _render_level() -> void:
	if _level_args.size() == 3:
		level_label.text = Loc.f("GAME_LEVEL_TITLE", [_level_args[0], _level_args[2]])


func set_timer_text(text: String) -> void:
	timer_label.text = text


## Replaces the strip text. `seconds` > 0 fades back to the default afterwards.
func set_hint(text: String, seconds: float = 0.0) -> void:
	if _hint_tween != null and _hint_tween.is_valid():
		_hint_tween.kill()
	hint_label.text = text
	_hint_is_default = false
	hint_label.modulate.a = 0.0
	_hint_tween = create_tween()
	_hint_tween.tween_property(hint_label, "modulate:a", 1.0, Motion.d(Motion.FAST))
	if seconds > 0.0:
		_hint_tween.tween_interval(Motion.d(seconds))
		_hint_tween.tween_property(hint_label, "modulate:a", 0.0, Motion.d(Motion.BASE))
		_hint_tween.tween_callback(func() -> void: hint_label.text = Loc.t(DEFAULT_HINT_KEY); _hint_is_default = true)
		_hint_tween.tween_property(hint_label, "modulate:a", 1.0, Motion.d(Motion.BASE))


## The chip keeps its slot in the header for the whole game and only fades,
## so the first mistake cannot reflow the header, the board or the hint strip.
func set_mistakes(n: int) -> void:
	var was_shown := mistakes_chip.modulate.a > 0.0
	mistakes_label.text = str(n)
	if not is_inside_tree():
		mistakes_chip.modulate.a = 1.0 if n > 0 else 0.0
		return
	Motion.fade(mistakes_chip, 1.0 if n > 0 else 0.0, Motion.BASE)
	if n > 0 and was_shown:
		Motion.bump(mistakes_chip, 1.25, Motion.SLOW)


func set_hints_used(n: int) -> void:
	_hints_used = n
	hint_button.text = Loc.t("GAME_HINT") if n == 0 else Loc.f("GAME_HINT_N", [n])


## The header and the hint strip are built in code, so they do not follow a
## language change on their own (settings are reachable from the pause menu).
func _notification(what: int) -> void:
	if what != NOTIFICATION_TRANSLATION_CHANGED or not is_node_ready():
		return
	_render_level()
	set_hints_used(_hints_used)
	if _hint_is_default:
		hint_label.text = Loc.t(DEFAULT_HINT_KEY)


func set_hint_enabled(enabled: bool) -> void:
	hint_button.disabled = not enabled


func bump_timer() -> void:
	Motion.bump(timer_chip, 1.08, Motion.BASE)


## The eraser wipes one cell per tap; it stays on until it is switched off.
func _on_erase_toggled(pressed: bool) -> void:
	board.erase_mode = pressed
	if pressed:
		set_hint(Loc.t("GAME_ERASE_ON"))
	else:
		set_hint(Loc.t(DEFAULT_HINT_KEY))
		_hint_is_default = true


func _on_board_changed() -> void:
	if board.locked:
		hint_button.disabled = true
		clear_button.disabled = true
		erase_button.disabled = true
		erase_button.button_pressed = false
