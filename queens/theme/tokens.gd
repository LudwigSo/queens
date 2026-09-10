class_name Ui
extends RefCounted
## Design tokens: the single source of truth for colours, sizes and spacing.
## The generated Theme (theme/theme.tres, built by theme/theme_builder.gd)
## and any runtime drawing code (board, list rows) read these constants.

# --- colours ------------------------------------------------------------------
# Forest green primary; the neutrals below carry the same hue at low
# saturation. SUCCESS is a mint-teal so "correct" stays distinct from it.

const PRIMARY := Color("1f7f52")
const PRIMARY_LIGHT := Color("5fbf8a")
const PRIMARY_DARK := Color("145a3a")
const SECONDARY := Color("ffb627")
const SECONDARY_LIGHT := Color("ffd666")
const SECONDARY_DARK := Color("d98e00")

const SUCCESS := Color("14b1a4")
const SUCCESS_BG := Color("d8f4f1")
const WARNING := Color("f5a524")
const WARNING_BG := Color("fff0d6")
const ERROR := Color("e5484d")
const ERROR_BG := Color("fde2e4")

const BG := Color("f4fbf8")
const SURFACE_0 := Color("ffffff")
const SURFACE_1 := Color("eefaf4")
const SURFACE_2 := Color("e2f7ed")
const OUTLINE := Color("d3eee1")

const INK := Color("1b3a2b")
const MUTED := Color("5a7a6b")
const FAINT := Color("96b4a6")
const ON_PRIMARY := Color("ffffff")

const PLATE := Color("2a2c3e")
const SCRIM := Color(0.106, 0.227, 0.169, 0.55)
const SHADOW := Color(0.106, 0.227, 0.169, 0.10)
const SHADOW_STRONG := Color(0.106, 0.227, 0.169, 0.22)

const ME_BG := Color("eafff5")
const HINT_GLOW := Color("ffb703")

## League tier colours by tier id.
const TIER_COLORS := {
	"bronze": Color("c77b3a"),
	"silver": Color("a9b0bf"),
	"gold": Color("ffb627"),
	"platinum": Color("7fd4e8"),
	"diamond": Color("7ca8ff"),
	"challenger": Color("b07cff"),
}

## Board region palette: flat pastels (lifted 10 % toward white) so an ink
## crown and the marks keep high contrast; neighbours differ in luminance.
const REGIONS: Array[Color] = [
	Color("ff968d"), Color("89caff"), Color("ffe875"), Color("c9a5ff"), Color("8ce6ac"),
	Color("ffbf7e"), Color("7de3e0"), Color("ffacd6"), Color("d0dc79"), Color("bfc3d5"),
]

# --- type scale (px at the 720-wide viewport) ---------------------------------

const FONT_SCORE := 88
const FONT_DISPLAY := 64
const FONT_TITLE := 44
const FONT_HEADING := 32
const FONT_BODY := 26
const FONT_CAPTION := 20
const FONT_BUTTON_L := 32
const FONT_BUTTON_M := 26
const FONT_BUTTON_S := 22

# --- sizes and spacing ---------------------------------------------------------

const RADIUS_S := 12
const RADIUS_M := 16
const RADIUS_L := 24
const RADIUS_PILL := 999

const SPACE_XS := 8
const SPACE_S := 12
const SPACE_M := 16
const SPACE_L := 24
const SPACE_XL := 32
const SPACE_XXL := 48

const BUTTON_H_L := 96
const BUTTON_H_M := 72
const BUTTON_H_S := 56
const ICON_BUTTON := 72
const ICON_S := 28
const ICON_M := 36
const ICON_L := 48
const ICON_XL := 64

const SCREEN_MARGIN := 32
const SCREEN_MARGIN_TOP := 48


static func zone_color(zone: String) -> Color:
	match zone:
		"promote":
			return SUCCESS
		"relegate":
			return ERROR
	return MUTED


static func zone_bg(zone: String) -> Color:
	match zone:
		"promote":
			return SUCCESS_BG
		"relegate":
			return ERROR_BG
	return SURFACE_0


static func tier_color(tier_id: String) -> Color:
	return TIER_COLORS.get(tier_id, PRIMARY)


static func region_color(index: int) -> Color:
	return REGIONS[index % REGIONS.size()]
