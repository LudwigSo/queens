class_name Skeleton
extends Control
## Loading placeholder: a column of soft rounded bars that pulse. Sits in the
## same slot as the list it stands in for; the screen toggles the pair.

@export var rows: int = 6
@export var row_height: float = 72.0
@export var gap: float = 10.0
@export var radius: float = 16.0

var _alpha: float = 0.6
var _tween: Tween = null
var _style: StyleBoxFlat


func _ready() -> void:
	_style = StyleBoxFlat.new()
	_style.bg_color = Ui.SURFACE_2
	_style.set_corner_radius_all(int(radius))
	_style.anti_aliasing = true
	visibility_changed.connect(_on_visibility)
	_on_visibility()


func _on_visibility() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if not visible or not Motion.effects_enabled():
		_alpha = 0.6
		queue_redraw()
		return
	_tween = create_tween().set_loops()
	_tween.tween_method(func(v: float) -> void: _alpha = v; queue_redraw(), 0.45, 0.85, 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(func(v: float) -> void: _alpha = v; queue_redraw(), 0.85, 0.45, 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _get_minimum_size() -> Vector2:
	return Vector2(0, rows * row_height + (rows - 1) * gap)


func _draw() -> void:
	var y := 0.0
	for i in rows:
		var w := size.x * (1.0 if i % 3 != 2 else 0.82)
		draw_style_box(_style, Rect2(0, y, w, row_height))
		y += row_height + gap
	# Modulate through alpha of the whole control.
	modulate.a = _alpha
