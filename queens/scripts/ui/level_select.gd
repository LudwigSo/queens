extends Control
## The level overview: one button per level, locked ones disabled.
## Only emits intents; the main script builds the rows and starts games.

signal level_chosen(level_id: String)
signal detail_requested(level_id: String)
signal back_requested

@onready var grid: GridContainer = $Margin/VBox/Scroll/Grid
@onready var back_button: Button = $Margin/VBox/TopBar/BackButton
@onready var spacer: Control = $Margin/VBox/TopBar/Spacer


func _ready() -> void:
	back_button.pressed.connect(back_requested.emit)


func set_back_visible(shown: bool) -> void:
	back_button.visible = shown
	spacer.visible = shown


## rows: [{id: String, text: String, locked: bool}] in display order.
func refresh(rows: Array) -> void:
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	for row in rows:
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", 4)
		var btn := Button.new()
		btn.text = row["text"]
		btn.disabled = row["locked"]
		btn.custom_minimum_size = Vector2(0, 170)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 28)
		btn.pressed.connect(level_chosen.emit.bind(row["id"]))
		cell.add_child(btn)
		var detail := Button.new()
		detail.text = "Leaderboard"
		detail.flat = true
		detail.custom_minimum_size = Vector2(0, 44)
		detail.add_theme_font_size_override("font_size", 22)
		detail.pressed.connect(detail_requested.emit.bind(row["id"]))
		cell.add_child(detail)
		grid.add_child(cell)
