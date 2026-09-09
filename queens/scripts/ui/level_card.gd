class_name LevelCard
extends Button
## One level in the overview: thumbnail, number, size, stars, best result,
## and a lock countdown while the level cools down.

signal chosen(level_id: String)

@onready var thumb: BoardThumb = $VBox/Thumb
@onready var title: Label = $VBox/Title
@onready var size_label: Label = $VBox/Meta/SizeLabel
@onready var stars: StarRow = $VBox/Meta/Stars
@onready var best: Label = $VBox/Best
@onready var lock_row: HBoxContainer = $VBox/LockRow
@onready var lock_label: Label = $VBox/LockRow/LockLabel

var level_id: String = ""
var locked: bool = false
var data: Dictionary = {}


func _ready() -> void:
	pressed.connect(_on_pressed)
	Motion.make_pressable(self)


## card: {id, level_no, size, difficulty, stars, regions, locked, lock_text, best_text, played}
func setup(card: Dictionary) -> void:
	data = card
	level_id = str(card.get("id", ""))
	locked = bool(card.get("locked", false))
	thumb.regions = card.get("regions", [])
	thumb.dim = locked
	title.text = "Level %d" % int(card.get("level_no", 0))
	size_label.text = "%s · diff %d" % [Fmt.size_text(int(card.get("size", 0))), int(card.get("difficulty", 0))]
	stars.set_stars(int(card.get("stars", 0)), 4)
	var best_text := str(card.get("best_text", ""))
	best.text = best_text if best_text != "" else "Not played yet"
	best.visible = not locked
	lock_row.visible = locked
	lock_label.text = str(card.get("lock_text", ""))
	modulate.a = 0.72 if locked else 1.0


func text_summary() -> String:
	return "%s %s %s" % [title.text, size_label.text, lock_label.text if locked else best.text]


func _on_pressed() -> void:
	if locked:
		Motion.shake(self)
		Sfx.haptic(20)
	chosen.emit(level_id)
