extends Control
## One level: thumbnail and stats, the leaderboard (global / friends /
## fastest flawless) and a sticky Play button (locked while on cooldown).

signal back_requested
signal play_requested(level_id: String)
signal scope_requested(scope: String)

const LOCK_ICON := "res://assets/icons/line/lock.svg"
const HEART_ICON := "res://assets/icons/line/heart_fill.svg"

@onready var back_button: Button = $Margin/VBox/TopBar/BackButton
@onready var title_label: Label = $Margin/VBox/TopBar/Title
@onready var thumb: BoardThumb = $Margin/VBox/HeaderCard/HBox/Thumb
@onready var size_label: Label = $Margin/VBox/HeaderCard/HBox/Stats/Meta/SizeLabel
@onready var stars: StarRow = $Margin/VBox/HeaderCard/HBox/Stats/Meta/Stars
@onready var diff_label: Label = $Margin/VBox/HeaderCard/HBox/Stats/DiffLabel
@onready var mine_label: Label = $Margin/VBox/HeaderCard/HBox/Stats/MineLabel
@onready var tabs: Segmented = $Margin/VBox/Tabs
@onready var scroll: ScrollContainer = $Margin/VBox/Scroll
@onready var list: VBoxContainer = $Margin/VBox/Scroll/List
@onready var skeleton: Control = $Margin/VBox/Skeleton
@onready var play_button: Button = $Margin/VBox/PlayButton

var level_id: String = ""
var _locked: bool = false


func _ready() -> void:
	back_button.pressed.connect(back_requested.emit)
	tabs.selected.connect(scope_requested.emit)
	play_button.pressed.connect(_on_play)


func set_loading(loading: bool) -> void:
	skeleton.visible = loading
	scroll.visible = not loading


## view: {level_id, level_no, size, difficulty, stars, regions, par_text, players,
## mine:{score, time_text, mistakes, rank}|{}, scope, entries:[{rank, nickname, score,
## time_text, wrong_placements, is_me, is_friend}], lock_text}
func refresh(view: Dictionary) -> void:
	level_id = str(view.get("level_id", ""))
	title_label.text = "Level %d" % int(view.get("level_no", 0))
	thumb.regions = view.get("regions", [])
	size_label.text = Fmt.size_text(int(view.get("size", 0)))
	stars.set_stars(int(view.get("stars", 0)), 4)
	diff_label.text = "Difficulty %d · par %s · %d players" % [int(view.get("difficulty", 0)), str(view.get("par_text", "")), int(view.get("players", 0))]
	var mine: Dictionary = view.get("mine", {})
	if mine.is_empty():
		mine_label.text = "Not played yet"
	else:
		mine_label.text = "Your best: %s · %s · %s · #%d" % [Fmt.points(int(mine.get("score", 0))), str(mine.get("time_text", "")), Fmt.mistakes(int(mine.get("mistakes", 0))), int(mine.get("rank", 0))]
	tabs.select(str(view.get("scope", "global")), false)
	var lock_text := str(view.get("lock_text", ""))
	_locked = lock_text != ""
	play_button.text = "Play this level" if not _locked else "Unlocks in %s" % lock_text
	play_button.icon = load(LOCK_ICON) if _locked and ResourceLoader.exists(LOCK_ICON, "Texture2D") else null
	play_button.theme_type_variation = &"ButtonPrimary" if not _locked else &"ButtonSecondary"
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()
	var entries: Array = view.get("entries", [])
	var scope := str(view.get("scope", "global"))
	if entries.is_empty():
		var note := Label.new()
		note.text = "Nobody here yet." if scope != "friends" else "None of your friends has played this level."
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.theme_type_variation = &"LabelMuted"
		list.add_child(note)
	var rows: Array = []
	for e in entries:
		var row := _entry_row(e)
		list.add_child(row)
		rows.append(row)
	Motion.stagger(rows)
	set_loading(false)


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


func _rank_badge(rank: int, is_me: bool) -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"ChipPrimary" if is_me else &"Chip"
	panel.custom_minimum_size = Vector2(52, 0)
	var label := Label.new()
	label.text = str(rank)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.theme_type_variation = &"LabelOnDark" if is_me else &"LabelCaptionInk"
	panel.add_child(label)
	return panel


func _entry_row(e: Dictionary) -> Control:
	var is_me := bool(e.get("is_me", false))
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"RowMe" if is_me else &"RowPanel"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(_rank_badge(int(e.get("rank", 0)), is_me))
	var name := str(e.get("nickname", ""))
	if is_me:
		name += " (you)"
	row.add_child(_cell(name, 0, HORIZONTAL_ALIGNMENT_LEFT, &"LabelBodyBold" if is_me else &"LabelBody"))
	if bool(e.get("is_friend", false)) and ResourceLoader.exists(HEART_ICON, "Texture2D"):
		var heart := TextureRect.new()
		heart.texture = load(HEART_ICON)
		heart.custom_minimum_size = Vector2(20, 20)
		heart.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		heart.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		heart.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		heart.modulate = Ui.ERROR
		row.add_child(heart)
	row.add_child(_cell("%d" % int(e.get("score", 0)), 80, HORIZONTAL_ALIGNMENT_RIGHT, &"LabelBodyBold"))
	row.add_child(_cell(str(e.get("time_text", "")), 80, HORIZONTAL_ALIGNMENT_RIGHT, &"LabelCaption"))
	var wrong := int(e.get("wrong_placements", 0))
	row.add_child(_cell("clean" if wrong == 0 else "%d ✕" % wrong, 80, HORIZONTAL_ALIGNMENT_RIGHT, &"LabelCaption"))
	panel.add_child(row)
	return panel


func _on_play() -> void:
	if _locked:
		Motion.shake(play_button)
		Sfx.haptic(20)
		return
	play_requested.emit(level_id)
