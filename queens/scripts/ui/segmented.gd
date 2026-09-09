class_name Segmented
extends HBoxContainer
## A row of pill toggle buttons where exactly one is selected. Children are
## Buttons whose `name` is the option id; `selected(id)` fires on change.

signal selected(id: String)

var _current: String = ""


func _ready() -> void:
	for child in get_children():
		if child is Button:
			var b: Button = child
			b.toggle_mode = true
			b.theme_type_variation = &"ButtonPill"
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.pressed.connect(_on_pressed.bind(b.name))
			Motion.make_pressable(b)
	if _current == "" and get_child_count() > 0:
		select(get_child(0).name, false)


## Builds the options from [{id, text}] (or plain strings).
func set_options(options: Array) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	for opt in options:
		var b := Button.new()
		if opt is Dictionary:
			b.name = str(opt["id"])
			b.text = str(opt.get("text", opt["id"]))
		else:
			b.name = str(opt)
			b.text = str(opt)
		b.toggle_mode = true
		b.theme_type_variation = &"ButtonPill"
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, Ui.BUTTON_H_S)
		b.pressed.connect(_on_pressed.bind(b.name))
		Motion.make_pressable(b)
		add_child(b)
	_current = ""


func current() -> String:
	return _current


func select(id: String, emit: bool = true) -> void:
	for child in get_children():
		if child is Button:
			child.button_pressed = child.name == id
	var changed := _current != id
	_current = id
	if emit and changed:
		selected.emit(id)


func _on_pressed(id: String) -> void:
	# Keep the tapped button pressed even when it was already selected.
	select(id, true)
