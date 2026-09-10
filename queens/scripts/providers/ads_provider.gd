class_name AdsProvider
extends Node
## Rewarded-ad interface. The game only ever talks to this API; the Android
## build plugs in AdMob, everything else gets FakeAdsProvider.
##
## The reward amount in energy is decided by the game (GameConfig), not by
## the ad network's reward units, so the network configuration can never
## change the game balance.

signal availability_changed(ready: bool)
signal reward_earned(units: int)
signal ad_closed(rewarded: bool)
signal ad_failed(reason: String)
signal ad_progress(text: String)


func provider_name() -> String:
	return "none"


func initialize() -> void:
	pass


func preload_ad() -> void:
	pass


func is_ready() -> bool:
	return false


func show_rewarded() -> void:
	ad_failed.emit(Loc.t("ERR_ADS_UNAVAILABLE"))
