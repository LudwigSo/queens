class_name StarRow
extends HBoxContainer
## A row of star icons: `count` filled out of `maximum`.

const STAR_FILL := "res://assets/icons/line/star_fill.svg"
const STAR_LINE := "res://assets/icons/line/star.svg"

@export var maximum: int = 4
@export var count: int = 0:
	set(v):
		count = v
		_rebuild()
@export var icon_size: int = 20
@export var fill_color: Color = Ui.SECONDARY
@export var empty_color: Color = Ui.OUTLINE
@export var show_empty: bool = true


func _ready() -> void:
	add_theme_constant_override("separation", 2)
	_rebuild()


func set_stars(n: int, max_stars: int = -1) -> void:
	if max_stars > 0:
		maximum = max_stars
	count = n


func _rebuild() -> void:
	if not is_inside_tree():
		return
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var fill := load(STAR_FILL) if ResourceLoader.exists(STAR_FILL, "Texture2D") else null
	var line := load(STAR_LINE) if ResourceLoader.exists(STAR_LINE, "Texture2D") else null
	var total := maximum if show_empty else count
	for i in total:
		var tr := TextureRect.new()
		tr.custom_minimum_size = Vector2(icon_size, icon_size)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		if i < count:
			tr.texture = fill
			tr.modulate = fill_color
		else:
			tr.texture = line
			tr.modulate = empty_color
		add_child(tr)
