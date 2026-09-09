class_name Sfx
extends RefCounted
## Static front for the `Audio` autoload so scripts compile and run without
## it (headless tests, tree-less boards). Every call is a no-op when the
## autoload is missing.


static func _audio() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Audio")
	return null


static func play(name: StringName, pitch_jitter: float = 0.05, db: float = 0.0, pitch: float = 1.0) -> void:
	var a := _audio()
	if a != null:
		a.play(name, pitch_jitter, db, pitch)


static func haptic(ms: int) -> void:
	var a := _audio()
	if a != null:
		a.haptic(ms)


static func haptic_double(ms: int, gap_ms: int = 60) -> void:
	var a := _audio()
	if a != null:
		a.haptic_double(ms, gap_ms)


static func duck_music(db: float = -8.0, seconds: float = 1.5) -> void:
	var a := _audio()
	if a != null:
		a.duck_music(db, seconds)


static func play_music(name: StringName = &"music_loop") -> void:
	var a := _audio()
	if a != null:
		a.play_music(name)
