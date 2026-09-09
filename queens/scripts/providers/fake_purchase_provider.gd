class_name FakePurchaseProvider
extends PurchaseProvider
## Desktop / editor stand-in: every purchase succeeds after a short delay
## (immediately with `instant = true`). Ownership only lives in memory, so
## restore() returns what was bought in this run plus `fake_owned`.

var instant: bool = false
var delay: float = 0.5
var price_text: String = "2.99 € (fake)"
var fake_owned: Array = []


func provider_name() -> String:
	return "fake"


func is_available() -> bool:
	return true


func start() -> void:
	pass


func query_products(product_ids: Array) -> void:
	var products := {}
	for id in product_ids:
		products[id] = {"price_text": price_text}
	products_updated.emit(products)


func purchase(product_id: String) -> void:
	if not instant and is_inside_tree():
		await get_tree().create_timer(delay).timeout
	if not fake_owned.has(product_id):
		fake_owned.append(product_id)
	purchase_completed.emit(product_id, "fake-token-" + product_id)


func restore() -> void:
	restore_completed.emit(fake_owned.duplicate())
