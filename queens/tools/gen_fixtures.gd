extends SceneTree
## Writes the cross-language fixtures that pin scoring and the league maths.
##
## GDScript is the oracle: this script runs the real Scoring and LeagueRules and
## writes what they produce. The Go port reads the same files and must agree.
## CI regenerates and diffs, so changing a formula means regenerating in the same
## commit, which puts every changed expected value in front of a reviewer next to
## the change that caused it.
##
##   godot --headless --path queens --script tools/gen_fixtures.gd
##
## Floats are compared by their IEEE-754 bit pattern in hex, never by decimal
## text: JSON.stringify does not round-trip a double, so a decimal comparison
## would be testing the printer rather than the maths.

const Levels := preload("res://scripts/levels.gd")

## 220 elapsed values for the sweep. Every one is exactly representable as a
## double, so neither runtime has to parse a decimal that rounds.
const ELAPSED_SET: Array[float] = []


func _initialize() -> void:
	Loc.load_csv()
	TranslationServer.set_locale("en")
	var dir := _fixtures_dir()
	DirAccess.make_dir_recursive_absolute(dir)

	_write(dir.path_join("scoring_cases.json"), _scoring_cases())
	_write(dir.path_join("league_cases.json"), _league_cases())

	var digest := _sweep_digest()
	var f := FileAccess.open(dir.path_join("sweep.sha256"), FileAccess.WRITE)
	f.store_string("sha256:%s\ncases:%d\nlevels:%d\n" % [digest["hash"], digest["cases"], digest["levels"]])
	f.close()

	print("wrote fixtures to ", dir)
	print("sweep: %d cases, sha256:%s" % [digest["cases"], digest["hash"]])
	quit(0)


## The fixtures live beside the project, at the repository root, because both
## runtimes read them.
static func _fixtures_dir() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../shared/fixtures").simplify_path()


func _write(path: String, data: Variant) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	# LF only, so a Windows checkout and a Linux one hash the same bytes.
	f.store_string(JSON.stringify(data, "  ").replace("\r\n", "\n") + "\n")
	f.close()


## The bit pattern of a double as 16 hex digits, big-endian. StreamPeerBuffer is
## used rather than PackedFloat64Array.to_byte_array() because that one yields
## host byte order, which would differ between machines.
static func hex_of(v: float) -> String:
	var b := StreamPeerBuffer.new()
	b.big_endian = true
	b.put_double(v)
	return b.data_array.hex_encode()


static func _case(size: int, difficulty: float, wrong: int, hints: int, elapsed: float, completed: bool, par_override: float) -> Dictionary:
	var result := {
		"size": size, "difficulty": difficulty, "wrong_placements": wrong,
		"hint_count": hints, "elapsed_seconds": elapsed, "completed": completed,
	}
	if par_override > 0.0:
		result["par_seconds"] = par_override
	var bd := Scoring.breakdown(result)
	return {
		"size": size,
		"difficulty": difficulty, "difficulty_hex": hex_of(difficulty),
		"wrong": wrong, "hints": hints,
		"elapsed": elapsed, "elapsed_hex": hex_of(elapsed),
		"completed": completed,
		"par_override": par_override, "par_override_hex": hex_of(par_override),
		"expect": {
			"score": int(bd["score"]),
			"base": int(bd["base"]),
			"par_hex": hex_of(float(bd["par_seconds"])),
			"accuracy_hex": hex_of(float(bd["accuracy_factor"])),
			"speed_hex": hex_of(float(bd["speed_factor"])),
			"hint_hex": hex_of(float(bd["hint_factor"])),
			"flawless": bool(bd["flawless"]),
		},
	}


func _scoring_cases() -> Dictionary:
	var cases: Array = []
	# The rows checked in at tests/run_tests.gd, including the knife edge at
	# (10, 55, wrong 12, 900 s) -> 84.
	for row in [[6, 8.0, 0, 45.0, 223], [6, 8.0, 0, 72.0, 166], [6, 8.0, 3, 150.0, 42],
			[10, 55.0, 0, 180.0, 1420], [10, 55.0, 0, 245.0, 1169],
			[10, 55.0, 5, 600.0, 190], [10, 55.0, 12, 900.0, 84]]:
		cases.append(_case(int(row[0]), float(row[1]), int(row[2]), 0, float(row[3]), true, 0.0))
	# A forfeit scores nothing, whatever it claims.
	cases.append(_case(10, 55.0, 0, 0, 10.0, false, 0.0))
	# Hints, including the clamp at the bottom.
	for h in 7:
		cases.append(_case(10, 55.0, 0, h, 180.0, true, 0.0))
	# A stored par overrides the formula, so old results stay reproducible.
	cases.append(_case(6, 8.0, 0, 0, 72.0, true, 144.0))
	# elapsed 0 takes the SPEED_MAX branch: historic rows carry it.
	cases.append(_case(6, 8.0, 0, 0, 0.0, true, 0.0))
	# Accuracy clamp.
	for w in [10, 100]:
		cases.append(_case(8, 20.0, w, 0, 120.0, true, 0.0))
	# Both speed clamps, and the two points where they meet the curve exactly.
	for e in [80.0, 79.0, 240.0, 720.0, 721.0]:
		cases.append(_case(8, 20.0, 0, 0, e, true, 240.0))
	# Nothing reaches zero while completed.
	cases.append(_case(10, 55.0, 99, 99, 1000000.0, true, 0.0))
	# The grid.
	for size in [6, 7, 8, 9, 10]:
		for difficulty in [6.0, 20.0, 40.0, 61.0]:
			var par := Scoring.par_seconds(difficulty, size)
			for wrong in [0, 1, 3, 12]:
				for hints in [0, 1, 2]:
					for f in [0.25, 1.0 / 3.0, 0.5, 1.0, 2.0, 3.0, 4.0]:
						cases.append(_case(size, difficulty, wrong, hints, par * f, true, 0.0))

	var weeks: Array = []
	for t in [0, 345600, 345599, 604800, 1788739200, 1788739199, 1789343999]:
		weeks.append({"t": t, "index": Scoring.week_index(t)})
	var bounds: Array = []
	for i in [0, 2957, 3000]:
		bounds.append({"index": i, "start": Scoring.week_start(i), "end": Scoring.week_end(i)})

	return {
		"format": 1,
		"generator": "queens/tools/gen_fixtures.gd",
		"constants": {
			"base_flat_hex": hex_of(Scoring.BASE_FLAT),
			"base_per_size_hex": hex_of(Scoring.BASE_PER_SIZE),
			"base_per_difficulty_hex": hex_of(Scoring.BASE_PER_DIFFICULTY),
			"difficulty_ref_hex": hex_of(Scoring.DIFFICULTY_REF),
			"difficulty_exponent_hex": hex_of(Scoring.DIFFICULTY_EXPONENT),
			"par_base_hex": hex_of(Scoring.PAR_BASE),
			"par_per_difficulty_hex": hex_of(Scoring.PAR_PER_DIFFICULTY),
			"par_per_cell_hex": hex_of(Scoring.PAR_PER_CELL),
			"k_wrong_hex": hex_of(Scoring.K_WRONG),
			"accuracy_min_hex": hex_of(Scoring.ACCURACY_MIN),
			"speed_min_hex": hex_of(Scoring.SPEED_MIN),
			"speed_max_hex": hex_of(Scoring.SPEED_MAX),
			"speed_exponent_hex": hex_of(Scoring.SPEED_EXPONENT),
			"hint_penalty_hex": hex_of(Scoring.HINT_PENALTY),
			"hint_min_hex": hex_of(Scoring.HINT_MIN),
			"week_seconds": Scoring.WEEK_SECONDS,
			"week_epoch_offset": Scoring.WEEK_EPOCH_OFFSET,
		},
		"cases": cases,
		"week": weeks,
		"week_bounds": bounds,
	}


func _member(id: String, score: int, games: int, last: int) -> Dictionary:
	return {"player_id": id, "nickname": id, "round_score": score, "games": games,
		"last_submit_at": last, "is_me": false, "is_friend": false}


func _league_cases() -> Dictionary:
	var cfg := LeagueConfigFile.load_default()
	var tiers: Array = []
	for t in cfg["tiers"]:
		tiers.append(str(t["id"]))

	var rounds: Array = []
	for tier in tiers:
		for t in [0, 345600, 345601, 1788739200, 1788912000, 1789343999, 1789344000]:
			rounds.append({"tier": tier, "t": t, "expect": LeagueRules.round_index(cfg, tier, t)})
	var bounds: Array = []
	for tier in tiers:
		for i in [0, 2957, 6900]:
			bounds.append({"tier": tier, "index": i,
				"start": LeagueRules.round_start(cfg, tier, i), "end": LeagueRules.round_end(cfg, tier, i)})

	var slots: Array = []
	for below in [0, 1, 49, 50, 51, 99, 100, 499, 500, 501, 1000]:
		for tier in ["challenger", "diamond"]:
			slots.append({"tier": tier, "below": below, "expect": LeagueRules.slots(cfg, tier, below)})
	var openings: Array = []
	for below in [6, 60, 69, 100, 500]:
		for members in [0, 3, 5, 6, 10, 50]:
			openings.append({"tier": "challenger", "below": below, "members": members,
				"expect": LeagueRules.openings(cfg, "challenger", below, members)})

	var counts: Array = []
	for tier in tiers:
		var tier_cfg: Dictionary = LeagueRules.tier(cfg, tier)
		for n in range(0, 41):
			for leader in [0, 1499, 1500, 2500]:
				for up in [-1, 0, 3]:
					var c := LeagueRules.counts(n, tier_cfg, cfg, leader, up)
					counts.append({"tier": tier, "n": n, "leader": leader, "up_count": up,
						"expect": {"up": int(c["up"]), "down": int(c["down"])}})

	var round_scores: Array = []
	for scores in [[], [100], [100, 50, 200], [10, 20, 30, 40, 50, 60, 70, 80, 90, 100,
			110, 120, 130, 140, 150, 160, 170, 180, 190, 200]]:
		round_scores.append({"scores": scores, "expect": LeagueRules.round_score(scores, cfg)})

	# Fixed member lists, generated once from a seeded RNG and stored, so the Go
	# side never needs Godot's random number generator. Deliberate ties pin the
	# fourth sort key (player_id), which the GDScript comparator does not have:
	# its sort is unstable, so identical triples used to come out in any order.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260919
	var evaluations: Array = []
	for size in [0, 1, 3, 4, 5, 6, 29, 30, 31, 47, 100]:
		var members: Array = []
		for i in size:
			var score := 0 if i % 7 == 3 else rng.randi_range(0, 4000)
			# Every third member shares a score, games and submit time with the
			# one before it.
			if i % 3 == 0 and i > 0:
				members.append(_member("p%03d" % i, int(members[i - 1]["round_score"]),
					int(members[i - 1]["games"]), int(members[i - 1]["last_submit_at"])))
			else:
				members.append(_member("p%03d" % i, score, rng.randi_range(1, 20), rng.randi_range(100, 999)))
		for tier in tiers:
			for up in [-1, 0, 3]:
				var ev := LeagueRules.evaluate(members.duplicate(true), tier, cfg, up)
				var out: Array = []
				for m in ev["members"]:
					out.append({"player_id": m["player_id"], "rank": m["rank"], "zone": m["zone"]})
				evaluations.append({"tier": tier, "up_count": up, "members": members,
					"expect": {"promote_count": int(ev["promote_count"]),
						"relegate_count": int(ev["relegate_count"]), "members": out}})

	var transitions: Array = []
	for tier in tiers:
		for outcome in ["promoted", "stayed", "relegated", "inactive_frozen", "inactive_relegated"]:
			transitions.append({"tier": tier, "outcome": outcome, "expect": LeagueRules.apply(cfg, tier, outcome)})
	var inactive: Array = []
	var promote: Array = []
	var relegate: Array = []
	for tier in tiers:
		inactive.append({"tier": tier, "expect": LeagueRules.inactive_outcome(LeagueRules.tier(cfg, tier))})
		promote.append({"tier": tier, "expect": LeagueRules.promote_tier(cfg, tier)})
		relegate.append({"tier": tier, "expect": LeagueRules.relegate_tier(cfg, tier)})

	return {
		"format": 1,
		"config_hash": LeagueConfigFile.hash_of_file(),
		"round_index": rounds,
		"round_bounds": bounds,
		"slots": slots,
		"openings": openings,
		"counts": counts,
		"round_score": round_scores,
		"evaluate": evaluations,
		"transitions": transitions,
		"inactive_outcome": inactive,
		"promote_tier": promote,
		"relegate_tier": relegate,
	}


## The elapsed values of the sweep, in the order both runtimes must walk them.
static func elapsed_set() -> Array:
	var out: Array = [0.0]
	for v in range(1, 61):
		out.append(float(v))
	for v in range(65, 301, 5):
		out.append(float(v))
	for v in range(310, 601, 10):
		out.append(float(v))
	for v in range(630, 1201, 30):
		out.append(float(v))
	for v in range(1260, 3601, 60):
		out.append(float(v))
	for v in range(3900, 7201, 300):
		out.append(float(v))
	for v in [14400, 21600, 43200, 86400]:
		out.append(float(v))
	# Binary fractions, exactly representable in both runtimes.
	for v in [0.5, 2.5, 12.25, 33.75, 99.5]:
		out.append(float(v))
	return out


## Hashes the score of every level x mistakes x hints x elapsed combination.
## This is the real proof: it answers the "is Go's pow the same as the engine's"
## question empirically rather than by argument.
func _sweep_digest() -> Dictionary:
	var levels: Array = Levels.load_all()
	var elapsed := elapsed_set()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var buffer := PackedStringArray()
	var count := 0
	for lv in levels:
		var size := int(lv["size"])
		var difficulty := float(lv["difficulty"])
		for wrong in range(0, 26):
			for hints in range(0, 7):
				for e in elapsed:
					var score := Scoring.score({
						"size": size, "difficulty": difficulty, "wrong_placements": wrong,
						"hint_count": hints, "elapsed_seconds": e, "completed": true,
					})
					buffer.append(str(score))
					count += 1
			if buffer.size() > 20000:
				ctx.update(("\n".join(buffer) + "\n").to_utf8_buffer())
				buffer = PackedStringArray()
	if buffer.size() > 0:
		ctx.update(("\n".join(buffer) + "\n").to_utf8_buffer())
	return {"hash": ctx.finish().hex_encode(), "cases": count, "levels": levels.size()}
