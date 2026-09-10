class_name HintFinder
extends RefCounted
## Finds the next hint for a board, cheapest deduction first. Every hint is
## verified against the shipped solution, so a hint never places a wrong
## queen. Pure and stateless: `find()` only reads the model.
##
## Returned dictionary:
##   kind   "wrong_queen" | "wrong_mark" | "single" | "confined" | "reveal" | "none"
##   cells  cells to highlight (Array[Vector2i])
##   unit   the row/column/region cells that explain the deduction (Array[Vector2i])
##   place  the queen cell to place, or null
##   marks  cells to X-mark (confined), Array[Vector2i]
##   text   one sentence for the player


static func find(m: BoardModel) -> Dictionary:
	if m.locked or m.size_n == 0:
		return _none()
	var wrong := _wrong_queen(m)
	if not wrong.is_empty():
		return wrong
	var mark := _wrong_mark(m)
	if not mark.is_empty():
		return mark
	var cands := m.candidates()
	var single := _single(m, cands)
	if not single.is_empty():
		return single
	var confined := _confined(m, cands)
	if not confined.is_empty():
		return confined
	return _reveal(m, cands)


static func _none() -> Dictionary:
	return {"kind": "none", "cells": [], "unit": [], "place": null, "marks": [], "text_key": "HINT_NONE"}


static func _wrong_queen(m: BoardModel) -> Dictionary:
	for q in m.queens():
		if not m.is_correct_cell(q.x, q.y):
			return {"kind": "wrong_queen", "cells": [q], "unit": [], "place": null, "marks": [],
				"text_key": "HINT_WRONG_QUEEN"}
	return {}


static func _wrong_mark(m: BoardModel) -> Dictionary:
	for r in m.size_n:
		var c := int(m.solution[r])
		if m.cells[r][c] == BoardModel.Cell.MARK:
			return {"kind": "wrong_mark", "cells": [Vector2i(r, c)], "unit": [], "place": null, "marks": [],
				"text_key": "HINT_WRONG_MARK"}
	return {}


## A row, column or region with exactly one candidate: the queen goes there.
static func _single(m: BoardModel, cands: Array[Vector2i]) -> Dictionary:
	var by_row := {}
	var by_col := {}
	var by_region := {}
	for p in cands:
		_push(by_row, p.x, p)
		_push(by_col, p.y, p)
		_push(by_region, int(m.regions[p.x][p.y]), p)
	for r in m.size_n:
		if not m.row_has_queen(r) and by_row.get(r, []).size() == 1:
			var p: Vector2i = by_row[r][0]
			if m.is_correct_cell(p.x, p.y):
				return _single_result(p, _row_cells(m, r), "HINT_SINGLE_ROW")
	for c in m.size_n:
		if not m.col_has_queen(c) and by_col.get(c, []).size() == 1:
			var p: Vector2i = by_col[c][0]
			if m.is_correct_cell(p.x, p.y):
				return _single_result(p, _col_cells(m, c), "HINT_SINGLE_COL")
	for reg in by_region:
		if not m.region_has_queen(reg) and by_region[reg].size() == 1:
			var p: Vector2i = by_region[reg][0]
			if m.is_correct_cell(p.x, p.y):
				return _single_result(p, m.region_cells(reg), "HINT_SINGLE_REGION")
	return {}


static func _single_result(p: Vector2i, unit: Array, text_key: String) -> Dictionary:
	return {"kind": "single", "cells": [p], "unit": unit, "place": p, "marks": [], "text_key": text_key}


## A region whose candidates all share one row (or column): the rest of that
## row (column) can be marked.
static func _confined(m: BoardModel, cands: Array[Vector2i]) -> Dictionary:
	var by_region := {}
	for p in cands:
		_push(by_region, int(m.regions[p.x][p.y]), p)
	var cand_set := {}
	for p in cands:
		cand_set[p] = true
	for reg in by_region:
		if m.region_has_queen(reg):
			continue
		var ps: Array = by_region[reg]
		if ps.size() < 2:
			continue
		var same_row := true
		var same_col := true
		for p in ps:
			same_row = same_row and p.x == ps[0].x
			same_col = same_col and p.y == ps[0].y
		if same_row:
			var marks: Array[Vector2i] = []
			for c in m.size_n:
				var p := Vector2i(ps[0].x, c)
				if cand_set.has(p) and int(m.regions[p.x][p.y]) != reg:
					marks.append(p)
			if not marks.is_empty():
				return {"kind": "confined", "cells": ps, "unit": _row_cells(m, ps[0].x), "place": null, "marks": marks,
					"text_key": "HINT_CONFINED_ROW"}
		if same_col:
			var marks: Array[Vector2i] = []
			for r in m.size_n:
				var p := Vector2i(r, ps[0].y)
				if cand_set.has(p) and int(m.regions[p.x][p.y]) != reg:
					marks.append(p)
			if not marks.is_empty():
				return {"kind": "confined", "cells": ps, "unit": _col_cells(m, ps[0].y), "place": null, "marks": marks,
					"text_key": "HINT_CONFINED_COL"}
	return {}


## Fallback: the solution cell of the open row with the fewest candidates.
static func _reveal(m: BoardModel, cands: Array[Vector2i]) -> Dictionary:
	var counts := {}
	for p in cands:
		counts[p.x] = int(counts.get(p.x, 0)) + 1
	var best_row := -1
	var best_count := 1 << 30
	for r in m.size_n:
		if m.row_has_queen(r):
			continue
		var n := int(counts.get(r, 0))
		if n < best_count:
			best_count = n
			best_row = r
	if best_row < 0:
		return _none()
	var p := Vector2i(best_row, int(m.solution[best_row]))
	return {"kind": "reveal", "cells": [p], "unit": _row_cells(m, best_row), "place": p, "marks": [], "text_key": "HINT_REVEAL"}


## Applies a hint to the model. Returns the cells changed.
static func apply(m: BoardModel, hint: Dictionary) -> Array:
	match str(hint.get("kind", "none")):
		"single", "reveal":
			var p: Vector2i = hint["place"]
			m.apply_queen(p.x, p.y, hint["kind"])
			return [p]
		"confined":
			m.apply_marks(hint["marks"], "confined")
			return hint["marks"]
	return []


static func _push(d: Dictionary, key, p: Vector2i) -> void:
	if not d.has(key):
		d[key] = []
	d[key].append(p)


static func _row_cells(m: BoardModel, r: int) -> Array:
	var out: Array = []
	for c in m.size_n:
		out.append(Vector2i(r, c))
	return out


static func _col_cells(m: BoardModel, c: int) -> Array:
	var out: Array = []
	for r in m.size_n:
		out.append(Vector2i(r, c))
	return out
