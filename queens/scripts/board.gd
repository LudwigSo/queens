class_name Board
extends Control
## Renders a BoardModel and turns touch input into moves.
##
## The rules live in `model` (BoardModel). This node owns the look: glossy
## tiles drawn in `_draw()`, crown sprites as children, and every feedback
## animation (pops, ripples, conflict shakes, mistake flashes, hint glows,
## the win wave and confetti). Animations read `Motion.instant` so tests see
## final states on the next frame.
##
## Input: single-finger touch. Tap cycles a cell (see BoardModel.tap), a drag
## paints or erases X marks as one stroke, a long press places a queen directly.

signal state_changed
signal solved
signal celebration_finished

const MARK_PATH := "res://assets/board/mark.svg"
const CROWN_PATHS := {
	"ink": "res://assets/board/crown_ink.svg",
	"red": "res://assets/board/crown_red.svg",
	"gold": "res://assets/board/crown_gold.svg",
}

const PLATE_PAD := 8.0
const CROWN_SCALE := 0.74
const MARK_SCALE_MANUAL := 0.44
const MARK_SCALE_AUTO := 0.32
const MARK_ALPHA_MANUAL := 0.62
const MARK_ALPHA_AUTO := 0.30
const LONG_PRESS_SECONDS := 0.45
const SLOP_PX := 14.0

enum Gesture { IDLE, PRESSED, DRAGGING }

var model: BoardModel = BoardModel.new()
var input_enabled: bool = true
var mistake_alerts: bool = true
var allowed_cells: Array = []        ## Tutorial: only these cells accept input (empty = all).
var region_patterns: bool = false    ## Colour-vision aid: pattern overlay per region.

# Pass-throughs so callers and tests can keep using the board as before.
var size_n: int:
	get: return model.size_n
var solution: Array:
	get: return model.solution
var regions: Array:
	get: return model.regions
var cells: Array:
	get: return model.cells
var auto_marks: Array:
	get: return model.auto_marks
var conflicts: Dictionary:
	get: return model.conflicts
var locked: bool:
	get: return model.locked

var _mark: Texture2D
var _crown_tex: Dictionary = {}
var _plate_style: StyleBoxFlat

var _board_rect: Rect2 = Rect2()
var _cell_size: float = 0.0

var _pieces: Node2D
var _crowns: Dictionary = {}          ## Vector2i -> Sprite2D
var _confetti: CPUParticles2D

# Animation values per cell, all read by _draw().
var _mark_alpha: Dictionary = {}      ## 0..1 fade of the X mark
var _mark_scale: Dictionary = {}      ## scale factor of the X mark
var _pulse: Dictionary = {}           ## conflict red overlay
var _flash: Dictionary = {}           ## mistake flash
var _glow: Dictionary = {}            ## hint amber overlay
var _bright: Dictionary = {}          ## win white overlay
var _ring: float = 0.0
var _last_cell: Vector2i = Vector2i(-1, -1)
var _pressed_cell: Vector2i = Vector2i(-1, -1)
var _plate_scale: float = 1.0

var _prev_cells: Array = []
var _prev_auto: Array = []
var _prev_conflicts: Dictionary = {}
var _suppress_diff: bool = false

# Gesture state.
var _gesture: int = Gesture.IDLE
var _finger: int = -1
var _press_pos: Vector2 = Vector2.ZERO
var _press_cell: Vector2i = Vector2i(-1, -1)
var _press_time: float = 0.0
var _long_press_done: bool = false
var _stroke_cells: int = 0


var _setup_done: bool = false
var _tweens: Array[Tween] = []


func _ready() -> void:
	_setup()
	resized.connect(_on_resized)
	set_process(false)
	_layout()


## Builds textures, styles and child nodes once. Called from _ready, or
## lazily when a board is driven before it entered the tree (tests).
func _setup() -> void:
	if _setup_done:
		return
	_setup_done = true
	_mark = _load_tex(MARK_PATH)
	for key in CROWN_PATHS:
		_crown_tex[key] = _load_tex(CROWN_PATHS[key])
	_plate_style = StyleBoxFlat.new()
	_plate_style.bg_color = Ui.PLATE
	_plate_style.set_corner_radius_all(0)
	_plate_style.shadow_size = 14
	_plate_style.shadow_color = Ui.SHADOW_STRONG
	_plate_style.shadow_offset = Vector2(0, 8)
	_plate_style.anti_aliasing = true
	_pieces = Node2D.new()
	_pieces.name = "Pieces"
	add_child(_pieces)
	_confetti = _make_confetti()
	add_child(_confetti)
	model.state_changed.connect(_on_model_changed)
	model.queen_placed.connect(_on_queen_placed)
	model.solved.connect(_on_solved)
	model.hint_applied.connect(_on_hint_applied)


func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path, "Texture2D"):
		return load(path)
	return null


# --- public API -----------------------------------------------------------------

func load_level(level: Dictionary) -> void:
	_setup()
	_suppress_diff = true
	model.load_level(level)
	_suppress_diff = false
	_reset_view()


func reset() -> void:
	_suppress_diff = true
	model.reset()
	_suppress_diff = false
	_reset_view()


func clear() -> void:
	if model.locked:
		return
	var had_pieces := not _crowns.is_empty() or _any_marks()
	_suppress_diff = true
	model.clear()
	_suppress_diff = false
	if had_pieces:
		_animate_clear()
	else:
		_reset_view()
	Sfx.play(&"clear")
	Sfx.haptic(20)


func queen_count() -> int:
	return model.queen_count()


func tap_cell(r: int, c: int) -> void:
	_last_cell = Vector2i(r, c)
	model.tap(r, c)


## Kept for callers and tests that drove the old single-node board.
func _tap(r: int, c: int) -> void:
	tap_cell(r, c)


## Rect of a cell in this control's local space.
func _cell_rect(r: int, c: int) -> Rect2:
	return Rect2(_board_rect.position + Vector2(c, r) * _cell_size, Vector2(_cell_size, _cell_size))


func cell_rect(r: int, c: int) -> Rect2:
	return _cell_rect(r, c)


## Centre of a cell in global coordinates (for synthetic input in tests).
func cell_center(r: int, c: int) -> Vector2:
	return global_position + _cell_rect(r, c).get_center()


## Highlights cells (hint / tutorial). `seconds` 0 keeps the glow until cleared.
func set_glow(targets: Array, seconds: float = 0.0) -> void:
	for p in targets:
		if seconds > 0.0:
			_pulse_value(_glow, p, 0.0, 0.65, seconds * 0.5, seconds * 0.5)
		else:
			_glow[p] = 0.55
	queue_redraw()


func clear_glow() -> void:
	_glow.clear()
	queue_redraw()


## Applies a hint from HintFinder with its animations.
func apply_hint(hint: Dictionary) -> void:
	var kind := str(hint.get("kind", "none"))
	if kind == "none":
		return
	var unit: Array = hint.get("unit", [])
	var cells_hl: Array = hint.get("cells", [])
	for p in unit:
		_pulse_value(_glow, p, 0.0, 0.28, 0.5, 1.1)
	for p in cells_hl:
		_pulse_value(_glow, p, 0.0, 0.7, 0.5, 1.3)
	Sfx.play(&"hint")
	Sfx.haptic(20)
	if kind in ["single", "reveal", "confined"]:
		var target = hint.get("place")
		if target != null:
			_last_cell = target
		# Apply after the glow has had a moment so the player sees the reasoning.
		var delay := Motion.d(0.45)
		if delay > 0.0:
			await get_tree().create_timer(delay).timeout
		HintFinder.apply(model, hint)


# --- layout and drawing -------------------------------------------------------------

func _on_resized() -> void:
	_layout()
	_place_all_crowns()
	queue_redraw()


func _layout() -> void:
	if model.size_n == 0:
		_cell_size = 0.0
		return
	var side := minf(size.x, size.y) - 2.0 * PLATE_PAD
	_cell_size = floorf(side / model.size_n)
	side = _cell_size * model.size_n
	# The origin is floored: a half-pixel offset puts the thin separators on a
	# pixel centre, where the unantialiased rasteriser drops some of them.
	_board_rect = Rect2(((size - Vector2(side, side)) * 0.5).floor(), Vector2(side, side))


func _draw() -> void:
	if model.size_n == 0 or _cell_size <= 0.0:
		return
	var n := model.size_n
	var plate := _board_rect.grow(PLATE_PAD)
	if _plate_scale != 1.0:
		var center := plate.get_center()
		plate = Rect2(center - plate.size * 0.5 * _plate_scale, plate.size * _plate_scale)
	draw_style_box(_plate_style, plate)

	# Cells: one flat colour per region, filling the whole cell.
	for r in n:
		for c in n:
			var p := Vector2i(r, c)
			var col := Ui.region_color(int(model.regions[r][c]))
			var rect := _cell_rect(r, c)
			if p == _pressed_cell:
				col = col.darkened(0.10)
			draw_rect(rect, col)
			if region_patterns:
				_draw_pattern(rect, int(model.regions[r][c]))
			var bright: float = _bright.get(p, 0.0)
			if bright > 0.0:
				draw_rect(rect, Color(1, 1, 1, bright))
			var glow: float = _glow.get(p, 0.0)
			if glow > 0.0:
				draw_rect(rect, Color(Ui.HINT_GLOW, glow))
			var pulse: float = _pulse.get(p, 0.0)
			if pulse > 0.0:
				draw_rect(rect, Color(Ui.ERROR, pulse))
			var flash: float = _flash.get(p, 0.0)
			if flash > 0.0:
				draw_rect(rect, Color(Ui.ERROR, flash))

	# Hairlines between cells of the same region. The width follows the cell and
	# keeps a two pixel floor, so the lines survive the canvas downscale on a
	# small screen instead of thinning below one device pixel and flickering.
	var hair := Color(Ui.INK, 0.20)
	var hw := maxf(2.0, roundf(_cell_size * 0.03))
	for i in range(1, n):
		var x := _board_rect.position.x + i * _cell_size
		var y := _board_rect.position.y + i * _cell_size
		draw_rect(Rect2(x - hw * 0.5, _board_rect.position.y, hw, _board_rect.size.y), hair)
		draw_rect(Rect2(_board_rect.position.x, y - hw * 0.5, _board_rect.size.x, hw), hair)

	# Region borders: filled bars centred on the shared edge, extended by half
	# their thickness so joints are square and gap-free.
	var t := _border_width()
	var h := t * 0.5
	for r in n:
		for c in n:
			var rect := _cell_rect(r, c)
			if c + 1 < n and model.regions[r][c] != model.regions[r][c + 1]:
				draw_rect(Rect2(rect.end.x - h, rect.position.y - h, t, rect.size.y + t), Ui.PLATE)
			if r + 1 < n and model.regions[r][c] != model.regions[r + 1][c]:
				draw_rect(Rect2(rect.position.x - h, rect.end.y - h, rect.size.x + t, t), Ui.PLATE)

	# Marks.
	for r in n:
		for c in n:
			var p := Vector2i(r, c)
			var manual: bool = model.cells[r][c] == BoardModel.Cell.MARK
			var auto: bool = model.auto_marks[r][c] > 0
			var alpha: float = _mark_alpha.get(p, 1.0 if (manual or auto) else 0.0)
			if alpha <= 0.0:
				continue
			var base_scale := MARK_SCALE_MANUAL if manual else MARK_SCALE_AUTO
			var base_alpha := MARK_ALPHA_MANUAL if manual else MARK_ALPHA_AUTO
			if not (manual or auto):
				# Fading out: keep the last look.
				base_scale = MARK_SCALE_MANUAL
				base_alpha = MARK_ALPHA_MANUAL
			var s: float = base_scale * _mark_scale.get(p, 1.0)
			var rect := _cell_rect(r, c)
			var mark_size := rect.size.x * s
			var mark_rect := Rect2(rect.get_center() - Vector2(mark_size, mark_size) * 0.5, Vector2(mark_size, mark_size))
			if _mark != null:
				draw_texture_rect(_mark, mark_rect, false, Color(Ui.INK, base_alpha * alpha))
			else:
				var w := maxf(2.0, rect.size.x * 0.045)
				draw_line(mark_rect.position, mark_rect.end, Color(Ui.INK, base_alpha * alpha), w, true)
				draw_line(Vector2(mark_rect.position.x, mark_rect.end.y), Vector2(mark_rect.end.x, mark_rect.position.y), Color(Ui.INK, base_alpha * alpha), w, true)

	# Ring on the last changed queen cell.
	if _ring > 0.0 and model.in_bounds(_last_cell.x, _last_cell.y):
		draw_rect(_cell_rect(_last_cell.x, _last_cell.y).grow(-_border_width() * 0.5 - 1.0), Color(Ui.INK, _ring * 0.35), false, 2.0)


func _border_width() -> float:
	return maxf(5.0, roundf(_cell_size * 0.08))


## Colour-vision aid: a distinct line pattern per region at low contrast.
func _draw_pattern(rect: Rect2, region_id: int) -> void:
	var col := Color(Ui.INK, 0.12)
	var step := maxf(6.0, rect.size.x / 5.0)
	match region_id % 5:
		0:
			pass
		1:
			var x := rect.position.x
			while x < rect.end.x:
				draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), col, 1.5)
				x += step
		2:
			var y := rect.position.y
			while y < rect.end.y:
				draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), col, 1.5)
				y += step
		3:
			var d := -rect.size.y
			while d < rect.size.x:
				var a := Vector2(rect.position.x + maxf(d, 0.0), rect.position.y + maxf(-d, 0.0))
				var b := Vector2(rect.position.x + minf(d + rect.size.y, rect.size.x), rect.position.y + minf(rect.size.x - d, rect.size.y))
				draw_line(a, b, col, 1.5)
				d += step
		4:
			var y := rect.position.y + step * 0.5
			while y < rect.end.y:
				var x := rect.position.x + step * 0.5
				while x < rect.end.x:
					draw_circle(Vector2(x, y), 2.0, col)
					x += step
				y += step


# --- crowns --------------------------------------------------------------------------

func _crown_key(p: Vector2i) -> String:
	if model.locked:
		return "gold"
	if model.conflicts.has(p):
		return "red"
	return "ink"


func _crown_scale() -> float:
	var tex: Texture2D = _crown_tex.get("ink")
	if tex == null:
		return 1.0
	return _cell_size * CROWN_SCALE / tex.get_width()


func _spawn_crown(p: Vector2i, animate: bool) -> Sprite2D:
	var sp := Sprite2D.new()
	sp.texture = _crown_tex.get(_crown_key(p))
	sp.position = _cell_rect(p.x, p.y).get_center()
	var s := _crown_scale()
	sp.scale = Vector2(s, s)
	_pieces.add_child(sp)
	_crowns[p] = sp
	if animate and Motion.effects_enabled():
		sp.scale = Vector2(s * 0.4, s * 0.4)
		var t := sp.create_tween()
		t.tween_property(sp, "scale", Vector2(s * 1.18, s * 1.18), 0.11).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(sp, "scale", Vector2(s, s), 0.10).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	return sp


func _remove_crown(p: Vector2i, animate: bool) -> void:
	if not _crowns.has(p):
		return
	var sp: Sprite2D = _crowns[p]
	_crowns.erase(p)
	if animate and Motion.effects_enabled():
		var t := sp.create_tween()
		t.tween_property(sp, "scale", Vector2.ZERO, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		t.tween_callback(sp.queue_free)
	else:
		sp.queue_free()


func _place_all_crowns() -> void:
	var s := _crown_scale()
	for p in _crowns:
		var sp: Sprite2D = _crowns[p]
		sp.position = _cell_rect(p.x, p.y).get_center()
		sp.scale = Vector2(s, s)


func _retint_crowns() -> void:
	for p in _crowns:
		var sp: Sprite2D = _crowns[p]
		var tex: Texture2D = _crown_tex.get(_crown_key(p))
		if sp.texture != tex:
			sp.texture = tex


func _shake_crown(p: Vector2i) -> void:
	if not _crowns.has(p) or not Motion.effects_enabled():
		return
	var sp: Sprite2D = _crowns[p]
	var rest := _cell_rect(p.x, p.y).get_center()
	var t := sp.create_tween()
	for i in 3:
		t.tween_property(sp, "position:x", rest.x + 6.0, 0.045)
		t.tween_property(sp, "position:x", rest.x - 6.0, 0.045)
	t.tween_property(sp, "position:x", rest.x, 0.045)


func _wobble_crown(p: Vector2i) -> void:
	if not _crowns.has(p) or not Motion.effects_enabled():
		return
	var sp: Sprite2D = _crowns[p]
	var t := sp.create_tween()
	t.tween_property(sp, "rotation", deg_to_rad(8.0), 0.07)
	t.tween_property(sp, "rotation", deg_to_rad(-8.0), 0.09)
	t.tween_property(sp, "rotation", deg_to_rad(4.0), 0.07)
	t.tween_property(sp, "rotation", 0.0, 0.07)


# --- model change -> animations -----------------------------------------------------------

## A tween that is killed by the next reset, so stale animations never
## write into the overlay maps of a new level.
func _tw() -> Tween:
	var t := create_tween()
	_tweens.append(t)
	if _tweens.size() > 64:
		_tweens = _tweens.filter(func(x: Tween) -> bool: return x.is_valid())
	return t


func _kill_tweens() -> void:
	for t in _tweens:
		if t.is_valid():
			t.kill()
	_tweens.clear()


func _reset_view() -> void:
	_kill_tweens()
	for p in _crowns.keys():
		_remove_crown(p, false)
	if _confetti != null:
		_confetti.emitting = false
		_confetti.visible = false
	_mark_alpha.clear()
	_mark_scale.clear()
	_pulse.clear()
	_flash.clear()
	_glow.clear()
	_bright.clear()
	_ring = 0.0
	_pressed_cell = Vector2i(-1, -1)
	_plate_scale = 1.0
	_layout()
	_snapshot_prev()
	state_changed.emit()
	queue_redraw()


func _snapshot_prev() -> void:
	_prev_cells = model.cells.duplicate(true)
	_prev_auto = model.auto_marks.duplicate(true)
	_prev_conflicts = model.conflicts.duplicate()


func _any_marks() -> bool:
	for r in model.size_n:
		for c in model.size_n:
			if model.is_marked(r, c):
				return true
	return false


func _on_model_changed() -> void:
	if _suppress_diff:
		return
	if _prev_cells.size() != model.size_n:
		_snapshot_prev()
		_reset_view()
		return
	var n := model.size_n
	var origin := _last_cell
	var placed_queen := false
	var removed_queen := false
	for r in n:
		for c in n:
			var p := Vector2i(r, c)
			var was_q: bool = _prev_cells[r][c] == BoardModel.Cell.QUEEN
			var is_q: bool = model.cells[r][c] == BoardModel.Cell.QUEEN
			if is_q and not was_q:
				_spawn_crown(p, true)
				placed_queen = true
			elif was_q and not is_q:
				_remove_crown(p, true)
				removed_queen = true
			var was_m: bool = _prev_cells[r][c] == BoardModel.Cell.MARK or _prev_auto[r][c] > 0
			var is_m: bool = model.cells[r][c] == BoardModel.Cell.MARK or model.auto_marks[r][c] > 0
			if is_m and not was_m:
				var delay := 0.0
				if placed_queen and model.in_bounds(origin.x, origin.y):
					delay = 0.012 * maxi(absi(p.x - origin.x), absi(p.y - origin.y))
				_anim_mark_in(p, delay)
			elif was_m and not is_m:
				_anim_mark_out(p)
	# Conflicts: pulse the shared line of every newly clashing pair.
	var new_conflicts: Array[Vector2i] = []
	for q in model.conflicts:
		if not _prev_conflicts.has(q):
			new_conflicts.append(q)
	if not new_conflicts.is_empty():
		_show_conflicts(new_conflicts)
	_retint_crowns()
	if placed_queen:
		_ring = 1.0
		_pulse_scalar("_ring", 1.0, 0.0, 1.2)
		Sfx.play(&"queen_place")
		Sfx.haptic(25)
	elif removed_queen:
		Sfx.play(&"queen_remove")
		Sfx.haptic(15)
	_snapshot_prev()
	state_changed.emit()
	queue_redraw()


func _show_conflicts(new_conflicts: Array[Vector2i]) -> void:
	var qs := model.queens()
	var pulsed := {}
	for a in new_conflicts:
		_shake_crown(a)
		for b in qs:
			if a == b or not model.clash(a, b):
				continue
			for p in _conflict_cells(a, b):
				if not pulsed.has(p):
					pulsed[p] = true
					_pulse_value(_pulse, p, 0.35, 0.0, 0.5, 0.0)
	Sfx.play(&"conflict")
	Sfx.haptic_double(40)


## The cells that explain why queens a and b clash.
func _conflict_cells(a: Vector2i, b: Vector2i) -> Array:
	var out: Array = []
	if a.x == b.x:
		for c in model.size_n:
			out.append(Vector2i(a.x, c))
	elif a.y == b.y:
		for r in model.size_n:
			out.append(Vector2i(r, a.y))
	elif model.regions[a.x][a.y] == model.regions[b.x][b.y]:
		out = model.region_cells(int(model.regions[a.x][a.y]))
	else:
		for dr in range(-1, 2):
			for dc in range(-1, 2):
				var p := a + Vector2i(dr, dc)
				if model.in_bounds(p.x, p.y):
					out.append(p)
	return out


func _on_queen_placed(r: int, c: int, correct: bool) -> void:
	if correct or not mistake_alerts or _suppress_diff:
		return
	var p := Vector2i(r, c)
	# Two red pulses on the cell plus a wobble of the crown (spawned by the diff).
	_pulse_value(_flash, p, 0.55, 0.0, 0.22, 0.0)
	call_deferred("_second_flash", p)
	Sfx.play(&"mistake")
	Sfx.haptic(30)


func _second_flash(p: Vector2i) -> void:
	_wobble_crown(p)
	if Motion.effects_enabled():
		var t := _tw()
		t.tween_interval(0.24)
		t.tween_callback(func() -> void: _pulse_value(_flash, p, 0.45, 0.0, 0.22, 0.0))


func _on_hint_applied(_kind: String, _cells: Array) -> void:
	pass


func _anim_mark_in(p: Vector2i, delay: float) -> void:
	if not Motion.effects_enabled():
		_mark_alpha.erase(p)
		_mark_scale.erase(p)
		return
	_mark_alpha[p] = 0.0
	_mark_scale[p] = 1.4
	var t := _tw().set_parallel(true)
	t.tween_method(func(v: float) -> void: _mark_alpha[p] = v; queue_redraw(), 0.0, 1.0, 0.12).set_delay(delay)
	t.tween_method(func(v: float) -> void: _mark_scale[p] = v; queue_redraw(), 1.4, 1.0, 0.12).set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.chain().tween_callback(func() -> void: _mark_alpha.erase(p); _mark_scale.erase(p); queue_redraw())


func _anim_mark_out(p: Vector2i) -> void:
	if not Motion.effects_enabled():
		_mark_alpha.erase(p)
		return
	_mark_alpha[p] = 1.0
	var t := _tw()
	t.tween_method(func(v: float) -> void: _mark_alpha[p] = v; queue_redraw(), 1.0, 0.0, 0.10)
	t.tween_callback(func() -> void: _mark_alpha.erase(p); queue_redraw())


## Animates dict[p] from `from` to `to` over `secs`, after `delay`, then erases it.
func _pulse_value(dict: Dictionary, p: Vector2i, from: float, to: float, secs: float, hold_then_fade: float) -> void:
	if not Motion.effects_enabled() or not is_inside_tree():
		if to > 0.0:
			dict[p] = to
		else:
			dict.erase(p)
		queue_redraw()
		return
	dict[p] = from
	var t := _tw()
	t.tween_method(func(v: float) -> void: dict[p] = v; queue_redraw(), from, to, secs).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	if hold_then_fade > 0.0 and to > 0.0:
		t.tween_method(func(v: float) -> void: dict[p] = v; queue_redraw(), to, 0.0, hold_then_fade).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	t.tween_callback(func() -> void:
		if dict.get(p, 0.0) <= 0.001:
			dict.erase(p)
		queue_redraw())


func _pulse_scalar(property: String, from: float, to: float, secs: float) -> void:
	if not Motion.effects_enabled() or not is_inside_tree():
		set(property, to)
		queue_redraw()
		return
	set(property, from)
	var t := _tw()
	t.tween_method(func(v: float) -> void: set(property, v); queue_redraw(), from, to, secs).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)


func _animate_clear() -> void:
	# Cascade: rows shrink away top to bottom, then the plate settles.
	var by_row := {}
	for p in _crowns.keys():
		_remove_crown(p, true)
	_mark_alpha.clear()
	_mark_scale.clear()
	if Motion.effects_enabled() and is_inside_tree():
		for r in model.size_n:
			for c in model.size_n:
				if _prev_cells[r][c] == BoardModel.Cell.MARK or _prev_auto[r][c] > 0:
					var p := Vector2i(r, c)
					_mark_alpha[p] = 1.0
					var t := _tw()
					t.tween_interval(0.018 * r)
					t.tween_method(func(v: float) -> void: _mark_alpha[p] = v; queue_redraw(), 1.0, 0.0, 0.10)
					t.tween_callback(func() -> void: _mark_alpha.erase(p); queue_redraw())
		var pt := _tw()
		pt.tween_method(func(v: float) -> void: _plate_scale = v; queue_redraw(), 0.985, 1.0, 0.25).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_pulse.clear()
	_flash.clear()
	_glow.clear()
	_ring = 0.0
	_snapshot_prev()
	state_changed.emit()
	queue_redraw()


# --- win ----------------------------------------------------------------------------

func _on_solved() -> void:
	input_enabled = false
	_cancel_gesture()
	_retint_crowns()
	solved.emit()
	_play_win()


func _play_win() -> void:
	Sfx.play(&"win")
	Sfx.duck_music()
	Sfx.haptic_double(60, 90)
	if not Motion.effects_enabled() or not is_inside_tree():
		celebration_finished.emit()
		return
	var s := _crown_scale()
	var n := model.size_n
	for p in _crowns:
		var sp: Sprite2D = _crowns[p]
		var t := sp.create_tween()
		t.tween_interval(0.04 * p.y)
		t.tween_property(sp, "scale", Vector2(s * 1.35, s * 1.35), 0.17).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(sp, "scale", Vector2(s, s), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	for r in n:
		for c in n:
			var p := Vector2i(r, c)
			var t := _tw()
			t.tween_interval(0.04 * c)
			t.tween_callback(func() -> void: _pulse_value(_bright, p, 0.0, 0.32, 0.12, 0.35))
	_confetti.visible = true
	_confetti.position = Vector2(size.x * 0.5, _board_rect.position.y - 10.0)
	_confetti.emission_rect_extents = Vector2(_board_rect.size.x * 0.5, 4.0)
	_confetti.restart()
	_confetti.emitting = true
	var done := _tw()
	done.tween_interval(0.9)
	done.tween_callback(celebration_finished.emit)


func _make_confetti() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.name = "Confetti"
	p.emitting = false
	p.one_shot = true
	p.amount = 140
	p.lifetime = 2.2
	p.explosiveness = 0.9
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(200, 4)
	p.direction = Vector2(0, 1)
	p.spread = 30.0
	p.gravity = Vector2(0, 700)
	p.initial_velocity_min = 220.0
	p.initial_velocity_max = 480.0
	p.angular_velocity_min = -300.0
	p.angular_velocity_max = 300.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var img := Image.create(8, 12, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	p.texture = ImageTexture.create_from_image(img)
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.4, 0.6, 0.8, 1.0])
	ramp.colors = PackedColorArray([Ui.REGIONS[0], Ui.REGIONS[1], Ui.REGIONS[2], Ui.REGIONS[3], Ui.SECONDARY, Ui.PRIMARY_LIGHT])
	p.color_initial_ramp = ramp
	p.z_index = 5
	return p


# --- input -------------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if model.locked or not input_enabled:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if _finger == -1:
				_begin(event.index, event.position)
		elif event.index == _finger:
			_end(event.position)
		accept_event()
	elif event is InputEventScreenDrag and event.index == _finger:
		_move(event.position)
		accept_event()


func _cell_at(pos: Vector2) -> Vector2i:
	if _cell_size <= 0.0 or not _board_rect.has_point(pos):
		return Vector2i(-1, -1)
	var local := pos - _board_rect.position
	var c := int(local.x / _cell_size)
	var r := int(local.y / _cell_size)
	if not model.in_bounds(r, c):
		return Vector2i(-1, -1)
	return Vector2i(r, c)


func _allowed(p: Vector2i) -> bool:
	return allowed_cells.is_empty() or allowed_cells.has(p)


func _begin(index: int, pos: Vector2) -> void:
	var p := _cell_at(pos)
	if p.x < 0 or not _allowed(p):
		return
	_finger = index
	_gesture = Gesture.PRESSED
	_press_pos = pos
	_press_cell = p
	_press_time = 0.0
	_long_press_done = false
	_pressed_cell = p
	set_process(true)
	queue_redraw()


func _move(pos: Vector2) -> void:
	if _gesture == Gesture.PRESSED:
		if pos.distance_to(_press_pos) < maxf(SLOP_PX, _cell_size * 0.2):
			return
		var mode := model.stroke_mode_for(_press_cell.x, _press_cell.y)
		_pressed_cell = Vector2i(-1, -1)
		if mode == BoardModel.Stroke.NONE:
			# Started on a queen or an automatic mark: the drag does nothing.
			_cancel_gesture()
			return
		_gesture = Gesture.DRAGGING
		_stroke_cells = 0
		model.begin_stroke(mode)
		_stroke_into(_press_cell)
	if _gesture == Gesture.DRAGGING:
		var p := _cell_at(pos)
		if p.x >= 0:
			_stroke_into(p)


func _stroke_into(p: Vector2i) -> void:
	if not _allowed(p):
		return
	_last_cell = p
	if model.stroke_cell(p.x, p.y):
		_stroke_cells += 1
		Sfx.play(&"drag_tick", 0.0, 0.0, 1.0 + 0.02 * (_stroke_cells % 8))
		Sfx.haptic(8)


func _end(_pos: Vector2) -> void:
	match _gesture:
		Gesture.DRAGGING:
			model.end_stroke()
		Gesture.PRESSED:
			if not _long_press_done:
				_last_cell = _press_cell
				var was_queen: bool = model.cells[_press_cell.x][_press_cell.y] == BoardModel.Cell.QUEEN
				var was_marked := model.is_marked(_press_cell.x, _press_cell.y)
				model.tap(_press_cell.x, _press_cell.y)
				if not was_queen and not model.cells[_press_cell.x][_press_cell.y] == BoardModel.Cell.QUEEN:
					Sfx.play(&"tap_mark" if not was_marked else &"tap_unmark")
					Sfx.haptic(10)
	_cancel_gesture()


func _cancel_gesture() -> void:
	if _gesture == Gesture.DRAGGING and model.in_stroke():
		model.end_stroke()
	_gesture = Gesture.IDLE
	_finger = -1
	_pressed_cell = Vector2i(-1, -1)
	set_process(false)
	queue_redraw()


func _process(delta: float) -> void:
	if _gesture != Gesture.PRESSED or _long_press_done:
		return
	_press_time += delta
	if _press_time >= LONG_PRESS_SECONDS:
		_long_press_done = true
		var p := _press_cell
		if model.cells[p.x][p.y] != BoardModel.Cell.QUEEN:
			_last_cell = p
			_pressed_cell = Vector2i(-1, -1)
			model.place_directly(p.x, p.y)
			Sfx.play(&"long_press")
			Sfx.haptic(20)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		if _gesture != Gesture.IDLE:
			_cancel_gesture()
