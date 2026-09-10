extends Control
## "Solved!" panel over the board: the score counts up, the factor bars fill,
## badges stamp in, then the league line and the next-game choice.

signal next_requested(step: int)   ## -1 easier, 0 same, +1 harder
signal home_requested
signal closed

## Translation keys, not text: a const cannot call into Loc.
const FACTOR_KEYS := {"accuracy": "FACTOR_ACCURACY", "speed": "FACTOR_SPEED", "hint": "FACTOR_HINT"}

@onready var dim: ColorRect = $Dim
@onready var panel: PanelContainer = $Panel
@onready var crown: TextureRect = $Panel/VBox/Crown
@onready var score_label: Label = $Panel/VBox/ScoreLabel
@onready var badges: HBoxContainer = $Panel/VBox/Badges
@onready var stats: HBoxContainer = $Panel/VBox/Stats
@onready var factors: VBoxContainer = $Panel/VBox/Factors
@onready var league_card: PanelContainer = $Panel/VBox/LeagueCard
@onready var medal: TextureRect = $Panel/VBox/LeagueCard/HBox/Medal
@onready var league_label: Label = $Panel/VBox/LeagueCard/HBox/LeagueLabel
@onready var easier_button: Button = $Panel/VBox/Next/Easier
@onready var same_button: Button = $Panel/VBox/Next/Same
@onready var harder_button: Button = $Panel/VBox/Next/Harder
@onready var home_button: Button = $Panel/VBox/HomeButton

var _bars: Array = []


func _ready() -> void:
	harder_button.pressed.connect(_choose.bind(1))
	same_button.pressed.connect(_choose.bind(0))
	easier_button.pressed.connect(_choose.bind(-1))
	home_button.pressed.connect(func() -> void: close(); home_requested.emit())


func _choose(step: int) -> void:
	close()
	next_requested.emit(step)


func close() -> void:
	visible = false
	closed.emit()


## view: {score, badges:[String], stats:[{label, value}], factors:[{id, value, pct}],
## league:{tier_id, tier_name, rank, size, zone, score}|{}, next:{"-1": {size, enabled}, ...}}
func show_result(view: Dictionary) -> void:
	visible = true
	Motion.fade(dim, 1.0, Motion.FAST)
	Motion.pop_in(panel, Motion.SLOW, 0.9)
	crown.pivot_offset = crown.size * 0.5
	Motion.pop_in(crown, Motion.SLOW, 0.3)
	Motion.count_up(score_label, int(view.get("score", 0)), Motion.SLOW)

	_clear(badges)
	var i := 0
	for b in view.get("badges", []):
		var chip := _chip(str(b), &"ChipGold")
		badges.add_child(chip)
		if Motion.effects_enabled():
			chip.modulate.a = 0.0
			var t := chip.create_tween()
			t.tween_interval(0.35 + 0.12 * i)
			t.tween_callback(func() -> void: Motion.pop_in(chip, Motion.BASE, 1.4))
		i += 1
	badges.visible = badges.get_child_count() > 0

	_clear(stats)
	for s in view.get("stats", []):
		stats.add_child(_stat(str(s.get("label", "")), str(s.get("value", ""))))

	_clear(factors)
	_bars.clear()
	var j := 0
	for f in view.get("factors", []):
		var row := _factor_row(str(f.get("id", "")), float(f.get("value", 1.0)), float(f.get("pct", 1.0)), j)
		factors.add_child(row)
		j += 1

	var league: Dictionary = view.get("league", {})
	league_card.visible = not league.is_empty()
	if not league.is_empty():
		medal.modulate = Ui.tier_color(str(league.get("tier_id", "bronze")))
		if str(league.get("promoted_to_name", "")) != "":
			medal.modulate = Ui.tier_color(str(league.get("promoted_to", "bronze")))
			league_label.text = Loc.f("WIN_PROMOTED", [str(league.get("promoted_to_name", ""))])
		elif int(league.get("promo_score", 0)) > 0:
			league_label.text = Loc.f("WIN_LEAGUE_PROMO_LINE", [
				str(league.get("tier_name", "")), str(league.get("promo_text", "")), int(league.get("rank", 0)), int(league.get("size", 0))])
		else:
			league_label.text = Loc.f("WIN_LEAGUE_LINE", [
				str(league.get("tier_name", "")), int(league.get("score", 0)), int(league.get("rank", 0)),
				int(league.get("size", 0)), Fmt.zone(str(league.get("zone", "safe")))])

	var next: Dictionary = view.get("next", {})
	for pair in [[easier_button, -1], [same_button, 0], [harder_button, 1]]:
		var button: Button = pair[0]
		var opt: Dictionary = next.get(str(pair[1]), {})
		button.visible = not opt.is_empty()
		button.disabled = not bool(opt.get("enabled", true))
		var base: String = Loc.t({-1: "STEP_EASIER", 0: "STEP_SAME", 1: "STEP_HARDER"}[pair[1]])
		button.text = base if opt.is_empty() else "%s\n%s" % [base, Fmt.size_text(int(opt.get("size", 0)))]


## Kept for older callers: preformatted strings only.
func show_result_text(score_text: String, badge_text: String, detail_text: String, league_text: String = "") -> void:
	show_result({"score": int(score_text), "badges": Array(badge_text.split(" · ", false)), "stats": [{"label": Loc.t("WIN_STAT_DETAILS"), "value": detail_text}], "factors": [], "league": {}, "next": {}})
	league_label.text = league_text


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _chip(text: String, variation: StringName) -> PanelContainer:
	var chip := PanelContainer.new()
	chip.theme_type_variation = variation
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"LabelCaptionInk"
	chip.add_child(label)
	return chip


func _stat(label_text: String, value_text: String) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 0)
	var value := Label.new()
	value.text = value_text
	value.theme_type_variation = &"LabelHeading"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var label := Label.new()
	label.text = label_text
	label.theme_type_variation = &"LabelCaption"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(value)
	box.add_child(label)
	return box


func _factor_row(id: String, value: float, pct: float, index: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var name := Label.new()
	name.text = Loc.t(FACTOR_KEYS[id]) if FACTOR_KEYS.has(id) else id.capitalize()
	name.theme_type_variation = &"LabelCaption"
	name.custom_minimum_size = Vector2(96, 0)
	row.add_child(name)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 14)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# Coloured off the multiplier, not the fill: the speed bar is scaled so that
	# x1.00 sits at half width, and a half-full speed bar is not a bad round.
	if value < 0.6:
		var fill := StyleBoxFlat.new()
		fill.bg_color = Ui.ERROR if value < 0.4 else Ui.WARNING
		fill.set_corner_radius_all(Ui.RADIUS_PILL)
		bar.add_theme_stylebox_override("fill", fill)
	row.add_child(bar)
	var val := Label.new()
	val.text = Fmt.factor(value)
	val.theme_type_variation = &"LabelCaptionInk"
	val.custom_minimum_size = Vector2(64, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	if Motion.effects_enabled():
		bar.value = 0.0
		var t := bar.create_tween()
		t.tween_interval(0.25 + 0.1 * index)
		t.tween_property(bar, "value", clampf(pct, 0.0, 1.0), Motion.SLOW).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		bar.value = clampf(pct, 0.0, 1.0)
	return row
