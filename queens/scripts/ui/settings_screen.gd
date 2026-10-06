extends Control
## Settings: sound volumes as sliders, motion and play options as toggles, the
## language, the nickname and how-to-play. Emits one `setting_changed` per
## toggle or slider move and `language_selected` for the flag row.

signal back_requested
signal setting_changed(key: String, value: Variant)
signal language_selected(code: String)
signal rename_requested(nickname: String)

const TOGGLE_KEYS := ["haptics", "reduced_motion", "mistake_alerts", "region_patterns"]
const SLIDER_KEYS := ["sfx_volume", "music_volume"]

@onready var back_button: Button = $Margin/VBox/TopBar/BackButton
@onready var list: VBoxContainer = $Margin/VBox/Scroll/List
@onready var name_edit: LineEdit = $Margin/VBox/Scroll/List/ProfileCard/VBox/NameRow/NameEdit
@onready var name_button: Button = $Margin/VBox/Scroll/List/ProfileCard/VBox/NameRow/NameButton
@onready var version_label: Label = $Margin/VBox/Scroll/List/AboutCard/VBox/Version
@onready var language: Segmented = $Margin/VBox/Scroll/List/LanguageCard/VBox/Language

var _toggles: Dictionary = {}
var _sliders: Dictionary = {}
var _loading: bool = false


func _ready() -> void:
	back_button.pressed.connect(back_requested.emit)
	for key in TOGGLE_KEYS:
		var toggle: CheckButton = list.find_child(key, true, false)
		if toggle == null:
			continue
		_toggles[key] = toggle
		toggle.toggled.connect(_on_toggled.bind(key))
	for key in SLIDER_KEYS:
		var slider: HSlider = list.find_child(key, true, false)
		if slider == null:
			continue
		_sliders[key] = slider
		slider.value_changed.connect(_on_slider_changed.bind(key))
	# A sample at the new level once the effects slider is let go.
	if _sliders.has("sfx_volume"):
		_sliders["sfx_volume"].drag_ended.connect(func(changed: bool) -> void:
			if changed:
				Sfx.play(&"button"))
	name_button.pressed.connect(func() -> void: rename_requested.emit(name_edit.text.strip_edges()))
	name_edit.text_submitted.connect(func(t: String) -> void: rename_requested.emit(t.strip_edges()))
	language.selected.connect(func(code: String) -> void:
		Sfx.play(&"button")
		Sfx.haptic(8)
		language_selected.emit(code))


## view: {sfx_volume, music_volume, haptics, reduced_motion, mistake_alerts,
## region_patterns, language_effective, nickname, version}
func refresh(view: Dictionary) -> void:
	_loading = true
	language.select(str(view.get("language_effective", Loc.DEFAULT)), false)
	for key in _toggles:
		_toggles[key].button_pressed = bool(view.get(key, _toggles[key].button_pressed))
	for key in _sliders:
		_sliders[key].set_value_no_signal(float(view.get(key, _sliders[key].value)))
	_loading = false
	if name_edit.text == "" or not name_edit.has_focus():
		name_edit.text = str(view.get("nickname", ""))
	version_label.text = "Queens %s" % str(view.get("version", ""))


func _on_toggled(pressed: bool, key: String) -> void:
	if _loading:
		return
	Sfx.play(&"button")
	Sfx.haptic(8)
	setting_changed.emit(key, pressed)


func _on_slider_changed(value: float, key: String) -> void:
	if _loading:
		return
	setting_changed.emit(key, value)
