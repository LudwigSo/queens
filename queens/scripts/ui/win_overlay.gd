extends Control
## "Solved!" panel shown over the game, with the next-game choice.

signal next_requested(step: int)   ## -1 easier, 0 same, +1 harder
signal home_requested

@onready var time_label: Label = $Panel/Margin/VBox/TimeLabel
@onready var stats_label: Label = $Panel/Margin/VBox/StatsLabel
@onready var harder_button: Button = $Panel/Margin/VBox/HarderButton
@onready var same_button: Button = $Panel/Margin/VBox/SameButton
@onready var easier_button: Button = $Panel/Margin/VBox/EasierButton
@onready var home_button: Button = $Panel/Margin/VBox/HomeButton


func _ready() -> void:
	harder_button.pressed.connect(next_requested.emit.bind(1))
	same_button.pressed.connect(next_requested.emit.bind(0))
	easier_button.pressed.connect(next_requested.emit.bind(-1))
	home_button.pressed.connect(home_requested.emit)


func show_result(time_text: String, stats_text: String) -> void:
	time_label.text = time_text
	stats_label.text = stats_text
	visible = true
