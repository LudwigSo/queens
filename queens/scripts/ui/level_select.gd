extends Control
## The level overview: a size filter and a grid of LevelCards. Tapping a
## card opens the level's detail (leaderboard and Play).

signal detail_requested(level_id: String)
signal back_requested

const LevelCardScene := preload("res://scenes/ui/level_card.tscn")

@onready var grid: GridContainer = $Margin/VBox/Scroll/Grid
@onready var scroll: ScrollContainer = $Margin/VBox/Scroll
@onready var filter: Segmented = $Margin/VBox/Filter
@onready var back_button: Button = $Margin/VBox/TopBar/BackButton
@onready var skeleton: Control = $Margin/VBox/Skeleton

var _cards: Array = []       ## card dictionaries in display order
var _nodes: Dictionary = {}  ## level id -> LevelCard
var _size_filter: int = 0    ## 0 = all


func _ready() -> void:
	back_button.pressed.connect(back_requested.emit)
	filter.selected.connect(_on_filter)


func set_back_visible(shown: bool) -> void:
	back_button.visible = shown


func set_loading(loading: bool) -> void:
	skeleton.visible = loading
	scroll.visible = not loading


## cards: [{id, level_no, size, difficulty, stars, regions, locked, lock_text, best_text, played}]
func refresh(cards: Array) -> void:
	_cards = cards
	var sizes := {}
	for c in cards:
		sizes[int(c["size"])] = true
	var options: Array = [{"id": "0", "text": Loc.t("LEVELS_FILTER_ALL")}]
	var keys := sizes.keys()
	keys.sort()
	for s in keys:
		options.append({"id": str(s), "text": "%d×%d" % [s, s]})
	filter.set_options(options)
	filter.select(str(_size_filter), false)
	_rebuild()


func _rebuild() -> void:
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	_nodes.clear()
	var shown: Array = []
	for c in _cards:
		if _size_filter != 0 and int(c["size"]) != _size_filter:
			continue
		var card: LevelCard = LevelCardScene.instantiate()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.custom_minimum_size = Vector2(0, 236)
		grid.add_child(card)
		card.setup(c)
		card.chosen.connect(_on_card_chosen)
		_nodes[str(c["id"])] = card
		shown.append(card)
	Motion.stagger(shown, 0.02, Motion.BASE, 10)


func _on_filter(id: String) -> void:
	_size_filter = int(id)
	_rebuild()
	scroll.scroll_vertical = 0


func _on_card_chosen(level_id: String) -> void:
	detail_requested.emit(level_id)


func card_for(level_id: String) -> LevelCard:
	return _nodes.get(level_id)


func scroll_to(level_id: String) -> void:
	var card: LevelCard = _nodes.get(level_id)
	if card != null:
		scroll.scroll_vertical = int(card.position.y)
