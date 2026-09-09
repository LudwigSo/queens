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
var energy: EnergyLedger
var ads: AdsProvider
var purchases: PurchaseProvider
var backend: Backend

var product_prices: Dictionary = {}   ## product id -> price text from the store

var _save_queued: bool = false


func _ready() -> void:
	config = GameConfig.new()
	save = SaveData.load_or_create(config)
	catalog = LevelCatalog.new(Levels.load_all())
	var rng := RandomNumberGenerator.new()
	rng.seed = Time.get_ticks_usec()
	picker = LevelPicker.new(catalog, config, rng)
	energy = EnergyLedger.new(save, config)
	save.changed.connect(_queue_save)
	_start_backend()
	_forfeit_dangling_game()
	flush_pending_results()
	_select_providers()
	ads.reward_earned.connect(_on_reward_earned)
	purchases.products_updated.connect(_on_products_updated)
	purchases.purchase_completed.connect(_on_purchase_completed)
	purchases.restore_completed.connect(_on_restore_completed)
	ads.initialize()
	purchases.start()
	purchases.query_products([config.unlimited_product_id])
	purchases.restore()


## Real providers only on Android with the plugin present; the fakes let the
## game run in the editor and in headless tests. The Android scripts are
## loaded by path so the project parses without the addons installed.
func _select_providers() -> void:
	var android := OS.has_feature("android")
	var admob_script := "res://scripts/providers/admob_ads_provider.gd"
	if android and ResourceLoader.exists(admob_script) and ResourceLoader.exists("res://addons/admob/plugin.cfg"):
		ads = load(admob_script).new()
	else:
		ads = FakeAdsProvider.new()
	var billing_script := "res://scripts/providers/play_billing_provider.gd"
	if android and ResourceLoader.exists(billing_script) and Engine.has_singleton("GodotGooglePlayBilling"):
		purchases = load(billing_script).new()
	else:
		purchases = FakePurchaseProvider.new()
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


## Creates the backend for the current save. Only the local stub exists so
## far; a networked one would be chosen here.
func _start_backend() -> void:
	if backend != null:
		remove_child(backend)
		backend.queue_free()
	backend = LocalBackend.new(config, catalog, now)
	backend.name = "Backend"
	add_child(backend)
	backend.init()
	backend.register_player(save.player_id(), save.nickname())


## Sends results the backend has not accepted yet (offline, crash, ...).
func flush_pending_results() -> void:
	var pending: Array = save.data["pending_results"]
	if pending.is_empty():
		return
	var kept: Array = []
	for r in pending:
		var res: Dictionary = await backend.submit_result(r)
		if not res["ok"]:
			kept.append(r)
	save.data["pending_results"] = kept
	save.mark_changed()


## A game that was running when the app was killed counts as forfeited.
func _forfeit_dangling_game() -> void:
	if not save.has_running_game():
		return
	var marker: Dictionary = save.data["current_game"]
	var level := catalog.get_level(str(marker.get("level_id", "")))
	var result := GameSession.forfeit_from_marker(marker, level, save.player_id(), now(), config.client_version)
	record_result(result)


## Stores a finished game, hands it to the backend and writes the save.
## Returns {score, best_time_improved, best_score_improved, league} where
## league is the backend's submit response ({} when it failed).
func record_result(result: GameResult) -> Dictionary:
	var dict := result.to_dict()
	var outcome := save.record_result(dict, config.result_history_cap)
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
	_start_backend()
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
