class_name TouchScroll
extends ScrollContainer
## A ScrollContainer that scrolls when the drag starts on its content.
##
## Godot only drag-scrolls when the touch reaches the ScrollContainer, and
## every Control with MOUSE_FILTER_STOP below it (Buttons, PanelContainers,
## a plain Control like VirtualGrid) swallows the touch first. This switches
## all such content to MOUSE_FILTER_PASS, including nodes added later (rebuilt
## lists, recycled grid tiles). Buttons still work: a tap presses them, and the
## container cancels the press once a drag turns into a scroll.
##
## Sliders and text fields keep STOP, since there a drag means something else.


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		# Not _ready: views added by a --script test never get it.
		var tree := get_tree()
		if not tree.node_added.is_connected(_on_node_added):
			tree.node_added.connect(_on_node_added)
		for child in get_children():
			let_drags_through(child)
	elif what == NOTIFICATION_EXIT_TREE:
		var tree := get_tree()
		if tree.node_added.is_connected(_on_node_added):
			tree.node_added.disconnect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node is Control and is_ancestor_of(node) and not node is ScrollBar:
		_pass(node)


## Lets drags on `root` and everything below it reach the scroll container.
static func let_drags_through(root: Node) -> void:
	if root is Control:
		_pass(root)
	for c in root.find_children("*", "Control", true, false):
		_pass(c)


static func _pass(c: Control) -> void:
	if c.mouse_filter != Control.MOUSE_FILTER_STOP:
		return
	if c is Range or c is LineEdit or c is TextEdit:
		return
	c.mouse_filter = Control.MOUSE_FILTER_PASS
