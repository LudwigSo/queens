extends Control
## After a promotion into a grouped tier: the friends who are already playing
## this round there, one button per group, and "place me anywhere". The
## choice is the caller's to send (Backend.join_group); closing without one
## leaves the normal placement to the next game.

signal chosen(group_id: String, label: String)   ## "" for the normal placement
signal closed

@onready var dim: ColorRect = $Dim
@onready var title_label: Label = $Panel/Margin/VBox/Title
@onready var body_label: Label = $Panel/Margin/VBox/Body
@onready var options_box: VBoxContainer = $Panel/Margin/VBox/Options
@onready var random_button: Button = $Panel/Margin/VBox/RandomButton


func _ready() -> void:
	random_button.pressed.connect(_choose.bind("", ""))
	dim.gui_input.connect(_on_dim_input)


## options: JoinOptions.options ([{group_id, members, friends: [{nickname}]}]).
func open(tier_name: String, options: Array) -> void:
	title_label.text = Loc.f("JOIN_TITLE", [tier_name])
	body_label.text = Loc.t("JOIN_BODY")
	for child in options_box.get_children():
		options_box.remove_child(child)
		child.queue_free()
	for opt in options:
		var names: Array = []
		for fr in opt.get("friends", []):
			names.append(str(fr.get("nickname", "")))
		var label := ", ".join(names)
		var button := Button.new()
		button.text = Loc.f("JOIN_OPTION", [label, int(opt.get("members", 0))])
		button.theme_type_variation = &"ButtonPrimary"
		button.custom_minimum_size = Vector2(0, 80)
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.pressed.connect(_choose.bind(str(opt.get("group_id", "")), label))
		Motion.make_pressable(button)
		options_box.add_child(button)
	visible = true


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func _choose(group_id: String, label: String) -> void:
	chosen.emit(group_id, label)
	close()


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()
