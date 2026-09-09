extends Node
## Autoload `Audio`: sound effects, music and haptics behind the settings.
##
## Streams live in assets/audio/<name>.wav (or .ogg) and are loaded lazily; a
## missing file is a silent no-op, so headless tests and unfinished asset sets
## never error. Buses: Master / Music / SFX (default_bus_layout.tres).

const SFX_DIR := "res://assets/audio/"
const POOL_SIZE := 8
const MUSIC_DB := -12.0

var sfx_enabled: bool = true
var music_enabled: bool = true
var haptics_enabled: bool = true

var _pool: Array[AudioStreamPlayer] = []
var _next: int = 0
var _streams: Dictionary = {}
var _music: AudioStreamPlayer = null
var _music_tween: Tween = null


func _ready() -> void:
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
		add_child(p)
		_pool.append(p)
	_music = AudioStreamPlayer.new()
	_music.bus = "Music" if AudioServer.get_bus_index("Music") >= 0 else "Master"
	_music.volume_db = MUSIC_DB
	add_child(_music)


## Applies persisted settings ({sfx, music, haptics}).
func apply_settings(settings: Dictionary) -> void:
	sfx_enabled = bool(settings.get("sfx", true))
	music_enabled = bool(settings.get("music", true))
	haptics_enabled = bool(settings.get("haptics", true))
	if _music == null:
		return
	if not music_enabled:
		stop_music()
	elif _music.stream != null and not _music.playing:
		_music.play()


func _stream(name: StringName) -> AudioStream:
	if _streams.has(name):
		return _streams[name]
	var stream: AudioStream = null
	for ext in ["wav", "ogg"]:
		var path: String = SFX_DIR + String(name) + "." + ext
		if ResourceLoader.exists(path):
			stream = load(path)
			break
	_streams[name] = stream
	return stream


## Plays a one-shot effect with slight pitch variation.
func play(name: StringName, pitch_jitter: float = 0.05, db: float = 0.0, pitch: float = 1.0) -> void:
	if not sfx_enabled or _pool.is_empty():
		return
	var stream := _stream(name)
	if stream == null:
		return
	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.stream = stream
	p.pitch_scale = pitch * (1.0 + randf_range(-pitch_jitter, pitch_jitter))
	p.volume_db = db
	p.play()


func play_music(name: StringName = &"music_loop") -> void:
	var stream := _stream(name)
	if stream == null:
		return
	if _music.stream != stream:
		_music.stream = stream
	if music_enabled and not _music.playing:
		_music.volume_db = MUSIC_DB
		_music.play()


func stop_music() -> void:
	_music.stop()


## Temporarily lowers the music (e.g. under the win jingle).
func duck_music(db: float = -8.0, seconds: float = 1.5) -> void:
	if not _music.playing:
		return
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
	_music_tween = create_tween()
	_music_tween.tween_property(_music, "volume_db", MUSIC_DB + db, 0.15)
	_music_tween.tween_interval(seconds)
	_music_tween.tween_property(_music, "volume_db", MUSIC_DB, 0.6)


func haptic(ms: int) -> void:
	if not haptics_enabled or ms <= 0:
		return
	if OS.has_feature("mobile"):
		Input.vibrate_handheld(ms)


## Two short pulses.
func haptic_double(ms: int, gap_ms: int = 60) -> void:
	haptic(ms)
	if haptics_enabled and OS.has_feature("mobile"):
		get_tree().create_timer((ms + gap_ms) / 1000.0).timeout.connect(haptic.bind(ms))
