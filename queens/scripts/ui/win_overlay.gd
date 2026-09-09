extends Control
## "Solved!" panel shown over the game.

signal next_requested
signal levels_requested

@onready var time_label: Label = $Panel/Margin/VBox/TimeLabel
@onready var stats_label: Label = $Panel/Margin/VBox/StatsLabel
@onready var next_button: Button = $Panel/Margin/VBox/NextButton
@onready var levels_button: Button = $Panel/Margin/VBox/LevelsButton


func _ready() -> void:
	next_button.pressed.connect(next_requested.emit)
	levels_button.pressed.connect(levels_requested.emit)


func show_result(time_text: String, stats_text: String, has_next: bool) -> void:
	time_label.text = time_text
	stats_label.text = stats_text
	next_button.visible = has_next
	visible = true
