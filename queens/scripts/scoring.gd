class_name Scoring
extends RefCounted
## Score of a finished game and the calendar week it belongs to. Pure static
## functions with all constants in one place, so the client, the local
## backend stub and a future server compute identical numbers.
##
##   base     = 10 * difficulty + 10 * size
##   par      = 30 + 3 * difficulty + 0.5 * size^2   (seconds)
##   accuracy = 1 / (1 + 0.4 * wrong)                dominant factor
##   speed    = clamp(0.5 + 0.5 * par / t, 0.5, 1.25) secondary, capped
##   undo     = clamp(1 - 0.01 * undos, 0.85, 1)     nudge only
##   hint     = clamp(1 - 0.15 * hints, 0.4, 1)      hints are free but cost score
##   score    = round(base * accuracy * speed * undo * hint), 0 for a forfeit
##
## A sloppy hard level scores below a perfect easy one on purpose: the
## score steers the player to the difficulty where they are accurate.

const BASE_PER_DIFFICULTY := 10.0
const BASE_PER_SIZE := 10.0
const PAR_BASE := 30.0
const PAR_PER_DIFFICULTY := 3.0
const PAR_PER_CELL := 0.5           ## times size^2
const K_WRONG := 0.4
const SPEED_MIN := 0.5
const SPEED_MAX := 1.25
const UNDO_PENALTY := 0.01
const UNDO_MIN := 0.85
const HINT_PENALTY := 0.15
const HINT_MIN := 0.4

const WEEK_SECONDS := 604800
const WEEK_EPOCH_OFFSET := 345600   ## Unix epoch is a Thursday; Monday 1970-01-05 00:00 UTC.


static func base(difficulty: float, size: int) -> int:
	return int(round(BASE_PER_DIFFICULTY * difficulty + BASE_PER_SIZE * size))


static func par_seconds(difficulty: float, size: int) -> float:
	return PAR_BASE + PAR_PER_DIFFICULTY * difficulty + PAR_PER_CELL * size * size


static func accuracy_factor(wrong_placements: int) -> float:
	return 1.0 / (1.0 + K_WRONG * maxi(wrong_placements, 0))


static func speed_factor(elapsed_seconds: float, par: float) -> float:
	if elapsed_seconds <= 0.0:
		return SPEED_MAX
	return clampf(0.5 + 0.5 * par / elapsed_seconds, SPEED_MIN, SPEED_MAX)


static func undo_factor(undo_count: int) -> float:
	return clampf(1.0 - UNDO_PENALTY * maxi(undo_count, 0), UNDO_MIN, 1.0)


static func hint_factor(hint_count: int) -> float:
	return clampf(1.0 - HINT_PENALTY * maxi(hint_count, 0), HINT_MIN, 1.0)


## Full breakdown for a GameResult dictionary (see GameResult.to_dict).
## Uses the result's own par_seconds when present so stored results are
## reproducible even after the par formula changes.
static func breakdown(result: Dictionary) -> Dictionary:
	var difficulty := float(result.get("difficulty", 0.0))
	var size := int(result.get("size", 0))
	var par := float(result.get("par_seconds", 0.0))
	if par <= 0.0:
		par = par_seconds(difficulty, size)
	var completed := bool(result.get("completed", false))
	var wrong := int(result.get("wrong_placements", 0))
	var undos := int(result.get("undo_count", 0))
	var hints := int(result.get("hint_count", 0))
	var b := base(difficulty, size)
	var accuracy := accuracy_factor(wrong)
	var speed := speed_factor(float(result.get("elapsed_seconds", 0.0)), par)
	var undo := undo_factor(undos)
	var hint := hint_factor(hints)
	var total := int(round(b * accuracy * speed * undo * hint)) if completed else 0
	return {
		"score": total,
		"base": b,
		"par_seconds": par,
		"accuracy_factor": accuracy,
		"speed_factor": speed,
		"undo_factor": undo,
		"hint_factor": hint,
		"flawless": completed and wrong == 0 and hints == 0,
	}


static func score(result: Dictionary) -> int:
	return int(breakdown(result)["score"])


## Weeks start Monday 00:00 UTC; index 0 is the week of 1970-01-05.
static func week_index(unix_time: int) -> int:
	return int(floor(float(unix_time - WEEK_EPOCH_OFFSET) / WEEK_SECONDS))


static func week_start(index: int) -> int:
	return index * WEEK_SECONDS + WEEK_EPOCH_OFFSET


static func week_end(index: int) -> int:
	return week_start(index + 1)
