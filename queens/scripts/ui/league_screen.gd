extends Control
## League: the tier card, standings of the player's group (promotion zone
## green, relegation zone red, the player highlighted, friends marked) and a
## Friends tab with the player's code and adding friends.

signal back_requested
signal add_friend_requested(code: String)
signal remove_friend_requested(player_id: String)
signal rename_requested(nickname: String)   ## Kept for API compatibility; renaming lives in Settings.

const HEART_ICON := "res://assets/icons/line/heart_fill.svg"
const CLOSE_ICON := "res://assets/icons/line/close.svg"

@onready var back_button: Button = $Margin/VBox/TopBar/BackButton
@onready var medal: TextureRect = $Margin/VBox/TierCard/HBox/Medal
@onready var tier_label: Label = $Margin/VBox/TierCard/HBox/Text/TierLabel
@onready var info_label: Label = $Margin/VBox/TierCard/HBox/Text/InfoLabel
@onready var progress: ProgressBar = $Margin/VBox/TierCard/HBox/Text/Progress
@onready var progress_label: Label = $Margin/VBox/TierCard/HBox/Text/ProgressLabel
@onready var tabs: Segmented = $Margin/VBox/Tabs
@onready var friends_panel: VBoxContainer = $Margin/VBox/FriendsPanel
@onready var code_label: Label = $Margin/VBox/FriendsPanel/CodeRow/CodeChip/HBox/CodeLabel
@onready var copy_button: Button = $Margin/VBox/FriendsPanel/CodeRow/CopyButton
@onready var share_button: Button = $Margin/VBox/FriendsPanel/CodeRow/ShareButton
@onready var code_edit: LineEdit = $Margin/VBox/FriendsPanel/AddRow/CodeEdit
@onready var add_button: Button = $Margin/VBox/FriendsPanel/AddRow/AddButton
@onready var scroll: ScrollContainer = $Margin/VBox/Scroll
@onready var list: VBoxContainer = $Margin/VBox/Scroll/List
@onready var skeleton: Control = $Margin/VBox/Skeleton

var tab: String = "standings"
var _standing: Dictionary = {}
var _friends: Array = []
var _code: String = ""
var _last_my_rank: int = -1
var _status: String = ""


func _ready() -> void:
	back_button.pressed.connect(back_requested.emit)
	tabs.selected.connect(show_tab)
	add_button.pressed.connect(_on_add)
	code_edit.text_submitted.connect(func(_t: String) -> void: _on_add())
	copy_button.pressed.connect(_copy_code)
	share_button.pressed.connect(_copy_code)


func set_loading(loading: bool) -> void:
	skeleton.visible = loading
	scroll.visible = not loading


## standing: LeagueStanding; friends: [FriendEntry]; code: own friend code.
func refresh(standing: Dictionary, friends: Array, code: String, _nickname: String, round_left_text: String) -> void:
	_standing = standing
	_friends = friends
	_code = code
	var tier_id := str(standing.get("tier", "bronze"))
	tier_label.text = "%s league" % standing.get("tier_name", "")
	medal.modulate = Ui.tier_color(tier_id)
	var rules: Dictionary = standing.get("rules", {})
	var counting := "best %d games count" % int(rules.get("best_n", 15)) if str(rules.get("round_mode", "best_n")) == "best_n" else "every game counts"
	var days := int(rules.get("round_days", 7))
	var period := "Week" if days == 7 else "%d-day round" % days
	info_label.text = "%s · %s\n%s ends in %s" % [standing.get("rules_text", ""), counting, period, round_left_text]
	# A tier that promotes by tier points shows the progress toward the next tier.
	var need := int(rules.get("promo_score", 0))
	var points_now := int(standing.get("my_tier_points", 0))
	progress.visible = need > 0
	progress_label.visible = need > 0
	if need > 0:
		progress.max_value = need
		progress.value = mini(points_now, need)
		progress_label.text = Fmt.progress(points_now, need, str(rules.get("up_to", "")))
	code_label.text = code
	tabs.select(tab, false)
	show_tab(tab)
	set_loading(false)


func set_status(text: String) -> void:
	_status = text


func show_tab(name: String) -> void:
	tab = name
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
		list.add_child(_note("Play a game to join this round's league."))
		return
	var group: Dictionary = _standing.get("group", {})
	var rules: Dictionary = _standing.get("rules", {})
	if rules.get("global", false):
		var size := int(group.get("size", 0))
		var note := "%s is one global standing of %d players." % [_standing.get("tier_name", ""), size]
		if size > 100:
			note += " Top 100 shown."
		if int(rules.get("up_count", -1)) >= 0:
			note += " %d Challenger slot%s open this round." % [int(rules["up_count"]), "" if int(rules["up_count"]) == 1 else "s"]
		list.add_child(_note(note))
	var shown := 0
	var rows: Array = []
	var my_row: Control = null
	var my_rank := -1
	for m in group.get("members", []):
		if shown >= 100 and not m.get("is_me", false):
			continue
		var row := _member_row(m)
		list.add_child(row)
		rows.append(row)
		if m.get("is_me", false):
			my_row = row
			my_rank = int(m.get("rank", 0))
		shown += 1
	Motion.stagger(rows)
	if my_row != null and _last_my_rank >= 0 and my_rank != _last_my_rank and is_inside_tree():
		Motion.bump(my_row, 1.04, Motion.SLOW)
	_last_my_rank = my_rank


func _fill_friends() -> void:
	if _friends.is_empty():
		list.add_child(_note("No friends yet. Swap codes to see each other here and land in the same league group."))
		return
	var rows: Array = []
	for fr in _friends:
		var row := _friend_row(fr)
		list.add_child(row)
		rows.append(row)
	Motion.stagger(rows)


func _note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.theme_type_variation = &"LabelMuted"
	return label


func _cell(text: String, width: float, align: int, variation: StringName = &"LabelBody") -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = align
	label.theme_type_variation = variation
	if width > 0:
		label.custom_minimum_size = Vector2(width, 0)
	else:
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label


func _rank_badge(rank: int, is_me: bool, zone: String) -> Control:
	var panel := PanelContainer.new()
	var variation: StringName = &"Chip"
	if is_me:
		variation = &"ChipPrimary"
	elif zone == "promote":
		variation = &"ChipSuccess"
	elif zone == "relegate":
		variation = &"ChipError"
	panel.theme_type_variation = variation
	panel.custom_minimum_size = Vector2(52, 0)
	var label := Label.new()
	label.text = str(rank)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.theme_type_variation = &"LabelOnDark" if is_me else &"LabelCaptionInk"
	panel.add_child(label)
	return panel


func _icon(path: String, color: Color, size: int = 20) -> TextureRect:
	var tr := TextureRect.new()
	if ResourceLoader.exists(path, "Texture2D"):
		tr.texture = load(path)
	tr.custom_minimum_size = Vector2(size, size)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tr.modulate = color
	return tr


func _member_row(m: Dictionary) -> Control:
	var zone := str(m.get("zone", "safe"))
	var is_me := bool(m.get("is_me", false))
	var variation: StringName = &"RowPanel"
	if is_me:
		variation = &"RowMe"
	elif zone == "promote":
		variation = &"RowPromote"
	elif zone == "relegate":
		variation = &"RowRelegate"
	var panel := PanelContainer.new()
	panel.theme_type_variation = variation
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(_rank_badge(int(m.get("rank", 0)), is_me, zone))
	var name := str(m.get("nickname", ""))
	if is_me:
		name += " (you)"
	row.add_child(_cell(name, 0, HORIZONTAL_ALIGNMENT_LEFT, &"LabelBodyBold" if is_me else &"LabelBody"))
	if m.get("is_friend", false):
		row.add_child(_icon(HEART_ICON, Ui.ERROR))
	row.add_child(_cell("%d games" % int(m.get("games", 0)), 110, HORIZONTAL_ALIGNMENT_RIGHT, &"LabelCaption"))
	row.add_child(_cell("%d" % int(m.get("round_score", 0)), 90, HORIZONTAL_ALIGNMENT_RIGHT, &"LabelBodyBold"))
	panel.add_child(row)
	return panel


func _friend_row(fr: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"RowPanel"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(_icon(HEART_ICON, Ui.ERROR, 22))
	row.add_child(_cell(str(fr.get("nickname", "")), 0, HORIZONTAL_ALIGNMENT_LEFT, &"LabelBodyBold"))
	var tier_chip := PanelContainer.new()
	tier_chip.theme_type_variation = &"Chip"
	var tier := Label.new()
	tier.text = str(fr.get("tier_name", ""))
	tier.theme_type_variation = &"LabelCaptionInk"
	tier_chip.add_child(tier)
	row.add_child(tier_chip)
	row.add_child(_cell("%d pts" % int(fr.get("round_score", 0)), 110, HORIZONTAL_ALIGNMENT_RIGHT, &"LabelCaption"))
	var remove := Button.new()
	remove.theme_type_variation = &"ButtonIconGhost"
	remove.custom_minimum_size = Vector2(44, 44)
	if ResourceLoader.exists(CLOSE_ICON, "Texture2D"):
		remove.icon = load(CLOSE_ICON)
		remove.expand_icon = true
		remove.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		remove.text = "x"
	remove.pressed.connect(remove_friend_requested.emit.bind(str(fr.get("player_id", ""))))
	Motion.make_pressable(remove)
	row.add_child(remove)
	panel.add_child(row)
	return panel


func _on_add() -> void:
	var code := code_edit.text.strip_edges().to_upper()
	if code == "":
		Motion.shake(code_edit)
		return
	add_friend_requested.emit(code)


func _copy_code() -> void:
	DisplayServer.clipboard_set(_code)
	Motion.bump(code_label, 1.1)
	Sfx.play(&"toast")


func clear_code() -> void:
	code_edit.text = ""
