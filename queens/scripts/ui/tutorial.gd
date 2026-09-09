extends Control
## First-run tutorial on a real board: eight scripted steps that wait for the
## player's move or a Next tap. No session, no energy, no cooldown.

signal finished(completed: bool)

@onready var board: Board = $Margin/VBox/Board
@onready var coach_text: Label = $Margin/VBox/Coach/VBox/Text
@onready var next_button: Button = $Margin/VBox/Coach/VBox/NextButton
@onready var skip_button: Button = $Margin/VBox/TopBar/SkipButton
@onready var progress: HBoxContainer = $Margin/VBox/Progress
@onready var coach: PanelContainer = $Margin/VBox/Coach

var step_index: int = -1
var _level: Dictionary = {}
var _steps: Array = []
var _active: bool = false
var _run_id: int = 0


func _ready() -> void:
	next_button.pressed.connect(_on_next)
	skip_button.pressed.connect(skip)
	board.model.state_changed.connect(_on_board_changed)
	board.model.stroke_ended.connect(_on_stroke_ended)


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
	board.clear_glow()
	board.allowed_cells = []
	finished.emit(false)


## Jumps to a step (tests, and Next).
func jump_to(index: int) -> void:
	if index >= _steps.size():
		_complete()
		return
	step_index = index
	var step: Dictionary = _steps[index]
	board.clear_glow()
	board.allowed_cells = step.get("allowed", [])
	if step.has("setup"):
		step["setup"].call()
	coach_text.text = str(step["text"])
	next_button.visible = str(step.get("wait", "next")) == "next"
	if step.has("glow"):
		board.set_glow(step["glow"])
	for i in progress.get_child_count():
		var dot: Panel = progress.get_child(i)
		dot.theme_type_variation = &"ChipPrimary" if i <= index else &"Chip"
	if is_inside_tree():
		Motion.pop_in(coach, Motion.BASE, 0.96)
	if str(step.get("wait", "next")) == "solved":
		_idle_hint(index)


func _on_next() -> void:
	if not _active:
		return
	jump_to(step_index + 1)


func _complete() -> void:
	if not _active:
		return
	_active = false
	board.clear_glow()
	board.allowed_cells = []
	finished.emit(true)


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


## A free cell next to the first queen, for the conflict step.
func _neighbour_of(p: Vector2i) -> Vector2i:
	for d in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
		var q: Vector2i = p + d
		if board.model.in_bounds(q.x, q.y):
			return q
	return p


func _build_steps() -> void:
	var q0 := _sol(0)
	var q1 := _sol(1)
	var nb := _neighbour_of(q0)
	var row_cells: Array = []
	for c in board.model.size_n:
		var p := Vector2i(board.model.size_n - 1, c)
		if p != q0 and p != q1:
			row_cells.append(p)
	_steps = [
		{"text": "One queen in every row, column and colour region. Queens never touch, not even diagonally.", "glow": _region_of(q0), "wait": "next"},
		{"text": "Tap a cell once to mark it with an X. Try the glowing cell.", "glow": [q0], "allowed": [q0], "wait": "mark", "cell": q0},
		{"text": "Tap it again to place a queen.", "glow": [q0], "allowed": [q0], "wait": "queen", "cell": q0},
		{"text": "The small X marks show where no other queen can go: its row, column, region and the cells around it.", "wait": "next"},
		{"text": "Try placing a queen right next to it.", "glow": [nb], "allowed": [nb], "wait": "queen", "cell": nb},
		{"text": "See the shake? Two queens can't touch. Tap it again to remove it.", "glow": [nb], "allowed": [nb], "wait": "removed", "cell": nb},
		{"text": "Drag your finger across cells to mark many at once. Try the bottom row.", "glow": row_cells, "allowed": row_cells, "wait": "stroke"},
		{"text": "Now finish the board. Every queen must sit on a different colour.", "allowed": [], "wait": "solved"},
	]


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
