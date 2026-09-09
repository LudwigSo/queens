class_name Toast
extends Control
## Bottom snackbar for short status messages. Queues up to three.

const MAX_QUEUE := 3

@onready var panel: PanelContainer = $Panel
@onready var label: Label = $Panel/HBox/Label
@onready var icon: TextureRect = $Panel/HBox/Icon

var _queue: Array = []
var _showing: bool = false
var _rest_y: float = 0.0


func _ready() -> void:
	panel.visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE


## kind: "info" | "success" | "error"
func show_message(text: String, kind: String = "info", seconds: float = 2.2) -> void:
	if text.strip_edges() == "":
		return
	if _queue.size() >= MAX_QUEUE:
		_queue.pop_front()
	_queue.append({"text": text, "kind": kind, "seconds": seconds})
	if not _showing:
		_next()


func _next() -> void:
	if _queue.is_empty():
		_showing = false
		return
	_showing = true
	var item: Dictionary = _queue.pop_front()
	label.text = item["text"]
	var kind := str(item["kind"])
	icon.visible = kind != "info"
	icon.modulate = Ui.SUCCESS if kind == "success" else Ui.ERROR
	var tex := "res://assets/icons/line/check.svg" if kind == "success" else "res://assets/icons/line/warning.svg"
	if ResourceLoader.exists(tex, "Texture2D"):
		icon.texture = load(tex)
	panel.visible = true
	Sfx.play(&"toast", 0.0, -6.0)
	panel.reset_size()
	await get_tree().process_frame
	_rest_y = size.y - panel.size.y - 120.0
	panel.position = Vector2((size.x - panel.size.x) * 0.5, _rest_y)
	var t := Motion.slide_in(panel, Vector2(0, 24))
	if Motion.effects_enabled():
		await t.finished
	await get_tree().create_timer(Motion.d(float(item["seconds"]))).timeout
	var out := Motion.fade(panel, 0.0, Motion.FAST)
	if Motion.effects_enabled():
		await out.finished
	panel.visible = false
	panel.modulate.a = 1.0
	_next()
