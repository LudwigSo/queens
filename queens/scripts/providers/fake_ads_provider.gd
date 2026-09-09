class_name FakeAdsProvider
extends AdsProvider
## Desktop / editor stand-in: an "ad" is a short countdown that always pays.
## With `instant = true` (tests) everything happens synchronously.

var instant: bool = false
var load_delay: float = 0.5
var show_seconds: int = 3

var _loaded: bool = false
var _showing: bool = false


func provider_name() -> String:
	return "fake"


func initialize() -> void:
	preload_ad()


func preload_ad() -> void:
	if _loaded or _showing:
		return
	if not instant and is_inside_tree():
		await get_tree().create_timer(load_delay).timeout
	_loaded = true
	availability_changed.emit(true)


func is_ready() -> bool:
	return _loaded and not _showing


func show_rewarded() -> void:
	if not is_ready():
		ad_failed.emit("Ad not ready yet")
		return
	_showing = true
	_loaded = false
	availability_changed.emit(false)
	if not instant and is_inside_tree():
		for i in range(show_seconds, 0, -1):
			ad_progress.emit("Fake ad playing… %d" % i)
			await get_tree().create_timer(1.0).timeout
	_showing = false
	reward_earned.emit(1)
	ad_closed.emit(true)
	preload_ad()
