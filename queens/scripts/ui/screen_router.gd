class_name ScreenRouter
extends Node
## Owns screen visibility: a stack of full screens plus a stack of modals.
## Screens must be direct children of the same Control (not of a Container)
## because transitions tween their position. Only this node sets `visible`
## on registered screens.

signal screen_changed(name: String)

const SLIDE_PX := 24.0

var _screens: Dictionary = {}       ## name -> Control
var _stack: Array[String] = []
var _modals: Array[Control] = []
var _busy: bool = false


func register(name: String, node: Control) -> void:
	_screens[name] = node
	node.visible = false


func current() -> String:
	return _stack.back() if not _stack.is_empty() else ""


func is_current(name: String) -> bool:
	return current() == name


func screen(name: String) -> Control:
	return _screens.get(name)


## Shows `name`. With `replace_stack` the history is cleared (a new root).
func go(name: String, replace_stack: bool = false) -> void:
	if not _screens.has(name):
		push_error("router: unknown screen %s" % name)
		return
	if replace_stack:
		_stack.clear()
	if current() == name:
		return
	_stack.append(name)
	await _transition(name, Vector2(SLIDE_PX, 0))


## Goes back to `name` (which must be on the stack or becomes the new root),
## sliding in from the left.
func go_back_to(name: String) -> void:
	if not _screens.has(name):
		push_error("router: unknown screen %s" % name)
		return
	var idx := _stack.find(name)
	if idx >= 0:
		_stack.resize(idx + 1)
	else:
		_stack.clear()
		_stack.append(name)
	await _transition(name, Vector2(-SLIDE_PX, 0))


## Pops the current screen. Returns false at the root.
func back() -> bool:
	if _stack.size() <= 1:
		return false
	_stack.pop_back()
	await _transition(_stack.back(), Vector2(-SLIDE_PX, 0))
	return true


## Shows a modal (a Control with `Dim` and `Panel` children and a `closed`
## signal). The caller does its own `open()`; this only animates and tracks.
func present(modal: Control) -> void:
	if _modals.has(modal):
		return
	_modals.append(modal)
	modal.visible = true
	var dim := modal.get_node_or_null("Dim")
	var panel := modal.get_node_or_null("Panel")
	if dim != null:
		Motion.fade(dim, 1.0, Motion.FAST)
	if panel != null:
		if modal.has_meta("sheet"):
			# Sheets are anchored to the bottom edge: scale up from it.
			var p: Control = panel
			p.pivot_offset = Vector2(p.size.x * 0.5, p.size.y)
			Motion.pop_in(p, Motion.SLOW, 0.94)
		else:
			Motion.pop_in(panel)
	if modal.has_signal("closed") and not modal.closed.is_connected(_on_modal_closed):
		modal.closed.connect(_on_modal_closed.bind(modal), CONNECT_ONE_SHOT | CONNECT_DEFERRED)


func _on_modal_closed(_a = null, modal: Control = null) -> void:
	if modal == null:
		return
	_modals.erase(modal)


func dismiss(modal: Control) -> void:
	_modals.erase(modal)


func top_modal() -> Control:
	while not _modals.is_empty() and not _modals.back().visible:
		_modals.pop_back()
	return _modals.back() if not _modals.is_empty() else null


func has_modal() -> bool:
	return top_modal() != null


## Android back: closes the top modal, else pops the screen stack.
func handle_back() -> bool:
	var m := top_modal()
	if m != null:
		if m.has_method("close"):
			m.call("close")
		elif m.has_method("cancel"):
			m.call("cancel")
		else:
			m.visible = false
		_modals.erase(m)
		return true
	return await back()


func _transition(name: String, from: Vector2) -> void:
	var target: Control = _screens[name]
	if _busy:
		# A transition is running: just settle on the requested screen.
		for n in _screens:
			_screens[n].visible = n == name
		target.modulate.a = 1.0
		screen_changed.emit(name)
		return
	_busy = true
	var outgoing: Array[Control] = []
	for n in _screens:
		if n != name and _screens[n].visible:
			outgoing.append(_screens[n])
	if not outgoing.is_empty() and Motion.effects_enabled():
		for o in outgoing:
			Motion.fade(o, 0.0, Motion.FAST)
		await get_tree().create_timer(Motion.FAST).timeout
	for o in outgoing:
		o.visible = false
		o.modulate.a = 1.0
	target.visible = true
	var t := Motion.slide_in(target, from)
	_busy = false
	screen_changed.emit(name)
	if Motion.effects_enabled():
		await t.finished
