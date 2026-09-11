extends Control
## First-run tutorial on a real board: eight scripted steps that wait for the
## player's move. No session, no energy, no cooldown.
##
## Two rules keep it unstuckable. Every step carries a `do` Callable and shows a
## button that runs it, so the player can always hand the move to the tutorial
## and move on. And a tap outside the step's cells is answered - the target
## re-pulses and the coach nudges - instead of being swallowed in silence.

signal finished(completed: bool)

@onready var board: Board = $Margin/VBox/Board
@onready var coach_text: Label = $Margin/VBox/Coach/VBox/Text
@onready var next_button: Button = $Margin/VBox/Coach/VBox/NextButton
@onready var skip_button: Button = $Margin/VBox/TopBar/SkipButton
@onready var progress: HBoxContainer = $Margin/VBox/Progress
@onready var coach: PanelContainer = $Margin/VBox/Coach

## Label on the step button per `wait` kind; anything else asks for a move.
const BUTTON_KEYS := {"next": "TUT_NEXT", "solved": "TUT_FINISH"}

var step_index: int = -1
var _level: Dictionary = {}
var _steps: Array = []
var _active: bool = false
var _run_id: int = 0
var _nudge_id: int = 0


func _ready() -> void:
	next_button.pressed.connect(_on_next)
	skip_button.pressed.connect(skip)
	board.model.state_changed.connect(_on_board_changed)
	board.model.stroke_ended.connect(_on_stroke_ended)
	board.blocked_tap.connect(_on_blocked_tap)


func start(level: Dictionary) -> void:
	_level = level
	board.input_enabled = true
	board.mistake_alerts = false
	board.load_level(level)
	_run_id += 1
	_active = true
	_build_steps()
	_build_progress()
	jump_to(0)


func skip() -> void:
	if not _active:
		return
	_active = false
	_clear_board_hints()
	finished.emit(false)


## Jumps to a step (tests, and the step button).
func jump_to(index: int) -> void:
	if index >= _steps.size():
		_complete()
		return
	step_index = index
	_nudge_id += 1
	var step: Dictionary = _steps[index]
	var wait := str(step.get("wait", "next"))
	board.clear_glow()
	board.clear_target()
	board.allowed_cells = step.get("allowed", [])
	coach_text.text = str(step["text"])
	next_button.text = Loc.t(str(BUTTON_KEYS.get(wait, "TUT_SHOW_ME")))
	next_button.visible = true
	if step.has("glow"):
		board.set_target(step["glow"])
	for i in progress.get_child_count():
		var dot: Panel = progress.get_child(i)
		dot.theme_type_variation = &"ChipPrimary" if i <= index else &"Chip"
	if is_inside_tree():
		Motion.pop_in(coach, Motion.BASE, 0.96)
	if wait == "solved":
		_idle_hint(index)


## The step button: makes the move the step is waiting for, so there is never a
## move the player cannot get past. The board change then advances the step on
## its own, exactly as a real tap would.
func _on_next() -> void:
	if not _active or step_index < 0 or step_index >= _steps.size():
		return
	var action: Variant = _steps[step_index].get("do")
	if action is Callable:
		(action as Callable).call()
	else:
		jump_to(step_index + 1)


func _complete() -> void:
	if not _active:
		return
	_active = false
	_clear_board_hints()
	finished.emit(true)


func _clear_board_hints() -> void:
	board.clear_glow()
	board.clear_target()
	board.allowed_cells = []


func _build_progress() -> void:
	for child in progress.get_children():
		progress.remove_child(child)
		child.queue_free()
	for i in _steps.size():
		var dot := Panel.new()
		dot.custom_minimum_size = Vector2(14, 14)
		dot.theme_type_variation = &"Chip"
		progress.add_child(dot)


func _sol(r: int) -> Vector2i:
	return Vector2i(r, int(_level["solution"][r]))


func _region_of(p: Vector2i) -> Array:
	return board.model.region_cells(int(_level["regions"][p.x][p.y]))


func _is_solution(p: Vector2i) -> bool:
	return int(_level["solution"][p.x]) == p.y


## The square the player would fill first anyway: the solution cell of the
## smallest colour region. On a board with a one-cell region that is the cell
## with no choice at all, which teaches far better than an arbitrary corner.
func _demo_cell() -> Vector2i:
	var best := _sol(0)
	var best_size := _region_of(best).size()
	for r in range(1, board.model.size_n):
		var p := _sol(r)
		var n := _region_of(p).size()
		if n < best_size:
			best = p
			best_size = n
	return best


## A free cell next to the demo queen, for the conflict step. Never a solution
## cell: the step ends by taking that queen off again, and the player should not
## learn that the square it stood on was right all along.
func _neighbour_of(p: Vector2i) -> Vector2i:
	for d in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
		var q: Vector2i = p + d
		if board.model.in_bounds(q.x, q.y) and not _is_solution(q):
			return q
	return p


func _build_steps() -> void:
	var demo := _demo_cell()
	var nb := _neighbour_of(demo)
	# Step 1 illustrates "colour region", so it needs a region with room in it.
	var region: Array = _region_of(demo)
	if region.size() < 2:
		region = _region_of(_sol(0))
	# The drag step must not ask for an X on a cell the solution needs.
	var row_cells: Array = []
	for c in board.model.size_n:
		var p := Vector2i(board.model.size_n - 1, c)
		if p != demo and p != nb and not _is_solution(p):
			row_cells.append(p)
	_steps = [
		{"text": Loc.t("TUT_STEP_1"), "glow": region, "wait": "next"},
		{"text": Loc.t("TUT_STEP_2"), "glow": [demo], "allowed": [demo], "wait": "mark", "cell": demo,
			"do": _tap.bind(demo)},
		{"text": Loc.t("TUT_STEP_3"), "glow": [demo], "allowed": [demo], "wait": "queen", "cell": demo,
			"do": _tap_until_queen.bind(demo)},
		{"text": Loc.t("TUT_STEP_4"), "wait": "next"},
		{"text": Loc.t("TUT_STEP_5"), "glow": [nb], "allowed": [nb], "wait": "queen", "cell": nb,
			"do": _tap_until_queen.bind(nb)},
		{"text": Loc.t("TUT_STEP_6"), "glow": [nb], "allowed": [nb], "wait": "removed", "cell": nb,
			"do": _tap.bind(nb)},
		{"text": Loc.t("TUT_STEP_7"), "glow": row_cells, "allowed": row_cells, "wait": "stroke",
			"do": _paint.bind(row_cells)},
		{"text": Loc.t("TUT_STEP_8"), "allowed": [], "wait": "solved", "do": _complete},
	]


# --- the moves the step button makes ------------------------------------------------

func _tap(p: Vector2i) -> void:
	board.tap_cell(p.x, p.y)


## A cell carrying automatic marks becomes a queen with one tap, an empty one
## needs two. Bounded, so a cell that refuses cannot spin here.
func _tap_until_queen(p: Vector2i) -> void:
	for _i in 3:
		if board.model.cells[p.x][p.y] == BoardModel.Cell.QUEEN:
			return
		board.tap_cell(p.x, p.y)


## One real stroke, so `stroke_ended` fires and the step advances. `apply_marks`
## would not: it resets the stroke by hand and never reports it.
func _paint(cells: Array) -> void:
	board.model.begin_stroke(BoardModel.Stroke.PAINT)
	for p in cells:
		board.model.stroke_cell(p.x, p.y)
	board.model.end_stroke()


# --- reacting to the player ----------------------------------------------------------

func _on_board_changed() -> void:
	if not _active or step_index < 0 or step_index >= _steps.size():
		return
	var step: Dictionary = _steps[step_index]
	var cell: Vector2i = step.get("cell", Vector2i(-1, -1))
	match str(step.get("wait", "next")):
		"mark":
			if board.model.cells[cell.x][cell.y] == BoardModel.Cell.MARK:
				_advance_later()
		"queen":
			if board.model.cells[cell.x][cell.y] == BoardModel.Cell.QUEEN:
				_advance_later()
		"removed":
			if board.model.cells[cell.x][cell.y] != BoardModel.Cell.QUEEN:
				_advance_later()
		"solved":
			if board.model.locked:
				_advance_later(0.9)


func _on_stroke_ended(cells_changed: int) -> void:
	if not _active or step_index < 0:
		return
	if str(_steps[step_index].get("wait", "")) == "stroke" and cells_changed >= 2:
		_advance_later()


## A tap the step does not accept. Point at the cells that would work, instead
## of letting the board feel dead.
func _on_blocked_tap(_cell: Vector2i) -> void:
	if not _active or step_index < 0 or step_index >= _steps.size():
		return
	var step: Dictionary = _steps[step_index]
	if not step.has("glow"):
		return
	board.set_target(step["glow"])
	Sfx.play(&"tap_unmark")
	_nudge(str(step["text"]))


## Swaps the coach text for the nudge and puts the step text back afterwards.
func _nudge(restore: String) -> void:
	_nudge_id += 1
	var my := _nudge_id
	var run := _run_id
	coach_text.text = Loc.t("TUT_NUDGE")
	var delay := Motion.d(2.5)
	if delay <= 0.0:
		coach_text.text = restore
		return
	await get_tree().create_timer(delay).timeout
	if _active and my == _nudge_id and run == _run_id:
		coach_text.text = restore


func _advance_later(seconds: float = 0.5) -> void:
	var my := _run_id
	var target := step_index + 1
	var delay := Motion.d(seconds)
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	if _active and my == _run_id and step_index == target - 1:
		jump_to(target)


## Solving step: after a pause without progress, glow the next solution cell.
func _idle_hint(index: int) -> void:
	var my := _run_id
	var delay := Motion.d(8.0)
	if delay <= 0.0:
		return
	await get_tree().create_timer(delay).timeout
	if _active and my == _run_id and step_index == index:
		var hint := HintFinder.find(board.model)
		if hint["kind"] != "none":
			board.set_glow(hint["cells"], 1.6)
		_idle_hint(index)
