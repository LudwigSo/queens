class_name SafeArea
extends RefCounted
## Keeps the screens out from under a status bar or a camera cutout.
##
## The game draws edge to edge (portrait, `canvas_items` stretch), so on a phone
## with a hole-punch camera the top of the viewport sits behind it. Godot reports
## the usable rectangle in *screen* pixels; this converts it into the canvas units
## the theme works in and adds it on top of `Ui.SCREEN_MARGIN_TOP` for every
## `ScreenMargin` container, which every screen and sheet uses.


## Extra top margin in canvas units, 0 when the platform reports no cutout.
static func top_inset(window: Window) -> int:
	if window == null or not OS.has_feature("mobile"):
		return 0
	var safe := DisplayServer.get_display_safe_area()
	var top := safe.position.y
	if top <= 0:
		return 0
	var window_px := float(window.size.y)
	if window_px <= 0.0:
		return 0
	# Canvas units per window pixel; identical to 1.0 when there is no stretch.
	var scale := window.get_visible_rect().size.y / window_px
	return int(round(float(top) * scale))


## Adds `top_inset` to every ScreenMargin below `root`. Safe to call again after
## a rotation: the override is replaced, never accumulated.
static func apply(root: Node) -> void:
	var extra := top_inset(root.get_window() if root.is_inside_tree() else null)
	for node in _screen_margins(root):
		node.add_theme_constant_override("margin_top", Ui.SCREEN_MARGIN_TOP + extra)


static func _screen_margins(node: Node) -> Array[MarginContainer]:
	var out: Array[MarginContainer] = []
	if node is MarginContainer and (node as MarginContainer).theme_type_variation == &"ScreenMargin":
		out.append(node)
	for child in node.get_children():
		out.append_array(_screen_margins(child))
	return out
