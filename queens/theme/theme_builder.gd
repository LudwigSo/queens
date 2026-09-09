extends SceneTree
## Builds the project theme from theme/tokens.gd (class Ui) and the assets.
##
## Run from the repo root:
##   godot --headless --path queens --script theme/theme_builder.gd
##
## The first run writes the button textures (assets/ui/*.svg); those need an
## import pass (`godot --headless --path queens --import`) before the theme can
## reference them, so run the builder again afterwards. Output:
##   theme/fonts/*.tres   FontVariation resources
##   theme/theme.tres     the Theme registered as gui/theme/custom
## Never edit theme.tres by hand: change tokens.gd or this script and rebuild.

const UI_DIR := "res://assets/ui/"
const FONT_DIR := "res://theme/fonts/"
const THEME_PATH := "res://theme/theme.tres"
const FREDOKA := "res://assets/fonts/Fredoka[wdth,wght].ttf"
const NUNITO := "res://assets/fonts/Nunito[wght].ttf"

## Button texture geometry (viewport pixels; SVGs import at scale 1).
const BTN_W := 120
const BTN_H := 120
const BTN_BODY_H := 104
const BTN_RADIUS := 24
const BTN_LIP := 8
const BTN_MARGIN := 30
const BTN_MARGIN_BOTTOM := 46

var _fonts: Dictionary = {}
var _missing_textures := false


func _initialize() -> void:
	_write_button_svgs()
	_write_misc_svgs()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FONT_DIR))
	_build_fonts()
	var theme := Theme.new()
	_build_defaults(theme)
	_build_labels(theme)
	_build_buttons(theme)
	_build_panels(theme)
	_build_inputs(theme)
	var err := ResourceSaver.save(theme, THEME_PATH)
	if err != OK:
		push_error("theme save failed: %s" % error_string(err))
	elif _missing_textures:
		print("theme.tres written with flat fallbacks; run --import and build again for the textured buttons")
	else:
		print("theme.tres written")
	quit(0 if err == OK else 1)


# --- fonts --------------------------------------------------------------------

func _font(name: String, base_path: String, axes: Dictionary, features: Dictionary = {}) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = load(base_path)
	var opentype := {}
	for tag in axes:
		opentype[TextServerManager.get_primary_interface().name_to_tag(tag)] = axes[tag]
	fv.variation_opentype = opentype
	if not features.is_empty():
		var feats := {}
		for tag in features:
			feats[TextServerManager.get_primary_interface().name_to_tag(tag)] = features[tag]
		fv.opentype_features = feats
	var path := FONT_DIR + name + ".tres"
	var err := ResourceSaver.save(fv, path)
	if err != OK:
		push_error("font save failed %s: %s" % [path, error_string(err)])
	_fonts[name] = load(path)
	return _fonts[name]


func _build_fonts() -> void:
	_font("display", FREDOKA, {"wght": 600, "wdth": 100})
	_font("display_bold", FREDOKA, {"wght": 700, "wdth": 100})
	_font("body", NUNITO, {"wght": 600})
	_font("body_bold", NUNITO, {"wght": 800})
	_font("digits", NUNITO, {"wght": 800}, {"tnum": 1})


# --- helpers ------------------------------------------------------------------

func _hex(c: Color) -> String:
	return "#" + c.to_html(false)


func _flat(bg: Color, radius: int, shadow: int = 0, shadow_color: Color = Ui.SHADOW, border: int = 0, border_color: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 12 if radius < 40 else 20
	sb.anti_aliasing = true
	if shadow > 0:
		sb.shadow_size = shadow
		sb.shadow_color = shadow_color
		sb.shadow_offset = Vector2(0, shadow * 0.5)
	if border > 0:
		sb.set_border_width_all(border)
		sb.border_color = border_color
	return sb


func _margins(sb: StyleBox, l: int, t: int, r: int, b: int) -> StyleBox:
	sb.content_margin_left = l
	sb.content_margin_top = t
	sb.content_margin_right = r
	sb.content_margin_bottom = b
	return sb


func _texture_box(file: String) -> StyleBox:
	var path := UI_DIR + file
	if not ResourceLoader.exists(path, "Texture2D"):
		_missing_textures = true
		return null
	var sb := StyleBoxTexture.new()
	sb.texture = load(path)
	sb.texture_margin_left = BTN_MARGIN
	sb.texture_margin_right = BTN_MARGIN
	sb.texture_margin_top = BTN_MARGIN
	sb.texture_margin_bottom = BTN_MARGIN_BOTTOM
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	_margins(sb, 28, 8, 28, 8 + BTN_H - BTN_BODY_H)
	return sb


# --- button textures ------------------------------------------------------------

## A chunky glossy button: flat shadow, darker "lip", gradient body, highlight.
func _button_svg(top: Color, bottom: Color, lip: Color, pressed: bool, alpha: float = 1.0) -> String:
	var shift := 6 if pressed else 0
	var hl_alpha := 0.18 if pressed else 0.30
	return """<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient></defs>
<g opacity="%.2f">
<rect x="0" y="14" width="%d" height="%d" rx="%d" fill="#1f1b3a" fill-opacity="0.16"/>
<rect x="0" y="%d" width="%d" height="%d" rx="%d" fill="%s"/>
<rect x="0" y="%d" width="%d" height="%d" rx="%d" fill="url(#g)"/>
<rect x="8" y="%d" width="%d" height="34" rx="18" fill="#ffffff" fill-opacity="%.2f"/>
</g></svg>
""" % [BTN_W, BTN_H, BTN_W, BTN_H, _hex(top), _hex(bottom), alpha,
		BTN_W, BTN_BODY_H, BTN_RADIUS,
		BTN_LIP, BTN_W, BTN_BODY_H, BTN_RADIUS, _hex(lip),
		shift, BTN_W, BTN_BODY_H, BTN_RADIUS,
		shift + 6, BTN_W - 16, hl_alpha]


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("cannot write %s" % path)
		return
	f.store_string(text)
	f.close()


func _write_button_svgs() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(UI_DIR))
	var variants := {
		"primary": [Ui.PRIMARY_LIGHT, Ui.PRIMARY, Ui.PRIMARY_DARK],
		"secondary": [Ui.SURFACE_0, Ui.SURFACE_1, Ui.OUTLINE],
		"danger": [Color("ff7a7e"), Ui.ERROR, Color("b8353a")],
		"gold": [Ui.SECONDARY_LIGHT, Ui.SECONDARY, Ui.SECONDARY_DARK],
		"success": [Color("5fd9b0"), Ui.SUCCESS, Color("13906a")],
	}
	for name in variants:
		var v: Array = variants[name]
		_write(UI_DIR + "btn_%s_normal.svg" % name, _button_svg(v[0], v[1], v[2], false))
		_write(UI_DIR + "btn_%s_pressed.svg" % name, _button_svg(v[0], v[1], v[2], true))
	_write(UI_DIR + "btn_disabled.svg", _button_svg(Color("e7e2f7"), Color("d9d3ee"), Color("c9c2e3"), false, 0.7))


func _write_misc_svgs() -> void:
	# Toggle switch art for CheckButton (settings).
	_write(UI_DIR + "toggle_on.svg", """<svg xmlns="http://www.w3.org/2000/svg" width="72" height="40" viewBox="0 0 72 40">
<rect x="0" y="0" width="72" height="40" rx="20" fill="%s"/><circle cx="52" cy="20" r="15" fill="#fff"/></svg>
""" % _hex(Ui.PRIMARY))
	_write(UI_DIR + "toggle_off.svg", """<svg xmlns="http://www.w3.org/2000/svg" width="72" height="40" viewBox="0 0 72 40">
<rect x="0" y="0" width="72" height="40" rx="20" fill="%s"/><circle cx="20" cy="20" r="15" fill="#fff"/></svg>
""" % _hex(Ui.OUTLINE))
	# A soft radial glow used behind hero content.
	_write(UI_DIR + "glow.svg", """<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
<defs><radialGradient id="r"><stop offset="0" stop-color="%s" stop-opacity="0.55"/><stop offset="1" stop-color="%s" stop-opacity="0"/></radialGradient></defs>
<rect width="256" height="256" fill="url(#r)"/></svg>
""" % [_hex(Ui.PRIMARY_LIGHT), _hex(Ui.PRIMARY_LIGHT)])


# --- theme sections -------------------------------------------------------------

func _build_defaults(theme: Theme) -> void:
	theme.default_font = _fonts["body"]
	theme.default_font_size = Ui.FONT_BODY
	theme.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	theme.set_stylebox("panel", "PopupPanel", _margins(_flat(Ui.SURFACE_0, Ui.RADIUS_L, 24, Ui.SHADOW_STRONG), 24, 24, 24, 24))
	theme.add_type("ScreenMargin")
	theme.set_type_variation("ScreenMargin", "MarginContainer")
	theme.set_constant("margin_left", "ScreenMargin", Ui.SCREEN_MARGIN)
	theme.set_constant("margin_right", "ScreenMargin", Ui.SCREEN_MARGIN)
	theme.set_constant("margin_top", "ScreenMargin", Ui.SCREEN_MARGIN_TOP)
	theme.set_constant("margin_bottom", "ScreenMargin", Ui.SCREEN_MARGIN)
	theme.set_constant("separation", "VBoxContainer", Ui.SPACE_M)
	theme.set_constant("separation", "HBoxContainer", Ui.SPACE_M)
	theme.set_constant("h_separation", "GridContainer", Ui.SPACE_M)
	theme.set_constant("v_separation", "GridContainer", Ui.SPACE_M)
	var grabber := _flat(Color(Ui.INK, 0.18), 6)
	theme.set_stylebox("grabber", "VScrollBar", grabber)
	theme.set_stylebox("grabber_highlight", "VScrollBar", _flat(Color(Ui.INK, 0.3), 6))
	theme.set_stylebox("grabber_pressed", "VScrollBar", _flat(Color(Ui.INK, 0.3), 6))
	theme.set_stylebox("scroll", "VScrollBar", _margins(StyleBoxEmpty.new(), 0, 0, 0, 0))
	theme.set_stylebox("scroll_focus", "VScrollBar", StyleBoxEmpty.new())


func _label(theme: Theme, name: String, font: String, size: int, color: Color) -> void:
	theme.add_type(name)
	theme.set_type_variation(name, "Label")
	theme.set_font("font", name, _fonts[font])
	theme.set_font_size("font_size", name, size)
	theme.set_color("font_color", name, color)


func _build_labels(theme: Theme) -> void:
	theme.set_color("font_color", "Label", Ui.INK)
	theme.set_font_size("font_size", "Label", Ui.FONT_BODY)
	theme.set_constant("line_spacing", "Label", 4)
	_label(theme, "LabelScore", "display_bold", Ui.FONT_SCORE, Ui.INK)
	_label(theme, "LabelDisplay", "display_bold", Ui.FONT_DISPLAY, Ui.INK)
	_label(theme, "LabelTitle", "display_bold", Ui.FONT_TITLE, Ui.INK)
	_label(theme, "LabelHeading", "display", Ui.FONT_HEADING, Ui.INK)
	_label(theme, "LabelBody", "body", Ui.FONT_BODY, Ui.INK)
	_label(theme, "LabelBodyBold", "body_bold", Ui.FONT_BODY, Ui.INK)
	_label(theme, "LabelMuted", "body", Ui.FONT_BODY, Ui.MUTED)
	_label(theme, "LabelCaption", "body", Ui.FONT_CAPTION, Ui.MUTED)
	_label(theme, "LabelCaptionBold", "body_bold", Ui.FONT_CAPTION, Ui.MUTED)
	_label(theme, "LabelCaptionInk", "body_bold", Ui.FONT_CAPTION, Ui.INK)
	_label(theme, "LabelOnDark", "body_bold", Ui.FONT_BODY, Ui.ON_PRIMARY)
	_label(theme, "LabelCaptionOnDark", "body_bold", Ui.FONT_CAPTION, Color(1, 1, 1, 0.8))
	_label(theme, "LabelTitleOnDark", "display_bold", Ui.FONT_TITLE, Ui.ON_PRIMARY)
	_label(theme, "LabelDigits", "digits", Ui.FONT_HEADING, Ui.INK)
	_label(theme, "LabelGold", "display_bold", Ui.FONT_TITLE, Ui.SECONDARY_DARK)
	_label(theme, "LabelBadge", "display_bold", Ui.FONT_HEADING, Ui.SECONDARY_DARK)
	_label(theme, "LabelError", "body_bold", Ui.FONT_BODY, Ui.ERROR)
	_label(theme, "LabelSuccess", "body_bold", Ui.FONT_BODY, Ui.SUCCESS)


func _button_colors(theme: Theme, name: String, text: Color, text_pressed: Color) -> void:
	for state in ["font_color", "font_hover_color", "font_focus_color", "icon_normal_color", "icon_hover_color", "icon_focus_color"]:
		theme.set_color(state, name, text)
	for state in ["font_pressed_color", "font_hover_pressed_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		theme.set_color(state, name, text_pressed)
	theme.set_color("font_disabled_color", name, Ui.FAINT)
	theme.set_color("icon_disabled_color", name, Ui.FAINT)


func _button_textured(theme: Theme, name: String, variant: String, font: String, size: int, text: Color, text_pressed: Color, fallback_bg: Color, fallback_lip: Color) -> void:
	theme.add_type(name)
	if name != "Button":
		theme.set_type_variation(name, "Button")
	var normal := _texture_box("btn_%s_normal.svg" % variant)
	var pressed := _texture_box("btn_%s_pressed.svg" % variant)
	var disabled := _texture_box("btn_disabled.svg")
	if normal == null:
		var flat := _flat(fallback_bg, BTN_RADIUS, 0, Ui.SHADOW, 0)
		flat.border_width_bottom = BTN_LIP
		flat.border_color = fallback_lip
		normal = _margins(flat, 28, 8, 28, 16)
		pressed = normal
		disabled = _margins(_flat(Ui.SURFACE_2, BTN_RADIUS), 28, 8, 28, 16)
	theme.set_stylebox("normal", name, normal)
	theme.set_stylebox("hover", name, normal)
	theme.set_stylebox("pressed", name, pressed)
	theme.set_stylebox("hover_pressed", name, pressed)
	theme.set_stylebox("disabled", name, disabled)
	theme.set_stylebox("focus", name, StyleBoxEmpty.new())
	theme.set_font("font", name, _fonts[font])
	theme.set_font_size("font_size", name, size)
	_button_colors(theme, name, text, text_pressed)
	theme.set_constant("icon_max_width", name, Ui.ICON_M)
	theme.set_constant("h_separation", name, Ui.SPACE_S)


func _button_flat(theme: Theme, name: String, normal: StyleBox, pressed: StyleBox, disabled: StyleBox, font: String, size: int, text: Color, text_pressed: Color, icon_max: int) -> void:
	theme.add_type(name)
	theme.set_type_variation(name, "Button")
	theme.set_stylebox("normal", name, normal)
	theme.set_stylebox("hover", name, normal)
	theme.set_stylebox("pressed", name, pressed)
	theme.set_stylebox("hover_pressed", name, pressed)
	theme.set_stylebox("disabled", name, disabled)
	theme.set_stylebox("focus", name, StyleBoxEmpty.new())
	theme.set_font("font", name, _fonts[font])
	theme.set_font_size("font_size", name, size)
	_button_colors(theme, name, text, text_pressed)
	theme.set_constant("icon_max_width", name, icon_max)
	theme.set_constant("h_separation", name, Ui.SPACE_S)


func _build_buttons(theme: Theme) -> void:
	# Base Button = secondary look, so an unstyled button never shows the stock grey.
	_button_textured(theme, "Button", "secondary", "display_bold", Ui.FONT_BUTTON_M, Ui.PRIMARY, Ui.PRIMARY_DARK, Ui.SURFACE_0, Ui.OUTLINE)
	_button_textured(theme, "ButtonPrimary", "primary", "display_bold", Ui.FONT_BUTTON_L, Ui.ON_PRIMARY, Ui.ON_PRIMARY, Ui.PRIMARY, Ui.PRIMARY_DARK)
	_button_textured(theme, "ButtonSecondary", "secondary", "display_bold", Ui.FONT_BUTTON_M, Ui.PRIMARY, Ui.PRIMARY_DARK, Ui.SURFACE_0, Ui.OUTLINE)
	_button_textured(theme, "ButtonDanger", "danger", "display_bold", Ui.FONT_BUTTON_M, Ui.ON_PRIMARY, Ui.ON_PRIMARY, Ui.ERROR, Color("b8353a"))
	_button_textured(theme, "ButtonGold", "gold", "display_bold", Ui.FONT_BUTTON_L, Ui.INK, Ui.INK, Ui.SECONDARY, Ui.SECONDARY_DARK)
	_button_textured(theme, "ButtonSuccess", "success", "display_bold", Ui.FONT_BUTTON_M, Ui.ON_PRIMARY, Ui.ON_PRIMARY, Ui.SUCCESS, Color("13906a"))

	# Ghost: flat text button.
	var ghost_normal := _margins(StyleBoxEmpty.new(), 16, 8, 16, 8)
	var ghost_pressed := _margins(_flat(Color(Ui.PRIMARY, 0.10), Ui.RADIUS_M), 16, 8, 16, 8)
	_button_flat(theme, "ButtonGhost", ghost_normal, ghost_pressed, ghost_normal, "body_bold", Ui.FONT_BUTTON_M, Ui.PRIMARY, Ui.PRIMARY_DARK, Ui.ICON_S)
	_button_flat(theme, "ButtonGhostMuted", ghost_normal, ghost_pressed, ghost_normal, "body_bold", Ui.FONT_BUTTON_S, Ui.MUTED, Ui.INK, Ui.ICON_S)

	# Pill: toggle-able chip button (tabs, energy counter).
	var pill_normal := _margins(_flat(Ui.SURFACE_2, Ui.RADIUS_PILL), 20, 8, 20, 8)
	var pill_pressed := _margins(_flat(Ui.PRIMARY, Ui.RADIUS_PILL), 20, 8, 20, 8)
	var pill_disabled := _margins(_flat(Ui.SURFACE_1, Ui.RADIUS_PILL), 20, 8, 20, 8)
	_button_flat(theme, "ButtonPill", pill_normal, pill_pressed, pill_disabled, "body_bold", Ui.FONT_BUTTON_S, Ui.INK, Ui.ON_PRIMARY, Ui.ICON_S)
	var pill_white := _margins(_flat(Ui.SURFACE_0, Ui.RADIUS_PILL, 8, Ui.SHADOW), 20, 8, 20, 8)
	_button_flat(theme, "ButtonPillWhite", pill_white, pill_pressed, pill_disabled, "body_bold", Ui.FONT_BUTTON_S, Ui.INK, Ui.ON_PRIMARY, Ui.ICON_S)

	# Icon: round buttons.
	var icon_normal := _margins(_flat(Ui.SURFACE_0, Ui.RADIUS_PILL, 8, Ui.SHADOW), 0, 0, 0, 0)
	var icon_pressed := _margins(_flat(Ui.SURFACE_2, Ui.RADIUS_PILL, 4, Ui.SHADOW), 0, 0, 0, 0)
	var icon_disabled := _margins(_flat(Ui.SURFACE_1, Ui.RADIUS_PILL), 0, 0, 0, 0)
	_button_flat(theme, "ButtonIcon", icon_normal, icon_pressed, icon_disabled, "body_bold", Ui.FONT_BUTTON_S, Ui.INK, Ui.INK, Ui.ICON_M)
	var icon_primary := _margins(_flat(Ui.PRIMARY, Ui.RADIUS_PILL, 8, Ui.SHADOW), 0, 0, 0, 0)
	var icon_primary_pressed := _margins(_flat(Ui.PRIMARY_DARK, Ui.RADIUS_PILL, 4, Ui.SHADOW), 0, 0, 0, 0)
	_button_flat(theme, "ButtonIconPrimary", icon_primary, icon_primary_pressed, icon_disabled, "body_bold", Ui.FONT_BUTTON_S, Ui.ON_PRIMARY, Ui.ON_PRIMARY, Ui.ICON_M)
	var icon_ghost := _margins(StyleBoxEmpty.new(), 0, 0, 0, 0)
	_button_flat(theme, "ButtonIconGhost", icon_ghost, _margins(_flat(Color(Ui.INK, 0.08), Ui.RADIUS_PILL), 0, 0, 0, 0), icon_ghost, "body_bold", Ui.FONT_BUTTON_S, Ui.INK, Ui.INK, Ui.ICON_M)

	# Card button: a whole tappable card (level cards, difficulty cards).
	var card_normal := _margins(_flat(Ui.SURFACE_0, Ui.RADIUS_L, 8, Ui.SHADOW), 20, 16, 20, 16)
	var card_pressed := _margins(_flat(Ui.SURFACE_1, Ui.RADIUS_L, 4, Ui.SHADOW), 20, 16, 20, 16)
	var card_disabled := _margins(_flat(Ui.SURFACE_1, Ui.RADIUS_L), 20, 16, 20, 16)
	_button_flat(theme, "ButtonCard", card_normal, card_pressed, card_disabled, "display_bold", Ui.FONT_BUTTON_M, Ui.INK, Ui.INK, Ui.ICON_L)

	# CheckButton (settings toggles).
	if ResourceLoader.exists(UI_DIR + "toggle_on.svg", "Texture2D"):
		theme.set_icon("checked", "CheckButton", load(UI_DIR + "toggle_on.svg"))
		theme.set_icon("unchecked", "CheckButton", load(UI_DIR + "toggle_off.svg"))
		theme.set_icon("checked_disabled", "CheckButton", load(UI_DIR + "toggle_on.svg"))
		theme.set_icon("unchecked_disabled", "CheckButton", load(UI_DIR + "toggle_off.svg"))
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		theme.set_stylebox(state, "CheckButton", _margins(StyleBoxEmpty.new(), 0, 8, 0, 8))
	theme.set_font("font", "CheckButton", _fonts["body_bold"])
	theme.set_font_size("font_size", "CheckButton", Ui.FONT_BODY)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		theme.set_color(state, "CheckButton", Ui.INK)
	theme.set_constant("h_separation", "CheckButton", Ui.SPACE_M)


func _panel(theme: Theme, name: String, sb: StyleBox) -> void:
	theme.add_type(name)
	theme.set_type_variation(name, "PanelContainer")
	theme.set_stylebox("panel", name, sb)


func _build_panels(theme: Theme) -> void:
	theme.set_stylebox("panel", "PanelContainer", _margins(_flat(Ui.SURFACE_0, Ui.RADIUS_L, 8, Ui.SHADOW), 24, 20, 24, 20))
	_panel(theme, "Card", _margins(_flat(Ui.SURFACE_0, Ui.RADIUS_L, 8, Ui.SHADOW), 24, 20, 24, 20))
	_panel(theme, "CardFlat", _margins(_flat(Ui.SURFACE_1, Ui.RADIUS_L), 24, 20, 24, 20))
	_panel(theme, "CardElevated", _margins(_flat(Ui.SURFACE_0, Ui.RADIUS_L, 24, Ui.SHADOW_STRONG), 32, 32, 32, 32))
	_panel(theme, "CardPrimary", _margins(_flat(Ui.PRIMARY, Ui.RADIUS_L, 12, Color(Ui.PRIMARY_DARK, 0.35)), 24, 20, 24, 20))
	_panel(theme, "CardPlate", _margins(_flat(Ui.PLATE, Ui.RADIUS_L, 12, Ui.SHADOW_STRONG), 12, 12, 12, 12))
	_panel(theme, "Sheet", _margins(_flat(Ui.SURFACE_0, Ui.RADIUS_L, 24, Ui.SHADOW_STRONG), 32, 24, 32, 40))
	_panel(theme, "RowPanel", _margins(_flat(Ui.SURFACE_0, Ui.RADIUS_M), 16, 12, 16, 12))
	_panel(theme, "RowPromote", _margins(_flat(Ui.SUCCESS_BG, Ui.RADIUS_M), 16, 12, 16, 12))
	_panel(theme, "RowRelegate", _margins(_flat(Ui.ERROR_BG, Ui.RADIUS_M), 16, 12, 16, 12))
	_panel(theme, "RowMe", _margins(_flat(Ui.ME_BG, Ui.RADIUS_M, 0, Ui.SHADOW, 3, Ui.PRIMARY), 16, 12, 16, 12))
	_panel(theme, "Chip", _margins(_flat(Ui.SURFACE_2, Ui.RADIUS_PILL), 14, 6, 14, 6))
	_panel(theme, "ChipWhite", _margins(_flat(Ui.SURFACE_0, Ui.RADIUS_PILL, 6, Ui.SHADOW), 14, 6, 14, 6))
	_panel(theme, "ChipPrimary", _margins(_flat(Ui.PRIMARY, Ui.RADIUS_PILL), 14, 6, 14, 6))
	_panel(theme, "ChipGold", _margins(_flat(Ui.SECONDARY, Ui.RADIUS_PILL), 14, 6, 14, 6))
	_panel(theme, "ChipSuccess", _margins(_flat(Ui.SUCCESS_BG, Ui.RADIUS_PILL), 14, 6, 14, 6))
	_panel(theme, "ChipError", _margins(_flat(Ui.ERROR_BG, Ui.RADIUS_PILL), 14, 6, 14, 6))
	_panel(theme, "ChipWarning", _margins(_flat(Ui.WARNING_BG, Ui.RADIUS_PILL), 14, 6, 14, 6))
	_panel(theme, "Banner", _margins(_flat(Ui.ERROR_BG, Ui.RADIUS_M), 16, 12, 16, 12))
	_panel(theme, "Toast", _margins(_flat(Ui.INK, Ui.RADIUS_M, 12, Ui.SHADOW_STRONG), 20, 14, 20, 14))
	_panel(theme, "Skeleton", _margins(_flat(Ui.SURFACE_2, Ui.RADIUS_M), 0, 0, 0, 0))


func _build_inputs(theme: Theme) -> void:
	var normal := _margins(_flat(Ui.SURFACE_1, Ui.RADIUS_M, 0, Ui.SHADOW, 2, Color.TRANSPARENT), 18, 12, 18, 12)
	var focus := _margins(_flat(Ui.SURFACE_0, Ui.RADIUS_M, 0, Ui.SHADOW, 2, Ui.PRIMARY), 18, 12, 18, 12)
	theme.set_stylebox("normal", "LineEdit", normal)
	theme.set_stylebox("focus", "LineEdit", focus)
	theme.set_stylebox("read_only", "LineEdit", normal)
	theme.set_font("font", "LineEdit", _fonts["body_bold"])
	theme.set_font_size("font_size", "LineEdit", Ui.FONT_BODY)
	theme.set_color("font_color", "LineEdit", Ui.INK)
	theme.set_color("font_placeholder_color", "LineEdit", Ui.FAINT)
	theme.set_color("caret_color", "LineEdit", Ui.PRIMARY)
	theme.set_color("selection_color", "LineEdit", Color(Ui.PRIMARY, 0.25))
	theme.set_constant("minimum_character_width", "LineEdit", 4)

	theme.set_stylebox("background", "ProgressBar", _flat(Ui.SURFACE_2, Ui.RADIUS_PILL))
	theme.set_stylebox("fill", "ProgressBar", _flat(Ui.PRIMARY, Ui.RADIUS_PILL))
	theme.set_font_size("font_size", "ProgressBar", Ui.FONT_CAPTION)
	theme.set_color("font_color", "ProgressBar", Ui.INK)
