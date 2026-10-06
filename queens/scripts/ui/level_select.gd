extends Control
## The level overview: a search by level number, a size filter and a recycled
## grid of LevelCard tiles. Tapping a tile opens the level's detail
## (leaderboard and Play); Enter in the search opens the typed level directly.

signal detail_requested(level_id: String)
signal back_requested

@onready var grid: VirtualGrid = $Margin/VBox/Scroll/Grid
@onready var scroll: ScrollContainer = $Margin/VBox/Scroll
@onready var search: LineEdit = $Margin/VBox/Search
@onready var filter: Segmented = $Margin/VBox/Filter
@onready var empty_label: Label = $Margin/VBox/Empty
@onready var back_button: Button = $Margin/VBox/TopBar/BackButton
@onready var skeleton: Control = $Margin/VBox/Skeleton

var _cards: Array = []       ## card dictionaries in display order
var _shown: Array = []       ## `_cards` after the size filter and the search
var _size_filter: int = 0    ## 0 = all
var _query: String = ""      ## digits typed into the search


func _ready() -> void:
	back_button.pressed.connect(back_requested.emit)
	filter.selected.connect(_on_filter)
	search.text_changed.connect(_on_search_changed)
	search.text_submitted.connect(_on_search_submitted)
	grid.item_created.connect(func(node: Control) -> void:
		node.chosen.connect(_on_card_chosen))


func set_back_visible(shown: bool) -> void:
	back_button.visible = shown


func set_loading(loading: bool) -> void:
	skeleton.visible = loading
	scroll.visible = not loading
	empty_label.visible = false


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
		options.append({"id": str(s), "text": Fmt.size_text(s)})
	filter.set_options(options)
	filter.select(str(_size_filter), false)
	_apply(true)


## Empties the search; the overview calls this when it is opened afresh
## rather than returned to.
func reset_search() -> void:
	search.text = ""
	_query = ""


func _apply(keep_scroll: bool) -> void:
	_shown = Views.filter_level_cards(_cards, _size_filter, _query)
	grid.set_items(_shown, keep_scroll)
	empty_label.visible = _shown.is_empty() and not _cards.is_empty()
	scroll.visible = not empty_label.visible
	if not keep_scroll:
		Motion.stagger(grid.visible_nodes(), 0.015, Motion.BASE, 12)


func _on_filter(id: String) -> void:
	_size_filter = int(id)
	_apply(false)


func _on_search_changed(text: String) -> void:
	var digits := ""
	for ch in text:
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits != text:
		var caret := search.caret_column - (text.length() - digits.length())
		search.text = digits
		search.caret_column = clampi(caret, 0, digits.length())
	if digits == _query:
		return
	_query = digits
	_apply(false)


## Enter opens the typed level, whatever the size filter shows.
func _on_search_submitted(_text: String) -> void:
	var card := _card_by_number(int(_query)) if _query != "" else {}
	if card.is_empty():
		Motion.shake(search)
		Sfx.haptic(20)
		return
	if search.has_focus():
		search.release_focus()
	detail_requested.emit(str(card["id"]))


func _card_by_number(level_no: int) -> Dictionary:
	for c in _cards:
		if int(c["level_no"]) == level_no:
			return c
	return {}


func _on_card_chosen(level_id: String) -> void:
	detail_requested.emit(level_id)


## {locked, text} for a level's card, whether or not it is on screen.
func card_summary(level_id: String) -> Dictionary:
	for c in _cards:
		if str(c["id"]) != level_id:
			continue
		var locked := bool(c.get("locked", false))
		var best := str(c.get("best_text", ""))
		var state := str(c.get("lock_text", "")) if locked else (best if best != "" else Loc.t("LEVELS_NOT_PLAYED"))
		var meta := Loc.f("LEVELS_CARD_META", [Fmt.size_text(int(c["size"])), int(c["difficulty"])])
		return {"locked": locked, "text": "%s %s %s" % [Loc.f("COMMON_LEVEL_N", [int(c["level_no"])]), meta, state]}
	return {}


func scroll_to(level_id: String) -> void:
	for i in _shown.size():
		if str(_shown[i]["id"]) == level_id:
			grid.scroll_to_index(i)
			return
