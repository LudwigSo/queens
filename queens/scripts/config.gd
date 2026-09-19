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

## Level picker: "harder" moves this fraction of the ranked level list up.
## Small on purpose - the next board should feel like a step, not a wall.
var step_fraction_up: float = 0.08
## Level picker: "easier" moves this fraction of the list down. A bit larger
## than the step up, so a player who is stuck lands somewhere comfortable.
var step_fraction_down: float = 0.12
## Level picker: half-width of the candidate band as a fraction of the list.
var band_fraction: float = 0.05
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
var league: Dictionary = LeagueConfigFile.load_default()

## Base URL of the backend, or "" for offline play against the local stub.
##
## Release builds get SERVER_URL_RELEASE, everything else (the editor, the
## headless test suite, debug APKs) stays offline, so a test run can never
## reach a real server. QUEENS_SERVER_URL overrides both on desktop.
const SERVER_URL_RELEASE := ""
const SERVER_URL_DEBUG := ""
var server_url: String = _default_server_url()


static func _default_server_url() -> String:
	var from_env := OS.get_environment("QUEENS_SERVER_URL")
	if from_env != "":
		return from_env
	if OS.has_feature("editor") or OS.has_feature("debug"):
		return SERVER_URL_DEBUG
	return SERVER_URL_RELEASE

## AdMob test unit id for rewarded ads; replace with the real one for release.
var admob_rewarded_unit_id: String = "ca-app-pub-3940256099942544/5224354917"
var use_test_ads: bool = true

var client_version: String = "1.0"
