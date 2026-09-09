extends Control
## Screen coordinator: home -> game -> solved overlay, with the level
## overview, level detail, league screen and the dialogs on the side.
## Screens are sub-scenes that only emit intents and render view
## dictionaries (built by Views); this script talks to the App autoload
## (save, config, catalog, picker, energy, backend), owns the running
## GameSession and moves screens through the ScreenRouter.

@onready var home: Control = $Home
@onready var level_select: Control = $LevelSelect
@onready var level_detail: Control = $LevelDetail
@onready var league: Control = $League
@onready var game_screen: Control = $Game
@onready var board: Board = game_screen.board
@onready var win_overlay: Control = $WinOverlay
@onready var round_summary: Control = $RoundSummary
@onready var energy_dialog: Control = $EnergyDialog
@onready var message_dialog: Control = $MessageDialog
@onready var pause_menu: Control = $PauseMenu
@onready var settings_screen: Control = $Settings
@onready var tutorial: Control = $Tutorial
@onready var splash: Control = $Splash
@onready var toast: Toast = $Toast

var skip_splash: bool = false   ## Tests: go straight to the first screen.
var _settings_from: String = "home"

var router: ScreenRouter
var debug: DebugApi

var levels: Array = []          ## Level dictionaries, see scripts/levels.gd.
var current_level: int = -1
var session: GameSession = null ## The running game, null between games.
var detail_scope: String = "global"
var _options: Dictionary = {}   ## step -> pick (the level each home card would start)
var _req: int = 0               ## Request token: drops stale backend answers.


func _ready() -> void:
	levels = App.catalog.levels
	router = ScreenRouter.new()
	router.name = "Router"
	add_child(router)
	router.register("home", home)
	router.register("levels", level_select)
	router.register("detail", level_detail)
	router.register("league", league)
	router.register("game", game_screen)
	router.register("settings", settings_screen)
	router.register("tutorial", tutorial)
	router.register("splash", splash)
	debug = DebugApi.new(self)

	home.play_requested.connect(_play_step)
	home.overview_requested.connect(_show_level_select)
	home.league_requested.connect(_show_league)
	home.energy_pressed.connect(_open_energy_dialog.bind(false))
	home.settings_requested.connect(_show_settings)
	settings_screen.back_requested.connect(_on_settings_back)
	settings_screen.setting_changed.connect(_on_setting_changed)
	settings_screen.rename_requested.connect(_on_rename)
	settings_screen.restore_requested.connect(_on_restore_purchase)
	settings_screen.tutorial_requested.connect(_show_tutorial)
	tutorial.finished.connect(_on_tutorial_finished)
	pause_menu.settings_requested.connect(_show_settings)
	pause_menu.set_settings_available(true)
	energy_dialog.watch_ad_pressed.connect(_on_watch_ad)
	energy_dialog.buy_pressed.connect(_on_buy_unlimited)
	energy_dialog.restore_pressed.connect(_on_restore_purchase)
	energy_dialog.closed.connect(_resume_game)
	App.energy.changed.connect(_refresh_energy)
	App.ads.availability_changed.connect(func(_ready: bool) -> void: _refresh_energy())
	App.ads.ad_progress.connect(energy_dialog.set_status)
	App.ads.ad_failed.connect(func(reason: String) -> void: energy_dialog.set_status(reason); toast.show_message(reason, "error"))
	App.ads.ad_closed.connect(func(rewarded: bool) -> void:
		energy_dialog.set_status("Thanks! Energy added." if rewarded else "No reward this time.")
		if rewarded:
			toast.show_message("+%d energy" % App.config.ad_reward_energy, "success"))
	App.purchases.products_updated.connect(func(_products: Dictionary) -> void: _refresh_energy())
	App.purchases.purchase_failed.connect(func(reason: String) -> void: energy_dialog.set_status(reason); toast.show_message(reason, "error"))
	App.purchases.purchase_completed.connect(func(_id: String, _token: String) -> void:
		energy_dialog.set_status("Unlimited energy unlocked.")
		toast.show_message("Unlimited energy unlocked", "success"))
	App.purchases.restore_completed.connect(func(owned: Array) -> void: energy_dialog.set_status("Purchase restored." if not owned.is_empty() else "Nothing to restore."))
	level_select.detail_requested.connect(_show_level_detail)
	level_select.back_requested.connect(_show_home.bind(true))
	level_select.set_back_visible(true)
	level_detail.back_requested.connect(_show_level_select.bind(true))
	level_detail.play_requested.connect(_on_level_chosen)
	level_detail.scope_requested.connect(func(scope: String) -> void: _show_level_detail(level_detail.level_id, scope))
	league.back_requested.connect(_show_home.bind(true))
	league.add_friend_requested.connect(_on_add_friend)
	league.remove_friend_requested.connect(_on_remove_friend)
	App.backend.standing_changed.connect(func() -> void:
		if router.current() == "league":
			_refresh_league())
	game_screen.pause_requested.connect(_open_pause)
	game_screen.hint_requested.connect(_on_hint)
	pause_menu.resumed.connect(_resume_game)
	pause_menu.restart_requested.connect(_on_restart)
	pause_menu.give_up_requested.connect(_on_give_up)
	board.solved.connect(_on_solved)
	win_overlay.next_requested.connect(_play_step)
	win_overlay.home_requested.connect(_show_home)
	round_summary.closed.connect(_on_round_summary_closed)
	message_dialog.closed.connect(_on_dialog_closed)
	Motion.make_all_pressable(self)
	_boot()


func _boot() -> void:
	if skip_splash or Motion.instant:
		_after_splash()
		return
	splash.play()
	router.go("splash", true)
	await splash.done
	_after_splash()


func _after_splash() -> void:
	if not Motion.instant:
		Sfx.play_music()
	if not bool(App.save.setting("tutorial_done")):
		_show_tutorial()
	else:
		_show_home()


func _process(delta: float) -> void:
	if session != null and session.running:
		session.tick(delta)
		game_screen.set_timer_text(Fmt.time(session.elapsed_seconds()))


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_pause_game(true)
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_resume_game()
		NOTIFICATION_WM_GO_BACK_REQUEST:
			_on_back()


func _on_back() -> void:
	if message_dialog.visible:
		message_dialog.cancel()
	elif energy_dialog.visible:
		energy_dialog.close()
	elif round_summary.visible:
		round_summary.close()
	elif pause_menu.visible:
		pause_menu.close()
	elif win_overlay.visible:
		pass
	else:
		match router.current():
			"game":
				_open_pause()
			"detail":
				_show_level_select(true)
			"levels", "league":
				_show_home(true)
			"settings":
				_on_settings_back()
			"tutorial":
				tutorial.skip()


# --- home -------------------------------------------------------------------

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


## Picks the level behind each difficulty step once, so the cards and the
## Play button agree on what starts.
func _pick_options() -> Array:
	_options.clear()
	var last := App.save.last_game()
	var locked := _locked_ids()
	var played := _played_ids()
	var steps: Array = [-1, 0, 1] if not last.is_empty() else [0]
	var options: Array = []
	for step in steps:
		var pick := App.picker.pick(step, last, locked, played)
		_options[step] = pick
		options.append(Views.option(step, pick, App.catalog))
	return options


func _show_home(back: bool = false) -> void:
	_pause_game(false)
	_req += 1
	var my := _req
	var standing: Dictionary = (await App.backend.get_league_standing())["data"]
	if my != _req:
		return
	home.refresh(Views.home(App.save, App.catalog, App.energy, standing, _pick_options(), App.now()))
	if back:
		router.go_back_to("home")
	else:
		router.go("home", true)
	var summary: Dictionary = (await App.backend.get_round_summary())["data"]
	if not summary.is_empty() and not round_summary.visible:
		var cfg: Dictionary = App.config.league
		round_summary.open(summary,
			LeagueRules.tier_name(cfg, str(summary.get("tier_before", ""))),
			LeagueRules.tier_name(cfg, str(summary.get("tier_after", ""))))
		router.present(round_summary)


func _on_round_summary_closed(round_index: int) -> void:
	App.backend.ack_round_summary(round_index)


# --- energy -----------------------------------------------------------------

func _energy_state() -> Dictionary:
	return Views.energy_state(App.energy, App.ads, App.purchases, App.config.ad_reward_energy, App.unlimited_price_text())


func _refresh_energy() -> void:
	home.set_energy(App.energy.amount(), App.energy.is_unlimited())
	energy_dialog.set_state(_energy_state())


## `blocked`: a game start was refused for lack of energy.
func _open_energy_dialog(blocked: bool) -> void:
	_pause_game(true)
	energy_dialog.set_state(_energy_state())
	energy_dialog.open(blocked)
	energy_dialog.set_state(_energy_state())
	router.present(energy_dialog)


func _on_watch_ad() -> void:
	energy_dialog.set_status("Loading ad…")
	App.ads.show_rewarded()


func _on_buy_unlimited() -> void:
	energy_dialog.set_status("Contacting the store…")
	App.purchases.purchase(App.config.unlimited_product_id)


func _on_restore_purchase() -> void:
	energy_dialog.set_status("Restoring…")
	App.purchases.restore()


# --- settings and tutorial ------------------------------------------------------

func _settings_view() -> Dictionary:
	var view := App.save.settings()
	view["nickname"] = App.save.nickname()
	view["purchases_available"] = App.purchases.is_available()
	view["version"] = App.config.client_version
	return view


func _show_settings() -> void:
	_settings_from = router.current()
	if pause_menu.visible:
		pause_menu.visible = false
		router.dismiss(pause_menu)
	settings_screen.refresh(_settings_view())
	router.go("settings")


func _on_settings_back() -> void:
	if _settings_from == "game" and session != null and not session.finished:
		router.go_back_to("game")
		_open_pause()
	else:
		_show_home(true)


func _on_setting_changed(key: String, value: bool) -> void:
	App.save.set_setting(key, value)
	App.apply_settings()
	board.mistake_alerts = bool(App.save.setting("mistake_alerts"))
	board.region_patterns = bool(App.save.setting("region_patterns"))
	board.queue_redraw()


func _show_tutorial() -> void:
	_pause_game(false)
	tutorial.start(levels[0])
	router.go("tutorial", true)


func _on_tutorial_finished(completed: bool) -> void:
	App.save.set_setting("tutorial_done", true)
	if completed:
		toast.show_message("You're ready. Have fun!", "success")
	_show_home()


# --- picker -----------------------------------------------------------------

## Easier (-1) / Same (0) / Harder (+1) relative to the last game started.
func _play_step(step: int) -> void:
	if not _options.has(step):
		_pick_options()
	var pick: Dictionary = _options.get(step, {"level": {}, "reason": "none"})
	match str(pick.get("reason", "none")):
		"none_harder":
			toast.show_message("Every harder level is cooling down. Try Same or Easier.")
		"none_easier":
			toast.show_message("Every easier level is cooling down. Try Same or Harder.")
		"none":
			message_dialog.open("All levels cooling down", "The next level unlocks in %s." % Cooldown.format_remaining(_shortest_lock()))
			router.present(message_dialog)
		_:
			start_game(pick["level"], "Closest available level" if pick["reason"] == "nearest" else "")


# --- level overview and detail ------------------------------------------------

func _show_level_select(back: bool = false) -> void:
	_pause_game(false)
	level_select.refresh(Views.level_cards(levels, App.save, App.catalog, App.now(), App.config.cooldown_seconds))
	if back:
		router.go_back_to("levels")
	else:
		router.go("levels")


func _show_level_detail(level_id: String, scope: String = "global") -> void:
	var lv := App.catalog.get_level(level_id)
	if lv.is_empty():
		return
	detail_scope = scope
	_req += 1
	var my := _req
	var switching := router.current() != "detail"
	if switching:
		level_detail.set_loading(true)
		router.go("detail")
	var res: Dictionary = await App.backend.get_level_leaderboard(level_id, scope, 25)
	if my != _req:
		return
	var board_data: Dictionary = res["data"] if res["ok"] else {"entries": [], "my_entry": {}, "my_rank": 0, "total_players": 0, "par_seconds": Scoring.par_seconds(lv["difficulty"], lv["size"])}
	level_detail.refresh(Views.level_detail(lv, board_data, scope, App.save, App.catalog, App.now(), App.config.cooldown_seconds))


func _on_level_chosen(level_id: String) -> void:
	start_game(App.catalog.get_level(level_id))


func _is_locked(level: Dictionary) -> bool:
	return Cooldown.is_locked(App.save.level_entry(level["id"]), App.now(), App.config.cooldown_seconds)


# --- league -------------------------------------------------------------------

func _show_league() -> void:
	_pause_game(false)
	await _refresh_league()
	router.go("league")


func _refresh_league() -> void:
	var standing: Dictionary = (await App.backend.get_league_standing())["data"]
	var friends: Array = (await App.backend.get_friends())["data"]
	var profile: Dictionary = (await App.backend.get_profile())["data"]
	league.refresh(standing, friends, str(profile.get("friend_code", "")), App.save.nickname(), Views.league_summary(standing, App.now())["ends_in_text"])


func _on_add_friend(code: String) -> void:
	var res: Dictionary = await App.backend.add_friend(code)
	if res["ok"]:
		league.clear_code()
		league.set_status("Added %s" % res["data"]["nickname"])
		toast.show_message("Added %s" % res["data"]["nickname"], "success")
		await _refresh_league()
	else:
		league.set_status(res["error"])
		toast.show_message(res["error"], "error")


func _on_remove_friend(player_id: String) -> void:
	await App.backend.remove_friend(player_id)
	league.set_status("Friend removed")
	await _refresh_league()


func _on_rename(nickname: String) -> void:
	var res: Dictionary = await App.backend.set_nickname(nickname)
	if res["ok"]:
		App.save.data["player"]["nickname"] = res["data"]["nickname"]
		App.save.mark_changed()
		toast.show_message("You are now %s" % res["data"]["nickname"], "success")
		settings_screen.refresh(_settings_view())
		await _refresh_league()
	else:
		toast.show_message(res["error"], "error")


# --- game -------------------------------------------------------------------

## Starts a game on `level`: records the start in the save, loads the board
## and runs the stopwatch. A game still running is forfeited first.
func start_game(level: Dictionary, note: String = "") -> void:
	if _is_locked(level):
		var remaining := Cooldown.remaining(App.save.level_entry(level["id"]), App.now(), App.config.cooldown_seconds)
		message_dialog.open("Level locked", "You played this level recently. It unlocks in %s." % Cooldown.format_remaining(remaining))
		router.present(message_dialog)
		return
	if not App.energy.can_start():
		_open_energy_dialog(true)
		return
	if session != null and not session.finished:
		end_game(false)
	if router.current() == "home" and not win_overlay.visible:
		home.drain_energy()
	App.energy.charge_start()
	current_level = levels.find(level)
	session = GameSession.new()
	session.start(level, App.save.player_id(), App.now(), App.config.client_version)
	session.attach(board.model)
	session.mistake.connect(_on_mistake)
	App.save.begin_game(level, session.to_marker(), App.now())
	App.save_now()
	App.backend.start_game(level["id"])
	board.input_enabled = true
	board.mistake_alerts = bool(App.save.setting("mistake_alerts"))
	board.region_patterns = bool(App.save.setting("region_patterns"))
	board.load_level(level)
	game_screen.set_level(App.catalog.display_index(level["id"]) + 1, int(level["size"]), int(level["difficulty"]), int(level.get("stars", 0)))
	game_screen.set_timer_text(Fmt.time(0.0))
	if note != "":
		game_screen.set_hint(note, 4.0)
	if win_overlay.visible:
		win_overlay.close()
	var delay := Motion.d(0.3) if router.current() == "home" else 0.0
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	router.go("game", true)
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
	if router.current() == "game" and not win_overlay.visible and not message_dialog.visible and not energy_dialog.visible and not pause_menu.visible:
		session.resume()


func _open_pause() -> void:
	if session == null or session.finished or pause_menu.visible or win_overlay.visible:
		return
	_pause_game(true)
	var lv: Dictionary = levels[current_level] if current_level >= 0 else {}
	var subtitle := ""
	if not lv.is_empty():
		subtitle = "Level %d · %s · %s" % [App.catalog.display_index(lv["id"]) + 1, Fmt.size_text(int(lv["size"])), Fmt.time(session.elapsed_seconds())]
	pause_menu.open(subtitle)
	router.present(pause_menu)


func _on_restart() -> void:
	if session == null or session.finished:
		return
	message_dialog.open("Restart level?", "The board is wiped. The clock keeps running.", "Restart", "Keep going")
	router.present(message_dialog)
	var confirmed: bool = await message_dialog.closed
	if confirmed:
		pause_menu.visible = false
		board.clear()
		_resume_game()


func _on_hint() -> void:
	if session == null or session.finished or board.locked:
		return
	var hint := HintFinder.find(board.model)
	if hint["kind"] == "none":
		game_screen.set_hint("Nothing left to hint. You're almost there!", 3.0)
		return
	game_screen.set_hint(hint["text"], 4.0)
	await board.apply_hint(hint)
	if session != null:
		game_screen.set_hints_used(session.result.hint_count)


func _on_mistake(count: int) -> void:
	game_screen.set_mistakes(count)


func _on_give_up() -> void:
	if session == null or session.finished or message_dialog.visible:
		return
	_pause_game(true)
	message_dialog.open("Give up?", "Giving up ends this game and locks the level for %s." % Cooldown.format_period(App.config.cooldown_seconds), "Give up", "Keep playing")
	router.present(message_dialog)
	var confirmed: bool = await message_dialog.closed
	if confirmed:
		pause_menu.visible = false
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
	var next := {}
	for opt in _pick_options():
		next[int(opt["step"])] = opt
	var view := Views.win(result, bd, outcome, next, App.config.league, int(App.save.level_entry(result.level_id)["completions"]))
	# Let the board celebrate before the overlay slides in.
	var delay := Motion.d(0.9)
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	win_overlay.show_result(view)
	router.present(win_overlay)
