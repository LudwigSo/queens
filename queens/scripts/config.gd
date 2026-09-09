class_name GameConfig
extends RefCounted
## Tunable game constants. Plain vars with defaults so tests can override
## single values; the game uses one instance owned by the App autoload.

## Seconds a level stays locked after it was started (finished or not).
var cooldown_seconds: int = 7 * 86400
## Energy a fresh install starts with.
var start_energy: int = 10
## Energy granted per rewarded ad.
var ad_reward_energy: int = 10
## Upper bound for stored energy; 0 means no cap.
var energy_cap: int = 0
## Google Play product id of the lifetime unlimited-energy purchase.
var unlimited_product_id: String = "queens_unlimited_energy"
## Price shown before the store has answered (or on desktop).
var unlimited_price_fallback: String = "2.99 €"

## Level picker: "harder"/"easier" move this fraction of the ranked level list.
var step_fraction: float = 0.20
## Level picker: half-width of the candidate band as a fraction of the list.
var band_fraction: float = 0.075
## Level picker: the first game is picked around this quantile (from the easy end).
var initial_quartile: float = 0.25

## How many finished games are kept in the save file.
var result_history_cap: int = 500

var save_path: String = "user://save.json"
var legacy_cfg_path: String = "user://progress.cfg"

## AdMob test unit id for rewarded ads; replace with the real one for release.
var admob_rewarded_unit_id: String = "ca-app-pub-3940256099942544/5224354917"
var use_test_ads: bool = true

var client_version: String = "1.0"
