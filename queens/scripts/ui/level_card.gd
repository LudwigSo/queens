class_name LevelCard
extends Button
## One tile in the level overview: number, size, difficulty stars, a tick once
## played, and a lock countdown while the level cools down.
##
## Tiles are recycled by VirtualGrid, so `setup` may run many times on one node
## and must reset everything it touches. Node references are looked up lazily:
## a recycled pool node can be bound before it is ready.
##
## A touch only counts as a tap if the finger stayed put. The overview scrolls
## under the finger, so a drag that starts on a tile also ends on it, and a
## plain Button would report that as a press.

signal chosen(level_id: String)

## How far (viewport px at the 720-wide layout) a touch may travel and still
## be a tap.
const TAP_SLOP := 24.0

var level_id: String = ""
var locked: bool = false
var data: Dictionary = {}

var _body: Control
var _number: Label
var _size_label: Label
var _stars: StarRow
var _lock_row: Control
var _lock_label: Label
var _played: TextureRect

var _press_at := Vector2.ZERO
var _dragged: bool = false


func _init() -> void:
	# Opt out of Motion.make_all_pressable: this tile gives its own feedback.
	set_meta("_pressable", true)
	pressed.connect(_on_pressed)


func _nodes() -> void:
	if _body != null:
		return
	_body = $Body
	_number = $Body/Number
	_size_label = $Body/SizeLabel
	_stars = $Body/Stars
	_lock_row = $Body/LockRow
	_lock_label = $Body/LockRow/LockLabel
	_played = $Played
	($Body/LockRow/LockIcon as CanvasItem).modulate = Ui.MUTED
	_played.modulate = Ui.SUCCESS


## card: {id, level_no, size, difficulty, stars, locked, lock_text, played, ...}
func setup(card: Dictionary) -> void:
	_nodes()
	data = card
	level_id = str(card.get("id", ""))
	locked = bool(card.get("locked", false))
	var number := str(int(card.get("level_no", 0)))
	_number.text = number
	if number.length() > 4:
		_number.add_theme_font_size_override("font_size", Ui.FONT_HEADING)
	else:
		_number.remove_theme_font_size_override("font_size")
	_size_label.text = Fmt.size_text(int(card.get("size", 0)))
	_stars.set_stars(int(card.get("stars", 0)), 4)
	_stars.visible = not locked
	_lock_row.visible = locked
	_lock_label.text = str(card.get("lock_text", ""))
	_played.visible = bool(card.get("played", false)) and not locked
	# Dim the content and the plate, not `modulate`: list fade-ins own that.
	_body.modulate.a = 0.6 if locked else 1.0
	self_modulate.a = 0.72 if locked else 1.0
	# A recycled node may still be mid-press or mid-shake from its last level.
	for key in ["_motion_press", "_motion_shake"]:
		if has_meta(key):
			var t = get_meta(key)
			if t is Tween and t.is_valid():
				t.kill()
			remove_meta(key)
	scale = Vector2.ONE
	_dragged = false


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press_at = event.global_position
			_dragged = false
			Motion.press_in(self)
		elif not _dragged:
			Motion.press_out(self)
	elif event is InputEventMouseMotion and not _dragged and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		if event.global_position.distance_to(_press_at) > TAP_SLOP:
			_dragged = true
			Motion.press_out(self)


func _on_pressed() -> void:
	if _dragged:
		_dragged = false
		return
	Sfx.play(&"button", 0.04, -4.0)
	if locked:
		Motion.shake(self)
		Sfx.haptic(20)
	chosen.emit(level_id)
