extends RefCounted
## Loads the level list: the file bundled with the game (written by
## tools/gen_boards.py), followed by the levels downloaded from the server since
## (LevelSync), which are cached in user://.
##
## Every level is a Dictionary with: id (permanent unique string), size,
## regions (row-major region id per cell), solution (queen column per row),
## difficulty (solver score), stars (1..5) and seed. The array order is the
## order in the game; player progress is keyed by id, so levels can be
## inserted or reordered later without losing anyone's best times.
##
## Published levels never change and never disappear (the server refuses
## both), so a level the device has is always the level the server has.

const PATH := "res://levels/queens.json"
const CACHE_PATH := "user://levels_cache.json"
const FORMAT := 1


## Bundled levels first, then the cached downloads the bundle does not have,
## in the order they were downloaded.
static func load_all(cache_path: String = CACHE_PATH) -> Array:
	var json: JSON = load(PATH)
	assert(json != null, "cannot load level file " + PATH)
	var data: Dictionary = json.data
	assert(int(data.get("format", 0)) == FORMAT, "unsupported level file format")
	var levels: Array = []
	var seen := {}
	for raw in data["levels"]:
		var lv := _normalize(raw)
		levels.append(lv)
		seen[lv["id"]] = true
	for lv in read_cache(cache_path):
		if not seen.has(lv["id"]):
			levels.append(lv)
			seen[lv["id"]] = true
	return levels


## The downloaded levels, normalised. A missing or unreadable cache is empty:
## the levels are downloaded again on the next sync.
static func read_cache(cache_path: String = CACHE_PATH) -> Array:
	if cache_path == "" or not FileAccess.file_exists(cache_path):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(cache_path))
	if not parsed is Dictionary or int((parsed as Dictionary).get("format", 0)) != FORMAT:
		push_warning("ignoring an unreadable level cache at " + cache_path)
		return []
	var out: Array = []
	for raw in (parsed as Dictionary).get("levels", []):
		if raw is Dictionary and validate(raw) == "":
			out.append(_normalize(raw))
	return out


## Adds levels to the cache file, keeping what is there. Written atomically
## (temp file, then rename), like the save file.
static func append_to_cache(new_levels: Array, cache_path: String = CACHE_PATH) -> Error:
	var levels: Array = read_cache(cache_path)
	var seen := {}
	for lv in levels:
		seen[lv["id"]] = true
	for lv in new_levels:
		if not seen.has(lv["id"]):
			levels.append(_to_file(lv))
			seen[lv["id"]] = true
	var dir_path := cache_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var tmp := cache_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify({"format": FORMAT, "game": "queens", "levels": levels}))
	f.close()
	return DirAccess.rename_absolute(tmp, cache_path)


## The fields of the level file, nothing the game adds at run time.
static func _to_file(lv: Dictionary) -> Dictionary:
	return {
		"id": lv["id"], "size": lv["size"], "regions": lv["regions"], "solution": lv["solution"],
		"difficulty": lv["difficulty"], "stars": lv["stars"], "seed": lv.get("seed", 0),
	}


## Why a level is not a playable Queens board, or "" when it is. A download
## is checked before it is cached: a broken board would stay broken on this
## device for good. The same rules as ValidateBoard on the server, minus the
## uniqueness search, which the server already ran on import.
static func validate(raw: Dictionary) -> String:
	var id := str(raw.get("id", ""))
	if id.length() != 36 or id.count("-") != 4:
		return "id is not a uuid"
	if not (raw.get("regions") is Array and raw.get("solution") is Array):
		return "regions or solution missing"
	var n := int(raw.get("size", 0))
	if n < 4 or n > 20:
		return "implausible size %d" % n
	var regions: Array = raw["regions"]
	var solution: Array = raw["solution"]
	if regions.size() != n or solution.size() != n:
		return "regions/solution do not match size %d" % n
	var region_seen := {}
	for row in regions:
		if not row is Array or (row as Array).size() != n:
			return "a region row is not %d wide" % n
		for v in row:
			var r := int(v)
			if r < 0 or r >= n:
				return "region id %d outside 0..%d" % [r, n - 1]
			region_seen[r] = true
	if region_seen.size() != n:
		return "not every region has a cell"
	var cols := {}
	var regs := {}
	for r in n:
		var c := int(solution[r])
		if c < 0 or c >= n:
			return "solution row %d outside the board" % r
		var reg := int(regions[r][c])
		if cols.has(c) or regs.has(reg):
			return "solution repeats a column or a region"
		cols[c] = true
		regs[reg] = true
		if r > 0 and absi(int(solution[r - 1]) - c) <= 1:
			return "solution queens touch in rows %d and %d" % [r - 1, r]
	var stars := int(raw.get("stars", 0))
	if stars < 1 or stars > 5:
		return "stars %d outside 1..5" % stars
	return ""


## JSON numbers arrive as floats; the board code expects ints.
static func _normalize(raw: Dictionary) -> Dictionary:
	var lv: Dictionary = raw.duplicate()
	lv.erase("position")
	lv["size"] = int(raw["size"])
	var regions: Array = []
	for row in raw["regions"]:
		var cells: Array = []
		for v in row:
			cells.append(int(v))
		regions.append(cells)
	lv["regions"] = regions
	var solution: Array = []
	for v in raw["solution"]:
		solution.append(int(v))
	lv["solution"] = solution
	lv["stars"] = int(raw.get("stars", 0))
	lv["difficulty"] = float(raw.get("difficulty", 0))
	if lv.has("seed"):
		lv["seed"] = int(lv["seed"])
	return lv


## A downloaded level in the shape load_all returns.
static func normalize(raw: Dictionary) -> Dictionary:
	return _normalize(raw)
