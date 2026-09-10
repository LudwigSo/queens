extends Control
## Settings: sound, motion and play options as toggles, the language, the
## nickname, restore purchases and how-to-play. Emits one `setting_changed`
## per toggle and `language_selected` for the flag row.

signal back_requested
signal setting_changed(key: String, value: bool)
signal language_selected(code: String)
signal rename_requested(nickname: String)
signal restore_requested

const TOGGLE_KEYS := ["sfx", "music", "haptics", "reduced_motion", "mistake_alerts", "region_patterns"]

@onready var back_button: Button = $Margin/VBox/TopBar/BackButton
@onready var list: VBoxContainer = $Margin/VBox/Scroll/List
@onready var name_edit: LineEdit = $Margin/VBox/Scroll/List/ProfileCard/VBox/NameRow/NameEdit
@onready var name_button: Button = $Margin/VBox/Scroll/List/ProfileCard/VBox/NameRow/NameButton
@onready var restore_button: Button = $Margin/VBox/Scroll/List/ProfileCard/VBox/RestoreButton
@onready var version_label: Label = $Margin/VBox/Scroll/List/AboutCard/VBox/Version
@onready var language: Segmented = $Margin/VBox/Scroll/List/LanguageCard/VBox/Language

var _toggles: Dictionary = {}
var _loading: bool = false


func _ready() -> void:
	back_button.pressed.connect(back_requested.emit)
	for key in TOGGLE_KEYS:
		var toggle: CheckButton = list.find_child(key, true, false)
		if toggle == null:
			continue
		_toggles[key] = toggle
		toggle.toggled.connect(_on_toggled.bind(key))
	name_button.pressed.connect(func() -> void: rename_requested.emit(name_edit.text.strip_edges()))
	name_edit.text_submitted.connect(func(t: String) -> void: rename_requested.emit(t.strip_edges()))
	restore_button.pressed.connect(restore_requested.emit)
	language.selected.connect(func(code: String) -> void:
		Sfx.play(&"button")
		Sfx.haptic(8)
		language_selected.emit(code))


## view: {sfx, music, haptics, reduced_motion, mistake_alerts, region_patterns,
## language_effective, nickname, purchases_available, version}
func refresh(view: Dictionary) -> void:
	_loading = true
	language.select(str(view.get("language_effective", Loc.DEFAULT)), false)
	for key in _toggles:
		_toggles[key].button_pressed = bool(view.get(key, _toggles[key].button_pressed))
	_loading = false
	if name_edit.text == "" or not name_edit.has_focus():
		name_edit.text = str(view.get("nickname", ""))
	restore_button.visible = bool(view.get("purchases_available", false))
	version_label.text = "Queens %s" % str(view.get("version", ""))


func _on_toggled(pressed: bool, key: String) -> void:
	if _loading:
		return
	Sfx.play(&"button")
	Sfx.haptic(8)
	setting_changed.emit(key, pressed)
