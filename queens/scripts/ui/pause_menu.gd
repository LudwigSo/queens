extends Control
## Pause modal over the game. The dim is opaque enough to hide the board,
## because the stopwatch stops while this is open.

signal resumed
signal restart_requested
signal settings_requested
signal give_up_requested

@onready var dim: ColorRect = $Dim
@onready var panel: PanelContainer = $Panel
@onready var subtitle: Label = $Panel/VBox/Subtitle
@onready var resume_button: Button = $Panel/VBox/ResumeButton
@onready var restart_button: Button = $Panel/VBox/RestartButton
@onready var settings_button: Button = $Panel/VBox/SettingsButton
@onready var give_up_button: Button = $Panel/VBox/GiveUpButton


func _ready() -> void:
	resume_button.pressed.connect(close)
	restart_button.pressed.connect(restart_requested.emit)
	settings_button.pressed.connect(settings_requested.emit)
	give_up_button.pressed.connect(give_up_requested.emit)
	dim.gui_input.connect(_on_dim_input)


func open(subtitle_text: String) -> void:
	subtitle.text = subtitle_text
	visible = true
	Motion.fade(dim, 1.0, Motion.FAST)
	Motion.pop_in(panel)
	Sfx.play(&"pause_open")


func close() -> void:
	if not visible:
		return
	visible = false
	Sfx.play(&"pause_close")
	resumed.emit()


func set_settings_available(available: bool) -> void:
	settings_button.visible = available


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()
