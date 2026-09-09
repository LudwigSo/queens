extends PurchaseProvider
## The lifetime unlimited-energy purchase through Godot's Google Play
## Billing plugin (res://addons/GodotGooglePlayBilling, Godot 4.2+). The
## plugin's BillingClient class is looked up by name at runtime, so this
## script parses and degrades to "purchases unavailable" when the addon is
## missing. Selected by App only on Android with the addon present.

var _client: Object = null
var _connected: bool = false
var _pending_product_ids: Array = []
var _known_product_ids: Array = []


static func has_plugin() -> bool:
	return _class_script("BillingClient") != null


static func _class_script(class_name_: String) -> GDScript:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == class_name_:
			return load(str(entry["path"]))
	return null


func provider_name() -> String:
	return "play_billing"


func is_available() -> bool:
	return _connected


func start() -> void:
	if not has_plugin():
		purchase_failed.emit("Google Play Billing plugin not installed")
		return
	if _client != null:
		return
	_client = _class_script("BillingClient").new()
	_client.connected.connect(_on_connected)
	_client.disconnected.connect(func() -> void: _connected = false)
	_client.connect_error.connect(func(code: int, message: String) -> void:
		_connected = false
		purchase_failed.emit("Store connection failed (%d): %s" % [code, message]))
	_client.query_product_details_response.connect(_on_product_details)
	_client.query_purchases_response.connect(_on_purchases_response)
	_client.on_purchase_updated.connect(_on_purchases_response)
	_client.acknowledge_purchase_response.connect(func(_response: Dictionary) -> void: pass)
	_client.start_connection()


func _inapp() -> int:
	return int(_client.ProductType.INAPP)


func _on_connected() -> void:
	_connected = true
	if not _pending_product_ids.is_empty():
		query_products(_pending_product_ids)
		_pending_product_ids = []
	restore()


func query_products(product_ids: Array) -> void:
	_known_product_ids = product_ids.duplicate()
	if _client == null or not _connected:
		_pending_product_ids = product_ids.duplicate()
		return
	_client.query_product_details(product_ids, _inapp())


func _on_product_details(response: Dictionary) -> void:
	if int(response.get("response_code", 0)) != 0:
		purchase_failed.emit("Store error: %s" % str(response.get("debug_message", "")))
		return
	var products := {}
	for detail in response.get("product_details", []):
		var id := str(detail.get("product_id", ""))
		var price := str(detail.get("one_time_purchase_offer_details", {}).get("formatted_price", ""))
		products[id] = {"price_text": price}
	products_updated.emit(products)


func purchase(product_id: String) -> void:
	if _client == null or not _connected:
		purchase_failed.emit("Store not connected")
		return
	_client.purchase(product_id)


func restore() -> void:
	if _client == null or not _connected:
		restore_completed.emit([])
		return
	_client.query_purchases(_inapp())


## Shared by the purchase flow and query_purchases: acknowledges and reports
## every purchased item.
func _on_purchases_response(response: Dictionary) -> void:
	if int(response.get("response_code", 0)) != 0:
		var message := str(response.get("debug_message", ""))
		if message != "":
			purchase_failed.emit("Purchase failed: %s" % message)
		restore_completed.emit([])
		return
	var owned: Array = []
	for p in response.get("purchases", []):
		if int(p.get("purchase_state", 0)) != int(_client.PurchaseState.PURCHASED):
			continue
		var token := str(p.get("purchase_token", ""))
		if not bool(p.get("is_acknowledged", false)):
			_client.acknowledge_purchase(token)
		for id in p.get("product_ids", []):
			owned.append(str(id))
			purchase_completed.emit(str(id), token)
	restore_completed.emit(owned)
