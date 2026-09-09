extends AdsProvider
## Rewarded ads through the Poing Studios AdMob plugin (res://addons/admob,
## Godot 4.2+). The plugin's classes (MobileAds, RewardedAdLoader, ...) are
## looked up by name at runtime, so this script parses and degrades to
## "no ads" when the addon is not installed. Selected by App only on Android
## with the addon present.
##
## Rewarded ads are single use: after every show the ad is destroyed and the
## next one preloaded.

var unit_id: String = ""

var _rewarded_ad: Object = null
var _loading: bool = false
var _showing: bool = false


static func has_plugin() -> bool:
	return _class_script("MobileAds") != null and _class_script("RewardedAdLoader") != null


static func _class_script(class_name_: String) -> GDScript:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == class_name_:
			return load(str(entry["path"]))
	return null


static func _instance(class_name_: String) -> Object:
	var script := _class_script(class_name_)
	return script.new() if script != null else null


func provider_name() -> String:
	return "admob"


func initialize() -> void:
	if not has_plugin():
		ad_failed.emit("AdMob plugin not installed")
		return
	var mobile_ads := _class_script("MobileAds")
	mobile_ads.initialize()
	preload_ad()


func preload_ad() -> void:
	if _loading or _showing or _rewarded_ad != null or not has_plugin():
		return
	_loading = true
	var callback := _instance("RewardedAdLoadCallback")
	callback.on_ad_failed_to_load = func(ad_error: Object) -> void:
		_loading = false
		ad_failed.emit("Ad failed to load: %s" % str(ad_error.get("message")))
	callback.on_ad_loaded = func(rewarded_ad: Object) -> void:
		_loading = false
		_rewarded_ad = rewarded_ad
		var content := _instance("FullScreenContentCallback")
		content.on_ad_dismissed_full_screen_content = _on_dismissed
		content.on_ad_failed_to_show_full_screen_content = func(ad_error: Object) -> void:
			_on_show_failed(str(ad_error.get("message")))
		content.on_ad_showed_full_screen_content = func() -> void:
			ad_progress.emit("Ad playing…")
		_rewarded_ad.full_screen_content_callback = content
		availability_changed.emit(true)
	var loader := _instance("RewardedAdLoader")
	loader.load(unit_id, _instance("AdRequest"), callback)


func is_ready() -> bool:
	return _rewarded_ad != null and not _showing


func show_rewarded() -> void:
	if not is_ready():
		ad_failed.emit("Ad not ready yet")
		preload_ad()
		return
	_showing = true
	availability_changed.emit(false)
	var listener := _instance("OnUserEarnedRewardListener")
	listener.on_user_earned_reward = func(rewarded_item: Object) -> void:
		reward_earned.emit(maxi(1, int(rewarded_item.get("amount"))))
	_rewarded_ad.show(listener)


func _on_dismissed() -> void:
	_release()
	ad_closed.emit(true)
	preload_ad()


func _on_show_failed(message: String) -> void:
	_release()
	ad_failed.emit("Ad could not be shown: %s" % message)
	preload_ad()


func _release() -> void:
	_showing = false
	if _rewarded_ad != null:
		_rewarded_ad.destroy()
		_rewarded_ad = null
