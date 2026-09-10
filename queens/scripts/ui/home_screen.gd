extends Control
## Start screen: energy and settings on top, the league teaser, and three
## difficulty cards (Easier / Same / Harder) previewing the level each would
## start. Tapping a card selects it; Play starts the selected one.

signal play_requested(step: int)   ## -1 easier, 0 same, +1 harder
signal overview_requested
signal league_requested
signal energy_pressed
signal settings_requested

const STEP_NAMES := {-1: "Easier", 0: "Same", 1: "Harder"}

@onready var settings_button: Button = $Margin/VBox/TopBar/SettingsButton
@onready var energy_button: Button = $Margin/VBox/TopBar/EnergyButton
@onready var streak_chip: PanelContainer = $Margin/VBox/Hero/StreakChip
@onready var streak_label: Label = $Margin/VBox/Hero/StreakChip/HBox/StreakLabel
@onready var league_card: Button = $Margin/VBox/LeagueCard
@onready var medal: TextureRect = $Margin/VBox/LeagueCard/HBox/Medal
@onready var league_title: Label = $Margin/VBox/LeagueCard/HBox/Text/LeagueTitle
@onready var league_line: Label = $Margin/VBox/LeagueCard/HBox/Text/LeagueLine
@onready var last_game_label: Label = $Margin/VBox/LastGame
@onready var play_button: Button = $Margin/VBox/PlayButton
@onready var overview_button: Button = $Margin/VBox/Bottom/OverviewButton
@onready var player_label: Label = $Margin/VBox/Player

var _cards: Dictionary = {}      ## step -> Button
var _selected: int = 0
var _options: Dictionary = {}    ## step -> option dict
var _energy_amount: int = -1
var _selected_style: StyleBoxFlat


func _ready() -> void:
	_cards = {-1: $Margin/VBox/Options/Easier, 0: $Margin/VBox/Options/Same, 1: $Margin/VBox/Options/Harder}
	for step in _cards:
		_cards[step].pressed.connect(_select.bind(step))
	play_button.pressed.connect(func() -> void: play_requested.emit(_selected))
	overview_button.pressed.connect(overview_requested.emit)
	league_card.pressed.connect(league_requested.emit)
	energy_button.pressed.connect(energy_pressed.emit)
	settings_button.pressed.connect(settings_requested.emit)
	_selected_style = StyleBoxFlat.new()
	_selected_style.bg_color = Ui.ME_BG
	_selected_style.set_corner_radius_all(Ui.RADIUS_L)
	_selected_style.set_border_width_all(3)
	_selected_style.border_color = Ui.PRIMARY
	_selected_style.shadow_size = 8
	_selected_style.shadow_color = Ui.SHADOW
	_selected_style.shadow_offset = Vector2(0, 4)
	_selected_style.anti_aliasing = true


## view: {nickname, energy:{amount, unlimited}, league:{tier_id, tier_name, joined,
## rank, size, zone, score, promo_score, promo_text, ends_in_text}, streak:{days}, last:{level_no, size,
## difficulty, stars}|{}, options:[{step, level_no, size, difficulty, stars, enabled, reason}]}
func refresh(view: Dictionary) -> void:
	var energy: Dictionary = view.get("energy", {})
	set_energy(int(energy.get("amount", 0)), bool(energy.get("unlimited", false)))
	player_label.text = str(view.get("nickname", ""))
	_refresh_league(view.get("league", {}))
	var streak: Dictionary = view.get("streak", {})
	var days := int(streak.get("days", 0))
	streak_chip.visible = days >= 2
	streak_label.text = "%d day streak" % days
	var last: Dictionary = view.get("last", {})
	if last.is_empty():
		last_game_label.text = "Pick how hard you want to start"
	else:
		last_game_label.text = "Last game: Level %d · %s · diff %d" % [int(last.get("level_no", 0)), Fmt.size_text(int(last.get("size", 0))), int(last.get("difficulty", 0))]
	_options.clear()
	for opt in view.get("options", []):
		_options[int(opt["step"])] = opt
	for step in _cards:
		var card: Button = _cards[step]
		var opt: Dictionary = _options.get(step, {})
		card.visible = not opt.is_empty()
		if opt.is_empty():
			continue
		card.disabled = not bool(opt.get("enabled", true))
		card.get_node("VBox/Name").text = STEP_NAMES[step] if not last.is_empty() else "Start easy"
		card.get_node("VBox/Size").text = Fmt.size_text(int(opt.get("size", 0)))
		card.get_node("VBox/Stars").set_stars(int(opt.get("stars", 0)), 4)
		var diff: Label = card.get_node("VBox/Diff")
		diff.text = "diff %d" % int(opt.get("difficulty", 0)) if not card.disabled else str(opt.get("reason", "cooling down"))
	var wanted := _selected
	if not _options.has(wanted) or not bool(_options[wanted].get("enabled", true)):
		wanted = 0
		for step in [0, -1, 1]:
			if _options.has(step) and bool(_options[step].get("enabled", true)):
				wanted = step
				break
	_select(wanted)


func _refresh_league(league: Dictionary) -> void:
	var tier_name := str(league.get("tier_name", "Bronze"))
	league_title.text = "%s league" % tier_name
	medal.modulate = Ui.tier_color(str(league.get("tier_id", "bronze")))
	if not bool(league.get("joined", false)):
		league_line.text = "Play a game to join this round"
		return
	if int(league.get("promo_score", 0)) > 0:
		# A tier that promotes by tier points: the progress replaces the zone.
		league_line.text = "#%d of %d · %s · ends in %s" % [
			int(league.get("rank", 0)), int(league.get("size", 0)), str(league.get("promo_text", "")), str(league.get("ends_in_text", ""))]
		return
	league_line.text = "#%d of %d · %s · %d pts · ends in %s" % [
		int(league.get("rank", 0)), int(league.get("size", 0)), Fmt.zone(str(league.get("zone", "safe"))),
		int(league.get("score", 0)), str(league.get("ends_in_text", ""))]


func _select(step: int) -> void:
	_selected = step
	for s in _cards:
		var card: Button = _cards[s]
		if s == step:
			card.add_theme_stylebox_override("normal", _selected_style)
			card.add_theme_stylebox_override("hover", _selected_style)
		else:
			card.remove_theme_stylebox_override("normal")
			card.remove_theme_stylebox_override("hover")
	var opt: Dictionary = _options.get(step, {})
	if opt.is_empty():
		play_button.text = "Play"
		play_button.disabled = true
	else:
		play_button.disabled = not bool(opt.get("enabled", true))
		play_button.text = "Play %s" % Fmt.size_text(int(opt.get("size", 0)))


func selected_step() -> int:
	return _selected


func set_energy(amount: int, unlimited: bool) -> void:
	var changed := _energy_amount != amount and _energy_amount >= 0
	_energy_amount = amount
	energy_button.text = "∞" if unlimited else str(amount)
	if changed and is_inside_tree():
		Motion.bump(energy_button, 1.12)


## Kept for older callers: a preformatted energy text.
func set_energy_text(text: String) -> void:
	energy_button.text = text


## Plays the "-1" drain when a game starts.
func drain_energy() -> void:
	if not is_inside_tree() or not Motion.effects_enabled():
		return
	Motion.bump(energy_button, 0.86)
	var float_label := Label.new()
	float_label.text = "-1"
	float_label.theme_type_variation = &"LabelBodyBold"
	float_label.add_theme_color_override("font_color", Ui.ERROR)
	float_label.top_level = true
	add_child(float_label)
	float_label.global_position = energy_button.global_position + Vector2(energy_button.size.x * 0.5 - 12, energy_button.size.y)
	var t := create_tween().set_parallel(true)
	t.tween_property(float_label, "global_position:y", float_label.global_position.y + 30.0, 0.6)
	t.tween_property(float_label, "modulate:a", 0.0, 0.6)
	t.chain().tween_callback(float_label.queue_free)
