class_name Motion
extends RefCounted
## Shared tween helpers with the app's motion constants. Every duration goes
## through `d()`, so headless tests (`instant`) and the reduced-motion setting
## (`reduced`) collapse animations without touching call sites.

const FAST := 0.12
const BASE := 0.22
const SLOW := 0.40

static var instant: bool = false   ## Tests: every tween finishes on the next frame.
static var reduced: bool = false   ## Setting: fades only, no movement or particles.


static func d(seconds: float) -> float:
	return 0.0 if instant else seconds


## Duration for movement/scale effects: zero under reduced motion.
static func dm(seconds: float) -> float:
	return 0.0 if (instant or reduced) else seconds


static func effects_enabled() -> bool:
	return not (instant or reduced)


## Kills the tween previously stored on `node` under `key` and stores a new one.
static func _own(node: Node, key: String = "_motion_tween") -> Tween:
	if node.has_meta(key):
		var old = node.get_meta(key)
		if old is Tween and old.is_valid():
			old.kill()
	var t := node.create_tween()
	node.set_meta(key, t)
	return t


static func fade(node: CanvasItem, to: float, secs: float = BASE) -> Tween:
	var t := _own(node, "_motion_fade")
	t.tween_property(node, "modulate:a", to, d(secs)).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	return t


## Slides `node` from `from` (an offset in px relative to its rest position)
## to its rest position while fading in. Only for Controls whose parent is
## not a Container (containers overwrite position every frame).
static func slide_in(node: Control, from: Vector2, secs: float = BASE) -> Tween:
	var rest := node.position
	node.modulate.a = 0.0
	if effects_enabled():
		node.position = rest + from
	var t := _own(node).set_parallel(true)
	t.tween_property(node, "position", rest, dm(secs)).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(node, "modulate:a", 1.0, d(secs))
	return t


## Springy scale-in from `from_scale` around the centre.
static func pop_in(node: Control, secs: float = BASE, from_scale: float = 0.92) -> Tween:
	node.pivot_offset = node.size * 0.5
	node.modulate.a = 0.0
	node.scale = Vector2(from_scale, from_scale) if effects_enabled() else Vector2.ONE
	var t := _own(node).set_parallel(true)
	t.tween_property(node, "scale", Vector2.ONE, dm(secs)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "modulate:a", 1.0, d(FAST))
	return t


static func pop_out(node: Control, secs: float = FAST) -> Tween:
	node.pivot_offset = node.size * 0.5
	var t := _own(node).set_parallel(true)
	t.tween_property(node, "scale", Vector2(0.92, 0.92), dm(secs)).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	t.tween_property(node, "modulate:a", 0.0, d(secs))
	return t


## A one-shot scale bump (1 -> peak -> 1), e.g. for a counter that changed.
static func bump(node: Control, peak: float = 1.12, secs: float = BASE) -> Tween:
	node.pivot_offset = node.size * 0.5
	node.scale = Vector2.ONE
	var t := _own(node, "_motion_bump")
	t.tween_property(node, "scale", Vector2(peak, peak), dm(secs * 0.4)).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "scale", Vector2.ONE, dm(secs * 0.6)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return t


## Horizontal shake, e.g. for a locked item that was tapped.
static func shake(node: Control, amplitude: float = 6.0, cycles: int = 4, secs: float = FAST) -> Tween:
	var rest := node.position
	var t := _own(node, "_motion_shake")
	if not effects_enabled():
		t.tween_interval(0.0)
		return t
	var step := secs / float(cycles * 2)
	for i in cycles:
		t.tween_property(node, "position:x", rest.x + amplitude, step)
		t.tween_property(node, "position:x", rest.x - amplitude, step)
	t.tween_property(node, "position:x", rest.x, step)
	return t


## Fades and slides list rows in one after another. Rows beyond `cap` appear
## instantly so long lists stay snappy. Rows live in containers, so this
## animates modulate only.
static func stagger(nodes: Array, per_item: float = 0.03, secs: float = BASE, cap: int = 12) -> void:
	for i in nodes.size():
		var n: CanvasItem = nodes[i]
		if i >= cap or not effects_enabled():
			n.modulate.a = 1.0
			continue
		n.modulate.a = 0.0
		var t := _own(n, "_motion_stagger")
		t.tween_interval(d(per_item * i))
		t.tween_property(n, "modulate:a", 1.0, d(secs)).set_ease(Tween.EASE_OUT)


## Counts a label from 0 to `to` using `fmt` (one %d placeholder).
static func count_up(label: Label, to: int, secs: float = SLOW, fmt: String = "%d") -> Tween:
	var t := _own(label, "_motion_count")
	if not effects_enabled():
		label.text = fmt % to
		t.tween_interval(0.0)
		return t
	t.tween_method(func(v: float) -> void: label.text = fmt % int(round(v)), 0.0, float(to), d(secs)) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUART)
	return t


## Press-down feedback for any BaseButton: 0.96 on press, spring back on release.
static func make_pressable(b: BaseButton) -> void:
	if b.has_meta("_pressable"):
		return
	b.set_meta("_pressable", true)
	b.button_down.connect(func() -> void:
		Sfx.play(&"button", 0.04, -4.0)
		b.pivot_offset = b.size * 0.5
		var t := _own(b, "_motion_press")
		t.tween_property(b, "scale", Vector2(0.96, 0.96), dm(FAST)).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT))
	b.button_up.connect(func() -> void:
		b.pivot_offset = b.size * 0.5
		var t := _own(b, "_motion_press")
		t.tween_property(b, "scale", Vector2.ONE, dm(BASE)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT))


## Applies `make_pressable` to every button below `root`.
static func make_all_pressable(root: Node) -> void:
	for b in root.find_children("*", "BaseButton", true, false):
		make_pressable(b)
