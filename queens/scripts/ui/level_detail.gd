extends Control
## One level's leaderboard: global, friends or fastest flawless runs, the
## player's own best, and a play button (disabled while on cooldown).

signal back_requested
signal play_requested(level_id: String)
signal scope_requested(scope: String)

const COLOR_ROW := Color("ffffff")
const COLOR_ME_BORDER := Color("1e1e2a")
const COLOR_TEXT := Color("1e1e2a")
const COLOR_MUTED := Color(0.3, 0.3, 0.35)

@onready var back_button: Button = $Margin/VBox/TopBar/BackButton
@onready var title_label: Label = $Margin/VBox/TopBar/Title
@onready var par_label: Label = $Margin/VBox/ParLabel
@onready var mine_label: Label = $Margin/VBox/MineLabel
@onready var global_button: Button = $Margin/VBox/Tabs/GlobalButton
@onready var friends_button: Button = $Margin/VBox/Tabs/FriendsButton
@onready var flawless_button: Button = $Margin/VBox/Tabs/FlawlessButton
@onready var list: VBoxContainer = $Margin/VBox/Scroll/List
@onready var play_button: Button = $Margin/VBox/PlayButton

var level_id: String = ""


func _ready() -> void:
	back_button.pressed.connect(back_requested.emit)
	global_button.pressed.connect(scope_requested.emit.bind("global"))
	friends_button.pressed.connect(scope_requested.emit.bind("friends"))
	flawless_button.pressed.connect(scope_requested.emit.bind("flawless"))
	play_button.pressed.connect(func() -> void: play_requested.emit(level_id))


## view: {level_id, title, par_text, mine_text, scope, entries: [LeaderboardEntry
## + time_text], play_text, play_enabled}
func refresh(view: Dictionary) -> void:
	level_id = view.get("level_id", "")
	title_label.text = view.get("title", "")
	par_label.text = view.get("par_text", "")
	mine_label.text = view.get("mine_text", "")
	var scope := str(view.get("scope", "global"))
	global_button.button_pressed = scope == "global"
	friends_button.button_pressed = scope == "friends"
	flawless_button.button_pressed = scope == "flawless"
	play_button.text = view.get("play_text", "Play this level")
	play_button.disabled = not view.get("play_enabled", true)
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()
	var entries: Array = view.get("entries", [])
	if entries.is_empty():
		var note := Label.new()
		note.text = "Nobody here yet." if scope != "friends" else "None of your friends has played this level."
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_font_size_override("font_size", 26)
		note.add_theme_color_override("font_color", COLOR_MUTED)
		list.add_child(note)
	for e in entries:
		list.add_child(_entry_row(e))


func _cell(text: String, width: float, align: int, size: int = 24, color: Color = COLOR_TEXT) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = align
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if width > 0:
		label.custom_minimum_size = Vector2(width, 0)
	else:
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label


func _entry_row(e: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_ROW
	style.set_corner_radius_all(12)
	style.set_content_margin_all(10)
	if e.get("is_me", false):
		style.set_border_width_all(3)
		style.border_color = COLOR_ME_BORDER
	panel.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_cell("%d" % int(e.get("rank", 0)), 50, HORIZONTAL_ALIGNMENT_RIGHT))
	var name := str(e.get("nickname", ""))
	if e.get("is_me", false):
		name += " (you)"
	elif e.get("is_friend", false):
		name += " ♥"
	row.add_child(_cell(name, 0, HORIZONTAL_ALIGNMENT_LEFT))
	row.add_child(_cell("%d" % int(e.get("score", 0)), 80, HORIZONTAL_ALIGNMENT_RIGHT))
	row.add_child(_cell(str(e.get("time_text", "")), 80, HORIZONTAL_ALIGNMENT_RIGHT, 22, COLOR_MUTED))
	var wrong := int(e.get("wrong_placements", 0))
	row.add_child(_cell("clean" if wrong == 0 else "%d ✕" % wrong, 80, HORIZONTAL_ALIGNMENT_RIGHT, 22, COLOR_MUTED))
	panel.add_child(row)
	return panel
