extends Control
## Screen router: level select -> game -> solved overlay, plus the message
## dialog. Screens are sub-scenes that only emit intents; this script talks
## to the App autoload (save, config, catalog) and owns the running
## GameSession.

@onready var level_select: Control = $LevelSelect
@onready var game_screen: Control = $Game
@onready var board: Board = game_screen.board
@onready var win_overlay: Control = $WinOverlay
@onready var message_dialog: Control = $MessageDialog

var levels: Array = []          ## Level dictionaries, see scripts/levels.gd.
var current_level: int = -1
var session: GameSession = null ## The running game, null between games.


func _ready() -> void:
	levels = App.catalog.levels
	level_select.level_chosen.connect(_on_level_chosen)
	game_screen.give_up_requested.connect(_on_give_up)
	board.solved.connect(_on_solved)
	win_overlay.next_requested.connect(_on_next)
	win_overlay.levels_requested.connect(_show_level_select)
	message_dialog.closed.connect(_on_dialog_closed)
	_show_level_select()


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
			elif game_screen.visible and not win_overlay.visible:
				_on_give_up()


# --- level overview ---------------------------------------------------------

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
		elif App.save.has_best(lv["id"]):
			text += "\nBest %s" % _format_time(App.save.best_time(lv["id"]))
		rows.append({"id": lv["id"], "text": text, "locked": remaining > 0})
	return rows


func _show_level_select() -> void:
	_pause_game(false)
	level_select.refresh(_level_rows())
	win_overlay.visible = false
	game_screen.visible = false
	level_select.visible = true


func _on_level_chosen(level_id: String) -> void:
	start_game(App.catalog.get_level(level_id))


func _start_level(index: int) -> void:
	start_game(levels[index])


func _is_locked(level: Dictionary) -> bool:
	return Cooldown.is_locked(App.save.level_entry(level["id"]), App.now(), App.config.cooldown_seconds)


# --- game -------------------------------------------------------------------

## Starts a game on `level`: records the start in the save, loads the board
## and runs the stopwatch. A game still running is forfeited first.
func start_game(level: Dictionary) -> void:
	if _is_locked(level):
		var remaining := Cooldown.remaining(App.save.level_entry(level["id"]), App.now(), App.config.cooldown_seconds)
		message_dialog.open("Level locked", "You played this level recently. It unlocks in %s." % Cooldown.format_remaining(remaining))
		return
	if session != null and not session.finished:
		end_game(false)
	current_level = levels.find(level)
	session = GameSession.new()
	session.start(level, App.save.player_id(), App.now(), App.config.client_version)
	session.attach(board)
	App.save.begin_game(level["id"], session.to_marker(), App.now())
	App.save_now()
	board.load_level(level)
	game_screen.set_level_text("Level %d · %dx%d · diff %d" % [current_level + 1, level["size"], level["size"], int(level["difficulty"])])
	game_screen.set_timer_text(_format_time(0.0))
	win_overlay.visible = false
	level_select.visible = false
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
	if game_screen.visible and not win_overlay.visible and not message_dialog.visible:
		session.resume()


func _on_give_up() -> void:
	if session == null or session.finished or message_dialog.visible:
		return
	_pause_game(true)
	var body := "Giving up ends this game and locks the level for %s." % Cooldown.format_period(App.config.cooldown_seconds)
	var confirmed: bool = await message_dialog.ask("Give up?", body, "Give up", "Keep playing")
	if confirmed:
		end_game(false)
		_show_level_select()


func _on_dialog_closed(_confirmed: bool) -> void:
	_resume_game()


func _on_solved() -> void:
	var result := end_game(true)
	if result == null:
		return
	win_overlay.show_result(
		"Time: %s" % _format_time(result.elapsed_seconds),
		"Mistakes %d · Undos %d" % [result.wrong_placements, result.undo_count],
		_next_unlocked(current_level) >= 0)


## Index of the next level in game order that is not on cooldown, or -1.
func _next_unlocked(after: int) -> int:
	for i in range(after + 1, levels.size()):
		if not _is_locked(levels[i]):
			return i
	return -1


func _on_next() -> void:
	var i := _next_unlocked(current_level)
	if i >= 0:
		_start_level(i)


func _format_time(seconds: float) -> String:
	var total := int(seconds)
	@warning_ignore("integer_division")
	return "%d:%02d" % [total / 60, total % 60]
