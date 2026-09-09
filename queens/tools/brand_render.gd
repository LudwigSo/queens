extends Node
## Renders the brand assets with the real theme and fonts:
##   assets/brand/icon_fg.png       432x432  adaptive icon foreground (art inside the 264 px safe circle)
##   assets/brand/icon_bg.png       432x432  adaptive icon background
##   assets/brand/icon_mono.png     432x432  monochrome icon layer
##   assets/brand/icon_192.png      192x192  legacy launcher icon (bg + fg flattened)
##   assets/brand/boot_splash.png   720x1280 boot splash (violet, crown, wordmark)
##   assets/brand/wordmark.png      720x220  wordmark on transparent
##   assets/brand/feature.png       1024x500 store feature graphic
##
## Run (needs a window, not headless):
##   godot --path queens res://tools/brand_render.tscn -- <out_dir>

const CROWN := "res://assets/board/crown_gold.svg"
const GLOW := "res://assets/ui/glow.svg"

var _out: String = ""


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[0] if not args.is_empty() else ProjectSettings.globalize_path("res://assets/brand")
	if not _out.ends_with("/") and not _out.ends_with("\\"):
		_out += "/"
	DirAccess.make_dir_recursive_absolute(_out)
	await _render("icon_fg.png", Vector2i(432, 432), _icon_fg, true)
	await _render("icon_bg.png", Vector2i(432, 432), _icon_bg, false)
	await _render("icon_mono.png", Vector2i(432, 432), _icon_mono, true)
	await _render("icon_192.png", Vector2i(192, 192), _icon_flat, false)
	await _render("boot_splash.png", Vector2i(720, 1280), _boot_splash, false)
	await _render("wordmark.png", Vector2i(720, 220), _wordmark_only, true)
	await _render("feature.png", Vector2i(1024, 500), _feature, false)
	get_tree().quit()


func _render(file: String, size: Vector2i, builder: Callable, transparent: bool) -> void:
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = transparent
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var root := Control.new()
	root.size = size
	vp.add_child(root)
	builder.call(root, Vector2(size))
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var err := img.save_png(_out + file)
	print("%s (%dx%d): %s" % [file, size.x, size.y, error_string(err)])
	vp.queue_free()


# --- pieces -------------------------------------------------------------------------

func _rect(parent: Control, rect: Rect2, color: Color) -> ColorRect:
	var cr := ColorRect.new()
	cr.position = rect.position
	cr.size = rect.size
	cr.color = color
	parent.add_child(cr)
	return cr


func _panel(parent: Control, rect: Rect2, color: Color, radius: int, shadow: int = 0) -> Panel:
	var p := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.anti_aliasing = true
	if shadow > 0:
		sb.shadow_size = shadow
		sb.shadow_color = Color(0, 0, 0, 0.25)
		sb.shadow_offset = Vector2(0, shadow * 0.4)
	p.add_theme_stylebox_override("panel", sb)
	p.position = rect.position
	p.size = rect.size
	parent.add_child(p)
	return p


func _texture(parent: Control, path: String, rect: Rect2, modulate: Color = Color.WHITE) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = load(path)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.position = rect.position
	tr.size = rect.size
	tr.modulate = modulate
	parent.add_child(tr)
	return tr


func _label(parent: Control, text: String, rect: Rect2, variation: StringName, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.position = rect.position
	l.size = rect.size
	parent.add_child(l)
	return l


## Wordmark: outlined display text with a soft drop, crown perched on the Q.
func _wordmark(parent: Control, center: Vector2, scale: float, on_dark: bool, with_crown: bool = true) -> void:
	var w := 640.0 * scale
	var h := 200.0 * scale
	var rect := Rect2(center - Vector2(w, h) * 0.5, Vector2(w, h))
	var fill := Color.WHITE if on_dark else Ui.PRIMARY
	var shadow_col := Ui.PRIMARY_DARK if on_dark else Color(Ui.PRIMARY_DARK, 0.35)
	var text_size := int(150 * scale)
	var shadow := _label(parent, "Queens", Rect2(rect.position + Vector2(0, 8 * scale), rect.size), &"LabelDisplay", text_size, shadow_col)
	shadow.add_theme_constant_override("outline_size", int(10 * scale))
	shadow.add_theme_color_override("font_outline_color", shadow_col)
	var main := _label(parent, "Queens", rect, &"LabelDisplay", text_size, fill)
	main.add_theme_constant_override("outline_size", int(10 * scale))
	main.add_theme_color_override("font_outline_color", Ui.INK if not on_dark else Ui.PRIMARY_DARK)
	if not with_crown:
		return
	# Crown perched on the top-left of the Q (tilted). The label centres its
	# text, so find where the text actually starts.
	var font: Font = main.get_theme_font("font")
	var text_w := font.get_string_size("Queens", HORIZONTAL_ALIGNMENT_LEFT, -1, text_size).x
	var text_h := font.get_height(text_size)
	var q_x := center.x - text_w * 0.5
	var top_y := center.y - text_h * 0.5
	var crown_size := 96.0 * scale
	var crown := _texture(parent, CROWN, Rect2(Vector2(q_x - crown_size * 0.35, top_y - crown_size * 0.55), Vector2(crown_size, crown_size)))
	crown.pivot_offset = Vector2(crown_size * 0.5, crown_size)
	crown.rotation = deg_to_rad(-16.0)


func _tiles(parent: Control, origin: Vector2, cell: float, gap: float, colors: Array, radius: int, with_crown: bool) -> void:
	for i in 9:
		@warning_ignore("integer_division")
		var r := i / 3
		var c := i % 3
		var pos := origin + Vector2(c, r) * (cell + gap)
		_panel(parent, Rect2(pos, Vector2(cell, cell)), colors[i], radius, int(cell * 0.06))
		# Gloss highlight.
		var hl := _panel(parent, Rect2(pos + Vector2(cell * 0.1, cell * 0.06), Vector2(cell * 0.8, cell * 0.28)), Color(1, 1, 1, 0.3), int(radius * 0.7))
		hl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if with_crown:
		var size := cell * 1.05
		_texture(parent, CROWN, Rect2(origin + Vector2(cell + gap, cell + gap) + Vector2(cell - size, cell - size) * 0.5, Vector2(size, size)))


func _icon_fg(root: Control, size: Vector2) -> void:
	# Everything inside the 264 px safe circle of a 432 px adaptive icon.
	var cell := 68.0
	var gap := 8.0
	var total := 3 * cell + 2 * gap
	var origin := (size - Vector2(total, total)) * 0.5
	var colors := [Ui.REGIONS[0], Ui.REGIONS[1], Ui.REGIONS[2], Ui.REGIONS[3], Ui.SURFACE_0, Ui.REGIONS[4], Ui.REGIONS[5], Ui.REGIONS[6], Ui.REGIONS[7]]
	_tiles(root, origin, cell, gap, colors, 14, true)


func _icon_bg(root: Control, size: Vector2) -> void:
	_rect(root, Rect2(Vector2.ZERO, size), Ui.PRIMARY_DARK)
	var glow := _texture(root, GLOW, Rect2(size * 0.5 - Vector2(360, 360), Vector2(720, 720)), Color(Ui.PRIMARY_LIGHT, 1.0))
	glow.modulate = Color(1, 1, 1, 0.9)


func _icon_mono(root: Control, size: Vector2) -> void:
	var cell := 68.0
	var gap := 8.0
	var total := 3 * cell + 2 * gap
	var origin := (size - Vector2(total, total)) * 0.5
	var colors: Array = []
	for i in 9:
		colors.append(Color.WHITE)
	_tiles(root, origin, cell, gap, colors, 14, false)
	var crown_size := cell * 1.05
	_texture(root, CROWN, Rect2(origin + Vector2(cell + gap, cell + gap) + Vector2(cell - crown_size, cell - crown_size) * 0.5, Vector2(crown_size, crown_size)), Ui.PRIMARY_DARK)


func _icon_flat(root: Control, size: Vector2) -> void:
	_rect(root, Rect2(Vector2.ZERO, size), Ui.PRIMARY_DARK)
	_texture(root, GLOW, Rect2(size * 0.5 - Vector2(160, 160), Vector2(320, 320)), Color(1, 1, 1, 0.9))
	var cell := 40.0
	var gap := 5.0
	var total := 3 * cell + 2 * gap
	var origin := (size - Vector2(total, total)) * 0.5
	var colors := [Ui.REGIONS[0], Ui.REGIONS[1], Ui.REGIONS[2], Ui.REGIONS[3], Ui.SURFACE_0, Ui.REGIONS[4], Ui.REGIONS[5], Ui.REGIONS[6], Ui.REGIONS[7]]
	_tiles(root, origin, cell, gap, colors, 9, true)


func _boot_splash(root: Control, size: Vector2) -> void:
	_rect(root, Rect2(Vector2.ZERO, size), Ui.PRIMARY)
	_texture(root, GLOW, Rect2(size * 0.5 - Vector2(520, 520), Vector2(1040, 1040)), Color(1, 1, 1, 0.8))
	_texture(root, CROWN, Rect2(size * 0.5 - Vector2(90, 250), Vector2(180, 180)))
	_wordmark(root, size * 0.5 + Vector2(0, 40), 0.8, true, false)
	_label(root, "a logic puzzle", Rect2(Vector2(0, size.y * 0.5 + 130), Vector2(size.x, 40)), &"LabelCaptionOnDark", 26, Color(1, 1, 1, 0.8))


func _wordmark_only(root: Control, size: Vector2) -> void:
	_wordmark(root, size * 0.5 + Vector2(0, 14), 0.9, false)


func _feature(root: Control, size: Vector2) -> void:
	_rect(root, Rect2(Vector2.ZERO, size), Ui.PRIMARY)
	_texture(root, GLOW, Rect2(Vector2(size.x * 0.32 - 420, size.y * 0.5 - 420), Vector2(840, 840)), Color(1, 1, 1, 0.8))
	_wordmark(root, Vector2(size.x * 0.33, size.y * 0.52), 0.95, true)
	var cell := 84.0
	var gap := 10.0
	var total := 3 * cell + 2 * gap
	var origin := Vector2(size.x * 0.78, size.y * 0.5) - Vector2(total, total) * 0.5
	var colors := [Ui.REGIONS[0], Ui.REGIONS[1], Ui.REGIONS[2], Ui.REGIONS[3], Ui.SURFACE_0, Ui.REGIONS[4], Ui.REGIONS[5], Ui.REGIONS[6], Ui.REGIONS[7]]
	var board := Control.new()
	board.position = origin
	board.rotation = deg_to_rad(-8.0)
	root.add_child(board)
	_tiles(board, Vector2.ZERO, cell, gap, colors, 18, true)
