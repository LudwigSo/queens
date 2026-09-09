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

var _save_queued: bool = false


func _ready() -> void:
	config = GameConfig.new()
	save = SaveData.load_or_create(config)
	catalog = LevelCatalog.new(Levels.load_all())
	save.changed.connect(_queue_save)


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
