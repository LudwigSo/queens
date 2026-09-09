extends Control
## Generic modal: title, body, an OK button and an optional Cancel button.
## `ask()` can be awaited and returns true when OK was pressed.

signal closed(confirmed: bool)

@onready var title_label: Label = $Panel/Margin/VBox/Title
@onready var body_label: Label = $Panel/Margin/VBox/Body
@onready var ok_button: Button = $Panel/Margin/VBox/Buttons/OkButton
@onready var cancel_button: Button = $Panel/Margin/VBox/Buttons/CancelButton
@onready var dim: ColorRect = $Dim


func _ready() -> void:
	ok_button.pressed.connect(_finish.bind(true))
	cancel_button.pressed.connect(_finish.bind(false))
	dim.gui_input.connect(_on_dim_input)


func open(title: String, body: String, ok_text: String = "OK", cancel_text: String = "") -> void:
	title_label.text = title
	body_label.text = body
	ok_button.text = ok_text
	cancel_button.text = cancel_text
	cancel_button.visible = cancel_text != ""
	visible = true


## Shows the dialog and waits for the answer.
func ask(title: String, body: String, ok_text: String = "OK", cancel_text: String = "Cancel") -> bool:
	open(title, body, ok_text, cancel_text)
	var confirmed: bool = await closed
	return confirmed


func cancel() -> void:
	if visible:
		_finish(false)


func _finish(confirmed: bool) -> void:
	visible = false
	closed.emit(confirmed)


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_finish(false)
