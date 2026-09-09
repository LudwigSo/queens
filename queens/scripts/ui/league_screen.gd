extends Control
## Weekly league: standings of the player's group (promotion zone green,
## relegation zone red, the player highlighted, friends marked) and a
## Friends tab with the player's code, adding friends and renaming.

signal back_requested
signal add_friend_requested(code: String)
signal remove_friend_requested(player_id: String)
signal rename_requested(nickname: String)

const COLOR_PROMOTE := Color("dff3df")
const COLOR_RELEGATE := Color("f8dcdc")
const COLOR_SAFE := Color("ffffff")
const COLOR_ME_BORDER := Color("1e1e2a")
const COLOR_TEXT := Color("1e1e2a")
const COLOR_MUTED := Color(0.3, 0.3, 0.35)

@onready var back_button: Button = $Margin/VBox/TopBar/BackButton
@onready var title_label: Label = $Margin/VBox/TopBar/Title
@onready var info_label: Label = $Margin/VBox/InfoLabel
@onready var standings_button: Button = $Margin/VBox/Tabs/StandingsButton
@onready var friends_button: Button = $Margin/VBox/Tabs/FriendsButton
@onready var friends_panel: VBoxContainer = $Margin/VBox/FriendsPanel
@onready var code_label: Label = $Margin/VBox/FriendsPanel/CodeLabel
@onready var code_edit: LineEdit = $Margin/VBox/FriendsPanel/AddRow/CodeEdit
@onready var add_button: Button = $Margin/VBox/FriendsPanel/AddRow/AddButton
@onready var name_edit: LineEdit = $Margin/VBox/FriendsPanel/NameRow/NameEdit
@onready var name_button: Button = $Margin/VBox/FriendsPanel/NameRow/NameButton
@onready var status_label: Label = $Margin/VBox/FriendsPanel/StatusLabel
@onready var list: VBoxContainer = $Margin/VBox/Scroll/List

var tab: String = "standings"
var _standing: Dictionary = {}
var _friends: Array = []


func _ready() -> void:
	back_button.pressed.connect(back_requested.emit)
	standings_button.pressed.connect(show_tab.bind("standings"))
	friends_button.pressed.connect(show_tab.bind("friends"))
	add_button.pressed.connect(_on_add)
	code_edit.text_submitted.connect(func(_t: String) -> void: _on_add())
	name_button.pressed.connect(func() -> void: rename_requested.emit(name_edit.text))


## standing: LeagueStanding; friends: [FriendEntry]; code: own friend code.
func refresh(standing: Dictionary, friends: Array, code: String, nickname: String, week_left_text: String) -> void:
	_standing = standing
	_friends = friends
	title_label.text = "%s league" % standing.get("tier_name", "")
	var rules: Dictionary = standing.get("rules", {})
	var counting := "Best %d games count" % int(rules.get("best_n", 15)) if str(rules.get("weekly_mode", "best_n")) == "best_n" else "Every game counts"
	info_label.text = "%s\n%s · ends in %s" % [standing.get("rules_text", ""), counting, week_left_text]
	code_label.text = "Your code: %s" % code
	if name_edit.text == "":
		name_edit.text = nickname
	show_tab(tab)


func set_status(text: String) -> void:
	status_label.text = text if text != "" else " "


func show_tab(name: String) -> void:
	tab = name
	standings_button.button_pressed = name == "standings"
	friends_button.button_pressed = name == "friends"
	friends_panel.visible = name == "friends"
	_clear_list()
	if name == "standings":
		_fill_standings()
	else:
		_fill_friends()


func _clear_list() -> void:
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()


func _fill_standings() -> void:
	if not _standing.get("joined", false):
		list.add_child(_note("Play a game to join this week's league."))
		return
	var group: Dictionary = _standing.get("group", {})
	var rules: Dictionary = _standing.get("rules", {})
	if rules.get("global", false):
		list.add_child(_note("Diamond is one global standing. Top %d shown." % mini(100, int(group.get("size", 0)))))
	var shown := 0
	for m in group.get("members", []):
		if shown >= 100 and not m.get("is_me", false):
			continue
		list.add_child(_member_row(m))
		shown += 1


func _fill_friends() -> void:
	if _friends.is_empty():
		list.add_child(_note("No friends yet. Swap codes to see each other here and in the same league group."))
		return
	for fr in _friends:
		list.add_child(_friend_row(fr))


func _note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 26)
	label.add_theme_color_override("font_color", COLOR_MUTED)
	return label


func _row_panel(bg: Color, highlight: bool) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(12)
	style.set_content_margin_all(12)
	if highlight:
		style.set_border_width_all(3)
		style.border_color = COLOR_ME_BORDER
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _cell(text: String, width: float, align: int, size: int = 26, color: Color = COLOR_TEXT) -> Label:
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


func _member_row(m: Dictionary) -> Control:
	var zone := str(m.get("zone", "safe"))
	var bg := COLOR_SAFE
	if zone == "promote":
		bg = COLOR_PROMOTE
	elif zone == "relegate":
		bg = COLOR_RELEGATE
	var panel := _row_panel(bg, m.get("is_me", false))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(_cell("%d" % int(m.get("rank", 0)), 56, HORIZONTAL_ALIGNMENT_RIGHT))
	var name := str(m.get("nickname", ""))
	if m.get("is_me", false):
		name += " (you)"
	elif m.get("is_friend", false):
		name += " ♥"
	row.add_child(_cell(name, 0, HORIZONTAL_ALIGNMENT_LEFT))
	row.add_child(_cell("%d games" % int(m.get("games", 0)), 120, HORIZONTAL_ALIGNMENT_RIGHT, 22, COLOR_MUTED))
	row.add_child(_cell("%d" % int(m.get("weekly_score", 0)), 110, HORIZONTAL_ALIGNMENT_RIGHT))
	panel.add_child(row)
	return panel


func _friend_row(fr: Dictionary) -> Control:
	var panel := _row_panel(COLOR_SAFE, false)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(_cell(str(fr.get("nickname", "")), 0, HORIZONTAL_ALIGNMENT_LEFT))
	row.add_child(_cell(str(fr.get("tier_name", "")), 120, HORIZONTAL_ALIGNMENT_CENTER, 22, COLOR_MUTED))
	row.add_child(_cell("%d this week" % int(fr.get("weekly_score", 0)), 170, HORIZONTAL_ALIGNMENT_RIGHT, 22, COLOR_MUTED))
	var remove := Button.new()
	remove.text = "Remove"
	remove.flat = true
	remove.add_theme_font_size_override("font_size", 22)
	remove.pressed.connect(remove_friend_requested.emit.bind(str(fr.get("player_id", ""))))
	row.add_child(remove)
	panel.add_child(row)
	return panel


func _on_add() -> void:
	var code := code_edit.text.strip_edges().to_upper()
	if code == "":
		return
	add_friend_requested.emit(code)


func clear_code() -> void:
	code_edit.text = ""
