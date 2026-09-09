extends RefCounted
## Loads the level list from the JSON level file written by tools/gen_boards.py.
##
## Every level is a Dictionary with: id (permanent unique string), size,
## regions (row-major region id per cell), solution (queen column per row),
## difficulty (solver score), stars (1..5) and seed. The array order is the
## order in the game; player progress is keyed by id, so levels can be
## inserted or reordered later without losing anyone's best times.

const PATH := "res://levels/queens.json"
const FORMAT := 1


static func load_all() -> Array:
	var json: JSON = load(PATH)
	assert(json != null, "cannot load level file " + PATH)
	var data: Dictionary = json.data
	assert(int(data.get("format", 0)) == FORMAT, "unsupported level file format")
	var levels: Array = []
	for raw in data["levels"]:
		levels.append(_normalize(raw))
	return levels


## JSON numbers arrive as floats; the board code expects ints.
static func _normalize(raw: Dictionary) -> Dictionary:
	var lv: Dictionary = raw.duplicate()
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
	return lv
