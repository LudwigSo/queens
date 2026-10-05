class_name LevelSync
extends RefCounted
## Brings the device's level set up to the server's at launch, so a new level
## needs no app release:
##
## 1. Ask how many levels the server publishes. The same number as the
##    catalog holds means the same set (levels are append-only and immutable on
##    the server), and the launch goes on. This is the usual case: one tiny
##    request.
## 2. Otherwise ask for every level id and diff it against the catalog.
## 3. Download the missing levels in chunks, check each one, cache it in
##    user:// and add it to the catalog.
##
## Each chunk is cached as soon as it arrives, so a sync cut off half way keeps
## what it got and the next launch fetches only the rest. Offline, step 1 fails
## and nothing happens: the cached levels from earlier syncs are already in the
## catalog (Levels.load_all).

const Levels := preload("res://scripts/levels.gd")


## Returns the levels added to the catalog (empty when nothing changed).
static func sync_levels(backend: Backend, catalog: LevelCatalog, cache_path: String = Levels.CACHE_PATH) -> Array:
	var added: Array = []
	var count_res: Dictionary = await backend.get_level_count()
	if not count_res["ok"] or int(count_res["data"]) == catalog.size():
		return added
	var ids_res: Dictionary = await backend.get_level_ids()
	if not ids_res["ok"]:
		return added
	var missing: Array = []
	for id in ids_res["data"]:
		if not catalog.has(str(id)):
			missing.append(str(id))
	var chunk := Backend.MAX_LEVELS_PER_REQUEST
	for start in range(0, missing.size(), chunk):
		var res: Dictionary = await backend.get_levels(missing.slice(start, start + chunk))
		if not res["ok"]:
			break
		var boards: Array = (res["data"] as Array).duplicate()
		boards.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("position", 0)) < int(b.get("position", 0)))
		var good: Array = []
		for raw in boards:
			var why := Levels.validate(raw)
			if why != "":
				push_warning("dropping downloaded level %s: %s" % [str(raw.get("id", "?")), why])
				continue
			good.append(Levels.normalize(raw))
		if good.is_empty():
			continue
		var err := Levels.append_to_cache(good, cache_path)
		if err != OK:
			push_warning("could not cache downloaded levels: %s" % error_string(err))
		catalog.add_levels(good)
		added.append_array(good)
	return added
