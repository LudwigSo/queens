extends Control
## Once-per-round modal: how the last league round ended, or (reason
## "score") a promotion earned mid-round by tier points. Shows the medal
## before and after (the new one flips in), a headline coloured by outcome,
## stat chips and confetti on a promotion.

signal closed(round_index: int)

const COLOR_UP := Ui.SECONDARY_DARK
const COLOR_STAY := Ui.INK
const COLOR_DOWN := Ui.ERROR

@onready var dim: ColorRect = $Dim
@onready var panel: PanelContainer = $Panel
@onready var title: Label = $Panel/VBox/Title
@onready var before: TextureRect = $Panel/VBox/Medals/Before
@onready var arrow: TextureRect = $Panel/VBox/Medals/Arrow
@onready var after: TextureRect = $Panel/VBox/Medals/After
@onready var headline: Label = $Panel/VBox/Headline
@onready var chips: HBoxContainer = $Panel/VBox/Chips
@onready var body: Label = $Panel/VBox/Body
@onready var ok_button: Button = $Panel/VBox/OkButton

var round_index: int = -1
var _confetti: CPUParticles2D


func _ready() -> void:
	ok_button.pressed.connect(close)
	_confetti = CPUParticles2D.new()
	_confetti.emitting = false
	_confetti.one_shot = true
	_confetti.amount = 90
	_confetti.lifetime = 2.0
	_confetti.explosiveness = 0.95
	_confetti.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_confetti.emission_rect_extents = Vector2(300, 4)
	_confetti.direction = Vector2(0, 1)
	_confetti.spread = 35.0
	_confetti.gravity = Vector2(0, 600)
	_confetti.initial_velocity_min = 200.0
	_confetti.initial_velocity_max = 420.0
	_confetti.angular_velocity_min = -300.0
	_confetti.angular_velocity_max = 300.0
	var img := Image.create(8, 12, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_confetti.texture = ImageTexture.create_from_image(img)
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.33, 0.66, 1.0])
	ramp.colors = PackedColorArray([Ui.SECONDARY, Ui.PRIMARY_LIGHT, Ui.REGIONS[0], Ui.REGIONS[4]])
	_confetti.color_initial_ramp = ramp
	_confetti.z_index = 5
	add_child(_confetti)


## summary: RoundSummary; tier names resolved by the caller.
func open(summary: Dictionary, tier_before_name: String, tier_after_name: String) -> void:
	round_index = int(summary.get("round_index", -1))
	var outcome := str(summary.get("outcome", "stayed"))
	var by_score := str(summary.get("reason", "round")) == "score"
	title.text = Loc.t("SUMMARY_HEADING_PROMOTION") if by_score else Loc.t("SUMMARY_HEADING_ROUND")
	var color := COLOR_STAY
	var changed := false
	match outcome:
		"promoted":
			headline.text = Loc.f("SUMMARY_PROMOTED", [tier_after_name])
			color = COLOR_UP
			changed = true
		"relegated":
			headline.text = Loc.f("SUMMARY_RELEGATED", [tier_after_name])
			color = COLOR_DOWN
			changed = true
		"inactive_relegated":
			headline.text = Loc.f("SUMMARY_INACTIVE_DOWN", [tier_after_name])
			color = COLOR_DOWN
			changed = true
		"inactive_frozen":
			headline.text = Loc.f("SUMMARY_INACTIVE_STAY", [tier_before_name])
		_:
			headline.text = Loc.f("SUMMARY_STAYED", [tier_before_name])
	headline.add_theme_color_override("font_color", color)
	before.modulate = Ui.tier_color(str(summary.get("tier_before", "bronze")))
	after.modulate = Ui.tier_color(str(summary.get("tier_after", summary.get("tier_before", "bronze"))))
	before.visible = changed
	arrow.visible = changed
	for child in chips.get_children():
		chips.remove_child(child)
		child.queue_free()
	if int(summary.get("group_size", 0)) > 0:
		chips.add_child(_chip(Loc.f("SUMMARY_RANK", [int(summary.get("rank", 0)), int(summary.get("group_size", 0))]), &"ChipPrimary", &"LabelOnDark"))
		if by_score:
			chips.add_child(_chip(Loc.f("SUMMARY_TIER_POINTS", [int(summary.get("tier_points", 0))]), &"Chip", &"LabelCaptionInk"))
		else:
			chips.add_child(_chip(Loc.f("SUMMARY_POINTS", [int(summary.get("round_score", 0))]), &"Chip", &"LabelCaptionInk"))
	var best: Dictionary = summary.get("best_game", {})
	if by_score:
		body.text = Loc.f("SUMMARY_REACHED", [int(summary.get("tier_points", 0)), tier_before_name])
	elif not best.is_empty():
		body.text = Loc.f("SUMMARY_BEST_GAME", [int(best.get("score", 0))])
	elif int(summary.get("group_size", 0)) == 0:
		body.text = Loc.t("SUMMARY_PLAY_TO_CLIMB")
	else:
		body.text = " "
	visible = true
	_animate(outcome == "promoted")


func _animate(promoted: bool) -> void:
	if not Motion.effects_enabled() or not is_inside_tree():
		return
	after.pivot_offset = after.size * 0.5
	after.scale = Vector2(0.0, 1.0)
	var t := create_tween()
	t.tween_interval(0.3)
	t.tween_property(after, "scale", Vector2(1.15, 1.15), Motion.SLOW).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(after, "scale", Vector2.ONE, Motion.BASE)
	if promoted:
		t.tween_callback(func() -> void:
			_confetti.position = Vector2(size.x * 0.5, panel.global_position.y - 20.0)
			_confetti.restart()
			_confetti.emitting = true
			Sfx.play(&"win", 0.0, -4.0)
			Sfx.haptic_double(50))


func _chip(text: String, variation: StringName, label_variation: StringName) -> PanelContainer:
	var chip := PanelContainer.new()
	chip.theme_type_variation = variation
	var label := Label.new()
	label.text = text
	label.theme_type_variation = label_variation
	chip.add_child(label)
	return chip


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit(round_index)
