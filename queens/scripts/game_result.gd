class_name GameResult
extends RefCounted
## One finished (or forfeited) game: the level, the timing and the counters
## that scoring and leaderboards are built on. Stored as a Dictionary in the
## save file and sent as-is to the backend.

const SCHEMA := 1

var result_id: String = ""
var player_id: String = ""
var level_id: String = ""
var size: int = 0
var difficulty: float = 0.0
var stars: int = 0
var par_seconds: float = 0.0
var started_at: int = 0
var finished_at: int = 0
var elapsed_seconds: float = 0.0       ## Active play time; paused time is excluded.
var completed: bool = false
var queens_placed: int = 0
var wrong_placements: int = 0          ## Queens placed on a non-solution cell.
var queens_removed: int = 0
var undo_count: int = 0
var clear_count: int = 0
var hint_count: int = 0                ## Hints used; free, but they cost score.
var taps: int = 0
var week_index: int = 0
var score: int = 0                     ## Scoring.score(); 0 for a forfeit.
var client_version: String = ""


func to_dict() -> Dictionary:
	return {
		"schema": SCHEMA,
		"result_id": result_id,
		"player_id": player_id,
		"level_id": level_id,
		"size": size,
		"difficulty": difficulty,
		"stars": stars,
		"par_seconds": par_seconds,
		"started_at": started_at,
		"finished_at": finished_at,
		"elapsed_seconds": elapsed_seconds,
		"completed": completed,
		"queens_placed": queens_placed,
		"wrong_placements": wrong_placements,
		"queens_removed": queens_removed,
		"undo_count": undo_count,
		"clear_count": clear_count,
		"hint_count": hint_count,
		"taps": taps,
		"week_index": week_index,
		"score": score,
		"client_version": client_version,
	}


static func from_dict(d: Dictionary) -> GameResult:
	var r := GameResult.new()
	r.result_id = str(d.get("result_id", ""))
	r.player_id = str(d.get("player_id", ""))
	r.level_id = str(d.get("level_id", ""))
	r.size = int(d.get("size", 0))
	r.difficulty = float(d.get("difficulty", 0.0))
	r.stars = int(d.get("stars", 0))
	r.par_seconds = float(d.get("par_seconds", 0.0))
	r.started_at = int(d.get("started_at", 0))
	r.finished_at = int(d.get("finished_at", 0))
	r.elapsed_seconds = float(d.get("elapsed_seconds", 0.0))
	r.completed = bool(d.get("completed", false))
	r.queens_placed = int(d.get("queens_placed", 0))
	r.wrong_placements = int(d.get("wrong_placements", 0))
	r.queens_removed = int(d.get("queens_removed", 0))
	r.undo_count = int(d.get("undo_count", 0))
	r.clear_count = int(d.get("clear_count", 0))
	r.hint_count = int(d.get("hint_count", 0))
	r.taps = int(d.get("taps", 0))
	r.week_index = int(d.get("week_index", 0))
	r.score = int(d.get("score", 0))
	r.client_version = str(d.get("client_version", ""))
	return r
