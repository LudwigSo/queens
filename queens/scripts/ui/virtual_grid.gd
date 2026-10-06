class_name VirtualGrid
extends Control
## A grid that only builds the rows on screen. Sits directly in a
## ScrollContainer; its minimum height stands in for every row, and a small
## pool of `item_scene` nodes is moved and rebound (`setup(item)`) as the
## list scrolls. The cost is the same for a hundred items or ten thousand.

## Emitted once per pooled node, right after it is created.
signal item_created(node: Control)

@export var columns: int = 4
@export var row_height: float = 150.0
@export var gap: float = 12.0
@export var item_scene: PackedScene

var items: Array = []

var _pool: Array = []          ## Control nodes, in creation order
var _scroll: ScrollContainer
var _pending_scroll: int = -1  ## Target to reapply once the scroll range catches up


func _ready() -> void:
	_attach()


func _attach() -> void:
	if _scroll != null:
		return
	_scroll = get_parent() as ScrollContainer
	resized.connect(_layout)
	if _scroll != null:
		var bar := _scroll.get_v_scroll_bar()
		bar.value_changed.connect(func(_v: float) -> void: _layout())
		bar.changed.connect(_on_range_changed)
		_scroll.resized.connect(_layout)


func pitch() -> float:
	return row_height + gap


func row_count() -> int:
	return ceili(float(items.size()) / maxi(columns, 1))


## Replaces the items. `keep_scroll` false jumps back to the top.
func set_items(new_items: Array, keep_scroll: bool = true) -> void:
	_attach()
	items = new_items
	var rows := row_count()
	custom_minimum_size.y = maxf(rows * pitch() - gap, 0.0)
	for node in _pool:
		node.set_meta("_vg_index", -1)
	if not keep_scroll and _scroll != null:
		_pending_scroll = -1
		_scroll.scroll_vertical = 0
	_layout()


## Scrolls so the row holding `index` sits at the top of the view.
func scroll_to_index(index: int) -> void:
	if _scroll == null or index < 0 or index >= items.size():
		return
	@warning_ignore("integer_division")
	var target := int((index / columns) * pitch())
	_scroll.scroll_vertical = target
	# Right after set_items the scroll range is still the old one and clamps
	# the value; try again once the container has resized it.
	_pending_scroll = target if _scroll.scroll_vertical != target else -1


func _on_range_changed() -> void:
	if _pending_scroll < 0:
		return
	_scroll.scroll_vertical = _pending_scroll
	if _scroll.scroll_vertical == _pending_scroll:
		_pending_scroll = -1


## The pooled node currently showing `index`, or null when it is off screen.
func node_for_index(index: int) -> Control:
	for node in _pool:
		if node.visible and int(node.get_meta("_vg_index", -1)) == index:
			return node
	return null


## Nodes on screen, top-left first.
func visible_nodes() -> Array:
	var shown: Array = []
	for node in _pool:
		if node.visible:
			shown.append(node)
	shown.sort_custom(func(a: Control, b: Control) -> bool:
		return int(a.get_meta("_vg_index")) < int(b.get_meta("_vg_index")))
	return shown


func _layout() -> void:
	if _scroll == null:
		layout_window(0.0, size.y)
	else:
		layout_window(float(_scroll.scroll_vertical), _scroll.size.y)


## Binds the pool to the rows overlapping [top, top + view_h], plus one row
## of slack each side so a fast fling never shows a gap.
func layout_window(top: float, view_h: float) -> void:
	var rows := row_count()
	var first_row := maxi(floori(top / pitch()) - 1, 0)
	var last_row := mini(ceili((top + view_h) / pitch()) + 1, rows - 1)
	var first := first_row * columns
	var last := mini((last_row + 1) * columns, items.size())  # exclusive
	var needed := maxi(last - first, 0)
	while _pool.size() < needed:
		var node: Control = item_scene.instantiate()
		node.set_meta("_vg_index", -1)
		add_child(node)
		_pool.append(node)
		item_created.emit(node)
	var cell_w := (size.x - gap * (columns - 1)) / columns
	# Nodes already showing an index in range keep it; the rest fill the gaps,
	# so scrolling only rebinds the rows that come into view.
	var free: Array = []
	var placed := {}
	for node in _pool:
		var idx := int(node.get_meta("_vg_index", -1))
		if idx >= first and idx < last and not placed.has(idx):
			placed[idx] = node
		else:
			free.append(node)
	for idx in range(first, last):
		var node: Control = placed.get(idx)
		if node == null:
			node = free.pop_back()
			node.set_meta("_vg_index", idx)
			node.setup(items[idx])
		@warning_ignore("integer_division")
		var row := idx / columns
		node.position = Vector2((idx % columns) * (cell_w + gap), row * pitch())
		node.size = Vector2(cell_w, row_height)
		node.visible = true
	for node in free:
		node.visible = false
		node.set_meta("_vg_index", -1)
