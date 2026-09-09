class_name BoardModel
extends RefCounted
## The rules and state of one Queens board, with no rendering or input.
##
## Rules: exactly one queen per row, column and colour region, and no two
## queens may touch each other (including diagonally).
##
## Tap cycle on a cell: empty -> X mark -> queen -> empty. Placing a queen
## automatically X-marks every cell that can no longer hold a queen (its row,
## column, region and the 8 surrounding cells). Those automatic marks are
## removed again when the queen is removed. Manual marks are kept.
##
## A drag "stroke" paints or erases manual marks across many cells and is one
## undo step. Queens are never created or removed by a stroke.

signal state_changed
signal solved
signal tapped(r: int, c: int)                    ## Every player tap on a cell.
signal queen_placed(r: int, c: int, correct: bool)  ## correct = the cell is in the solution.
signal queen_removed(r: int, c: int)
signal undone                                   ## A successful undo.
signal cleared                                  ## The player pressed Clear.
signal stroke_ended(cells_changed: int)         ## A drag stroke that changed something.
signal hint_applied(kind: String, cells: Array)  ## A hint changed the board.

enum Cell { EMPTY, MARK, QUEEN }
enum Stroke { NONE, PAINT, ERASE }

var size_n: int = 0
var regions: Array = []
var solution: Array = []
var cells: Array = []        ## Cell per [row][col] - what the player set.
var auto_marks: Array = []   ## Number of queens forcing an X on [row][col].
var conflicts: Dictionary = {}
var history: Array = []
var locked: bool = false

var _stroke: int = Stroke.NONE
var _stroke_changed: int = 0


func load_level(level: Dictionary) -> void:
	size_n = int(level["size"])
	regions = level["regions"]
	solution = level["solution"]
	reset()


func reset() -> void:
	cells = []
	auto_marks = []
	for r in size_n:
		var row: Array = []
		var marks: Array = []
		row.resize(size_n)
		marks.resize(size_n)
		row.fill(Cell.EMPTY)
		marks.fill(0)
		cells.append(row)
		auto_marks.append(marks)
	history.clear()
	conflicts.clear()
	locked = false
	_stroke = Stroke.NONE
	state_changed.emit()


## Player action: wipe the board. `reset()` does the same silently (used when
## a level is loaded); this one also reports the action.
func clear() -> void:
	reset()
	cleared.emit()


func can_undo() -> bool:
	return not history.is_empty() and not locked


func undo() -> void:
	if not can_undo():
		return
	var snap: Dictionary = history.pop_back()
	cells = snap["cells"]
	auto_marks = snap["auto"]
	_recompute_conflicts()
	state_changed.emit()
	undone.emit()


func queen_count() -> int:
	var n := 0
	for row in cells:
		for v in row:
			if v == Cell.QUEEN:
				n += 1
	return n


func in_bounds(r: int, c: int) -> bool:
	return r >= 0 and r < size_n and c >= 0 and c < size_n


func is_marked(r: int, c: int) -> bool:
	return cells[r][c] == Cell.MARK or auto_marks[r][c] > 0


func is_correct_cell(r: int, c: int) -> bool:
	return int(solution[r]) == c


func is_wrong_queen(r: int, c: int) -> bool:
	return cells[r][c] == Cell.QUEEN and not is_correct_cell(r, c)


func snapshot() -> Dictionary:
	return {"cells": cells.duplicate(true), "auto": auto_marks.duplicate(true)}


# --- taps -----------------------------------------------------------------------

func tap(r: int, c: int) -> void:
	if locked or not in_bounds(r, c):
		return
	history.append(snapshot())
	tapped.emit(r, c)
	match cells[r][c]:
		Cell.EMPTY:
			if auto_marks[r][c] > 0:
				# Already shown as X because of a queen: the next state is a queen.
				_place_queen(r, c)
			else:
				cells[r][c] = Cell.MARK
		Cell.MARK:
			_place_queen(r, c)
		Cell.QUEEN:
			_remove_queen(r, c)
	_after_change()


## Kept for one release so older callers and tests keep working.
func _tap(r: int, c: int) -> void:
	tap(r, c)


## Long-press: a queen straight away, skipping the X step. Only from a cell
## that holds no queen.
func place_directly(r: int, c: int) -> bool:
	if locked or not in_bounds(r, c) or cells[r][c] == Cell.QUEEN:
		return false
	history.append(snapshot())
	tapped.emit(r, c)
	_place_queen(r, c)
	_after_change()
	return true


func _after_change() -> void:
	_recompute_conflicts()
	state_changed.emit()
	_check_solved()


# --- strokes ---------------------------------------------------------------------

## Stroke mode for a drag that starts on (r, c): paint from an unmarked cell,
## erase from a manual mark, nothing from a queen or an automatic mark.
func stroke_mode_for(r: int, c: int) -> int:
	if locked or not in_bounds(r, c):
		return Stroke.NONE
	if cells[r][c] == Cell.QUEEN or auto_marks[r][c] > 0:
		return Stroke.NONE
	return Stroke.ERASE if cells[r][c] == Cell.MARK else Stroke.PAINT


func begin_stroke(mode: int) -> void:
	if locked or mode == Stroke.NONE:
		return
	_stroke = mode
	_stroke_changed = 0
	history.append(snapshot())


func in_stroke() -> bool:
	return _stroke != Stroke.NONE


## Applies the stroke to one cell. Returns true when the cell changed.
func stroke_cell(r: int, c: int) -> bool:
	if _stroke == Stroke.NONE or not in_bounds(r, c):
		return false
	if cells[r][c] == Cell.QUEEN or auto_marks[r][c] > 0:
		return false
	var target := Cell.MARK if _stroke == Stroke.PAINT else Cell.EMPTY
	if cells[r][c] == target:
		return false
	cells[r][c] = target
	_stroke_changed += 1
	state_changed.emit()
	return true


## Returns how many cells the stroke changed. An empty stroke leaves no undo step.
func end_stroke() -> int:
	if _stroke == Stroke.NONE:
		return 0
	_stroke = Stroke.NONE
	var changed := _stroke_changed
	_stroke_changed = 0
	if changed == 0:
		history.pop_back()
	else:
		stroke_ended.emit(changed)
	return changed


## Marks several cells as one undo step (used by hints).
func apply_marks(targets: Array, kind: String) -> void:
	if locked:
		return
	begin_stroke(Stroke.PAINT)
	var changed: Array = []
	for p in targets:
		if stroke_cell(p.x, p.y):
			changed.append(p)
	_stroke = Stroke.NONE
	if changed.is_empty():
		history.pop_back()
		return
	_stroke_changed = 0
	hint_applied.emit(kind, changed)


## Places a queen as a hint (one undo step).
func apply_queen(r: int, c: int, kind: String) -> void:
	if place_directly(r, c):
		hint_applied.emit(kind, [Vector2i(r, c)])


# --- queens ----------------------------------------------------------------------

func _place_queen(r: int, c: int) -> void:
	cells[r][c] = Cell.QUEEN
	for p in affected_cells(r, c):
		auto_marks[p.x][p.y] += 1
	queen_placed.emit(r, c, is_correct_cell(r, c))


func _remove_queen(r: int, c: int) -> void:
	cells[r][c] = Cell.EMPTY
	for p in affected_cells(r, c):
		auto_marks[p.x][p.y] = maxi(0, auto_marks[p.x][p.y] - 1)
	queen_removed.emit(r, c)


## Every cell (other than the queen cell itself) that cannot hold a queen once
## a queen stands at (r, c): same row, same column, same region, or adjacent.
func affected_cells(r: int, c: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var region_id: int = regions[r][c]
	for rr in size_n:
		for cc in size_n:
			if rr == r and cc == c:
				continue
			var hit: bool = rr == r or cc == c or regions[rr][cc] == region_id \
				or (absi(rr - r) <= 1 and absi(cc - c) <= 1)
			if hit:
				result.append(Vector2i(rr, cc))
	return result


func _affected_cells(r: int, c: int) -> Array[Vector2i]:
	return affected_cells(r, c)


func queens() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for r in size_n:
		for c in size_n:
			if cells[r][c] == Cell.QUEEN:
				result.append(Vector2i(r, c))
	return result


func clash(a: Vector2i, b: Vector2i) -> bool:
	return a.x == b.x or a.y == b.y \
		or regions[a.x][a.y] == regions[b.x][b.y] \
		or (absi(a.x - b.x) <= 1 and absi(a.y - b.y) <= 1)


func _recompute_conflicts() -> void:
	conflicts.clear()
	var qs := queens()
	for i in qs.size():
		for j in range(i + 1, qs.size()):
			if clash(qs[i], qs[j]):
				conflicts[qs[i]] = true
				conflicts[qs[j]] = true


func _check_solved() -> void:
	if conflicts.size() > 0 or queen_count() != size_n:
		return
	# n queens with no conflicts cover every row, column and region exactly once.
	locked = true
	state_changed.emit()
	solved.emit()


# --- queries for hints and views -----------------------------------------------------

## Cells that could still hold a queen: no mark of any kind and not attacked.
func candidates() -> Array[Vector2i]:
	var attacked := {}
	for q in queens():
		attacked[q] = true
		for p in affected_cells(q.x, q.y):
			attacked[p] = true
	var result: Array[Vector2i] = []
	for r in size_n:
		for c in size_n:
			var p := Vector2i(r, c)
			if cells[r][c] == Cell.EMPTY and auto_marks[r][c] == 0 and not attacked.has(p):
				result.append(p)
	return result


func region_cells(region_id: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for r in size_n:
		for c in size_n:
			if regions[r][c] == region_id:
				result.append(Vector2i(r, c))
	return result


func region_count() -> int:
	var seen := {}
	for row in regions:
		for v in row:
			seen[int(v)] = true
	return seen.size()


func row_has_queen(r: int) -> bool:
	for c in size_n:
		if cells[r][c] == Cell.QUEEN:
			return true
	return false


func col_has_queen(c: int) -> bool:
	for r in size_n:
		if cells[r][c] == Cell.QUEEN:
			return true
	return false


func region_has_queen(region_id: int) -> bool:
	for p in region_cells(region_id):
		if cells[p.x][p.y] == Cell.QUEEN:
			return true
	return false
