class_name HttpBackend
extends Backend
## The networked Backend: talks to the Go service over HTTP.
##
## It keeps the {ok, data, error} envelope byte-identical, because every caller
## in the game already reads that shape. The envelope deliberately does not go
## on the wire -- the server speaks ordinary HTTP with status codes, caching and
## 304s, and this class re-wraps it.
##
## Failures carry three extra keys the local stub never needed: `code` (the
## ERR_* key), `status` and `permanent` (true when retrying the same request can
## only fail again). Read methods also return the last known value, or an empty
## shape, in `data`, so the screens that index ["data"] without checking ["ok"]
## keep rendering instead of crashing when the phone is offline.

const POOL_SIZE := 4
const TIMEOUT_DEFAULT := 10.0
const TIMEOUT_SUBMIT := 8.0
const TIMEOUT_REGISTER := 15.0
const STANDING_FRESH_SECONDS := 15
const RESYNC_THROTTLE_SECONDS := 60
## Beyond this much disagreement between the wall clock and the monotonic clock,
## the device clock moved (or the process was suspended) and the offset is stale.
const CLOCK_DRIFT_TOLERANCE := 5

signal _released
signal _init_done

var _config: GameConfig
var _save: SaveData
var _base: String = ""
var _token: String = ""
var _pool: Array[HTTPRequest] = []
var _free: Array[HTTPRequest] = []

var _bootstrapped := false
var _init_in_flight := false

# Last known values, handed back on failure so the UI never renders an empty
# league screen just because a request timed out.
var _profile: Dictionary = {}
var _standing: Dictionary = {}
var _standing_fresh_until := 0
var _friends: Array = []
var _meta: Dictionary = {}
var _meta_etag: String = ""
var _locks: Dictionary = {}
var _summary: Dictionary = {}
var _ack_pending := -1
var _league_config: Dictionary = {}
var _config_hash: String = ""
var _cooldown_seconds := 0

var _synced := false
var _offset := 0
var _synced_wall := 0
var _synced_ticks := 0
var _last_resync := 0


func _init(config: GameConfig, save: SaveData) -> void:
	_config = config
	_save = save
	_base = config.server_url.rstrip("/")
	_token = save.auth_token()


func _ready() -> void:
	for i in POOL_SIZE:
		var req := HTTPRequest.new()
		req.name = "Req%d" % i
		req.use_threads = true
		req.accept_gzip = true
		add_child(req)
		_pool.append(req)
		_free.append(req)


func provider_name() -> String:
	return "http"


# --- plumbing ---------------------------------------------------------------


func _acquire() -> HTTPRequest:
	while _free.is_empty():
		await _released
	return _free.pop_back()


func _release(req: HTTPRequest) -> void:
	_free.append(req)
	_released.emit()


## Number of %-placeholders in a format string, so a params list of the wrong
## length never reaches `%` (which throws).
static func _placeholder_count(text: String) -> int:
	var n := 0
	var i := 0
	while i < text.length() - 1:
		if text[i] == "%":
			if text[i + 1] == "%":
				i += 1
			else:
				n += 1
		i += 1
	return n


## JSON has one number type, so every integer arrives as a float. Turn the
## integral ones back, or "%d" % [3.0] prints "3.0".
static func _coerce_params(params: Array) -> Array:
	var out: Array = []
	for p in params:
		if p is float and p == floor(p):
			out.append(int(p))
		else:
			out.append(p)
	return out


## Turns a server error code into the sentence the player sees. An unknown code
## from a newer server degrades to the generic message instead of showing a raw
## key.
static func _localise(_status: int, problem: Dictionary) -> String:
	var code := str(problem.get("code", ""))
	var params := _coerce_params(problem.get("params", []) as Array)
	if code == "ERR_LEVEL_LOCKED" and params.size() == 1:
		return Loc.f(code, [Cooldown.format_remaining(int(params[0]))])
	if code.begins_with("ERR_") and Loc.has(code):
		var text := Loc.t(code)
		if _placeholder_count(text) == params.size():
			return Loc.f(code, params) if params.size() > 0 else text
	return Loc.t("ERR_SERVER")


## True when repeating the identical request can only fail the same way, so the
## offline queue should drop the item instead of retrying it forever.
static func _is_permanent(status: int, code: String) -> bool:
	if code == "ERR_LEVEL_UNKNOWN":
		# An older server simply has not imported this level yet.
		return false
	return status in [400, 403, 405, 409, 410, 413, 415, 422]


func _transport_failure() -> Dictionary:
	return {
		"ok": false, "data": null, "error": Loc.t("ERR_NETWORK"),
		"code": "ERR_NETWORK", "status": 0, "permanent": false, "params": [],
	}


func _call(method: int, path: String, body: Variant = null, opts: Dictionary = {}) -> Dictionary:
	var use_auth: bool = bool(opts.get("auth", true))
	var retry: bool = bool(opts.get("retry", false))
	var timeout: float = float(opts.get("timeout", TIMEOUT_DEFAULT))
	var etag: String = str(opts.get("etag", ""))

	# A screen that asks for data while the bootstrap is still in flight waits
	# for it rather than rendering an empty league. The bootstrap itself must be
	# exempt, or it would sit waiting for itself to finish.
	if use_auth and _init_in_flight and not bool(opts.get("bootstrap", false)):
		await _init_done

	for attempt in 2:
		var res := await _request_once(method, path, body, use_auth, timeout, etag)
		var status := int(res.get("status", 0))
		var transport_failed := bool(res.get("transport_failed", false))
		if attempt == 0 and retry and (transport_failed or status in [502, 503, 504]):
			await _sleep(randf_range(0.5, 1.5))
			continue
		return _wrap(res)
	return _transport_failure()


func _sleep(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _request_once(method: int, path: String, body: Variant, use_auth: bool, timeout: float, etag: String) -> Dictionary:
	var req := await _acquire()
	req.timeout = timeout
	var headers := PackedStringArray([
		"Accept: application/json, application/problem+json",
		"X-Client-Version: " + _config.client_version,
	])
	if body != null:
		headers.append("Content-Type: application/json")
	if use_auth and _token != "":
		headers.append("Authorization: Bearer " + _token)
	if etag != "":
		headers.append("If-None-Match: " + etag)

	var payload := "" if body == null else JSON.stringify(body)
	var err := req.request(_base + path, headers, method, payload)
	if err != OK:
		_release(req)
		return {"transport_failed": true}
	var out: Array = await req.request_completed
	_release(req)

	var result := int(out[0])
	var status := int(out[1])
	var raw_headers: PackedStringArray = out[2]
	var bytes: PackedByteArray = out[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"transport_failed": true}

	var head := {}
	for h in raw_headers:
		var parts := h.split(":", true, 1)
		if parts.size() == 2:
			head[parts[0].strip_edges().to_lower()] = parts[1].strip_edges()
	if head.has("x-server-time"):
		_sync_clock(int(head["x-server-time"]))

	var text := bytes.get_string_from_utf8()
	var parsed: Variant = null
	if not text.strip_edges().is_empty():
		parsed = JSON.parse_string(text)
	return {"status": status, "headers": head, "parsed": parsed, "had_body": not text.strip_edges().is_empty()}


func _wrap(res: Dictionary) -> Dictionary:
	if res.get("transport_failed", false):
		return _transport_failure()
	var status := int(res["status"])
	var parsed: Variant = res.get("parsed")

	if status == 304 or status == 204:
		return {"ok": true, "data": null, "error": "", "status": status, "headers": res.get("headers", {})}
	if status >= 200 and status < 300:
		if res.get("had_body", false) and parsed == null:
			return {"ok": false, "data": null, "error": Loc.t("ERR_SERVER"),
				"code": "ERR_SERVER", "status": status, "permanent": false, "params": []}
		return {"ok": true, "data": parsed, "error": "", "status": status, "headers": res.get("headers", {})}

	if status == 401:
		# The credential is gone; the next launch registers again.
		_token = ""
		_save.clear_auth()
		_bootstrapped = false

	var problem: Dictionary = parsed if parsed is Dictionary else {}
	var code := str(problem.get("code", ""))
	return {
		"ok": false, "data": null, "error": _localise(status, problem), "code": code,
		"status": status, "permanent": _is_permanent(status, code),
		"params": _coerce_params(problem.get("params", []) as Array),
	}


# --- the clock --------------------------------------------------------------


func _sync_clock(server_now: int) -> void:
	var wall := int(Time.get_unix_time_from_system())
	_offset = server_now - wall
	_synced_wall = wall
	_synced_ticks = Time.get_ticks_msec()
	_synced = true


## Server time, without a round trip: Backend.now_utc() is synchronous and
## cannot await. The offset comes from the X-Server-Time header every response
## carries.
func now_utc() -> int:
	var wall := int(Time.get_unix_time_from_system())
	if not _synced:
		return wall
	# get_ticks_msec is monotonic and stalls while the process is suspended, so a
	# disagreement means either the device clock moved or we were asleep. Either
	# way the offset is no longer trustworthy.
	var wall_delta := wall - _synced_wall
	var ticks_delta := int((Time.get_ticks_msec() - _synced_ticks) / 1000.0)
	if absi(wall_delta - ticks_delta) > CLOCK_DRIFT_TOLERANCE:
		_request_resync()
	return wall + _offset


func _request_resync() -> void:
	var wall := int(Time.get_unix_time_from_system())
	if wall - _last_resync < RESYNC_THROTTLE_SECONDS:
		return
	_last_resync = wall
	resync_time()


func resync_time() -> void:
	await _call(HTTPClient.METHOD_GET, "/v1/time", null, {"auth": false, "timeout": 5.0})


## Called when the app comes back from the background.
func on_resume() -> void:
	_request_resync()
	if _token != "" and not _bootstrapped:
		await init()


# --- the contract -----------------------------------------------------------


func init() -> Dictionary:
	if _token == "":
		return ok(null)
	_init_in_flight = true
	var res := await _call(HTTPClient.METHOD_GET, "/v1/bootstrap", null, {"retry": true, "bootstrap": true})
	_init_in_flight = false
	_init_done.emit()
	if not res["ok"]:
		res["data"] = _profile
		return res
	var d: Dictionary = res["data"]
	_profile = d.get("profile", {})
	_standing = d.get("standing", {})
	_standing_fresh_until = now_utc() + STANDING_FRESH_SECONDS
	_summary = d.get("pending_summary", {})
	_league_config = d.get("league_config", {})
	_config_hash = str(d.get("config_hash", ""))
	_cooldown_seconds = int(d.get("cooldown_seconds", 0))
	_remember_meta(d.get("level_meta", {}))
	_bootstrapped = true
	standing_changed.emit()
	return ok(d)


func _remember_meta(levels: Variant) -> void:
	if not levels is Dictionary:
		return
	_meta = {"levels": levels}
	_locks.clear()
	for id in levels:
		_locks[id] = int((levels[id] as Dictionary).get("locked_until", 0))


func register_player(player_id: String, nickname: String) -> Dictionary:
	if _token != "":
		# Already registered on this device; the bootstrap already fetched the
		# profile.
		return ok(_profile)
	var res := await _call(HTTPClient.METHOD_POST, "/v1/players", {
		"player_id": player_id, "nickname": nickname, "client_version": _config.client_version,
	}, {"auth": false, "timeout": TIMEOUT_REGISTER})
	if not res["ok"]:
		res["data"] = {}
		return res
	var d: Dictionary = res["data"]
	_token = str(d.get("token", ""))
	if _token != "":
		_save.set_auth(player_id, _token, int(d.get("issued_at", 0)))
		# Write immediately: a debounced save could lose a token that exists
		# only on the server from here on.
		_save.save_to(_config.save_path)
	await init()
	return ok(d.get("profile", {}))


func set_nickname(nickname: String) -> Dictionary:
	var res := await _call(HTTPClient.METHOD_PATCH, "/v1/me", {"nickname": nickname.strip_edges()})
	if not res["ok"]:
		return res
	_profile = res["data"]
	return ok(_profile)


func get_profile() -> Dictionary:
	var res := await _call(HTTPClient.METHOD_GET, "/v1/me", null, {"retry": true})
	if not res["ok"]:
		res["data"] = _profile
		return res
	_profile = res["data"]
	return ok(_profile)


func delete_account() -> Dictionary:
	var res := await _call(HTTPClient.METHOD_DELETE, "/v1/me")
	if res["ok"] or int(res.get("status", 0)) == 401:
		_token = ""
		_save.clear_auth()
		_bootstrapped = false
		return ok(null)
	return res


func start_game(level_id: String) -> Dictionary:
	# No retry: the server hands back a still-open session for the same level, so
	# a lost response costs nothing, while a retry could.
	var res := await _call(HTTPClient.METHOD_POST, "/v1/games", {"level_id": level_id})
	if not res["ok"]:
		if str(res.get("code", "")) == "ERR_LEVEL_LOCKED":
			var params: Array = res.get("params", [])
			if params.size() == 1:
				_locks[level_id] = now_utc() + int(params[0])
		return res
	var d: Dictionary = res["data"]
	_locks[level_id] = int(d.get("locked_until", 0))
	_standing_fresh_until = 0
	standing_changed.emit()
	return ok(d)


func submit_result(result: Dictionary) -> Dictionary:
	# from_dict/to_dict normalises the numbers: after a save/load round trip every
	# int in a queued result is a float, and the server rejects 6.0 for an int.
	var payload := GameResult.from_dict(result).to_dict()
	var res := await _call(HTTPClient.METHOD_POST, "/v1/results", payload, {"timeout": TIMEOUT_SUBMIT})
	if not res["ok"]:
		return res
	var d: Dictionary = res["data"]
	if _profile.has("tier_points"):
		_profile["tier_points"] = int(d.get("tier_points", _profile["tier_points"]))
	_standing_fresh_until = 0
	standing_changed.emit()
	return ok(d)


func get_level_leaderboard(level_id: String, scope: String = "global", limit: int = 10) -> Dictionary:
	var path := "/v1/levels/%s/leaderboard?scope=%s&limit=%d" % [level_id.uri_encode(), scope.uri_encode(), limit]
	var res := await _call(HTTPClient.METHOD_GET, path, null, {"retry": true})
	if not res["ok"]:
		return res
	return ok(res["data"])


func get_level_meta() -> Dictionary:
	var res := await _call(HTTPClient.METHOD_GET, "/v1/levels/meta", null,
		{"retry": true, "etag": _meta_etag})
	if not res["ok"]:
		res["data"] = _meta.get("levels", {})
		return res
	if int(res.get("status", 0)) == 304:
		return ok(_meta.get("levels", {}))
	var d: Dictionary = res["data"]
	var head: Dictionary = res.get("headers", {})
	_meta_etag = str(head.get("etag", _meta_etag))
	_cooldown_seconds = int(d.get("cooldown_seconds", _cooldown_seconds))
	_remember_meta(d.get("levels", {}))
	return ok(_meta.get("levels", {}))


func get_league_standing() -> Dictionary:
	if not _standing.is_empty() and now_utc() < _standing_fresh_until:
		return ok(_standing)
	var res := await _call(HTTPClient.METHOD_GET, "/v1/league/standing", null, {"retry": true})
	if not res["ok"]:
		res["data"] = _standing
		return res
	_standing = res["data"]
	_standing_fresh_until = now_utc() + STANDING_FRESH_SECONDS
	return ok(_standing)


func get_round_summary() -> Dictionary:
	if _ack_pending >= 0:
		await ack_round_summary(_ack_pending)
	if not _summary.is_empty():
		return ok(_summary)
	var res := await _call(HTTPClient.METHOD_GET, "/v1/league/summary", null, {"retry": true})
	if not res["ok"]:
		# Never hand back a stale summary offline: it would reopen the overlay on
		# every visit to the home screen.
		res["data"] = {}
		return res
	if int(res.get("status", 0)) == 204 or res["data"] == null:
		return ok({})
	_summary = res["data"]
	return ok(_summary)


func ack_round_summary(round_index: int) -> Dictionary:
	var res := await _call(HTTPClient.METHOD_POST, "/v1/league/summary/ack", {"round_index": round_index})
	if not res["ok"]:
		_ack_pending = round_index
		return res
	_ack_pending = -1
	if int(_summary.get("round_index", -1)) == round_index:
		_summary = {}
	return ok(null)


func get_friends() -> Dictionary:
	var res := await _call(HTTPClient.METHOD_GET, "/v1/friends", null, {"retry": true})
	if not res["ok"]:
		res["data"] = _friends
		return res
	var d: Dictionary = res["data"]
	_friends = d.get("friends", [])
	return ok(_friends)


func add_friend(code: String) -> Dictionary:
	var res := await _call(HTTPClient.METHOD_POST, "/v1/friends",
		{"code": code.strip_edges().to_upper()})
	if not res["ok"]:
		return res
	standing_changed.emit()
	return ok(res["data"])


func remove_friend(friend_id: String) -> Dictionary:
	var res := await _call(HTTPClient.METHOD_DELETE, "/v1/friends/" + friend_id.uri_encode())
	if not res["ok"]:
		return res
	standing_changed.emit()
	return ok(null)


# --- what App reads after the bootstrap -------------------------------------


func level_locks() -> Dictionary:
	return _locks.duplicate()


func server_config() -> Dictionary:
	return {
		"league": _league_config,
		"config_hash": _config_hash,
		"cooldown_seconds": _cooldown_seconds,
	}
