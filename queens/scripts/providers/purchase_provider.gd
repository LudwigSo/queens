class_name PurchaseProvider
extends Node
## In-app purchase interface for the lifetime unlimited-energy product. The
## Android build plugs in Google Play Billing, everything else gets
## FakePurchaseProvider.

signal products_updated(products: Dictionary)          ## product id -> {"price_text": String}
signal purchase_completed(product_id: String, token: String)
signal purchase_failed(reason: String)
signal restore_completed(owned: Array)                 ## product ids the player owns


func provider_name() -> String:
	return "none"


func is_available() -> bool:
	return false


func start() -> void:
	pass


func query_products(_product_ids: Array) -> void:
	pass


func purchase(_product_id: String) -> void:
	purchase_failed.emit(Loc.t("ERR_PURCHASES_UNAVAILABLE"))


func restore() -> void:
	restore_completed.emit([])
