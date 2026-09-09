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
var backend_path: String = "user://backend_local.json"

## Weekly league (see scripts/league_rules.gd). Weekly score is the sum of
## the best `weekly_best_n` games ("best_n") or of all games ("sum").
## Per tier: share promoted / relegated at the end of the week, what happens
## in a week without a game, and the score a leader of a tiny group needs.
var league: Dictionary = {
	"group_size": 30,
	"min_group_size": 5,
	"weekly_mode": "best_n",
	"weekly_best_n": 15,
	"tiers": [
		{"id": "bronze", "name": "Bronze", "up_pct": 30, "down_pct": 0, "inactive": "stay", "min_promo_score": 500},
		{"id": "silver", "name": "Silver", "up_pct": 25, "down_pct": 10, "inactive": "stay", "min_promo_score": 1000},
		{"id": "gold", "name": "Gold", "up_pct": 20, "down_pct": 20, "inactive": "relegate", "min_promo_score": 1500},
		{"id": "platinum", "name": "Platinum", "up_pct": 15, "down_pct": 30, "inactive": "relegate", "min_promo_score": 2500},
		{"id": "diamond", "name": "Diamond", "up_pct": 0, "down_pct": 40, "inactive": "relegate", "min_promo_score": 0, "global": true},
	],
}

## AdMob test unit id for rewarded ads; replace with the real one for release.
var admob_rewarded_unit_id: String = "ca-app-pub-3940256099942544/5224354917"
var use_test_ads: bool = true

var client_version: String = "1.0"
