class_name Loc
extends RefCounted
## Translations: one CSV (i18n/strings.csv) is the single source of truth.
##
## The file is plain UTF-8 `key,en,de,...`: one row per string, one column per
## language, readable and editable without any tooling. `load_csv()` parses it
## at startup (App._ready) and registers one Translation per language column on
## the TranslationServer, so both scene text (a node whose `text` is a key is
## auto-translated by Godot) and `Loc.t("KEY")` in scripts resolve.
##
## Adding a language: add a column to the CSV, its code to SUPPORTED and its
## name to NAMES, then a flag button in the settings scene. Nothing else.

const CSV_PATH := "res://i18n/strings.csv"
## Language used when the device language has no column.
const DEFAULT := "en"
## Language codes with a column in the CSV, in the order the settings show them.
const SUPPORTED := ["de", "en"]
## Language names, each written in its own language (never translated).
const NAMES := {"en": "English", "de": "Deutsch"}

## locale -> the Translation this class registered, so a reload replaces it.
static var _registered: Dictionary = {}


## {key: {locale: text}} - the parsed file, without registering anything.
## Rows with an empty key or a key starting with "#" are comments.
static func parse_csv(path: String = CSV_PATH) -> Dictionary:
	var out: Dictionary = {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("cannot read translations %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return out
	var header: PackedStringArray = f.get_csv_line()
	if header.size() < 2 or header[0].strip_edges().lstrip("﻿") != "key":
		push_error("%s: first column of the header must be \"key\"" % path)
		return out
	var locales: Array[String] = []
	for i in range(1, header.size()):
		locales.append(header[i].strip_edges())
	while not f.eof_reached():
		var row: PackedStringArray = f.get_csv_line()
		if row.size() < 2:
			continue
		var key := row[0].strip_edges()
		if key == "" or key.begins_with("#"):
			continue
		var values: Dictionary = {}
		for i in locales.size():
			values[locales[i]] = row[i + 1] if i + 1 < row.size() else ""
		out[key] = values
	return out


## Parses the CSV and registers a Translation per language. Safe to call
## twice: an earlier registration for the same language is replaced.
## Returns {locale: number of messages}.
static func load_csv(path: String = CSV_PATH) -> Dictionary:
	var rows := parse_csv(path)
	var counts: Dictionary = {}
	var by_locale: Dictionary = {}
	for key in rows:
		for locale in rows[key]:
			var text: String = rows[key][locale]
			if text == "":
				continue
			if not by_locale.has(locale):
				by_locale[locale] = Translation.new()
				by_locale[locale].locale = locale
			by_locale[locale].add_message(key, text)
			counts[locale] = int(counts.get(locale, 0)) + 1
	for locale in by_locale:
		if _registered.has(locale):
			TranslationServer.remove_translation(_registered[locale])
		TranslationServer.add_translation(by_locale[locale])
		_registered[locale] = by_locale[locale]
	return counts


## The translation of `key`, or the key itself when it is unknown.
static func t(key: String) -> String:
	return String(TranslationServer.translate(key))


## The translation of `key` with its %s/%d placeholders filled from `args`.
static func f(key: String, args: Array) -> String:
	return t(key) % args


## Plural helper: uses `<base>_ONE` for exactly one and `<base>_OTHER`
## otherwise, and passes the count as the only placeholder.
static func plural(base: String, n: int) -> String:
	return f(base + ("_ONE" if n == 1 else "_OTHER"), [n])


static func has(key: String) -> bool:
	return t(key) != key


## The language to use: the player's choice when they made one, else the
## device language when it has a column, else DEFAULT.
static func resolve(setting: String, os_language: String) -> String:
	if SUPPORTED.has(setting):
		return setting
	return os_language if SUPPORTED.has(os_language) else DEFAULT


static func apply(code: String) -> void:
	if TranslationServer.get_locale() != code:
		TranslationServer.set_locale(code)


static func current() -> String:
	return TranslationServer.get_locale()
