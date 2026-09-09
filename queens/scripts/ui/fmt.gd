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
	return "Level %d · %dx%d · diff %d" % [level_no, size, size, difficulty]


static func size_text(size: int) -> String:
	return "%d×%d" % [size, size]


static func mistakes(n: int) -> String:
	if n == 0:
		return "flawless"
	return "%d mistake" % n if n == 1 else "%d mistakes" % n


static func points(n: int) -> String:
	return "%d pts" % n


static func zone(zone_id: String) -> String:
	match zone_id:
		"promote":
			return "promotion zone"
		"relegate":
			return "relegation zone"
	return "safe"


static func ordinal(n: int) -> String:
	return "#%d" % n
