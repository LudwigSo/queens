extends Control
## Energy panel: current amount, watch-an-ad refill, the unlimited purchase
## and restore. Opened from the Home energy button or when a game start is
## blocked by empty energy (then with a hint).

signal watch_ad_pressed
signal buy_pressed
signal restore_pressed
signal closed

@onready var energy_label: Label = $Panel/Margin/VBox/EnergyLabel
@onready var hint_label: Label = $Panel/Margin/VBox/HintLabel
@onready var watch_ad_button: Button = $Panel/Margin/VBox/WatchAdButton
@onready var buy_button: Button = $Panel/Margin/VBox/BuyButton
@onready var restore_button: Button = $Panel/Margin/VBox/RestoreButton
@onready var status_label: Label = $Panel/Margin/VBox/StatusLabel
@onready var close_button: Button = $Panel/Margin/VBox/CloseButton
@onready var dim: ColorRect = $Dim

var blocked: bool = false


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


## state: {energy_text, unlimited, can_start, ad_ready, ad_reward, price_text, purchases_available}
func set_state(state: Dictionary) -> void:
	var unlimited: bool = state.get("unlimited", false)
	energy_label.text = state.get("energy_text", "")
	hint_label.visible = blocked and not state.get("can_start", true)
	watch_ad_button.visible = not unlimited
	watch_ad_button.disabled = not state.get("ad_ready", false)
	watch_ad_button.text = "Watch an ad: +%d energy" % int(state.get("ad_reward", 0))
	buy_button.visible = not unlimited
	buy_button.disabled = not state.get("purchases_available", false)
	buy_button.text = "Unlimited energy · %s" % state.get("price_text", "")
	restore_button.visible = not unlimited and state.get("purchases_available", false)


func set_status(text: String) -> void:
	status_label.text = text if text != "" else " "


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()
