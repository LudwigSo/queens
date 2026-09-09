extends Control
## Once-per-round modal: how the last league round ended.

signal closed(round_index: int)

const COLOR_UP := Color("c58f00")
const COLOR_STAY := Color("1e1e2a")
const COLOR_DOWN := Color("d62839")

@onready var headline: Label = $Panel/Margin/VBox/Headline
@onready var body: Label = $Panel/Margin/VBox/Body
@onready var ok_button: Button = $Panel/Margin/VBox/OkButton

var round_index: int = -1


func _ready() -> void:
	ok_button.pressed.connect(close)


## summary: RoundSummary; tier names resolved by the caller.
func open(summary: Dictionary, tier_before_name: String, tier_after_name: String) -> void:
	round_index = int(summary.get("round_index", -1))
	var outcome := str(summary.get("outcome", "stayed"))
	var color := COLOR_STAY
	match outcome:
		"promoted":
			headline.text = "Promoted to %s!" % tier_after_name
			color = COLOR_UP
		"relegated":
			headline.text = "Relegated to %s" % tier_after_name
			color = COLOR_DOWN
		"inactive_relegated":
			headline.text = "No games played: down to %s" % tier_after_name
			color = COLOR_DOWN
		"inactive_frozen":
			headline.text = "No games played, still %s" % tier_before_name
		_:
			headline.text = "You stay in %s" % tier_before_name
	headline.add_theme_color_override("font_color", color)
	var lines: Array = []
	if int(summary.get("group_size", 0)) > 0:
		lines.append("#%d of %d · %d points" % [int(summary.get("rank", 0)), int(summary.get("group_size", 0)), int(summary.get("round_score", 0))])
	var best: Dictionary = summary.get("best_game", {})
	if not best.is_empty():
		lines.append("Best game: %d points" % int(best.get("score", 0)))
	if lines.is_empty():
		lines.append("Play this round to climb.")
	body.text = "\n".join(lines)
	visible = true


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit(round_index)
