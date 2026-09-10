class_name Fmt
extends RefCounted
## Display formatting shared by every screen, so wording lives in one place.


static func time(seconds: float) -> String:
	var total := int(seconds)
	@warning_ignore("integer_division")
	return "%d:%02d" % [total / 60, total % 60]


## "6d 23h", "3h 12m", "45m", "0m" - see Cooldown.format_remaining.
static func remaining(seconds: int) -> String:
	return Cooldown.format_remaining(seconds)


static func level_title(level_no: int, size: int, difficulty: int) -> String:
	return Loc.f("COMMON_LEVEL_TITLE", [level_no, size, size, difficulty])


static func size_text(size: int) -> String:
	return "%d×%d" % [size, size]


static func mistakes(n: int) -> String:
	if n == 0:
		return Loc.t("MISTAKES_ZERO")
	return Loc.plural("MISTAKES", n)


## "×0.85" / "×0,85": a score multiplier on the win overlay. GDScript always
## formats with a dot, so the separator comes from the translation file.
static func factor(value: float) -> String:
	return Loc.f("WIN_FACTOR", [("%.2f" % value).replace(".", Loc.t("COMMON_DECIMAL_SEP"))])


static func points(n: int) -> String:
	return Loc.f("COMMON_PTS", [n])


## "1240 / 3000 pts to Silver": tier points toward the next tier.
static func progress(points_now: int, need: int, next_tier: String) -> String:
	if next_tier == "":
		return Loc.f("COMMON_PROGRESS", [points_now, need])
	return Loc.f("COMMON_PROGRESS_TO", [points_now, need, next_tier])


static func zone(zone_id: String) -> String:
	match zone_id:
		"promote":
			return Loc.t("ZONE_PROMOTE")
		"relegate":
			return Loc.t("ZONE_RELEGATE")
	return Loc.t("ZONE_SAFE")


static func ordinal(n: int) -> String:
	return "#%d" % n
