extends Control
## The play screen: header, board, undo/clear. Owns the Board node and wires
## the two board buttons itself; giving up is reported to the main script.

signal give_up_requested

@onready var board: Board = $Margin/VBox/Board
@onready var level_label: Label = $Margin/VBox/Header/LevelLabel
@onready var timer_label: Label = $Margin/VBox/Header/TimerLabel
@onready var hint_label: Label = $Margin/VBox/Hint
@onready var give_up_button: Button = $Margin/VBox/Header/GiveUpButton
@onready var undo_button: Button = $Margin/VBox/Actions/UndoButton
@onready var clear_button: Button = $Margin/VBox/Actions/ClearButton


func _ready() -> void:
	give_up_button.pressed.connect(give_up_requested.emit)
	undo_button.pressed.connect(board.undo)
	clear_button.pressed.connect(board.clear)
	board.state_changed.connect(_on_board_changed)


func set_level_text(text: String) -> void:
	level_label.text = text


func set_timer_text(text: String) -> void:
	timer_label.text = text


func set_hint(text: String) -> void:
	hint_label.text = text


func _on_board_changed() -> void:
	undo_button.disabled = not board.can_undo()
