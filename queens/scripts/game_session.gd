class_name GameSession
extends RefCounted
## One game in progress: a pausable stopwatch plus the move counters, fed by
## the Board's signals. `finish()` turns it into a GameResult.
##
## The session is also written to the save file as a small marker while the
## game runs, so an app that is killed mid-game yields a forfeit on the next
## start (see `to_marker` / `forfeit_from_marker`).

const MAX_TICK := 1.0  ## Frames longer than this (resume after background) are not counted.

var result: GameResult = GameResult.new()
var running: bool = false
var finished: bool = false

var _board: Board = null


func start(level: Dictionary, player_id: String, now: int, client_version: String = "") -> void:
	result = GameResult.new()
	result.result_id = SaveData.new_uuid()
	result.player_id = player_id
	result.level_id = str(level["id"])
	result.size = int(level["size"])
	result.difficulty = float(level["difficulty"])
	result.stars = int(level.get("stars", 0))
	result.par_seconds = Scoring.par_seconds(result.difficulty, result.size)
	result.started_at = now
	result.client_version = client_version
	running = false
	finished = false


## Connects to the board's signals. Only one session may be attached at a time.
func attach(board: Board) -> void:
	detach()
	_board = board
	board.tapped.connect(_on_tapped)
	board.queen_placed.connect(_on_queen_placed)
	board.queen_removed.connect(_on_queen_removed)
	board.undone.connect(_on_undone)
	board.cleared.connect(_on_cleared)


func detach() -> void:
	if _board == null:
		return
	_board.tapped.disconnect(_on_tapped)
	_board.queen_placed.disconnect(_on_queen_placed)
	_board.queen_removed.disconnect(_on_queen_removed)
	_board.undone.disconnect(_on_undone)
	_board.cleared.disconnect(_on_cleared)
	_board = null


func elapsed_seconds() -> float:
	return result.elapsed_seconds


func tick(delta: float) -> void:
	if not running or finished or delta > MAX_TICK:
		return
	result.elapsed_seconds += delta


func pause() -> void:
	running = false


func resume() -> void:
	if not finished:
		running = true


func finish(completed: bool, now: int) -> GameResult:
	running = false
	finished = true
	detach()
	result.completed = completed
	result.finished_at = maxi(now, result.started_at)
	result.week_index = Scoring.week_index(result.finished_at)
	result.score = Scoring.score(result.to_dict())
	return result


## Compact state for the save file while the game runs.
func to_marker() -> Dictionary:
	return {
		"result_id": result.result_id,
		"level_id": result.level_id,
		"started_at": result.started_at,
		"elapsed_seconds": result.elapsed_seconds,
		"queens_placed": result.queens_placed,
		"wrong_placements": result.wrong_placements,
		"queens_removed": result.queens_removed,
		"undo_count": result.undo_count,
		"clear_count": result.clear_count,
		"taps": result.taps,
	}


## Rebuilds a forfeited result from a marker left by a killed app.
static func forfeit_from_marker(marker: Dictionary, level: Dictionary, player_id: String, now: int, client_version: String = "") -> GameResult:
	var r := GameResult.new()
	r.result_id = str(marker.get("result_id", SaveData.new_uuid()))
	r.player_id = player_id
	r.level_id = str(marker.get("level_id", ""))
	if not level.is_empty():
		r.size = int(level["size"])
		r.difficulty = float(level["difficulty"])
		r.stars = int(level.get("stars", 0))
		r.par_seconds = Scoring.par_seconds(r.difficulty, r.size)
	r.started_at = int(marker.get("started_at", now))
	r.finished_at = maxi(now, r.started_at)
	r.elapsed_seconds = float(marker.get("elapsed_seconds", 0.0))
	r.completed = false
	r.queens_placed = int(marker.get("queens_placed", 0))
	r.wrong_placements = int(marker.get("wrong_placements", 0))
	r.queens_removed = int(marker.get("queens_removed", 0))
	r.undo_count = int(marker.get("undo_count", 0))
	r.clear_count = int(marker.get("clear_count", 0))
	r.taps = int(marker.get("taps", 0))
	r.week_index = Scoring.week_index(r.finished_at)
	r.client_version = client_version
	return r


func _on_tapped(_r: int, _c: int) -> void:
	result.taps += 1


func _on_queen_placed(_r: int, _c: int, correct: bool) -> void:
	result.queens_placed += 1
	if not correct:
		result.wrong_placements += 1


func _on_queen_removed(_r: int, _c: int) -> void:
	result.queens_removed += 1


func _on_undone() -> void:
	result.undo_count += 1


func _on_cleared() -> void:
	result.clear_count += 1
