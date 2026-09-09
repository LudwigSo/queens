extends Node
## Autoload `App`: composition root and lifecycle listener.
##
## Owns the config, the save file and the level catalog. All game logic lives
## in plain classes that take these as arguments, so tests can build them
## without the autoload. Saves are debounced to the end of the frame and
## forced when the app is paused or closed.

signal app_paused
signal app_resumed

const Levels := preload("res://scripts/levels.gd")

var config: GameConfig
var save: SaveData
var catalog: LevelCatalog
var picker: LevelPicker

var _save_queued: bool = false


func _ready() -> void:
	config = GameConfig.new()
	save = SaveData.load_or_create(config)
	catalog = LevelCatalog.new(Levels.load_all())
	var rng := RandomNumberGenerator.new()
	rng.seed = Time.get_ticks_usec()
	picker = LevelPicker.new(catalog, config, rng)
	save.changed.connect(_queue_save)
	_forfeit_dangling_game()


## A game that was running when the app was killed counts as forfeited.
func _forfeit_dangling_game() -> void:
	if not save.has_running_game():
		return
	var marker: Dictionary = save.data["current_game"]
	var level := catalog.get_level(str(marker.get("level_id", "")))
	var result := GameSession.forfeit_from_marker(marker, level, save.player_id(), now(), config.client_version)
	record_result(result)


## Stores a finished game and writes the save immediately.
func record_result(result: GameResult) -> bool:
	var improved := save.record_result(result.to_dict(), config.result_history_cap)
	save_now()
	return improved


## Switches to another save file (used by the screenshot test so it does not
## touch the real progress).
func use_save_path(path: String) -> void:
	if save != null:
		save.changed.disconnect(_queue_save)
	config.save_path = path
	save = SaveData.load_or_create(config)
	save.changed.connect(_queue_save)
	_forfeit_dangling_game()


## Wall-clock unix time. The single place to swap in server time later.
func now() -> int:
	return int(Time.get_unix_time_from_system())


func save_now() -> void:
	_save_queued = false
	save.save_to()


func _queue_save() -> void:
	if _save_queued:
		return
	_save_queued = true
	_flush_save.call_deferred()


func _flush_save() -> void:
	if _save_queued:
		save_now()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_CLOSE_REQUEST:
			save_now()
			app_paused.emit()
		NOTIFICATION_APPLICATION_RESUMED:
			app_resumed.emit()
