class_name LevelCatalog
extends RefCounted
## Indexes the level list: lookup by id, position in game order, and a
## difficulty ranking used by the level picker.
##
## `ranked` sorts by (difficulty, size, id) so ranks are deterministic even
## though many levels share a difficulty score.

var levels: Array = []          ## Game order, as in the level file.
var ranked: Array = []          ## Same dictionaries sorted by difficulty.
var by_id: Dictionary = {}      ## id -> level
var _rank: Dictionary = {}      ## id -> index in `ranked`
var _index: Dictionary = {}     ## id -> index in `levels`


func _init(level_list: Array) -> void:
	levels = level_list
	for i in levels.size():
		var lv: Dictionary = levels[i]
		by_id[lv["id"]] = lv
		_index[lv["id"]] = i
	ranked = levels.duplicate()
	ranked.sort_custom(_compare)
	for i in ranked.size():
		_rank[ranked[i]["id"]] = i


static func _compare(a: Dictionary, b: Dictionary) -> bool:
	if float(a["difficulty"]) != float(b["difficulty"]):
		return float(a["difficulty"]) < float(b["difficulty"])
	if int(a["size"]) != int(b["size"]):
		return int(a["size"]) < int(b["size"])
	return str(a["id"]) < str(b["id"])


func size() -> int:
	return levels.size()


func has(level_id: String) -> bool:
	return by_id.has(level_id)


func get_level(level_id: String) -> Dictionary:
	return by_id.get(level_id, {})


## Position in the difficulty ranking, or -1 for an unknown id.
func rank_of(level_id: String) -> int:
	return _rank.get(level_id, -1)


## Where a level with this difficulty would be inserted in the ranking
## (number of ranked levels with a strictly lower difficulty).
func rank_for_difficulty(difficulty: float) -> int:
	var n := 0
	for lv in ranked:
		if float(lv["difficulty"]) < difficulty:
			n += 1
	return n


## Zero-based position in game order ("Level 12" is display_index 11).
func display_index(level_id: String) -> int:
	return _index.get(level_id, -1)
