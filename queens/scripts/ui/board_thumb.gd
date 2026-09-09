class_name BoardThumb
extends Control
## A tiny read-only picture of a level's regions, for cards and headers.

var regions: Array = []:
	set(v):
		regions = v
		queue_redraw()
var show_plate: bool = true
var dim: bool = false

var _plate: StyleBoxFlat


func _ready() -> void:
	_plate = StyleBoxFlat.new()
	_plate.bg_color = Ui.PLATE
	_plate.set_corner_radius_all(10)
	_plate.anti_aliasing = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func _draw() -> void:
	if regions.is_empty():
		return
	var n := regions.size()
	var pad := 3.0 if show_plate else 0.0
	var side := minf(size.x, size.y)
	var cell := (side - 2.0 * pad) / n
	var origin := (size - Vector2(side, side)) * 0.5
	if show_plate:
		draw_style_box(_plate, Rect2(origin, Vector2(side, side)))
	var gap := maxf(1.0, cell * 0.08)
	for r in n:
		for c in n:
			var col := Ui.region_color(int(regions[r][c]))
			if dim:
				col = col.lerp(Ui.SURFACE_2, 0.55)
			var rect := Rect2(origin + Vector2(pad, pad) + Vector2(c, r) * cell, Vector2(cell, cell)).grow(-gap * 0.5)
			draw_rect(rect, col)
