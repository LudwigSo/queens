class_name LevelPicker
extends RefCounted
## Chooses the next level for "easier" / "same" / "harder" relative to the
## last game started.
##
## Levels are ranked by solver difficulty (LevelCatalog.ranked). A step moves
## the target `step_fraction` of the list up or down; a band of
## `band_fraction` around the target is the candidate pool. Levels on
## cooldown are excluded. "harder" only accepts a strictly higher difficulty
## and "easier" a strictly lower one, so ties never count as a step.
##
## pick() returns {"level": Dictionary (empty when nothing fits),
## "reason": "band" | "nearest" | "none_harder" | "none_easier" | "none",
## "step": int}.

var catalog: LevelCatalog
var config: GameConfig
var rng: RandomNumberGenerator


func _init(level_catalog: LevelCatalog, game_config: GameConfig, random: RandomNumberGenerator) -> void:
	catalog = level_catalog
	config = game_config
	rng = random


## `last`: {"level_id", "difficulty"} of the last game started, or {} on the
## first launch. `locked_ids` / `played_ids`: level id -> true.
func pick(step: int, last: Dictionary, locked_ids: Dictionary, played_ids: Dictionary = {}) -> Dictionary:
	var ranked := catalog.ranked
	var n := ranked.size()
	if n == 0:
		return {"level": {}, "reason": "none", "step": step}
	var step_ranks := ceili(n * config.step_fraction)
	var half := ceili(n * config.band_fraction)

	var has_last := false
	var last_id := ""
	var last_difficulty := 0.0
	var anchor := 0
	if last.has("level_id") and catalog.has(str(last["level_id"])):
		has_last = true
		last_id = str(last["level_id"])
		anchor = catalog.rank_of(last_id)
		last_difficulty = float(ranked[anchor]["difficulty"])
	elif last.has("difficulty"):
		has_last = true
		last_difficulty = float(last["difficulty"])
		anchor = catalog.rank_for_difficulty(last_difficulty)
	if not has_last:
		step = 0
		anchor = int(floor(n * config.initial_quartile / 2.0))

	var center := clampi(anchor + step * step_ranks, 0, n - 1)
	var lo := maxi(0, center - half)
	var hi := mini(n - 1, center + half)

	var band: Array = []
	for i in range(lo, hi + 1):
		if _allowed(ranked[i], step, has_last, last_id, last_difficulty, locked_ids):
			band.append(ranked[i])
	if not band.is_empty():
		return {"level": _weighted_choice(band, played_ids), "reason": "band", "step": step}

	# Nothing in the band: the closest allowed level on the right side.
	var best_distance := n
	var nearest: Array = []
	for i in n:
		if not _allowed(ranked[i], step, has_last, last_id, last_difficulty, locked_ids):
			continue
		var distance := absi(i - center)
		if distance < best_distance:
			best_distance = distance
			nearest = [ranked[i]]
		elif distance <= best_distance + 2:
			nearest.append(ranked[i])
	if not nearest.is_empty():
		# Keep only those within two ranks of the closest one.
		var close: Array = []
		for lv in nearest:
			if absi(catalog.rank_of(lv["id"]) - center) <= best_distance + 2:
				close.append(lv)
		return {"level": close[rng.randi_range(0, close.size() - 1)], "reason": "nearest", "step": step}

	var reason := "none"
	if has_last and step > 0:
		reason = "none_harder"
	elif has_last and step < 0:
		reason = "none_easier"
	return {"level": {}, "reason": reason, "step": step}


func _allowed(level: Dictionary, step: int, has_last: bool, last_id: String, last_difficulty: float, locked_ids: Dictionary) -> bool:
	var id: String = level["id"]
	if locked_ids.has(id):
		return false
	if not has_last:
		return true
	if id == last_id:
		return false
	var difficulty := float(level["difficulty"])
	if step > 0:
		return difficulty > last_difficulty
	if step < 0:
		return difficulty < last_difficulty
	return true


## Never-played levels are twice as likely as played ones.
func _weighted_choice(pool: Array, played_ids: Dictionary) -> Dictionary:
	var total := 0.0
	for lv in pool:
		total += 1.0 if played_ids.has(lv["id"]) else 2.0
	var r := rng.randf() * total
	for lv in pool:
		r -= 1.0 if played_ids.has(lv["id"]) else 2.0
		if r <= 0.0:
			return lv
	return pool[pool.size() - 1]
