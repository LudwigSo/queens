class_name Views
extends RefCounted
## Builds the structured view dictionaries the screens render. Pure static
## functions over plain data, so tests can cover every wording branch
## without a scene tree.


# --- shared pieces ------------------------------------------------------------------

## LeagueStanding -> the summary the home card and the win overlay show.
## `promo_text` ("1240 / 3000 pts to Silver") is set only in a tier that
## promotes by tier points.
static func league_summary(standing: Dictionary, now: int) -> Dictionary:
	var group: Dictionary = standing.get("group", {})
	var rules: Dictionary = standing.get("rules", {})
	var need := int(rules.get("promo_score", 0))
	var points_now := int(standing.get("my_tier_points", 0))
	var next_tier := str(rules.get("up_to", ""))
	return {
		"tier_id": str(standing.get("tier", standing.get("tier_id", "bronze"))),
		"tier_name": LeagueRules.tier_label(str(standing.get("tier", standing.get("tier_id", "bronze")))),
		"joined": bool(standing.get("joined", false)),
		"rank": int(standing.get("my_rank", 0)),
		"size": int(group.get("size", 0)),
		"zone": str(standing.get("zone", "safe")),
		"score": int(standing.get("my_round_score", 0)),
		"tier_points": points_now,
		"promo_score": need,
		"next_tier_name": next_tier,
		"promo_text": Fmt.progress(points_now, need, next_tier) if need > 0 else "",
		"ends_in_s": int(standing.get("round_ends_at", 0)) - now,
		"ends_in_text": Cooldown.format_remaining(int(standing.get("round_ends_at", 0)) - now),
	}


## One difficulty option for the home cards / win overlay.
static func option(step: int, pick: Dictionary, catalog: LevelCatalog) -> Dictionary:
	var lv: Dictionary = pick.get("level", {})
	var reason := str(pick.get("reason", "none"))
	if lv.is_empty():
		var text := Loc.t("HOME_OPT_ALL_COOLING")
		match reason:
			"none_harder":
				text = Loc.t("HOME_OPT_NO_HARDER")
			"none_easier":
				text = Loc.t("HOME_OPT_NO_EASIER")
		return {"step": step, "enabled": false, "reason": text, "level_id": ""}
	return {
		"step": step,
		"enabled": true,
		"reason": Loc.t("HOME_OPT_NEAREST") if reason == "nearest" else "",
		"level_id": str(lv["id"]),
		"level_no": catalog.display_index(str(lv["id"])) + 1,
		"size": int(lv["size"]),
		"difficulty": int(lv["difficulty"]),
		"stars": int(lv.get("stars", 0)),
	}


static func best_text(save: SaveData, level_id: String) -> String:
	if save.has_best_score(level_id):
		var entry := save.level_entry(level_id)
		var wrong := int(entry.get("best_wrong", 0))
		return Loc.f("DETAIL_BEST_SCORE", [Fmt.points(int(entry["best_score"])), Loc.t("MISTAKES_ZERO") if wrong == 0 else Fmt.time(save.best_time(level_id))])
	if save.has_best(level_id):
		return Loc.f("DETAIL_BEST_TIME", [Fmt.time(save.best_time(level_id))])
	return ""


# --- screens ----------------------------------------------------------------------------

static func home(save: SaveData, catalog: LevelCatalog, energy: EnergyLedger, standing: Dictionary, options: Array, now: int) -> Dictionary:
	var last := save.last_game()
	var view := {
		"nickname": save.nickname(),
		"energy": {"amount": energy.amount(), "unlimited": energy.is_unlimited()},
		"league": league_summary(standing, now),
		"streak": {"days": save.streak_days(now)},
		"last": {},
		"options": options,
	}
	if not last.is_empty():
		var lv := catalog.get_level(str(last["level_id"]))
		if lv.is_empty():
			view["last"] = {"level_no": 0, "size": 0, "difficulty": int(last["difficulty"]), "stars": 0}
		else:
			view["last"] = {"level_no": catalog.display_index(str(lv["id"])) + 1, "size": int(lv["size"]), "difficulty": int(lv["difficulty"]), "stars": int(lv.get("stars", 0))}
	return view


static func level_card(lv: Dictionary, save: SaveData, catalog: LevelCatalog, now: int, cooldown_seconds: int) -> Dictionary:
	var id := str(lv["id"])
	var entry := save.level_entry(id)
	var remaining := Cooldown.remaining(entry, now, cooldown_seconds)
	return {
		"id": id,
		"level_no": catalog.display_index(id) + 1,
		"size": int(lv["size"]),
		"difficulty": int(lv["difficulty"]),
		"stars": int(lv.get("stars", 0)),
		"regions": lv["regions"],
		"locked": remaining > 0,
		"lock_text": Cooldown.format_remaining(remaining) if remaining > 0 else "",
		"best_text": best_text(save, id),
		"played": int(entry.get("plays", 0)) > 0,
	}


static func level_cards(levels: Array, save: SaveData, catalog: LevelCatalog, now: int, cooldown_seconds: int) -> Array:
	var cards: Array = []
	for lv in levels:
		cards.append(level_card(lv, save, catalog, now, cooldown_seconds))
	return cards


static func level_detail(lv: Dictionary, board_data: Dictionary, scope: String, save: SaveData, catalog: LevelCatalog, now: int, cooldown_seconds: int) -> Dictionary:
	var id := str(lv["id"])
	var entries: Array = []
	for e in board_data.get("entries", []):
		var row: Dictionary = e.duplicate()
		row["time_text"] = Fmt.time(float(e.get("time_seconds", 0.0)))
		entries.append(row)
	var mine: Dictionary = board_data.get("my_entry", {})
	var mine_view := {}
	if not mine.is_empty():
		mine_view = {
			"score": int(mine.get("score", 0)),
			"time_text": Fmt.time(float(mine.get("time_seconds", 0.0))),
			"mistakes": int(mine.get("wrong_placements", 0)),
			"rank": int(board_data.get("my_rank", 0)),
		}
	var remaining := Cooldown.remaining(save.level_entry(id), now, cooldown_seconds)
	return {
		"level_id": id,
		"level_no": catalog.display_index(id) + 1,
		"size": int(lv["size"]),
		"difficulty": int(lv["difficulty"]),
		"stars": int(lv.get("stars", 0)),
		"regions": lv["regions"],
		"par_text": Fmt.time(float(board_data.get("par_seconds", Scoring.par_seconds(float(lv["difficulty"]), int(lv["size"]))))),
		"players": int(board_data.get("total_players", 0)),
		"mine": mine_view,
		"scope": scope,
		"entries": entries,
		"lock_text": Cooldown.format_remaining(remaining) if remaining > 0 else "",
	}


## Win overlay. `outcome` is App.record_result's answer, `next` the step ->
## option dictionaries for the next game.
static func win(result: GameResult, bd: Dictionary, outcome: Dictionary, next: Dictionary, league_cfg: Dictionary, completions: int) -> Dictionary:
	var badges: Array = []
	var new_best := Loc.t("WIN_BADGE_NEW_BEST")
	if bd["flawless"]:
		badges.append(Loc.t("WIN_BADGE_FLAWLESS"))
	if bool(outcome.get("best_score_improved", false)) and completions > 1:
		badges.append(new_best)
	if bool(outcome.get("best_time_improved", false)) and completions > 1 and not badges.has(new_best):
		badges.append(Loc.t("WIN_BADGE_FASTEST"))
	if result.elapsed_seconds > 0.0 and result.elapsed_seconds < bd["par_seconds"]:
		badges.append(Loc.t("WIN_BADGE_UNDER_PAR"))
	var stats := [
		{"label": Loc.t("WIN_STAT_TIME"), "value": Fmt.time(result.elapsed_seconds)},
		{"label": Loc.t("WIN_STAT_PAR"), "value": Fmt.time(float(bd["par_seconds"]))},
		{"label": Loc.t("WIN_STAT_MISTAKES"), "value": str(result.wrong_placements)},
		{"label": Loc.t("WIN_STAT_UNDOS"), "value": str(result.undo_count)},
	]
	if result.hint_count > 0:
		stats.append({"label": Loc.t("WIN_STAT_HINTS"), "value": str(result.hint_count)})
	var factors := [
		{"id": "accuracy", "value": float(bd["accuracy_factor"]), "pct": float(bd["accuracy_factor"])},
		{"id": "speed", "value": float(bd["speed_factor"]), "pct": float(bd["speed_factor"]) / Scoring.SPEED_MAX},
		{"id": "undo", "value": float(bd["undo_factor"]), "pct": float(bd["undo_factor"])},
	]
	if result.hint_count > 0:
		factors.append({"id": "hint", "value": float(bd.get("hint_factor", 1.0)), "pct": float(bd.get("hint_factor", 1.0))})
	var league := {}
	var lg: Dictionary = outcome.get("league", {})
	if not lg.is_empty():
		var tier := str(lg.get("tier", "bronze"))
		var need := int(lg.get("promo_score", 0))
		var points_now := int(lg.get("tier_points", 0))
		var promoted_to := str(lg.get("promoted_to", ""))
		var above := LeagueRules.promote_tier(league_cfg, tier)
		league = {
			"tier_id": tier,
			"tier_name": LeagueRules.tier_name(league_cfg, tier),
			"score": int(lg.get("round_score", 0)),
			"rank": int(lg.get("group_rank", 0)),
			"size": int(lg.get("group_size", 0)),
			"zone": str(lg.get("zone", "safe")),
			"tier_points": points_now,
			"promo_score": need,
			"promo_text": Fmt.progress(points_now, need, LeagueRules.tier_name(league_cfg, above) if above != tier else "") if need > 0 else "",
			"promoted_to": promoted_to,
			"promoted_to_name": LeagueRules.tier_name(league_cfg, promoted_to) if promoted_to != "" else "",
		}
	var next_view := {}
	for step in next:
		var opt: Dictionary = next[step]
		next_view[str(step)] = {"size": int(opt.get("size", 0)), "enabled": bool(opt.get("enabled", false))}
	return {
		"score": result.score,
		"base": int(bd["base"]),
		"badges": badges,
		"stats": stats,
		"factors": factors,
		"league": league,
		"next": next_view,
	}


static func energy_state(energy: EnergyLedger, ads: AdsProvider, purchases: PurchaseProvider, ad_reward: int, price_text: String) -> Dictionary:
	return {
		"energy_text": energy.display_text(),
		"amount": energy.amount(),
		"unlimited": energy.is_unlimited(),
		"can_start": energy.can_start(),
		"ad_ready": ads.is_ready(),
		"ad_reward": ad_reward,
		"price_text": price_text,
		"purchases_available": purchases.is_available(),
	}
