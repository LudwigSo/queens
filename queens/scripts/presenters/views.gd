class_name Views
extends RefCounted
## Builds the structured view dictionaries the screens render. Pure static
## functions over plain data, so tests can cover every wording branch
## without a scene tree.


# --- shared pieces ------------------------------------------------------------------

## LeagueStanding -> the summary the home card and the win overlay show.
## `promo_text` ("1240 / 3000 pts to Silver") is set only in a tier that
## promotes by tier points.
## Fills in everything the league screen used to get from the backend: the tier
## names and the rule sentence. A server has no locale and must not carry a copy
## of the translations, so it sends ids and numbers and this turns them into
## words.
static func league_screen(standing: Dictionary, friends: Array, league_cfg: Dictionary) -> Dictionary:
	var out := standing.duplicate(true)
	var tier_id := str(out.get("tier", "bronze"))
	out["tier_name"] = LeagueRules.tier_label(tier_id)
	var rules: Dictionary = out.get("rules", {})
	var up_to := str(rules.get("up_to", ""))
	var up_to_name := LeagueRules.tier_label(up_to) if up_to != "" else ""
	rules["up_to_name"] = up_to_name
	out["rules"] = rules
	var tier_cfg: Dictionary = LeagueRules.tier(league_cfg, tier_id)
	out["rules_text"] = LeagueRules.rules_text(tier_cfg, int(rules.get("up_count", -1)), up_to_name)
	var friend_views: Array = []
	for fr in friends:
		var f: Dictionary = (fr as Dictionary).duplicate(true)
		f["tier_name"] = LeagueRules.tier_label(str(f.get("tier", "")))
		friend_views.append(f)
	return {"standing": out, "friends": friend_views}


static func league_summary(standing: Dictionary, now: int) -> Dictionary:
	var group: Dictionary = standing.get("group", {})
	var rules: Dictionary = standing.get("rules", {})
	var need := int(rules.get("promo_score", 0))
	var points_now := int(standing.get("my_tier_points", 0))
	# up_to is a tier id; the name is ours to build.
	var next_tier := LeagueRules.tier_label(str(rules.get("up_to", ""))) if str(rules.get("up_to", "")) != "" else ""
	return {
		"has_rounds": int(rules.get("round_days", standing.get("round_days", 7))) > 0,
		"offline": bool(standing.get("offline", false)),
		"online_required": bool(rules.get("online_required", false)),
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
		"energy": {"amount": energy.amount(), "unlimited": energy.is_unlimited(), "debt": energy.debt()},
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
## option dictionaries for the next game. `offline_tier` is the player's tier
## when the game could not be sent: the league card then says what happens to
## it instead of showing a rank.
static func win(result: GameResult, bd: Dictionary, outcome: Dictionary, next: Dictionary, league_cfg: Dictionary, completions: int, offline_tier: String = "") -> Dictionary:
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
		{"label": Loc.t("WIN_STAT_BASE"), "value": str(int(bd["base"]))},
		{"label": Loc.t("WIN_STAT_TIME"), "value": Fmt.time(result.elapsed_seconds)},
		{"label": Loc.t("WIN_STAT_PAR"), "value": Fmt.time(float(bd["par_seconds"]))},
		{"label": Loc.t("WIN_STAT_MISTAKES"), "value": str(result.wrong_placements)},
	]
	if result.hint_count > 0:
		stats.append({"label": Loc.t("WIN_STAT_HINTS"), "value": str(result.hint_count)})
	var factors := [
		{"id": "accuracy", "value": float(bd["accuracy_factor"]), "pct": float(bd["accuracy_factor"])},
		{"id": "speed", "value": float(bd["speed_factor"]), "pct": float(bd["speed_factor"]) / Scoring.SPEED_MAX},
	]
	if result.hint_count > 0:
		factors.append({"id": "hint", "value": float(bd.get("hint_factor", 1.0)), "pct": float(bd.get("hint_factor", 1.0))})
	var league := {}
	var lg: Dictionary = outcome.get("league", {})
	if lg.is_empty() and offline_tier != "":
		var strict := LeagueRules.online_required(league_cfg, offline_tier)
		league = {
			"tier_id": offline_tier,
			"note": Loc.f("WIN_OFFLINE_STRICT", [LeagueRules.tier_name(league_cfg, offline_tier)]) if strict else Loc.t("WIN_OFFLINE"),
		}
	elif not lg.is_empty() and not bool(lg.get("counted", true)):
		var tier_id := str(lg.get("tier", "bronze"))
		league = {"tier_id": tier_id, "note": Loc.f("WIN_NOT_COUNTED", [LeagueRules.tier_name(league_cfg, tier_id)])}
	elif not lg.is_empty():
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


## The run overview tab of the league screen. `runs` is a RoundRuns (offline,
## with the queued games merged in). Every row says whether it counts, and the
## lowest counted one is marked as the score to beat, so a glance tells how
## much the next game needs.
static func runs(runs_data: Dictionary, catalog: LevelCatalog) -> Dictionary:
	var has_rounds := bool(runs_data.get("has_rounds", true))
	var best_n := int(runs_data.get("best_n", 0))
	var cut := int(runs_data.get("cut_score", 0))
	var list: Array = runs_data.get("runs", [])
	var counted := 0
	var counted_points := 0
	for r in list:
		if bool(r.get("in_best", false)):
			counted += 1
			counted_points += int(r.get("score", 0))
	var header := ""
	if not has_rounds:
		header = Loc.t("RUNS_ALL_COUNT")
	elif cut > 0:
		header = Loc.f("RUNS_BEAT", [cut])
	else:
		header = Loc.f("RUNS_FILLING", [best_n, counted])
	var rows: Array = []
	var cut_marked := false
	# The last counted row in the list is the one to beat: the list is best first.
	var last_best := -1
	for i in list.size():
		if bool(list[i].get("in_best", false)):
			last_best = i
	for i in list.size():
		var r: Dictionary = list[i]
		var level_id := str(r.get("level_id", ""))
		var level_no := catalog.display_index(level_id) + 1 if catalog != null and level_id != "" else 0
		var state := "best" if bool(r.get("in_best", false)) else "extra"
		if not bool(r.get("counted", true)):
			state = "offline"
		var tags: Array = []
		if has_rounds and cut > 0 and i == last_best and not cut_marked:
			state = "cut"
			cut_marked = true
			tags.append(Loc.t("RUNS_CUT"))
		if bool(r.get("pending", false)):
			tags.append(Loc.t("RUNS_PENDING"))
		if state == "offline":
			tags.append(Loc.t("RUNS_OFFLINE_GAME"))
		rows.append({
			"result_id": str(r.get("result_id", "")),
			"title": Loc.f("RUNS_ROW", [level_no, Fmt.size_text(int(r.get("size", 0)))]),
			"diff_text": Loc.f("RUNS_ROW_DIFF", [int(r.get("difficulty", 0))]),
			"stars": int(r.get("stars", 0)),
			"score": int(r.get("score", 0)),
			"state": state,
			"tags": tags,
		})
	var empty_text := ""
	if list.is_empty():
		empty_text = Loc.t("RUNS_EMPTY") if has_rounds else Loc.t("RUNS_EMPTY_TIER")
	return {
		"header": header,
		"counted_title": Loc.f("RUNS_COUNTED", [counted_points if not has_rounds else int(runs_data.get("round_score", counted_points))]),
		"rows": rows,
		"empty_text": empty_text,
		"has_rounds": has_rounds,
	}


## The win overlay again, for one run of the overview: the same score panel,
## the level it was, no next-game choice.
static func run_detail(run: Dictionary, catalog: LevelCatalog, league_cfg: Dictionary) -> Dictionary:
	var result := GameResult.from_dict(run)
	result.score = int(run.get("score", 0))
	var bd: Dictionary = run.get("breakdown", {})
	if bd.is_empty():
		bd = Scoring.breakdown(run)
	var view := win(result, bd, {}, {}, league_cfg, 0)
	var level_id := str(run.get("level_id", ""))
	var level_no := catalog.display_index(level_id) + 1 if level_id != "" else 0
	var size := int(run.get("size", 0))
	view["level_text"] = Loc.f("COMMON_LEVEL_TITLE", [level_no, size, size, int(run.get("difficulty", 0))])
	view["stars"] = int(run.get("stars", 0))
	return view


static func energy_state(energy: EnergyLedger, ads: AdsProvider, purchases: PurchaseProvider, ad_reward: int, price_text: String,
		offline: bool = false, min_playable: int = 2) -> Dictionary:
	return {
		"energy_text": energy.display_text() + ("  " + energy.debt_text() if energy.debt() > 0 else ""),
		"amount": energy.amount(),
		"debt": energy.debt(),
		"offline": offline,
		"repay_per_ad": maxi(0, ad_reward - min_playable),
		"min_playable": min_playable,
		"unlimited": energy.is_unlimited(),
		"can_start": energy.can_start(offline),
		"ad_ready": ads.is_ready(),
		"ad_reward": ad_reward,
		"price_text": price_text,
		"purchases_available": purchases.is_available(),
	}
