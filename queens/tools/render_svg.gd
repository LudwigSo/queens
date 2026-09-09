extends SceneTree
## Headless SVG -> PNG renderer, used to preview hand-authored assets and to
## produce launcher icons, splash images and store graphics.
##
##   godot --headless --path queens --script tools/render_svg.gd -- <svg> <out.png> [scale]
##   godot --headless --path queens --script tools/render_svg.gd -- --sheet <dir> <out.png> [cell] [bg_hex]
##
## `--sheet` renders every .svg in <dir> onto one contact sheet.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: see header")
		quit(1)
		return
	if args[0] == "--sheet":
		_sheet(args[1], args[2], int(args[3]) if args.size() > 3 else 96, args[4] if args.size() > 4 else "2a2c3e")
	else:
		_single(args[0], args[1], float(args[2]) if args.size() > 2 else 1.0)
	quit(0)


func _load_svg(path: String, scale: float) -> Image:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("cannot read %s" % path)
		return null
	var img := Image.new()
	var err := img.load_svg_from_string(f.get_as_text(), scale)
	if err != OK:
		push_error("svg load failed %s: %s" % [path, error_string(err)])
		return null
	return img


func _single(svg: String, out: String, scale: float) -> void:
	var img := _load_svg(svg, scale)
	if img != null:
		print("%s -> %s (%dx%d): %s" % [svg, out, img.get_width(), img.get_height(), error_string(img.save_png(out))])


func _sheet(dir_path: String, out: String, cell: int, bg_hex: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("cannot open %s" % dir_path)
		return
	var files: Array[String] = []
	for f in dir.get_files():
		if f.ends_with(".svg"):
			files.append(f)
	files.sort()
	var cols := 8
	@warning_ignore("integer_division")
	var rows := (files.size() + cols - 1) / cols
	var pad := 12
	var sheet := Image.create(cols * (cell + pad) + pad, maxi(rows, 1) * (cell + pad) + pad, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(bg_hex))
	for i in files.size():
		var img := _load_svg(dir_path.path_join(files[i]), 1.0)
		if img == null:
			continue
		img.convert(Image.FORMAT_RGBA8)
		var scale := minf(float(cell) / img.get_width(), float(cell) / img.get_height())
		img.resize(int(img.get_width() * scale), int(img.get_height() * scale), Image.INTERPOLATE_LANCZOS)
		@warning_ignore("integer_division")
		var x := pad + (i % cols) * (cell + pad) + (cell - img.get_width()) / 2
		@warning_ignore("integer_division")
		var y := pad + (i / cols) * (cell + pad) + (cell - img.get_height()) / 2
		sheet.blend_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i(x, y))
	print("%d files -> %s: %s" % [files.size(), out, error_string(sheet.save_png(out))])
