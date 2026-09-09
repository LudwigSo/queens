class_name EnergyLedger
extends RefCounted
## Energy: every game start costs one unit, rewarded ads refill it and the
## lifetime purchase makes it unlimited. State lives in the save file's
## "energy" section; this class is the only writer.

signal changed

var save: SaveData
var config: GameConfig


func _init(save_data: SaveData, game_config: GameConfig) -> void:
	save = save_data
	config = game_config


## Points the ledger at another save (App.use_save_path).
func bind_save(save_data: SaveData) -> void:
	save = save_data
	changed.emit()


func _section() -> Dictionary:
	return save.data["energy"]


func amount() -> int:
	return int(_section()["amount"])


func is_unlimited() -> bool:
	return bool(_section()["unlimited"])


func can_start() -> bool:
	return is_unlimited() or amount() > 0


## Pays for a game start. Returns false (and changes nothing) when empty.
func charge_start() -> bool:
	if is_unlimited():
		return true
	if amount() <= 0:
		return false
	_section()["amount"] = amount() - 1
	_notify()
	return true


func grant(units: int) -> void:
	var total := amount() + maxi(units, 0)
	if config.energy_cap > 0:
		total = mini(total, config.energy_cap)
	_section()["amount"] = total
	_notify()


func record_ad_watched() -> void:
	_section()["ads_watched"] = int(_section().get("ads_watched", 0)) + 1
	_notify()


func set_unlimited(purchase_token: String) -> void:
	_section()["unlimited"] = true
	_section()["purchase_token"] = purchase_token
	_notify()


## "12" or "∞".
func display_text() -> String:
	return "∞" if is_unlimited() else str(amount())


func _notify() -> void:
	save.mark_changed()
	changed.emit()
