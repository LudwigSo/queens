class_name Cooldown
extends RefCounted
## Replay lock: a level that was started stays locked for a configurable
## period. Pure functions over the save's per-level entry.
##
## Uses the device clock; a user can shorten the lock by moving the clock
## forward. `remaining` is clamped to the cooldown so moving it backwards can
## never lock a level for longer than one period.


static func remaining(entry: Dictionary, now: int, cooldown_seconds: int) -> int:
	var started := int(entry.get("last_started_at", 0))
	if started <= 0:
		return 0
	return clampi(cooldown_seconds - (now - started), 0, cooldown_seconds)


static func is_locked(entry: Dictionary, now: int, cooldown_seconds: int) -> bool:
	return remaining(entry, now, cooldown_seconds) > 0


## "6d 23h", "3h 12m", "45m", "<1m".
static func format_remaining(seconds: int) -> String:
	seconds = maxi(seconds, 0)
	@warning_ignore("integer_division")
	var d := seconds / 86400
	@warning_ignore("integer_division")
	var h := (seconds % 86400) / 3600
	@warning_ignore("integer_division")
	var m := (seconds % 3600) / 60
	if d > 0:
		return Loc.f("COOLDOWN_D_H", [d, h])
	if h > 0:
		return Loc.f("COOLDOWN_H_M", [h, m])
	if m > 0:
		return Loc.f("COOLDOWN_M", [m])
	return Loc.t("COOLDOWN_LT_1M")


## A whole period in words: "7 days", "1 day", "12 hours", "30 minutes".
static func format_period(seconds: int) -> String:
	if seconds >= 86400 and seconds % 86400 == 0:
		@warning_ignore("integer_division")
		var d := seconds / 86400
		return Loc.plural("PERIOD_DAYS", d)
	if seconds >= 3600 and seconds % 3600 == 0:
		@warning_ignore("integer_division")
		var h := seconds / 3600
		return Loc.plural("PERIOD_HOURS", h)
	@warning_ignore("integer_division")
	var m := maxi(1, seconds / 60)
	return Loc.plural("PERIOD_MINUTES", m)
