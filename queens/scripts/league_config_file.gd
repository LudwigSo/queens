class_name LeagueConfigFile
extends RefCounted
## Loads the league rules from res://shared/league.json.
##
## The rules used to live inline in GameConfig. They moved to a JSON file so the
## client and the Go server read the same bytes: the server embeds a copy and a
## test fails when the two drift. A rule change is a behaviour change, so it goes
## through code review and re-runs the golden fixtures on both sides -- which is
## why this is a file in the repository and not a row in a database.

const PATH := "res://shared/league.json"


## The parsed rules, with every integral float turned back into an int. JSON has
## only one number type, so `round_days` comes back as 7.0 and every `int()` in
## LeagueRules would still work -- but `==` comparisons in tests would not.
static func load_default() -> Dictionary:
	var text := FileAccess.get_file_as_string(PATH)
	if text.is_empty():
		push_error("league config missing at " + PATH)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		push_error("league config is not a JSON object: " + PATH)
		return {}
	return _normalise(parsed) as Dictionary


## sha256 of the file with carriage returns removed, so a CRLF checkout on
## Windows hashes the same as a LF one on Linux. The server sends its own hash
## in every standing, so drift between the two copies is visible rather than
## silent.
static func hash_of_file() -> String:
	var text := FileAccess.get_file_as_string(PATH)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.replace("\r", "").to_utf8_buffer())
	return ctx.finish().hex_encode()


static func _normalise(value: Variant) -> Variant:
	if value is Dictionary:
		var out := {}
		for key in value:
			out[key] = _normalise(value[key])
		return out
	if value is Array:
		var arr: Array = []
		for item in value:
			arr.append(_normalise(item))
		return arr
	if value is float and value == floor(value) and absf(value) < 9007199254740992.0:
		return int(value)
	return value
