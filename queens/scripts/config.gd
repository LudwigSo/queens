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

## League (see scripts/league_rules.gd). Each tier plays in rounds of
## `round_days` days; the round score is the sum of the best `round_best_n`
## games ("best_n") or of all games ("sum"). Per tier: share promoted /
## relegated at the end of the round, what happens in a round without a
## game, and the score a leader of a tiny group needs.
##
## Bronze and Silver are the on-ramp: `up_mode` "score" promotes the moment
## the player's tier points (every solved game's score, added up while the
## player stays in the tier) reach `promo_score`; their rounds only rank the
## group and nobody moves at the end of one, nobody relegates. Gold is a
## floor: once reached it is never lost. Platinum
## and Diamond are skill-based with movement in both directions; Diamond is
## uncapped and, since nobody drops below Gold, grows slowly as the player
## base matures. Challenger is the capped top: one slot per
## `players_per_slot` Diamond players (5..50), half of it relegated every
## round, and Diamond promotes exactly the number of slots that opens.
var league: Dictionary = {
	"group_size": 30,
	"min_group_size": 5,
	"round_mode": "best_n",
	"round_best_n": 15,
	"tiers": [
		{"id": "bronze", "name": "Bronze", "round_days": 3, "up_mode": "score", "promo_score": 3000, "up_pct": 0, "down_pct": 0, "inactive": "stay"},
		{"id": "silver", "name": "Silver", "round_days": 7, "up_mode": "score", "promo_score": 10000, "up_pct": 0, "down_pct": 0, "inactive": "stay"},
		{"id": "gold", "name": "Gold", "round_days": 7, "up_pct": 20, "down_pct": 0, "inactive": "stay", "floor": true, "min_promo_score": 1500},
		{"id": "platinum", "name": "Platinum", "round_days": 7, "up_pct": 15, "down_pct": 25, "inactive": "relegate", "min_promo_score": 2500},
		{"id": "diamond", "name": "Diamond", "round_days": 7, "up_mode": "openings", "up_pct": 0, "down_pct": 20, "inactive": "relegate", "min_promo_score": 0, "global": true},
		{"id": "challenger", "name": "Challenger", "round_days": 7, "up_pct": 0, "down_pct": 50, "inactive": "relegate", "min_promo_score": 0, "global": true,
			"min_slots": 5, "max_slots": 50, "players_per_slot": 10},
	],
}

## AdMob test unit id for rewarded ads; replace with the real one for release.
var admob_rewarded_unit_id: String = "ca-app-pub-3940256099942544/5224354917"
var use_test_ads: bool = true

var client_version: String = "1.0"
