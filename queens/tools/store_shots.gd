extends Node
## Composes Play Store screenshots (1080x1920) from the screenshot suite:
## a violet band with the wordmark and a short benefit line on top, the
## captured screen below in a rounded frame.
##
## Run (needs a window, not headless), after tests/screenshot.tscn:
##   godot --path queens res://tools/store_shots.tscn -- <screenshot_dir> <out_dir>

const WORDMARK := "res://assets/brand/wordmark.png"
const GLOW := "res://assets/ui/glow.svg"

const SHOTS := [
	["04b_win_overlay.png", "Solve. Score. Climb."],
	["02_game_conflict.png", "One queen per row, column and colour"],
	["01_home_fresh.png", "Pick your difficulty every game"],
	["11_league_standings.png", "Weekly leagues with friends"],
	["10_level_select_locked.png", "100 hand-rated levels"],
	["03c_hint.png", "Stuck? Hints explain the logic"],
]

var _in: String = ""
var _out: String = ""


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: -- <screenshot_dir> <out_dir>")
		get_tree().quit(1)
		return
	_in = args[0].trim_suffix("/").trim_suffix("\\") + "/"
	_out = args[1].trim_suffix("/").trim_suffix("\\") + "/"
	DirAccess.make_dir_recursive_absolute(_out)
	var i := 1
	for shot in SHOTS:
		await _compose(i, str(shot[0]), str(shot[1]))
		i += 1
	get_tree().quit()


func _compose(index: int, file: String, caption: String) -> void:
	var img := Image.new()
	if img.load(_in + file) != OK:
		print("missing %s" % file)
		return
	var vp := SubViewport.new()
	vp.size = Vector2i(1080, 1920)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var root := Control.new()
	root.size = Vector2(1080, 1920)
	vp.add_child(root)
	var bg := ColorRect.new()
	bg.size = root.size
	bg.color = Ui.PRIMARY
	root.add_child(bg)
	var glow := TextureRect.new()
	glow.texture = load(GLOW)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.position = Vector2(540 - 700, -420)
	glow.size = Vector2(1400, 1400)
	glow.modulate = Color(1, 1, 1, 0.8)
	root.add_child(glow)
	var mark := TextureRect.new()
	mark.texture = load(WORDMARK)
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mark.position = Vector2(240, 90)
	mark.size = Vector2(600, 180)
	mark.modulate = Color.WHITE
	root.add_child(mark)
	var label := Label.new()
	label.text = caption
	label.theme_type_variation = &"LabelTitleOnDark"
	label.add_theme_font_size_override("font_size", 56)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.position = Vector2(80, 280)
	label.size = Vector2(920, 160)
	root.add_child(label)
	# The screen in a rounded frame with a shadow.
	var frame := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Ui.INK
	sb.set_corner_radius_all(48)
	sb.shadow_size = 40
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_offset = Vector2(0, 20)
	sb.anti_aliasing = true
	frame.add_theme_stylebox_override("panel", sb)
	var shot_w := 840.0
	var shot_h := shot_w * img.get_height() / img.get_width()
	frame.position = Vector2((1080 - shot_w) * 0.5 - 14, 470 - 14)
	frame.size = Vector2(shot_w + 28, shot_h + 28)
	root.add_child(frame)
	var tex := TextureRect.new()
	tex.texture = ImageTexture.create_from_image(img)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.position = Vector2((1080 - shot_w) * 0.5, 470)
	tex.size = Vector2(shot_w, shot_h)
	root.add_child(tex)
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var out := vp.get_texture().get_image()
	var name := "store_%02d.png" % index
	print("%s: %s" % [name, error_string(out.save_png(_out + name))])
	vp.queue_free()
