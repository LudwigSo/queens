class_name OfflineLeague
extends RefCounted
## What the client can tell about the league without the server: the games
## waiting in the offline queue, added on top of the last standing and run
## overview the server sent. Nothing here is authoritative. It is what the
## player sees until the queue is synced, so their own score keeps moving
## while the ranking waits.
##
## In a tier with `online_required` (Diamond, Challenger) a queued game will
## never count, so it is listed but adds nothing.


## A queued GameResult dictionary as a Run (see Backend).
static func pending_run(result: Dictionary, counts: bool) -> Dictionary:
	var bd := Scoring.breakdown(result)
	return {
		"result_id": str(result.get("result_id", "")), "level_id": str(result.get("level_id", "")),
		"size": int(result.get("size", 0)), "difficulty": float(result.get("difficulty", 0.0)),
		"stars": int(result.get("stars", 0)), "score": int(bd["score"]), "counted": counts, "in_best": false,
		"verified": false, "finished_at": int(result.get("finished_at", 0)),
		"elapsed_seconds": float(result.get("elapsed_seconds", 0.0)), "par_seconds": float(bd["par_seconds"]),
		"wrong_placements": int(result.get("wrong_placements", 0)), "hint_count": int(result.get("hint_count", 0)),
		"breakdown": bd, "pending": true,
	}


## The completed games in `pending` that the server has not seen.
static func pending_games(pending: Array) -> Array:
	var out: Array = []
	for p in pending:
		if p is Dictionary and bool((p as Dictionary).get("completed", false)):
			out.append(p)
	return out


## Higher score first, then the earlier game, like the server's list.
static func _run_before(a: Dictionary, b: Dictionary) -> bool:
	if int(a.get("score", 0)) != int(b.get("score", 0)):
		return int(a.get("score", 0)) > int(b.get("score", 0))
	return int(a.get("finished_at", 0)) < int(b.get("finished_at", 0))


## `runs` is the last RoundRuns the server sent ({} when there is none yet),
## `standing` the last LeagueStanding, `pending` the offline queue. Returns a
## RoundRuns with the queued games merged in, the best N marked again and the
## round score, cut and tier points recomputed.
static func merge_runs(runs: Dictionary, standing: Dictionary, pending: Array, cfg: Dictionary) -> Dictionary:
	var tier := str(runs.get("tier", standing.get("tier", "bronze")))
	var has_rounds := LeagueRules.has_rounds(cfg, tier)
	var counts := not LeagueRules.online_required(cfg, tier)
	var out := runs.duplicate(true)
	var from_scratch := out.is_empty()
	if from_scratch:
		out = {
			"tier": tier, "round_index": int(standing.get("round_index", 0)), "has_rounds": has_rounds,
			"round_ends_at": int(standing.get("round_ends_at", 0)),
			"best_n": int(cfg.get("round_best_n", 15)) if has_rounds else 0,
			"round_score": int(standing.get("my_round_score", 0)),
			"tier_points": int(standing.get("my_tier_points", 0)), "cut_score": 0, "runs": [],
		}
	var list: Array = out.get("runs", [])
	var known := {}
	for r in list:
		known[str(r.get("result_id", ""))] = true
	var added := 0
	for r in pending_games(pending):
		if known.has(str(r.get("result_id", ""))):
			continue
		var run := pending_run(r, counts)
		list.append(run)
		if counts:
			added += int(run["score"])
	list.sort_custom(_run_before)
	var best_n := int(out.get("best_n", 0))
	var counted_scores: Array = []
	var in_best := 0
	for run in list:
		run["in_best"] = false
		if bool(run.get("counted", true)):
			counted_scores.append(int(run["score"]))
			if not has_rounds or in_best < best_n:
				run["in_best"] = true
				in_best += 1
	out["runs"] = list
	out["tier_points"] = int(out.get("tier_points", 0)) + added
	if has_rounds:
		if from_scratch:
			# Without the server's list the best-N cut is unknown: add the
			# queued games on top, the best guess there is.
			out["round_score"] = int(out["round_score"]) + added
		else:
			out["round_score"] = LeagueRules.round_score(counted_scores, cfg)
			out["cut_score"] = LeagueRules.cut_score(counted_scores, cfg)
	return out


## The last LeagueStanding with my own numbers moved by the queued games, and
## `offline` set so the screens know the ranking is not live.
static func estimate_standing(standing: Dictionary, merged_runs: Dictionary) -> Dictionary:
	var out := standing.duplicate(true)
	out["offline"] = true
	out["my_tier_points"] = int(merged_runs.get("tier_points", out.get("my_tier_points", 0)))
	if bool(out.get("joined", false)) and bool(merged_runs.get("has_rounds", true)):
		out["my_round_score"] = int(merged_runs.get("round_score", out.get("my_round_score", 0)))
		var group: Dictionary = out.get("group", {})
		for m in group.get("members", []):
			if bool(m.get("is_me", false)):
				m["round_score"] = out["my_round_score"]
	return out
