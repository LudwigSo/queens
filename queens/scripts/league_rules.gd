class_name LeagueRules
extends RefCounted
## League maths: round score, ranking inside a group, promotion and
## relegation counts, tier transitions and round timing. Pure static
## functions over the `league` dictionary in GameConfig, shared by the local
## stub and a future server.
##
## A tier with `round_days` > 0 plays in rounds of that many days (7 for every
## ranked tier); all rounds start at Monday 00:00 UTC of 1970-01-05 and repeat
## from there, so 7-day rounds are calendar weeks. `round_days` 0 means no
## rounds at all: Bronze and Silver have no timer, no group and no ranking,
## only tier points. A tier with `floor` never relegates (Gold). A tier with
## `max_slots` (Challenger) has a capped population: `players_per_slot`
## players of the tier below open one slot, between `min_slots` and
## `max_slots`. The tier below it (`up_mode` "openings") promotes exactly as
## many players as slots are open after the top tier's own relegation. A tier
## with `up_mode` "score" (Bronze, Silver) promotes by tier points instead: the
## player moves up the moment the sum of all game scores since entering the
## tier reaches `promo_score`.
##
## Groups fill to `group_size` at random; friends of a member may join up to
## `group_max`. A tier with `bots` tops its groups up to `bots.fill_to` with
## deterministic bots that compete like anyone else (bot_progress()), one bot
## leaving for every human who joins. A tier with `online_required` counts a
## game only when it was started with a server session and reached the server
## within `online_grace_s` of finishing (counts_for_league()).
##
## A member is {player_id, nickname, round_score, games, last_submit_at,
## is_me, is_friend}; evaluate() adds rank and zone.

const DAY_SECONDS := 86400
const ROUND_EPOCH_OFFSET := Scoring.WEEK_EPOCH_OFFSET   ## Monday 1970-01-05 00:00 UTC, like calendar weeks.

const ZONE_PROMOTE := "promote"
const ZONE_SAFE := "safe"
const ZONE_RELEGATE := "relegate"

const OUTCOME_PROMOTED := "promoted"
const OUTCOME_STAYED := "stayed"
const OUTCOME_RELEGATED := "relegated"
const OUTCOME_INACTIVE_FROZEN := "inactive_frozen"
const OUTCOME_INACTIVE_RELEGATED := "inactive_relegated"

const UP_MODE_PCT := "pct"
const UP_MODE_OPENINGS := "openings"
const UP_MODE_SCORE := "score"


static func tier_index(cfg: Dictionary, tier_id: String) -> int:
	var tiers: Array = cfg["tiers"]
	for i in tiers.size():
		if tiers[i]["id"] == tier_id:
			return i
	return 0


static func tier(cfg: Dictionary, tier_id: String) -> Dictionary:
	return cfg["tiers"][tier_index(cfg, tier_id)]


## The tier's display name. Translated from the id, so the ids in the save
## file and in backend payloads stay language-neutral; the `name` in the
## config is the fallback for a tier without a TIER_ row.
static func tier_label(tier_id: String) -> String:
	var key := "TIER_" + tier_id.to_upper()
	return Loc.t(key) if Loc.has(key) else tier_id.capitalize()


static func tier_name(cfg: Dictionary, tier_id: String) -> String:
	var key := "TIER_" + tier_id.to_upper()
	if Loc.has(key):
		return Loc.t(key)
	return str(tier(cfg, tier_id).get("name", tier_id.capitalize()))


static func top_tier(cfg: Dictionary) -> String:
	var tiers: Array = cfg["tiers"]
	return tiers[tiers.size() - 1]["id"]


static func promote_tier(cfg: Dictionary, tier_id: String) -> String:
	var tiers: Array = cfg["tiers"]
	return tiers[mini(tier_index(cfg, tier_id) + 1, tiers.size() - 1)]["id"]


## One tier down, except from the bottom tier and from a floor tier.
static func relegate_tier(cfg: Dictionary, tier_id: String) -> String:
	if is_floor(cfg, tier_id):
		return tier_id
	var tiers: Array = cfg["tiers"]
	return tiers[maxi(tier_index(cfg, tier_id) - 1, 0)]["id"]


static func is_global(cfg: Dictionary, tier_id: String) -> bool:
	return bool(tier(cfg, tier_id).get("global", false))


static func is_floor(cfg: Dictionary, tier_id: String) -> bool:
	return bool(tier(cfg, tier_id).get("floor", false))


static func is_capped(cfg: Dictionary, tier_id: String) -> bool:
	return tier(cfg, tier_id).has("max_slots")


static func up_mode(cfg: Dictionary, tier_id: String) -> String:
	return str(tier(cfg, tier_id).get("up_mode", UP_MODE_PCT))


## Tier points needed to leave a score-mode tier, 0 for every other tier.
static func promo_score(tier_cfg: Dictionary) -> int:
	if str(tier_cfg.get("up_mode", UP_MODE_PCT)) != UP_MODE_SCORE:
		return 0
	return maxi(0, int(tier_cfg.get("promo_score", 0)))


## Whether `tier_points` promote out of a score-mode tier.
static func reaches_promo(tier_cfg: Dictionary, tier_points: int) -> bool:
	var need := promo_score(tier_cfg)
	return need > 0 and tier_points >= need


# --- rounds -----------------------------------------------------------------

## Days per round; 0 for a tier without rounds. A missing key means 7.
static func round_days(cfg: Dictionary, tier_id: String) -> int:
	return maxi(0, int(tier(cfg, tier_id).get("round_days", 7)))


## Whether the tier plays in timed rounds at all (not Bronze, not Silver).
static func has_rounds(cfg: Dictionary, tier_id: String) -> bool:
	return round_days(cfg, tier_id) > 0


static func round_seconds(cfg: Dictionary, tier_id: String) -> int:
	return round_days(cfg, tier_id) * DAY_SECONDS


## Index of the round of `tier_id` that contains `unix_time`. A tier without
## rounds lives in round 0 forever.
static func round_index(cfg: Dictionary, tier_id: String, unix_time: int) -> int:
	if not has_rounds(cfg, tier_id):
		return 0
	return int(floor(float(unix_time - ROUND_EPOCH_OFFSET) / round_seconds(cfg, tier_id)))


## 0 for a tier without rounds: it has neither a start nor an end.
static func round_start(cfg: Dictionary, tier_id: String, index: int) -> int:
	if not has_rounds(cfg, tier_id):
		return 0
	return index * round_seconds(cfg, tier_id) + ROUND_EPOCH_OFFSET


static func round_end(cfg: Dictionary, tier_id: String, index: int) -> int:
	if not has_rounds(cfg, tier_id):
		return 0
	return round_start(cfg, tier_id, index + 1)


# --- groups, bots and the online rule ---------------------------------------

## Random placement fills a group to this many humans.
static func group_size(cfg: Dictionary) -> int:
	return maxi(1, int(cfg.get("group_size", 30)))


## Friends of a member may join a group up to this many humans.
static func group_max(cfg: Dictionary) -> int:
	return maxi(group_size(cfg), int(cfg.get("group_max", group_size(cfg))))


static func online_required(cfg: Dictionary, tier_id: String) -> bool:
	return bool(tier(cfg, tier_id).get("online_required", false))


## Whether a completed game counts toward the league. Every game counts in a
## tier without `online_required`, however late it is synced; in one with it,
## the game must have been started with a server session and must reach the
## server within `online_grace_s` of finishing. `finished_at` is already
## clamped to the server clock.
static func counts_for_league(cfg: Dictionary, tier_id: String, has_session: bool, finished_at: int, received_at: int) -> bool:
	if not online_required(cfg, tier_id):
		return true
	if not has_session:
		return false
	return received_at - finished_at <= int(cfg.get("online_grace_s", 600))


## Bots topping a group of `humans` up to the tier's `bots.fill_to`; 0 in a
## tier without bots and in a group that is already full of people.
static func bot_count(tier_cfg: Dictionary, humans: int) -> int:
	var bots: Dictionary = tier_cfg.get("bots", {})
	if bots.is_empty():
		return 0
	return maxi(0, int(bots.get("fill_to", 0)) - humans)


const _PM_MOD := 2147483647
const _PM_MUL := 48271


## One step of the Park-Miller generator. x stays below 2^31, so the product
## stays below 2^47 and the arithmetic is exact in both runtimes.
static func _pm(x: int) -> int:
	return (x * _PM_MUL) % _PM_MOD


## The seed of the bot in `slot` of a group whose seed is `group_seed`.
static func bot_seed(group_seed: int, slot: int) -> int:
	return posmod(group_seed, _PM_MOD) * 131 + slot * 7919


## A bot's display name, distinct for every slot of one group as long as the
## group holds fewer bots than there are names.
static func bot_nickname(cfg: Dictionary, group_seed: int, slot: int) -> String:
	var names: Array = cfg.get("bot_names", [])
	if names.is_empty():
		return "Player %d" % (slot + 1)
	return str(names[posmod(group_seed + slot, names.size())])


## What a bot has played by `t` in a round running from `round_start` to
## `round_end`: {round_score, games, last_submit_at}. Deterministic in `bot`
## (a bot_seed()) and integer-only, so the server and the client agree to the
## point; monotone in `t` and final at the end of the round. A bot plays 1 to
## `games_max` games, skewed towards few, spread evenly from a random point in
## the first 40 % of the round (the first game is played right there) to just
## before its end, each worth `game_score` scaled by a per-bot skill of
## 60..140 % and a per-game 85..115 %.
static func bot_progress(tier_cfg: Dictionary, cfg: Dictionary, bot: int, round_start: int, round_end: int, t: int) -> Dictionary:
	var bots: Dictionary = tier_cfg.get("bots", {})
	var games_max := maxi(1, int(bots.get("games_max", 15)))
	var game_score := maxi(0, int(bots.get("game_score", 400)))
	# Two warm-up steps: neighbouring seeds give neighbouring first outputs, and
	# only after the product has wrapped the modulus twice are they unrelated.
	var x := _pm(_pm(posmod(bot, _PM_MOD - 1) + 1))
	x = _pm(x)
	var activity := x % 100
	x = _pm(x)
	var skill := 60 + x % 81
	x = _pm(x)
	var start_pct := x % 40
	@warning_ignore("integer_division")
	var total := 1 + activity * activity * (games_max - 1) / 9801
	var length := maxi(0, round_end - round_start)
	var scores: Array = []
	var last := 0
	for k in total:
		x = _pm(x)
		@warning_ignore("integer_division")
		var at := round_start + length * (start_pct * total + (100 - start_pct) * k) / (100 * total)
		if at > t:
			break
		@warning_ignore("integer_division")
		scores.append(game_score * skill * (85 + x % 31) / 10000)
		last = at
	return {"round_score": round_score(scores, cfg), "games": scores.size(), "last_submit_at": last}


# --- capped top tier --------------------------------------------------------

## Slots of a capped tier given the population of the tier below it, or -1
## when the tier is not capped.
static func slots(cfg: Dictionary, tier_id: String, below_players: int) -> int:
	var t := tier(cfg, tier_id)
	if not t.has("max_slots"):
		return -1
	var per_slot := maxi(1, int(t.get("players_per_slot", 10)))
	@warning_ignore("integer_division")
	return clampi(below_players / per_slot, int(t.get("min_slots", 1)), int(t["max_slots"]))


## Slots of the capped tier that are free after its own relegation: what the
## tier below may promote. `members_in_tier` is the current population of
## the capped tier, `below_players` the population of the tier below.
static func openings(cfg: Dictionary, tier_id: String, below_players: int, members_in_tier: int) -> int:
	var total := slots(cfg, tier_id, below_players)
	if total < 0:
		return 0
	var leaving: int = counts(members_in_tier, tier(cfg, tier_id), cfg, 0)["down"]
	return maxi(0, total - (members_in_tier - leaving))


# --- scores and ranking -----------------------------------------------------

## Sum of the best N game scores of the round (or the plain sum in "sum" mode).
static func round_score(scores: Array, cfg: Dictionary) -> int:
	var total := 0
	if str(cfg.get("round_mode", "best_n")) == "sum":
		for s in scores:
			total += int(s)
		return total
	var sorted := scores.duplicate()
	sorted.sort()
	sorted.reverse()
	var n := mini(int(cfg.get("round_best_n", 15)), sorted.size())
	for i in n:
		total += int(sorted[i])
	return total


## The score a new game must beat to raise the round score: the lowest of the
## counted best N once N games are in, 0 before that (every game counts) and
## always 0 in "sum" mode.
static func cut_score(scores: Array, cfg: Dictionary) -> int:
	if str(cfg.get("round_mode", "best_n")) == "sum":
		return 0
	var n := int(cfg.get("round_best_n", 15))
	if n <= 0 or scores.size() < n:
		return 0
	var sorted := scores.duplicate()
	sorted.sort()
	sorted.reverse()
	return int(sorted[n - 1])


## Higher score first, then fewer games (more efficient), then earlier submit,
## then player id.
##
## The last key looks redundant and is not: sort_custom is an introsort and is
## not stable, so two members with an identical (score, games, submit time) come
## out in an arbitrary order, and rank can flip between two calls -- across a
## promotion boundary, for a real player. It only orders pairs the first three
## keys call equal, so nothing else changes.
static func sort_members(members: Array) -> Array:
	var sorted := members.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["round_score"]) != int(b["round_score"]):
			return int(a["round_score"]) > int(b["round_score"])
		if int(a.get("games", 0)) != int(b.get("games", 0)):
			return int(a.get("games", 0)) < int(b.get("games", 0))
		if int(a.get("last_submit_at", 0)) != int(b.get("last_submit_at", 0)):
			return int(a.get("last_submit_at", 0)) < int(b.get("last_submit_at", 0))
		return str(a.get("player_id", "")) < str(b.get("player_id", "")))
	return sorted


## How many go up and down in a group of `n` whose leader scored
## `leader_score`. `up_count` >= 0 replaces the tier's percentage with a
## fixed number (the openings of a capped tier above). A score-mode tier
## promotes nobody at the end of a round, whatever its `up_pct` says.
static func counts(n: int, tier_cfg: Dictionary, cfg: Dictionary, leader_score: int, up_count: int = -1) -> Dictionary:
	if n <= 0:
		return {"up": 0, "down": 0}
	var by_score := promo_score(tier_cfg) > 0
	var wants_up := (up_count > 0 if up_count >= 0 else int(tier_cfg.get("up_pct", 0)) > 0) and not by_score
	if n < int(cfg.get("min_group_size", 5)):
		var up_tiny := 1 if leader_score >= int(tier_cfg.get("min_promo_score", 0)) and wants_up else 0
		return {"up": up_tiny, "down": 0}
	var up := 0
	if not by_score:
		up = mini(up_count, n) if up_count >= 0 else int(round(int(tier_cfg.get("up_pct", 0)) / 100.0 * n))
	var down := int(round(int(tier_cfg.get("down_pct", 0)) / 100.0 * n))
	if up + down > n:
		down = n - up
	return {"up": up, "down": down}


## Ranks the members and assigns zones. Returns
## {members: [sorted with rank + zone], promote_count, relegate_count}.
## `up_count` >= 0 fixes the number of promotions (see counts()).
static func evaluate(members: Array, tier_id: String, cfg: Dictionary, up_count: int = -1) -> Dictionary:
	var sorted := sort_members(members)
	var n := sorted.size()
	var tier_cfg := tier(cfg, tier_id)
	var leader := int(sorted[0]["round_score"]) if n > 0 else 0
	var c := counts(n, tier_cfg, cfg, leader, up_count)
	var promoted := 0
	for i in n:
		var m: Dictionary = sorted[i]
		m["rank"] = i + 1
		if i < int(c["up"]) and int(m["round_score"]) > 0:
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


## A round without a game: frozen in place, or relegated where the tier says
## so. A floor tier never relegates, whatever it says.
static func inactive_outcome(tier_cfg: Dictionary) -> String:
	if bool(tier_cfg.get("floor", false)):
		return OUTCOME_INACTIVE_FROZEN
	return OUTCOME_INACTIVE_RELEGATED if str(tier_cfg.get("inactive", "stay")) == "relegate" else OUTCOME_INACTIVE_FROZEN


## The tier a player is in after `outcome`.
static func apply(cfg: Dictionary, tier_id: String, outcome: String) -> String:
	match outcome:
		OUTCOME_PROMOTED:
			return promote_tier(cfg, tier_id)
		OUTCOME_RELEGATED, OUTCOME_INACTIVE_RELEGATED:
			return relegate_tier(cfg, tier_id)
	return tier_id


## "Top 20 % promote · bottom 20 % relegate". `up_count` >= 0 names a fixed
## number of promotions ("Top 3 promote to Challenger"); a score-mode tier
## reads "Reach 3000 points to promote to Silver". `up_to` is the name of
## the tier above, shown only in those two cases.
static func rules_text(tier_cfg: Dictionary, up_count: int = -1, up_to: String = "") -> String:
	var parts: Array = []
	var named := up_to != ""
	if promo_score(tier_cfg) > 0:
		if named:
			parts.append(Loc.f("RULES_PROMO_SCORE_TO", [promo_score(tier_cfg), up_to]))
		else:
			parts.append(Loc.f("RULES_PROMO_SCORE", [promo_score(tier_cfg)]))
	elif up_count >= 0:
		if up_count > 0:
			parts.append(Loc.f("RULES_UP_N_TO", [up_count, up_to]) if named else Loc.f("RULES_UP_N", [up_count]))
		else:
			parts.append(Loc.f("RULES_NO_SLOT_IN", [up_to]) if named else Loc.t("RULES_NO_SLOT"))
	elif int(tier_cfg.get("up_pct", 0)) > 0:
		parts.append(Loc.f("RULES_UP_PCT", [int(tier_cfg["up_pct"])]))
	if int(tier_cfg.get("down_pct", 0)) > 0:
		parts.append(Loc.f("RULES_DOWN_PCT", [int(tier_cfg["down_pct"])]))
	elif bool(tier_cfg.get("floor", false)):
		parts.append(Loc.t("RULES_DOWN_FLOOR"))
	else:
		parts.append(Loc.t("RULES_DOWN_NONE"))
	var text := " · ".join(parts)
	return text.substr(0, 1).to_upper() + text.substr(1)
