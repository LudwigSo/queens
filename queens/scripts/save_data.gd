class_name SaveData
extends RefCounted
## The player's save file: a versioned JSON document at user://save.json.
##
## Layout (version 1):
##   player        id (uuid), nickname, created_at
##   energy        amount, unlimited, purchase_token, ads_watched
##   last_game     {level_id, difficulty, started_at} or {} - the last game *started*
##   current_game  marker of a running game (so a killed app yields a forfeit) or {}
##   levels        level id -> {last_started_at, plays, completions, best_time (fastest),
##                 best_score, best_score_time, best_wrong, best_undo, best_result_id,
##                 best_at (all of the highest-scoring run)}
##   results       finished games, newest last, capped
##   pending_results  results not yet accepted by the backend
##   settings      free-form
##
## Writes are atomic (temp file + rename). The old ConfigFile save
## (progress.cfg, section best_times) is imported once and then renamed.

signal changed

const VERSION := 1

var data: Dictionary = {}
var path: String = ""


static func defaults(cfg: GameConfig) -> Dictionary:
	var id := new_uuid()
	return {
		"version": VERSION,
		"player": {
			"id": id,
			"nickname": "Player-" + id.substr(0, 4),
			"created_at": int(Time.get_unix_time_from_system()),
		},
		"energy": {
			"amount": cfg.start_energy,
			"unlimited": false,
			"purchase_token": "",
			"ads_watched": 0,
		},
		"last_game": {},
		"current_game": {},
		"levels": {},
		"results": [],
		"pending_results": [],
		"settings": {},
	}


static func level_defaults() -> Dictionary:
	return {
		"last_started_at": 0,
		"plays": 0,
		"completions": 0,
		"best_score": 0,
		"best_time": 0.0,
		"best_score_time": 0.0,
		"best_wrong": 0,
		"best_undo": 0,
		"best_result_id": "",
		"best_at": 0,
	}


## Loads the save file, importing the legacy ConfigFile if this is the first
## run of the new format, or creates a fresh save.
static func load_or_create(cfg: GameConfig) -> SaveData:
	var sd := SaveData.new()
	sd.path = cfg.save_path
	var dict: Dictionary = {}
	if FileAccess.file_exists(cfg.save_path):
		dict = read_json(cfg.save_path)
	if dict.is_empty():
		dict = from_legacy_cfg(cfg.legacy_cfg_path, cfg)
		if not dict.is_empty():
			sd.data = migrate(dict, cfg)
			sd.save_to()
			DirAccess.rename_absolute(
				ProjectSettings.globalize_path(cfg.legacy_cfg_path),
				ProjectSettings.globalize_path(cfg.legacy_cfg_path + ".migrated"))
			return sd
	if dict.is_empty():
		sd.data = defaults(cfg)
		sd.save_to()
		return sd
	sd.data = migrate(dict, cfg)
	return sd


static func read_json(file_path: String) -> Dictionary:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_warning("save file %s is not a JSON object, ignoring it" % file_path)
	return {}


## Builds a version-1 dictionary from the old progress.cfg, or {} if there is none.
static func from_legacy_cfg(cfg_path: String, cfg: GameConfig) -> Dictionary:
	var file := ConfigFile.new()
	if file.load(cfg_path) != OK:
		return {}
	var dict := defaults(cfg)
	if file.has_section("best_times"):
		for key in file.get_section_keys("best_times"):
			var entry := level_defaults()
			entry["plays"] = 1
			entry["completions"] = 1
			entry["best_time"] = float(file.get_value("best_times", key))
			dict["levels"][key] = entry
	return dict


## Brings a dictionary of any older version up to VERSION. Unknown newer
## versions are returned untouched (with a warning) so nothing is lost.
static func migrate(dict: Dictionary, cfg: GameConfig) -> Dictionary:
	var version := int(dict.get("version", 0))
	if version > VERSION:
		push_warning("save file version %d is newer than %d, loading as is" % [version, VERSION])
		return dict
	while version < VERSION:
		match version:
			0:
				# Pre-versioned or empty: fill every missing top-level key.
				var base := defaults(cfg)
				for key in base:
					if not dict.has(key):
						dict[key] = base[key]
				version = 1
		dict["version"] = version
	# Fill missing per-level fields so callers can index without checks.
	var levels: Dictionary = dict["levels"]
	for id in levels:
		var entry: Dictionary = levels[id]
		for key in level_defaults():
			if not entry.has(key):
				entry[key] = level_defaults()[key]
	return dict


static func new_uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]


## Writes the save atomically: temp file first, then rename over the target.
func save_to(target: String = "") -> Error:
	if target == "":
		target = path
	var dir_path := target.get_base_dir()
	if dir_path != "" and not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var tmp := target + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("cannot write save file %s: %s" % [tmp, error_string(FileAccess.get_open_error())])
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(data))
	f.close()
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var abs_target := ProjectSettings.globalize_path(target)
	if FileAccess.file_exists(target):
		DirAccess.remove_absolute(abs_target)
	var err := DirAccess.rename_absolute(abs_tmp, abs_target)
	if err != OK:
		push_error("cannot rename %s to %s: %s" % [tmp, target, error_string(err)])
	return err


## Call after mutating `data` directly; the App autoload saves on this signal.
func mark_changed() -> void:
	changed.emit()


func player_id() -> String:
	return str(data["player"]["id"])


func nickname() -> String:
	return str(data["player"]["nickname"])


## The per-level record, created with defaults when the level is unknown.
func level_entry(level_id: String) -> Dictionary:
	var levels: Dictionary = data["levels"]
	if not levels.has(level_id):
		levels[level_id] = level_defaults()
	return levels[level_id]


func has_best(level_id: String) -> bool:
	var levels: Dictionary = data["levels"]
	return levels.has(level_id) and float(levels[level_id]["best_time"]) > 0.0


func best_time(level_id: String) -> float:
	return float(level_entry(level_id)["best_time"]) if has_best(level_id) else 0.0


## Records a completed game's time; returns true when it is a new best.
func update_best_time(level_id: String, seconds: float) -> bool:
	var entry := level_entry(level_id)
	entry["completions"] = int(entry["completions"]) + 1
	var improved: bool = float(entry["best_time"]) <= 0.0 or seconds < float(entry["best_time"])
	if improved:
		entry["best_time"] = seconds
	mark_changed()
	return improved


## Marks a game as started: bumps the play count, starts the replay cooldown,
## remembers it as the last game (for easier/same/harder) and stores the
## running-game marker so a killed app yields a forfeit next time.
func begin_game(level: Dictionary, marker: Dictionary, now: int) -> void:
	var entry := level_entry(str(level["id"]))
	entry["plays"] = int(entry["plays"]) + 1
	entry["last_started_at"] = now
	data["current_game"] = marker
	data["last_game"] = {
		"level_id": str(level["id"]),
		"difficulty": float(level["difficulty"]),
		"started_at": now,
	}
	mark_changed()


## The last game started ({level_id, difficulty, started_at}) or {}.
func last_game() -> Dictionary:
	return data["last_game"]


func update_marker(marker: Dictionary) -> void:
	data["current_game"] = marker
	mark_changed()


func has_running_game() -> bool:
	return not (data["current_game"] as Dictionary).is_empty()


## Stores a finished game: history (capped), the backend queue and, for a
## completed game, the level's best time and best score. Returns
## {score, best_time_improved, best_score_improved}.
func record_result(result: Dictionary, history_cap: int) -> Dictionary:
	var outcome := {"score": int(result.get("score", 0)), "best_time_improved": false, "best_score_improved": false}
	if bool(result["completed"]):
		var level_id := str(result["level_id"])
		outcome["best_time_improved"] = update_best_time(level_id, float(result["elapsed_seconds"]))
		outcome["best_score_improved"] = update_best_score(level_id, result)
	var results: Array = data["results"]
	results.append(result)
	while results.size() > history_cap:
		results.pop_front()
	(data["pending_results"] as Array).append(result)
	data["current_game"] = {}
	mark_changed()
	return outcome


## Keeps the highest-scoring completed game per level (ties: fewer wrong
## placements, then faster). Returns true when the record changed.
func update_best_score(level_id: String, result: Dictionary) -> bool:
	var entry := level_entry(level_id)
	var score := int(result.get("score", 0))
	var wrong := int(result.get("wrong_placements", 0))
	var time := float(result.get("elapsed_seconds", 0.0))
	var better := false
	if str(entry["best_result_id"]) == "":
		better = true
	elif score != int(entry["best_score"]):
		better = score > int(entry["best_score"])
	elif wrong != int(entry["best_wrong"]):
		better = wrong < int(entry["best_wrong"])
	else:
		better = time < float(entry["best_score_time"])
	if not better:
		return false
	entry["best_score"] = score
	entry["best_wrong"] = wrong
	entry["best_score_time"] = time
	entry["best_undo"] = int(result.get("undo_count", 0))
	entry["best_result_id"] = str(result.get("result_id", ""))
	entry["best_at"] = int(result.get("finished_at", 0))
	mark_changed()
	return true


func has_best_score(level_id: String) -> bool:
	var levels: Dictionary = data["levels"]
	return levels.has(level_id) and str(levels[level_id]["best_result_id"]) != ""
