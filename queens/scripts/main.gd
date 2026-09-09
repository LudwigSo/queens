extends Control
## Screen router: home -> game -> solved overlay, with the level overview,
## level detail, league screen and the dialogs on the side. Screens are
## sub-scenes that only emit intents; this script talks to the App autoload
## (save, config, catalog, picker, energy, backend) and owns the running
## GameSession.

const DEFAULT_HINT := "Tap once to mark X, tap again to place a queen, tap again to clear."

@onready var home: Control = $Home
@onready var level_select: Control = $LevelSelect
@onready var level_detail: Control = $LevelDetail
@onready var league: Control = $League
@onready var game_screen: Control = $Game
@onready var board: Board = game_screen.board
@onready var win_overlay: Control = $WinOverlay
@onready var week_summary: Control = $WeekSummary
@onready var energy_dialog: Control = $EnergyDialog
@onready var message_dialog: Control = $MessageDialog

var levels: Array = []          ## Level dictionaries, see scripts/levels.gd.
var current_level: int = -1
var session: GameSession = null ## The running game, null between games.
var detail_scope: String = "global"


func _ready() -> void:
	levels = App.catalog.levels
	home.play_requested.connect(_play_step)
	home.overview_requested.connect(_show_level_select)
	home.league_requested.connect(_show_league)
	home.energy_pressed.connect(_open_energy_dialog.bind(false))
	energy_dialog.watch_ad_pressed.connect(_on_watch_ad)
	energy_dialog.buy_pressed.connect(_on_buy_unlimited)
	energy_dialog.restore_pressed.connect(_on_restore_purchase)
	energy_dialog.closed.connect(_resume_game)
	App.energy.changed.connect(_refresh_energy)
	App.ads.availability_changed.connect(func(_ready: bool) -> void: _refresh_energy())
	App.ads.ad_progress.connect(energy_dialog.set_status)
	App.ads.ad_failed.connect(func(reason: String) -> void: energy_dialog.set_status(reason))
	App.ads.ad_closed.connect(func(rewarded: bool) -> void: energy_dialog.set_status("Thanks! Energy added." if rewarded else "No reward this time."))
	App.purchases.products_updated.connect(func(_products: Dictionary) -> void: _refresh_energy())
	App.purchases.purchase_failed.connect(func(reason: String) -> void: energy_dialog.set_status(reason))
	App.purchases.purchase_completed.connect(func(_id: String, _token: String) -> void: energy_dialog.set_status("Unlimited energy unlocked."))
	App.purchases.restore_completed.connect(func(owned: Array) -> void: energy_dialog.set_status("Purchase restored." if not owned.is_empty() else "Nothing to restore."))
	level_select.level_chosen.connect(_on_level_chosen)
	level_select.detail_requested.connect(_show_level_detail)
	level_select.back_requested.connect(_show_home)
	level_select.set_back_visible(true)
	level_detail.back_requested.connect(_show_level_select)
	level_detail.play_requested.connect(_on_level_chosen)
	level_detail.scope_requested.connect(func(scope: String) -> void: _show_level_detail(level_detail.level_id, scope))
	league.back_requested.connect(_show_home)
	league.add_friend_requested.connect(_on_add_friend)
	league.remove_friend_requested.connect(_on_remove_friend)
	league.rename_requested.connect(_on_rename)
	game_screen.give_up_requested.connect(_on_give_up)
	board.solved.connect(_on_solved)
	win_overlay.next_requested.connect(_play_step)
	win_overlay.home_requested.connect(_show_home)
	week_summary.closed.connect(_on_week_summary_closed)
	message_dialog.closed.connect(_on_dialog_closed)
	_show_home()


func _process(delta: float) -> void:
	if session != null and session.running:
		session.tick(delta)
		game_screen.set_timer_text(_format_time(session.elapsed_seconds()))


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_pause_game(true)
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_resume_game()
		NOTIFICATION_WM_GO_BACK_REQUEST:
			if message_dialog.visible:
				message_dialog.cancel()
			elif energy_dialog.visible:
				energy_dialog.close()
			elif week_summary.visible:
				week_summary.close()
			elif game_screen.visible and not win_overlay.visible:
				_on_give_up()
			elif level_detail.visible:
				_show_level_select()
			elif level_select.visible or league.visible:
				_show_home()


func _hide_all() -> void:
	win_overlay.visible = false
	game_screen.visible = false
	level_select.visible = false
	level_detail.visible = false
	league.visible = false
	home.visible = false


# --- home -------------------------------------------------------------------

func _league_line(standing: Dictionary) -> String:
	var tier_name := str(standing.get("tier_name", ""))
	if not standing.get("joined", false):
		return "%s league · play a game to join this week" % tier_name
	return "%s league · %d pts · #%d of %d · %s\nWeek ends in %s" % [
		tier_name, int(standing.get("my_weekly_score", 0)), int(standing.get("my_rank", 0)),
		int(standing.get("group", {}).get("size", 0)), _zone_text(str(standing.get("zone", ""))),
		_week_left_text(standing)]


func _zone_text(zone: String) -> String:
	match zone:
		"promote":
			return "promotion zone"
		"relegate":
			return "relegation zone"
	return "safe"


func _week_left_text(standing: Dictionary) -> String:
	return Cooldown.format_remaining(int(standing.get("week_ends_at", 0)) - App.now())


func _home_view(standing: Dictionary) -> Dictionary:
	var last := App.save.last_game()
	var view := {
		"has_last": not last.is_empty(),
		"nickname": App.save.nickname(),
		"energy_text": App.energy.display_text(),
		"league_text": _league_line(standing),
		"last_text": "Pick how hard you want to start",
	}
	if not last.is_empty():
		var lv := App.catalog.get_level(str(last["level_id"]))
		if lv.is_empty():
			view["last_text"] = "Last game: difficulty %d" % int(last["difficulty"])
		else:
			view["last_text"] = "Last game: Level %d · %dx%d · diff %d" % [
				App.catalog.display_index(lv["id"]) + 1, lv["size"], lv["size"], int(lv["difficulty"])]
	return view


func _show_home() -> void:
	_pause_game(false)
	var standing: Dictionary = (await App.backend.get_league_standing())["data"]
	home.refresh(_home_view(standing))
	_hide_all()
	home.visible = true
	var summary: Dictionary = (await App.backend.get_week_summary())["data"]
	if not summary.is_empty() and not week_summary.visible:
		var cfg: Dictionary = App.config.league
		week_summary.open(summary,
			LeagueRules.tier_name(cfg, str(summary.get("tier_before", ""))),
			LeagueRules.tier_name(cfg, str(summary.get("tier_after", ""))))


func _on_week_summary_closed(week_index: int) -> void:
	App.backend.ack_week_summary(week_index)


# --- energy -----------------------------------------------------------------

func _energy_state() -> Dictionary:
	return {
		"energy_text": App.energy.display_text(),
		"unlimited": App.energy.is_unlimited(),
		"can_start": App.energy.can_start(),
		"ad_ready": App.ads.is_ready(),
		"ad_reward": App.config.ad_reward_energy,
		"price_text": App.unlimited_price_text(),
		"purchases_available": App.purchases.is_available(),
	}


func _refresh_energy() -> void:
	home.set_energy_text(App.energy.display_text())
	energy_dialog.set_state(_energy_state())


## `blocked`: a game start was refused for lack of energy.
func _open_energy_dialog(blocked: bool) -> void:
	_pause_game(true)
	energy_dialog.set_state(_energy_state())
	energy_dialog.open(blocked)
	energy_dialog.set_state(_energy_state())


func _on_watch_ad() -> void:
	energy_dialog.set_status("Loading ad…")
	App.ads.show_rewarded()


func _on_buy_unlimited() -> void:
	energy_dialog.set_status("Contacting the store…")
	App.purchases.purchase(App.config.unlimited_product_id)


func _on_restore_purchase() -> void:
	energy_dialog.set_status("Restoring…")
	App.purchases.restore()


# --- picker -----------------------------------------------------------------

func _locked_ids() -> Dictionary:
	var ids := {}
	var now := App.now()
	for lv in levels:
		if Cooldown.is_locked(App.save.level_entry(lv["id"]), now, App.config.cooldown_seconds):
			ids[lv["id"]] = true
	return ids


func _played_ids() -> Dictionary:
	var ids := {}
	for lv in levels:
		if int(App.save.level_entry(lv["id"])["plays"]) > 0:
			ids[lv["id"]] = true
	return ids


## Seconds until the first locked level unlocks again.
func _shortest_lock() -> int:
	var best := 0
	var now := App.now()
	for lv in levels:
		var remaining := Cooldown.remaining(App.save.level_entry(lv["id"]), now, App.config.cooldown_seconds)
		if remaining > 0 and (best == 0 or remaining < best):
			best = remaining
	return best


## Easier (-1) / Same (0) / Harder (+1) relative to the last game started.
func _play_step(step: int) -> void:
	var pick := App.picker.pick(step, App.save.last_game(), _locked_ids(), _played_ids())
	match pick["reason"]:
		"none_harder":
			message_dialog.open("No harder level", "Every harder level is cooling down right now. Try Same or Easier.")
		"none_easier":
			message_dialog.open("No easier level", "Every easier level is cooling down right now. Try Same or Harder.")
		"none":
			message_dialog.open("All levels cooling down", "The next level unlocks in %s." % Cooldown.format_remaining(_shortest_lock()))
		_:
			start_game(pick["level"], "Closest available level" if pick["reason"] == "nearest" else "")


# --- level overview and detail ------------------------------------------------

func _level_title(lv: Dictionary) -> String:
	return "Level %d · %dx%d · diff %d" % [App.catalog.display_index(lv["id"]) + 1, lv["size"], lv["size"], int(lv["difficulty"])]


func _level_rows() -> Array:
	var rows: Array = []
	var now := App.now()
	for i in levels.size():
		var lv: Dictionary = levels[i]
		var entry := App.save.level_entry(lv["id"])
		var text := "Level %d\n%dx%d · diff %d" % [i + 1, lv["size"], lv["size"], int(lv["difficulty"])]
		if lv["stars"] > 0:
			text += "\n" + "★".repeat(lv["stars"])
		var remaining := Cooldown.remaining(entry, now, App.config.cooldown_seconds)
		if remaining > 0:
			text += "\nLocked · %s" % Cooldown.format_remaining(remaining)
		elif App.save.has_best_score(lv["id"]):
			text += "\nBest %d pts · %s" % [int(entry["best_score"]), "flawless" if int(entry["best_wrong"]) == 0 else _format_time(App.save.best_time(lv["id"]))]
		elif App.save.has_best(lv["id"]):
			text += "\nBest %s" % _format_time(App.save.best_time(lv["id"]))
		rows.append({"id": lv["id"], "text": text, "locked": remaining > 0})
	return rows


func _show_level_select() -> void:
	_pause_game(false)
	level_select.refresh(_level_rows())
	_hide_all()
	level_select.visible = true


func _show_level_detail(level_id: String, scope: String = "global") -> void:
	var lv := App.catalog.get_level(level_id)
	if lv.is_empty():
		return
	detail_scope = scope
	var res: Dictionary = await App.backend.get_level_leaderboard(level_id, scope, 25)
	var board_data: Dictionary = res["data"] if res["ok"] else {"entries": [], "my_entry": {}, "my_rank": 0, "total_players": 0, "par_seconds": Scoring.par_seconds(lv["difficulty"], lv["size"])}
	var entries: Array = []
	for e in board_data["entries"]:
		var row: Dictionary = e.duplicate()
		row["time_text"] = _format_time(float(e.get("time_seconds", 0.0)))
		entries.append(row)
	var mine: Dictionary = board_data.get("my_entry", {})
	var mine_text := "Not played yet"
	if not mine.is_empty():
		var wrong := int(mine.get("wrong_placements", 0))
		mine_text = "Your best: %d pts · %s · %s · #%d" % [int(mine.get("score", 0)), _format_time(float(mine.get("time_seconds", 0.0))),
			"flawless" if wrong == 0 else ("%d mistake" % wrong if wrong == 1 else "%d mistakes" % wrong), int(board_data.get("my_rank", 0))]
	var remaining := Cooldown.remaining(App.save.level_entry(level_id), App.now(), App.config.cooldown_seconds)
	level_detail.refresh({
		"level_id": level_id,
		"title": _level_title(lv),
		"par_text": "Par %s · %d players" % [_format_time(float(board_data.get("par_seconds", 0.0))), int(board_data.get("total_players", 0))],
		"mine_text": mine_text,
		"scope": scope,
		"entries": entries,
		"play_text": "Play this level" if remaining <= 0 else "Locked · %s" % Cooldown.format_remaining(remaining),
		"play_enabled": remaining <= 0,
	})
	_hide_all()
	level_detail.visible = true


func _on_level_chosen(level_id: String) -> void:
	start_game(App.catalog.get_level(level_id))


func _start_level(index: int) -> void:
	start_game(levels[index])


func _is_locked(level: Dictionary) -> bool:
	return Cooldown.is_locked(App.save.level_entry(level["id"]), App.now(), App.config.cooldown_seconds)


# --- league -------------------------------------------------------------------

func _show_league() -> void:
	_pause_game(false)
	await _refresh_league()
	_hide_all()
	league.visible = true


func _refresh_league() -> void:
	var standing: Dictionary = (await App.backend.get_league_standing())["data"]
	var friends: Array = (await App.backend.get_friends())["data"]
	var profile: Dictionary = (await App.backend.get_profile())["data"]
	league.refresh(standing, friends, str(profile.get("friend_code", "")), App.save.nickname(), _week_left_text(standing))


func _on_add_friend(code: String) -> void:
	var res: Dictionary = await App.backend.add_friend(code)
	if res["ok"]:
		league.clear_code()
		league.set_status("Added %s" % res["data"]["nickname"])
		await _refresh_league()
	else:
		league.set_status(res["error"])


func _on_remove_friend(player_id: String) -> void:
	await App.backend.remove_friend(player_id)
	league.set_status("Friend removed")
	await _refresh_league()


func _on_rename(nickname: String) -> void:
	var res: Dictionary = await App.backend.set_nickname(nickname)
	if res["ok"]:
		App.save.data["player"]["nickname"] = res["data"]["nickname"]
		App.save.mark_changed()
		league.set_status("You are now %s" % res["data"]["nickname"])
		await _refresh_league()
	else:
		league.set_status(res["error"])


# --- game -------------------------------------------------------------------

## Starts a game on `level`: records the start in the save, loads the board
## and runs the stopwatch. A game still running is forfeited first.
func start_game(level: Dictionary, note: String = "") -> void:
	if _is_locked(level):
		var remaining := Cooldown.remaining(App.save.level_entry(level["id"]), App.now(), App.config.cooldown_seconds)
		message_dialog.open("Level locked", "You played this level recently. It unlocks in %s." % Cooldown.format_remaining(remaining))
		return
	if not App.energy.can_start():
		_open_energy_dialog(true)
		return
	if session != null and not session.finished:
		end_game(false)
	App.energy.charge_start()
	current_level = levels.find(level)
	session = GameSession.new()
	session.start(level, App.save.player_id(), App.now(), App.config.client_version)
	session.attach(board)
	App.save.begin_game(level, session.to_marker(), App.now())
	App.save_now()
	App.backend.start_game(level["id"])
	board.load_level(level)
	game_screen.set_level_text(_level_title(level))
	game_screen.set_timer_text(_format_time(0.0))
	game_screen.set_hint(note if note != "" else DEFAULT_HINT)
	_hide_all()
	game_screen.visible = true
	session.resume()


## Ends the running game as completed or forfeited and stores the result.
func end_game(completed: bool) -> GameResult:
	if session == null or session.finished:
		return null
	var result := session.finish(completed, App.now())
	App.record_result(result)
	return result


func _pause_game(persist: bool) -> void:
	if session == null or session.finished:
		return
	session.pause()
	if persist:
		App.save.update_marker(session.to_marker())
		App.save_now()


func _resume_game() -> void:
	if session == null or session.finished:
		return
	if game_screen.visible and not win_overlay.visible and not message_dialog.visible and not energy_dialog.visible:
		session.resume()


func _on_give_up() -> void:
	if session == null or session.finished or message_dialog.visible:
		return
	_pause_game(true)
	var body := "Giving up ends this game and locks the level for %s." % Cooldown.format_period(App.config.cooldown_seconds)
	var confirmed: bool = await message_dialog.ask("Give up?", body, "Give up", "Keep playing")
	if confirmed:
		end_game(false)
		_show_home()


func _on_dialog_closed(_confirmed: bool) -> void:
	_resume_game()


func _on_solved() -> void:
	if session == null or session.finished:
		return
	var result := session.finish(true, App.now())
	var outcome: Dictionary = await App.record_result(result)
	var bd := Scoring.breakdown(result.to_dict())
	var badges: Array = []
	if bd["flawless"]:
		badges.append("Flawless")
	if outcome["best_score_improved"] and int(App.save.level_entry(result.level_id)["completions"]) > 1:
		badges.append("New best")
	var detail := "Time %s · par %s\nMistakes %d · Undos %d\nLevel %d × accuracy %.2f × speed %.2f × undo %.2f" % [
		_format_time(result.elapsed_seconds), _format_time(bd["par_seconds"]),
		result.wrong_placements, result.undo_count,
		bd["base"], bd["accuracy_factor"], bd["speed_factor"], bd["undo_factor"]]
	var league_text := ""
	var lg: Dictionary = outcome.get("league", {})
	if not lg.is_empty():
		league_text = "%s league · %d pts · #%d of %d · %s" % [
			LeagueRules.tier_name(App.config.league, str(lg.get("tier", ""))), int(lg.get("weekly_score", 0)),
			int(lg.get("group_rank", 0)), int(lg.get("group_size", 0)), _zone_text(str(lg.get("zone", "")))]
	win_overlay.show_result("%d points" % result.score, " · ".join(badges), detail, league_text)


func _format_time(seconds: float) -> String:
	var total := int(seconds)
	@warning_ignore("integer_division")
	return "%d:%02d" % [total / 60, total % 60]
