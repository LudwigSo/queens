class_name DebugApi
extends RefCounted
## The stable surface tests drive the app through (tests/screenshot.gd), so
## scene restructuring never has to reach into private members again.

var main: Node


func _init(main_node: Node) -> void:
	main = main_node


func start_level(index: int) -> void:
	main.start_game(main.levels[index])


func play_step(step: int) -> void:
	main._play_step(step)


func screen() -> String:
	return main.router.current()


func modal() -> String:
	var m: Control = main.router.top_modal()
	return m.name if m != null else ""


func open_pause() -> void:
	main._open_pause()


func close_pause() -> void:
	main.pause_menu.close()


func open_shop(blocked: bool = false) -> void:
	main._open_energy_dialog(blocked)


func shop_state() -> Dictionary:
	return {"hint_visible": main.energy_dialog.hint_label.visible, "buy_visible": main.energy_dialog.buy_button.visible}


func timer_running() -> bool:
	return main.session != null and main.session.running


func hint() -> void:
	main._on_hint()


func give_up() -> void:
	main._on_give_up()


func show_home() -> void:
	main._show_home()


func show_levels() -> void:
	main._show_level_select()


func show_level_detail(level_id: String, scope: String = "global") -> void:
	main._show_level_detail(level_id, scope)


func show_league() -> void:
	main._show_league()


## {locked, text} for the card of the given level index (display order).
func level_card(index: int) -> Dictionary:
	var id: String = str(main.levels[index]["id"])
	var card = main.level_select.card_for(id)
	if card == null:
		return {}
	return {"locked": card.locked, "text": card.text_summary()}


func scroll_levels_to(index: int) -> void:
	main.level_select.scroll_to(str(main.levels[index]["id"]))


func open_settings() -> void:
	main._show_settings()


func open_tutorial(step: int = 0) -> void:
	main._show_tutorial()
	main.tutorial.jump_to(step)


func tutorial_step() -> int:
	return main.tutorial.step_index


func release_splash() -> void:
	main.splash.finish_now()
