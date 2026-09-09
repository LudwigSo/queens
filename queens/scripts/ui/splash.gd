extends Control
## Animated splash: crown and wordmark pop in with a burst of gold stars,
## then `done` fires after a short minimum time.

signal done

const MIN_SECONDS := 1.1

@onready var center: VBoxContainer = $Center
@onready var crown: TextureRect = $Center/Crown

var _finished: bool = false
var _stars: CPUParticles2D


func _ready() -> void:
	_stars = CPUParticles2D.new()
	_stars.emitting = false
	_stars.one_shot = true
	_stars.amount = 32
	_stars.lifetime = 1.4
	_stars.explosiveness = 1.0
	_stars.spread = 180.0
	_stars.gravity = Vector2(0, 160)
	_stars.initial_velocity_min = 180.0
	_stars.initial_velocity_max = 360.0
	_stars.scale_amount_min = 0.5
	_stars.scale_amount_max = 1.1
	_stars.color = Ui.SECONDARY_LIGHT
	var img := Image.create(10, 10, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_stars.texture = ImageTexture.create_from_image(img)
	add_child(_stars)


func play() -> void:
	_finished = false
	visible = true
	center.pivot_offset = center.size * 0.5
	Motion.pop_in(center, Motion.SLOW, 0.7)
	if Motion.effects_enabled():
		_stars.position = size * 0.5 - Vector2(0, 60)
		_stars.restart()
		_stars.emitting = true
	var t := create_tween()
	t.tween_interval(Motion.d(MIN_SECONDS))
	t.tween_callback(finish_now)


func finish_now() -> void:
	if _finished:
		return
	_finished = true
	done.emit()
