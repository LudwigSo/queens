extends Control
## Energy sheet: current amount, watch-an-ad refill, the unlimited purchase
## and restore. Slides up from the bottom; opened from the Home energy pill
## or when a game start is blocked by empty energy (then with a banner).

signal watch_ad_pressed
signal buy_pressed
signal restore_pressed
signal closed

@onready var dim: ColorRect = $Dim
@onready var panel: PanelContainer = $Panel
@onready var energy_label: Label = $Panel/VBox/Hero/EnergyLabel
@onready var explain: Label = $Panel/VBox/Hero/Explain
@onready var hint_banner: PanelContainer = $Panel/VBox/HintBanner
@onready var hint_label: Label = $Panel/VBox/HintBanner/HintLabel
@onready var watch_ad_button: Button = $Panel/VBox/WatchAdButton
@onready var buy_button: Button = $Panel/VBox/BuyButton
@onready var restore_button: Button = $Panel/VBox/RestoreButton
@onready var status_label: Label = $Panel/VBox/StatusLabel
@onready var close_button: Button = $Panel/VBox/TopRow/CloseButton

var blocked: bool = false
var _last_amount: int = -1


func _ready() -> void:
	watch_ad_button.pressed.connect(watch_ad_pressed.emit)
	buy_button.pressed.connect(buy_pressed.emit)
	restore_button.pressed.connect(restore_pressed.emit)
	close_button.pressed.connect(close)
	dim.gui_input.connect(_on_dim_input)


## `was_blocked`: opened because a game start was refused.
func open(was_blocked: bool) -> void:
	blocked = was_blocked
	status_label.text = " "
	visible = true


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


## state: {energy_text, amount, unlimited, can_start, ad_ready, ad_reward, price_text, purchases_available}
func set_state(state: Dictionary) -> void:
	var unlimited: bool = state.get("unlimited", false)
	energy_label.text = state.get("energy_text", "")
	var amount := int(state.get("amount", 0))
	if visible and _last_amount >= 0 and amount != _last_amount and is_inside_tree():
		Motion.bump(energy_label, 1.2, Motion.SLOW)
	_last_amount = amount
	explain.text = "Unlimited energy: play as much as you like." if unlimited else "Every game you start costs one energy."
	hint_banner.visible = blocked and not state.get("can_start", true)
	watch_ad_button.visible = not unlimited
	watch_ad_button.disabled = not state.get("ad_ready", false)
	watch_ad_button.text = "Watch an ad · +%d" % int(state.get("ad_reward", 0)) if state.get("ad_ready", false) else "No ad right now"
	buy_button.visible = not unlimited
	buy_button.disabled = not state.get("purchases_available", false)
	buy_button.text = "Unlimited · %s" % state.get("price_text", "")
	restore_button.visible = not unlimited and state.get("purchases_available", false)


func set_status(text: String) -> void:
	status_label.text = text if text != "" else " "


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()
