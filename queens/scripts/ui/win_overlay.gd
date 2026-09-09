extends Control
## "Solved!" panel shown over the game: score, badges, breakdown and the
## next-game choice.

signal next_requested(step: int)   ## -1 easier, 0 same, +1 harder
signal home_requested

@onready var score_label: Label = $Panel/Margin/VBox/ScoreLabel
@onready var badge_label: Label = $Panel/Margin/VBox/BadgeLabel
@onready var detail_label: Label = $Panel/Margin/VBox/DetailLabel
@onready var league_label: Label = $Panel/Margin/VBox/LeagueLabel
@onready var harder_button: Button = $Panel/Margin/VBox/HarderButton
@onready var same_button: Button = $Panel/Margin/VBox/SameButton
@onready var easier_button: Button = $Panel/Margin/VBox/EasierButton
@onready var home_button: Button = $Panel/Margin/VBox/HomeButton


func _ready() -> void:
	harder_button.pressed.connect(next_requested.emit.bind(1))
	same_button.pressed.connect(next_requested.emit.bind(0))
	easier_button.pressed.connect(next_requested.emit.bind(-1))
	home_button.pressed.connect(home_requested.emit)


## `badge_text` may be empty (the line is hidden then).
func show_result(score_text: String, badge_text: String, detail_text: String, league_text: String = "") -> void:
	score_label.text = score_text
	badge_label.text = badge_text
	badge_label.visible = badge_text != ""
	detail_label.text = detail_text
	league_label.text = league_text
	league_label.visible = league_text != ""
	visible = true
