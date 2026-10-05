class_name EnergyLedger
extends RefCounted
## Energy: every game start costs one unit, rewarded ads refill it and the
## lifetime purchase makes it unlimited. State lives in the save file's
## "energy" section; this class is the only writer.
##
## Offline, an empty tank does not stop the player: the start is charged to a
## debt instead. Back online the debt is paid back from the ads, gradually: an
## ad repays at most `ad_reward_energy - ad_min_playable` of it, so every ad
## still leaves at least `ad_min_playable` games to play.

signal changed

var save: SaveData
var config: GameConfig
## What the last charge_start() took: "amount", "debt" or "" (unlimited), so a
## refund gives back the right thing.
var _last_charge := ""
## {granted, repaid} of the last rewarded ad, for the toast.
var last_reward: Dictionary = {"granted": 0, "repaid": 0}


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


## Games played offline on an empty tank, still to be paid back.
func debt() -> int:
	return maxi(0, int(_section().get("debt", 0)))


func is_unlimited() -> bool:
	return bool(_section()["unlimited"])


## `offline`: the backend cannot be reached, so an empty tank may run into debt.
func can_start(offline: bool = false) -> bool:
	return is_unlimited() or amount() > 0 or offline


## Pays for a game start. Returns false (and changes nothing) when empty and
## online; offline, an empty tank adds one to the debt instead.
func charge_start(offline: bool = false) -> bool:
	if is_unlimited():
		_last_charge = ""
		return true
	if amount() > 0:
		_section()["amount"] = amount() - 1
		_last_charge = "amount"
	elif offline:
		_section()["debt"] = debt() + 1
		_last_charge = "debt"
	else:
		return false
	_notify()
	return true


## Gives back a start that never happened, because the server refused it. The
## charge is optimistic: the board appears before the server has answered.
func refund_start() -> void:
	if is_unlimited():
		return
	if _last_charge == "debt":
		_section()["debt"] = maxi(0, debt() - 1)
		_last_charge = ""
		_notify()
		return
	_last_charge = ""
	grant(1)


func grant(units: int) -> void:
	var total := amount() + maxi(units, 0)
	if config.energy_cap > 0:
		total = mini(total, config.energy_cap)
	_section()["amount"] = total
	_notify()


## A rewarded ad: `units` of energy, of which up to `units - ad_min_playable`
## first pay back the debt. Returns {granted, repaid}.
func reward_ad(units: int) -> Dictionary:
	var keep := clampi(config.ad_min_playable, 0, units)
	var repaid := mini(debt(), units - keep)
	if repaid > 0:
		_section()["debt"] = debt() - repaid
	last_reward = {"granted": units - repaid, "repaid": repaid}
	grant(units - repaid)
	return last_reward


func record_ad_watched() -> void:
	_section()["ads_watched"] = int(_section().get("ads_watched", 0)) + 1
	_notify()


## The purchase also clears the debt: there is nothing left to pay back with.
func set_unlimited(purchase_token: String) -> void:
	_section()["unlimited"] = true
	_section()["purchase_token"] = purchase_token
	_section()["debt"] = 0
	_notify()


## "12" or "∞".
func display_text() -> String:
	return "∞" if is_unlimited() else str(amount())


## "−5" while in debt, else "".
func debt_text() -> String:
	return "" if is_unlimited() or debt() == 0 else "−%d" % debt()


func _notify() -> void:
	save.mark_changed()
	changed.emit()
