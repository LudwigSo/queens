class_name LeagueRules
extends RefCounted
## Weekly league maths: weekly score, ranking inside a group, promotion and
## relegation counts, tier transitions. Pure static functions over the
## `league` dictionary in GameConfig, shared by the local stub and a future
## server.
##
## A member is {player_id, nickname, weekly_score, games, last_submit_at,
## is_me, is_friend, is_bot}; evaluate() adds rank and zone.

const ZONE_PROMOTE := "promote"
const ZONE_SAFE := "safe"
const ZONE_RELEGATE := "relegate"

const OUTCOME_PROMOTED := "promoted"
const OUTCOME_STAYED := "stayed"
const OUTCOME_RELEGATED := "relegated"
const OUTCOME_INACTIVE_FROZEN := "inactive_frozen"
const OUTCOME_INACTIVE_RELEGATED := "inactive_relegated"


static func tier_index(cfg: Dictionary, tier_id: String) -> int:
	var tiers: Array = cfg["tiers"]
	for i in tiers.size():
		if tiers[i]["id"] == tier_id:
			return i
	return 0


static func tier(cfg: Dictionary, tier_id: String) -> Dictionary:
	return cfg["tiers"][tier_index(cfg, tier_id)]


static func tier_name(cfg: Dictionary, tier_id: String) -> String:
	return str(tier(cfg, tier_id).get("name", tier_id.capitalize()))


static func promote_tier(cfg: Dictionary, tier_id: String) -> String:
	var tiers: Array = cfg["tiers"]
	return tiers[mini(tier_index(cfg, tier_id) + 1, tiers.size() - 1)]["id"]


static func relegate_tier(cfg: Dictionary, tier_id: String) -> String:
	var tiers: Array = cfg["tiers"]
	return tiers[maxi(tier_index(cfg, tier_id) - 1, 0)]["id"]


static func is_global(cfg: Dictionary, tier_id: String) -> bool:
	return bool(tier(cfg, tier_id).get("global", false))


## Sum of the best N game scores of the week (or the plain sum in "sum" mode).
static func weekly_score(scores: Array, cfg: Dictionary) -> int:
	var total := 0
	if str(cfg.get("weekly_mode", "best_n")) == "sum":
		for s in scores:
			total += int(s)
		return total
	var sorted := scores.duplicate()
	sorted.sort()
	sorted.reverse()
	var n := mini(int(cfg.get("weekly_best_n", 15)), sorted.size())
	for i in n:
		total += int(sorted[i])
	return total


## Higher score first, then fewer games (more efficient), then earlier submit.
static func sort_members(members: Array) -> Array:
	var sorted := members.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["weekly_score"]) != int(b["weekly_score"]):
			return int(a["weekly_score"]) > int(b["weekly_score"])
		if int(a.get("games", 0)) != int(b.get("games", 0)):
			return int(a.get("games", 0)) < int(b.get("games", 0))
		return int(a.get("last_submit_at", 0)) < int(b.get("last_submit_at", 0)))
	return sorted


## How many go up and down in a group of `n` whose leader scored `leader_score`.
static func counts(n: int, tier_cfg: Dictionary, cfg: Dictionary, leader_score: int) -> Dictionary:
	if n <= 0:
		return {"up": 0, "down": 0}
	if n < int(cfg.get("min_group_size", 5)):
		var up_tiny := 1 if leader_score >= int(tier_cfg.get("min_promo_score", 0)) and int(tier_cfg.get("up_pct", 0)) > 0 else 0
		return {"up": up_tiny, "down": 0}
	var up := int(round(int(tier_cfg.get("up_pct", 0)) / 100.0 * n))
	var down := int(round(int(tier_cfg.get("down_pct", 0)) / 100.0 * n))
	if up + down > n:
		down = n - up
	return {"up": up, "down": down}


## Ranks the members and assigns zones. Returns
## {members: [sorted with rank + zone], promote_count, relegate_count}.
static func evaluate(members: Array, tier_id: String, cfg: Dictionary) -> Dictionary:
	var sorted := sort_members(members)
	var n := sorted.size()
	var tier_cfg := tier(cfg, tier_id)
	var leader := int(sorted[0]["weekly_score"]) if n > 0 else 0
	var c := counts(n, tier_cfg, cfg, leader)
	var promoted := 0
	for i in n:
		var m: Dictionary = sorted[i]
		m["rank"] = i + 1
		if i < int(c["up"]) and int(m["weekly_score"]) > 0:
			m["zone"] = ZONE_PROMOTE
			promoted += 1
		elif i >= n - int(c["down"]):
			m["zone"] = ZONE_RELEGATE
		else:
			m["zone"] = ZONE_SAFE
	return {"members": sorted, "promote_count": promoted, "relegate_count": int(c["down"])}


static func outcome_for_zone(zone: String) -> String:
	match zone:
		ZONE_PROMOTE:
			return OUTCOME_PROMOTED
		ZONE_RELEGATE:
			return OUTCOME_RELEGATED
	return OUTCOME_STAYED


static func inactive_outcome(tier_cfg: Dictionary) -> String:
	return OUTCOME_INACTIVE_RELEGATED if str(tier_cfg.get("inactive", "stay")) == "relegate" else OUTCOME_INACTIVE_FROZEN


## The tier a player is in after `outcome`.
static func apply(cfg: Dictionary, tier_id: String, outcome: String) -> String:
	match outcome:
		OUTCOME_PROMOTED:
			return promote_tier(cfg, tier_id)
		OUTCOME_RELEGATED, OUTCOME_INACTIVE_RELEGATED:
			return relegate_tier(cfg, tier_id)
	return tier_id


## "Top 20 % promote · bottom 20 % relegate"
static func rules_text(tier_cfg: Dictionary) -> String:
	var parts: Array = []
	if int(tier_cfg.get("up_pct", 0)) > 0:
		parts.append("Top %d %% promote" % int(tier_cfg["up_pct"]))
	if int(tier_cfg.get("down_pct", 0)) > 0:
		parts.append("bottom %d %% relegate" % int(tier_cfg["down_pct"]))
	if parts.is_empty():
		return "Nobody moves"
	return " · ".join(parts)
