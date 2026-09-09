extends Control
## Start screen: pick the next game relative to the last one, or open the
## level overview. With no last game only one "Start easy" button is shown.

signal play_requested(step: int)   ## -1 easier, 0 same, +1 harder
signal overview_requested
signal league_requested
signal energy_pressed

@onready var energy_button: Button = $Margin/VBox/TopBar/EnergyButton
@onready var last_game_label: Label = $Margin/VBox/LastGame
@onready var harder_button: Button = $Margin/VBox/HarderButton
@onready var same_button: Button = $Margin/VBox/SameButton
@onready var easier_button: Button = $Margin/VBox/EasierButton
@onready var league_label: Label = $Margin/VBox/LeagueLabel
@onready var overview_button: Button = $Margin/VBox/Bottom/OverviewButton
@onready var league_button: Button = $Margin/VBox/Bottom/LeagueButton
@onready var player_label: Label = $Margin/VBox/Player


func _ready() -> void:
	harder_button.pressed.connect(play_requested.emit.bind(1))
	same_button.pressed.connect(play_requested.emit.bind(0))
	easier_button.pressed.connect(play_requested.emit.bind(-1))
	overview_button.pressed.connect(overview_requested.emit)
	league_button.pressed.connect(league_requested.emit)
	energy_button.pressed.connect(energy_pressed.emit)


## view: {has_last, last_text, nickname, energy_text, league_text}
func refresh(view: Dictionary) -> void:
	var has_last: bool = view.get("has_last", false)
	set_energy_text(view.get("energy_text", ""))
	league_label.text = view.get("league_text", "")
	last_game_label.text = view.get("last_text", "")
	harder_button.visible = has_last
	easier_button.visible = has_last
	same_button.text = "Same" if has_last else "Start easy"
	player_label.text = view.get("nickname", "")


func set_energy_text(text: String) -> void:
	energy_button.text = "Energy %s" % text
