extends Node
## Autoload `App`: composition root and lifecycle listener.
##
## Owns the config, the save file and the level catalog. All game logic lives
## in plain classes that take these as arguments, so tests can build them
## without the autoload. Saves are debounced to the end of the frame and
## forced when the app is paused or closed.

signal app_paused
signal app_resumed
## Emitted once the backend has been created, registered and bootstrapped.
signal backend_ready

const Levels := preload("res://scripts/levels.gd")

var config: GameConfig
var save: SaveData
var catalog: LevelCatalog
var picker: LevelPicker
var energy: EnergyLedger
var ads: AdsProvider
var purchases: PurchaseProvider
var backend: Backend

var product_prices: Dictionary = {}   ## product id -> price text from the store
## level id -> unix time the level is free again, as the server sees it.
var level_locks: Dictionary = {}

var _save_queued: bool = false


func _ready() -> void:
	Loc.load_csv()
	config = GameConfig.new()
	save = SaveData.load_or_create(config)
	catalog = LevelCatalog.new(Levels.load_all())
	var rng := RandomNumberGenerator.new()
	rng.seed = Time.get_ticks_usec()
	picker = LevelPicker.new(catalog, config, rng)
	energy = EnergyLedger.new(save, config)
	apply_settings()
	save.changed.connect(_queue_save)
	# Everything the first screen needs must exist before the first await. This
	# autoload's _ready became a coroutine when the backend went networked, and a
	# coroutine suspends: the main scene's _ready runs at the first await, and it
	# connects to App.ads and App.purchases straight away.
	_select_providers()
	ads.reward_earned.connect(_on_reward_earned)
	purchases.products_updated.connect(_on_products_updated)
	purchases.purchase_completed.connect(_on_purchase_completed)
	purchases.restore_completed.connect(_on_restore_completed)
	ads.initialize()
	purchases.start()
	purchases.query_products([config.unlimited_product_id])
	purchases.restore()
	# Awaited from here on: with a networked backend these are coroutines, and
	# firing them off unawaited raced the save file.
	await _start_backend()
	await _forfeit_dangling_game()
	await flush_pending_results()
	backend_ready.emit()


## Pushes the persisted settings into the language, motion and audio systems.
func apply_settings() -> void:
	var st := save.settings()
	Loc.apply(Loc.resolve(str(st.get("language", "")), OS.get_locale_language()))
	Motion.reduced = bool(st.get("reduced_motion", false))
	var audio := get_node_or_null("/root/Audio")
	if audio != null:
		audio.apply_settings(st)


## Real providers only on Android with the plugin present; the fakes let the
## game run in the editor and in headless tests. The Android scripts are
## loaded by path so the project parses without the addons installed.
func _select_providers() -> void:
	var android := OS.has_feature("android")
	var admob_script: GDScript = load("res://scripts/providers/admob_ads_provider.gd")
	if android and admob_script.has_plugin():
		ads = admob_script.new()
		ads.unit_id = config.admob_rewarded_unit_id
	else:
		ads = FakeAdsProvider.new()
	var billing_script: GDScript = load("res://scripts/providers/play_billing_provider.gd")
	if android and billing_script.has_plugin():
		purchases = billing_script.new()
	else:
		purchases = FakePurchaseProvider.new()
	print("providers: ads=%s purchases=%s" % [ads.provider_name(), purchases.provider_name()])
	ads.name = "Ads"
	purchases.name = "Purchases"
	add_child(ads)
	add_child(purchases)


func _on_reward_earned(_units: int) -> void:
	energy.grant(config.ad_reward_energy)
	energy.record_ad_watched()


func _on_products_updated(products: Dictionary) -> void:
	for id in products:
		product_prices[id] = str(products[id].get("price_text", ""))


func _on_purchase_completed(product_id: String, token: String) -> void:
	if product_id == config.unlimited_product_id:
		energy.set_unlimited(token)


func _on_restore_completed(owned: Array) -> void:
	if owned.has(config.unlimited_product_id) and not energy.is_unlimited():
		energy.set_unlimited("restored")


func unlimited_price_text() -> String:
	return str(product_prices.get(config.unlimited_product_id, config.unlimited_price_fallback))


## Creates the backend for the current save: the networked one when a server
## is configured, the offline stub otherwise.
##
## The node is added before anything is awaited, so a listener connected right
## after this call (main.gd wires up standing_changed) never misses the node.
func _start_backend() -> void:
	if backend != null:
		remove_child(backend)
		backend.queue_free()
	if config.server_url != "":
		backend = HttpBackend.new(config, save)
	else:
		backend = LocalBackend.new(config, catalog, _system_now)
	backend.name = "Backend"
	add_child(backend)
	await backend.init()
	var reg: Dictionary = await backend.register_player(save.player_id(), save.nickname())
	if not reg["ok"] and str(reg.get("code", "")) == "ERR_ID_TAKEN":
		# Two 122-bit random ids collided, or this id was used on another
		# device. Take a new one, keeping the progress, and try once more.
		save.rekey_player(SaveData.new_uuid())
		save_now()
		reg = await backend.register_player(save.player_id(), save.nickname())
	_apply_server_config()


## Takes the rules and the cooldown from the server when they differ from the
## shipped copy, so a rule change does not need a client release.
func _apply_server_config() -> void:
	if backend == null or not backend.has_method("server_config"):
		return
	var server: Dictionary = backend.server_config()
	var league: Dictionary = server.get("league", {})
	if not league.is_empty() and str(server.get("config_hash", "")) != LeagueConfigFile.hash_of_file():
		push_warning("league config differs from the server's; using the server's")
		config.league = league
	var cooldown := int(server.get("cooldown_seconds", 0))
	if cooldown > 0:
		config.cooldown_seconds = cooldown
	if backend.has_method("level_locks"):
		level_locks = backend.level_locks()


## Sends results the backend has not accepted yet (offline, crash, ...).
func flush_pending_results() -> void:
	var pending: Array = save.data["pending_results"]
	if pending.is_empty():
		return
	var kept: Array = []
	for i in pending.size():
		var r: Dictionary = pending[i]
		var res: Dictionary = await backend.submit_result(r)
		if res["ok"]:
			continue
		if bool(res.get("permanent", false)):
			# The server will never accept this one; keeping it would retry it
			# on every launch for ever.
			push_warning("dropping a result the server rejected: %s" % str(res.get("code", "")))
			continue
		# Anything else (offline, rate limited, a server error) is temporary.
		# Keep this result and everything after it, in order.
		for j in range(i, pending.size()):
			kept.append(pending[j])
		break
	save.data["pending_results"] = kept
	save.mark_changed()


## A game that was running when the app was killed counts as forfeited.
func _forfeit_dangling_game() -> void:
	if not save.has_running_game():
		return
	var marker: Dictionary = save.data["current_game"]
	var level := catalog.get_level(str(marker.get("level_id", "")))
	var result := GameSession.forfeit_from_marker(marker, level, save.player_id(), now(), config.client_version)
	await record_result(result)


## Stores a finished game, hands it to the backend and writes the save.
## Returns {score, best_time_improved, best_score_improved, league} where
## league is the backend's submit response ({} when it failed).
func record_result(result: GameResult) -> Dictionary:
	var dict := result.to_dict()
	var outcome := save.record_result(dict, config.result_history_cap)
	# Write before the await, not after: the result is already queued, and a
	# process death during the round trip would otherwise leave the old
	# current_game on disk and forfeit a game that was actually finished.
	save_now()
	outcome["league"] = {}
	if backend != null:
		var res: Dictionary = await backend.submit_result(dict)
		if res["ok"]:
			outcome["league"] = res["data"]
			var pending: Array = save.data["pending_results"]
			for i in range(pending.size() - 1, -1, -1):
				if str(pending[i].get("result_id", "")) == result.result_id:
					pending.remove_at(i)
	save_now()
	return outcome


## Switches to another save file (used by the screenshot test so it does not
## touch the real progress).
func use_save_path(path: String) -> void:
	if save != null:
		save.changed.disconnect(_queue_save)
	config.save_path = path
	config.backend_path = path.get_basename() + "_backend.json"
	if FileAccess.file_exists(config.backend_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(config.backend_path))
	save = SaveData.load_or_create(config)
	save.changed.connect(_queue_save)
	energy.bind_save(save)
	# A test or screenshot run must never reach a real server.
	config.server_url = ""
	await _start_backend()
	await _forfeit_dangling_game()


## Unix time, from the server when there is one. Backend.now_utc() is
## synchronous, so a networked backend keeps an offset from the X-Server-Time
## header rather than asking.
func now() -> int:
	if backend != null:
		return backend.now_utc()
	return _system_now()


## The device clock. The offline stub is given this rather than now(), or
## now() -> Backend.now_utc() -> clock -> now() would recurse for ever.
func _system_now() -> int:
	return int(Time.get_unix_time_from_system())


## Seconds until a level can be played again, taking the larger of what the
## server said and what the local formula says.
##
## The larger is deliberate: it is display only, and the server is the one that
## enforces. Taking the smaller would let a stale local value promise a level
## that the server then refuses.
func lock_remaining(level_id: String) -> int:
	var from_server := maxi(int(level_locks.get(level_id, 0)) - now(), 0)
	var from_local := Cooldown.remaining(save.level_entry(level_id), now(), config.cooldown_seconds)
	return maxi(from_server, from_local)


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
			if backend != null and backend.has_method("on_resume"):
				backend.on_resume()
			flush_pending_results()
			app_resumed.emit()
