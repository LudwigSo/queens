class_name Board
extends Control
## Renders a Queens puzzle board and handles tap input.
##
## Rules: exactly one queen per row, column and colour region, and no two
## queens may touch each other (including diagonally).
##
## Tap cycle on a cell: empty -> X mark -> queen -> empty.
## Placing a queen automatically X-marks every cell that can no longer hold a
## queen (its row, column, region and the 8 surrounding cells). Those automatic
## marks are removed again when the queen is removed. Manual marks are kept.

signal state_changed
signal solved

enum Cell { EMPTY, MARK, QUEEN }

const PALETTE: Array[Color] = [
	Color("f6b8b8"), Color("b8d9f6"), Color("c3f0b8"), Color("f6ecb0"), Color("dcbff6"),
	Color("f6cfa0"), Color("b0f0e6"), Color("f6bfe0"), Color("d6dfa0"), Color("c9c9c9"),
]
const GRID_COLOR := Color(0, 0, 0, 0.18)
const BORDER_COLOR := Color("1e1e2a")
const MARK_COLOR := Color(0.1, 0.1, 0.15, 0.55)
const QUEEN_COLOR := Color("1e1e2a")
const CONFLICT_COLOR := Color("d62839")
const SOLVED_COLOR := Color("c58f00")

var size_n: int = 0
var regions: Array = []
var solution: Array = []
var cells: Array = []        ## Cell per [row][col] - what the player set.
var auto_marks: Array = []   ## Number of queens forcing an X on [row][col].
var conflicts: Dictionary = {}
var history: Array = []
var locked: bool = false

var _board_rect: Rect2 = Rect2()
var _cell_size: float = 0.0


func _ready() -> void:
	resized.connect(queue_redraw)


func load_level(level: Dictionary) -> void:
	size_n = level["size"]
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
	queue_redraw()
	state_changed.emit()


func can_undo() -> bool:
	return not history.is_empty() and not locked


func undo() -> void:
	if not can_undo():
		return
	var snap: Dictionary = history.pop_back()
	cells = snap["cells"]
	auto_marks = snap["auto"]
	_recompute_conflicts()
	queue_redraw()
	state_changed.emit()


func queen_count() -> int:
	var n := 0
	for row in cells:
		for v in row:
			if v == Cell.QUEEN:
				n += 1
	return n


func _snapshot() -> Dictionary:
	return {"cells": cells.duplicate(true), "auto": auto_marks.duplicate(true)}


func _gui_input(event: InputEvent) -> void:
	if locked:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cell := _cell_at(event.position)
		if cell.x >= 0:
			_tap(cell.x, cell.y)
			accept_event()


func _cell_at(pos: Vector2) -> Vector2i:
	if _cell_size <= 0.0 or not _board_rect.has_point(pos):
		return Vector2i(-1, -1)
	var local := pos - _board_rect.position
	var c := int(local.x / _cell_size)
	var r := int(local.y / _cell_size)
	if r < 0 or r >= size_n or c < 0 or c >= size_n:
		return Vector2i(-1, -1)
	return Vector2i(r, c)


func _tap(r: int, c: int) -> void:
	history.append(_snapshot())
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
	_recompute_conflicts()
	queue_redraw()
	state_changed.emit()
	_check_solved()


func _place_queen(r: int, c: int) -> void:
	cells[r][c] = Cell.QUEEN
	for p in _affected_cells(r, c):
		auto_marks[p.x][p.y] += 1


func _remove_queen(r: int, c: int) -> void:
	cells[r][c] = Cell.EMPTY
	for p in _affected_cells(r, c):
		auto_marks[p.x][p.y] = maxi(0, auto_marks[p.x][p.y] - 1)


## Every cell (other than the queen cell itself) that cannot hold a queen once
## a queen stands at (r, c): same row, same column, same region, or adjacent.
func _affected_cells(r: int, c: int) -> Array[Vector2i]:
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


func _recompute_conflicts() -> void:
	conflicts.clear()
	var queens: Array[Vector2i] = []
	for r in size_n:
		for c in size_n:
			if cells[r][c] == Cell.QUEEN:
				queens.append(Vector2i(r, c))
	for i in queens.size():
		for j in range(i + 1, queens.size()):
			var a := queens[i]
			var b := queens[j]
			var clash: bool = a.x == b.x or a.y == b.y \
				or regions[a.x][a.y] == regions[b.x][b.y] \
				or (absi(a.x - b.x) <= 1 and absi(a.y - b.y) <= 1)
			if clash:
				conflicts[a] = true
				conflicts[b] = true


func _check_solved() -> void:
	if conflicts.size() > 0 or queen_count() != size_n:
		return
	# n queens with no conflicts cover every row, column and region exactly once.
	locked = true
	queue_redraw()
	solved.emit()


func _draw() -> void:
	if size_n == 0:
		return
	var side := minf(size.x, size.y)
	_cell_size = floorf(side / size_n)
	side = _cell_size * size_n
	_board_rect = Rect2((size - Vector2(side, side)) * 0.5, Vector2(side, side))

	# Cell backgrounds.
	for r in size_n:
		for c in size_n:
			draw_rect(_cell_rect(r, c), PALETTE[regions[r][c] % PALETTE.size()])

	# Thin grid lines.
	for i in range(1, size_n):
		var x := _board_rect.position.x + i * _cell_size
		var y := _board_rect.position.y + i * _cell_size
		draw_line(Vector2(x, _board_rect.position.y), Vector2(x, _board_rect.end.y), GRID_COLOR, 1.0)
		draw_line(Vector2(_board_rect.position.x, y), Vector2(_board_rect.end.x, y), GRID_COLOR, 1.0)

	# Thick borders between regions and around the board.
	var thick := maxf(3.0, _cell_size * 0.06)
	for r in size_n:
		for c in size_n:
			var rect := _cell_rect(r, c)
			if c + 1 < size_n and regions[r][c] != regions[r][c + 1]:
				draw_line(Vector2(rect.end.x, rect.position.y), rect.end, BORDER_COLOR, thick)
			if r + 1 < size_n and regions[r][c] != regions[r + 1][c]:
				draw_line(Vector2(rect.position.x, rect.end.y), rect.end, BORDER_COLOR, thick)
	draw_rect(_board_rect, BORDER_COLOR, false, thick)

	# Marks and queens.
	for r in size_n:
		for c in size_n:
			var rect := _cell_rect(r, c)
			if cells[r][c] == Cell.QUEEN:
				var col := QUEEN_COLOR
				if locked:
					col = SOLVED_COLOR
				elif conflicts.has(Vector2i(r, c)):
					col = CONFLICT_COLOR
				_draw_crown(rect, col)
			elif cells[r][c] == Cell.MARK or auto_marks[r][c] > 0:
				_draw_mark(rect)


func _cell_rect(r: int, c: int) -> Rect2:
	return Rect2(_board_rect.position + Vector2(c, r) * _cell_size, Vector2(_cell_size, _cell_size))


func _draw_mark(rect: Rect2) -> void:
	var inset := rect.size.x * 0.34
	var a := rect.position + Vector2(inset, inset)
	var b := rect.end - Vector2(inset, inset)
	var w := maxf(2.0, rect.size.x * 0.045)
	draw_line(a, b, MARK_COLOR, w, true)
	draw_line(Vector2(a.x, b.y), Vector2(b.x, a.y), MARK_COLOR, w, true)


func _draw_crown(rect: Rect2, color: Color) -> void:
	var s := rect.size.x
	var o := rect.position
	var pts := PackedVector2Array([
		o + Vector2(0.20, 0.78) * s,
		o + Vector2(0.20, 0.42) * s,
		o + Vector2(0.36, 0.56) * s,
		o + Vector2(0.50, 0.24) * s,
		o + Vector2(0.64, 0.56) * s,
		o + Vector2(0.80, 0.42) * s,
		o + Vector2(0.80, 0.78) * s,
	])
	draw_colored_polygon(pts, color)
	draw_circle(o + Vector2(0.50, 0.24) * s, s * 0.045, color)
	draw_circle(o + Vector2(0.20, 0.42) * s, s * 0.045, color)
	draw_circle(o + Vector2(0.80, 0.42) * s, s * 0.045, color)
