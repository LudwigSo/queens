extends Control
## League: the tier card, standings of the player's group (promotion zone
## green, relegation zone red, the player highlighted, friends marked), the
## player's own games of the round ("My games": which count, and the score to
## beat) and a Friends tab with the player's code and adding friends.
##
## Bronze and Silver have no group: their card shows the progress to the next
## tier, and the standings tab is not there. Offline the standings are replaced
## by a notice; the player's own numbers keep moving.

signal back_requested
signal add_friend_requested(code: String)
signal remove_friend_requested(player_id: String)
signal rename_requested(nickname: String)   ## Kept for API compatibility; renaming lives in Settings.
signal run_selected(result_id: String)
signal offline_info_requested

const HEART_ICON := "res://assets/icons/line/heart_fill.svg"
const CLOSE_ICON := "res://assets/icons/line/close.svg"
const CLOCK_ICON := "res://assets/icons/line/clock.svg"

@onready var back_button: Button = $Margin/VBox/TopBar/BackButton
@onready var offline_button: Button = $Margin/VBox/TopBar/Spacer/OfflineButton
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
var _runs: Dictionary = {}
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
	offline_button.pressed.connect(offline_info_requested.emit)
	Motion.make_pressable(offline_button)


func set_offline(offline: bool) -> void:
	offline_button.visible = offline


func set_loading(loading: bool) -> void:
	skeleton.visible = loading
	scroll.visible = not loading


## standing: LeagueStanding (with `offline` when it is the last known one);
## friends: [FriendEntry]; code: own friend code; runs: Views.runs().
func refresh(standing: Dictionary, friends: Array, code: String, _nickname: String, round_left_text: String, runs: Dictionary = {}) -> void:
	_standing = standing
	_friends = friends
	_runs = runs
	_code = code
	var tier_id := str(standing.get("tier", "bronze"))
	tier_label.text = Loc.f("LEAGUE_NAME", [LeagueRules.tier_label(tier_id)])
	medal.modulate = Ui.tier_color(tier_id)
	var rules: Dictionary = standing.get("rules", {})
	var has_rounds := int(rules.get("round_days", standing.get("round_days", 7))) > 0
	set_offline(bool(standing.get("offline", false)))
	# A tier that promotes by tier points shows the progress toward the next tier
	# instead. Neither the round length nor the best-N cap decides anything there,
	# so naming them would only mislead.
	var need := int(rules.get("promo_score", 0))
	if not has_rounds:
		info_label.text = str(standing.get("rules_text", "")) + "\n" + Loc.t("LEAGUE_NO_TIMER")
	elif need > 0:
		info_label.text = str(standing.get("rules_text", ""))
	else:
		var counting := Loc.f("LEAGUE_COUNT_BEST_N", [int(rules.get("best_n", 15))]) if str(rules.get("round_mode", "best_n")) == "best_n" else Loc.t("LEAGUE_COUNT_ALL")
		var days := int(rules.get("round_days", 7))
		var period := Loc.t("LEAGUE_PERIOD_WEEK") if days == 7 else Loc.f("LEAGUE_PERIOD_DAYS", [days])
		info_label.text = Loc.f("LEAGUE_INFO_RULES", [str(standing.get("rules_text", "")), counting]) + "\n" + Loc.f("LEAGUE_INFO_ENDS", [period, round_left_text])
	if bool(rules.get("online_required", false)):
		info_label.text += "\n" + Loc.t("LEAGUE_ONLINE_RULE")
	# No group, no standings: the run overview takes its place.
	var standings_button: Button = tabs.get_node("standings")
	standings_button.visible = has_rounds
	if not has_rounds and tab == "standings":
		tab = "runs"
	var points_now := int(standing.get("my_tier_points", 0))
	progress.visible = need > 0
	progress_label.visible = need > 0
	if need > 0:
		progress.max_value = need
		progress.value = mini(points_now, need)
		progress_label.text = Fmt.progress(points_now, need, str(rules.get("up_to_name", "")))
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
	match name:
		"standings":
			_fill_standings()
		"runs":
			_fill_runs()
		_:
			_fill_friends()


func _clear_list() -> void:
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()


func _fill_standings() -> void:
	if bool(_standing.get("offline", false)):
		# The ranking is the server's; the last one we have is stale, so do not
		# pretend. My own score is still up to date on the card above.
		var strict := bool((_standing.get("rules", {}) as Dictionary).get("online_required", false))
		var tier_name := LeagueRules.tier_label(str(_standing.get("tier", "")))
		list.add_child(_notice(Loc.f("LEAGUE_OFFLINE_STRICT", [tier_name]) if strict else Loc.t("LEAGUE_OFFLINE")))
		return
	if not _standing.get("joined", false):
		list.add_child(_note(Loc.t("LEAGUE_JOIN_NOTE")))
		return
	var group: Dictionary = _standing.get("group", {})
	var rules: Dictionary = _standing.get("rules", {})
	if rules.get("global", false):
		var size := int(group.get("size", 0))
		var note := Loc.f("LEAGUE_GLOBAL_NOTE", [LeagueRules.tier_label(str(_standing.get("tier", ""))), size])
		if size > 100:
			note += " " + Loc.t("LEAGUE_TOP_100")
		if int(rules.get("up_count", -1)) >= 0:
			note += " " + Loc.plural("LEAGUE_SLOTS_OPEN", int(rules["up_count"]))
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


func _fill_runs() -> void:
	if bool(_standing.get("offline", false)):
		var strict := bool((_standing.get("rules", {}) as Dictionary).get("online_required", false))
		var tier_name := LeagueRules.tier_label(str(_standing.get("tier", "")))
		list.add_child(_notice(Loc.f("LEAGUE_OFFLINE_STRICT", [tier_name]) if strict else Loc.t("LEAGUE_OFFLINE")))
	list.add_child(_header_note(str(_runs.get("header", ""))))
	var rows_data: Array = _runs.get("rows", [])
	if rows_data.is_empty():
		list.add_child(_note(str(_runs.get("empty_text", Loc.t("RUNS_EMPTY")))))
		return
	var rows: Array = []
	var counted_shown := false
	var extra_shown := false
	for r in rows_data:
		var state := str(r.get("state", "best"))
		var counting := state == "best" or state == "cut"
		if counting and not counted_shown:
			list.add_child(_section(str(_runs.get("counted_title", ""))))
			counted_shown = true
		elif not counting and not extra_shown:
			list.add_child(_section(Loc.t("RUNS_NOT_COUNTED")))
			extra_shown = true
		var row := _run_row(r)
		list.add_child(row)
		rows.append(row)
	Motion.stagger(rows)


func _fill_friends() -> void:
	if _friends.is_empty():
		list.add_child(_note(Loc.t("LEAGUE_NO_FRIENDS")))
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


## A prominent line, for the score to beat.
func _header_note(text: String) -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"CardFlat"
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.theme_type_variation = &"LabelBodyBold"
	panel.add_child(label)
	return panel


## The offline notice: what happens to the games played now.
func _notice(text: String) -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"ChipWarning"
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.theme_type_variation = &"LabelCaptionInk"
	panel.add_child(label)
	return panel


func _section(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"LabelCaption"
	return label


func _cell(text: String, width: float, align: int, variation: StringName = &"LabelBody") -> Label:
	var label := Label.new()
	label.auto_translate_mode = Control.AUTO_TRANSLATE_MODE_DISABLED
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
		name = Loc.f("COMMON_YOU", [name])
	row.add_child(_cell(name, 0, HORIZONTAL_ALIGNMENT_LEFT, &"LabelBodyBold" if is_me else &"LabelBody"))
	if m.get("is_friend", false):
		row.add_child(_icon(HEART_ICON, Ui.ERROR))
	row.add_child(_cell(Loc.plural("LEAGUE_GAMES", int(m.get("games", 0))), 110, HORIZONTAL_ALIGNMENT_RIGHT, &"LabelCaption"))
	row.add_child(_cell("%d" % int(m.get("round_score", 0)), 90, HORIZONTAL_ALIGNMENT_RIGHT, &"LabelBodyBold"))
	panel.add_child(row)
	return panel


## One game of the overview. The counted ones look like ordinary rows, the one
## to beat is highlighted, the rest are muted. A tap opens the game's details.
func _run_row(r: Dictionary) -> Control:
	var state := str(r.get("state", "best"))
	var button := Button.new()
	button.theme_type_variation = &"ButtonCard"
	button.custom_minimum_size = Vector2(0, 76)
	button.pressed.connect(run_selected.emit.bind(str(r.get("result_id", ""))))
	Motion.make_pressable(button)
	var panel := PanelContainer.new()
	match state:
		"cut":
			panel.theme_type_variation = &"RowMe"
		"best":
			panel.theme_type_variation = &"RowPanel"
		_:
			panel.theme_type_variation = &"RowPanel"
			panel.modulate = Color(1, 1, 1, 0.6)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 12)
	var text := VBoxContainer.new()
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	text.add_child(_cell(str(r.get("title", "")), 0, HORIZONTAL_ALIGNMENT_LEFT, &"LabelBodyBold"))
	var sub := HBoxContainer.new()
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub.add_theme_constant_override("separation", 8)
	var stars := StarRow.new()
	stars.icon_size = 14
	stars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub.add_child(stars)
	stars.set_stars(int(r.get("stars", 0)), 4)
	sub.add_child(_cell(str(r.get("diff_text", "")), -1, HORIZONTAL_ALIGNMENT_LEFT, &"LabelCaption"))
	for tag in r.get("tags", []):
		var chip := PanelContainer.new()
		chip.theme_type_variation = &"ChipPrimary" if state == "cut" and tag == Loc.t("RUNS_CUT") else &"Chip"
		var tag_label := Label.new()
		tag_label.text = str(tag)
		tag_label.theme_type_variation = &"LabelOnDark" if chip.theme_type_variation == &"ChipPrimary" else &"LabelCaptionInk"
		chip.add_child(tag_label)
		sub.add_child(chip)
	text.add_child(sub)
	row.add_child(text)
	if bool(r.get("tags", []).has(Loc.t("RUNS_PENDING"))):
		row.add_child(_icon(CLOCK_ICON, Ui.MUTED, 20))
	row.add_child(_cell("%d" % int(r.get("score", 0)), 90, HORIZONTAL_ALIGNMENT_RIGHT, &"LabelHeading"))
	panel.add_child(row)
	button.add_child(panel)
	return button


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
	tier.text = LeagueRules.tier_label(str(fr.get("tier", "")))
	tier.theme_type_variation = &"LabelCaptionInk"
	tier_chip.add_child(tier)
	row.add_child(tier_chip)
	row.add_child(_cell(Fmt.points(int(fr.get("round_score", 0))), 110, HORIZONTAL_ALIGNMENT_RIGHT, &"LabelCaption"))
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
