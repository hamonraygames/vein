extends Node
## Harness for the ring — see ring.gd, game.gd's _fuse_ring, ring_tell.gd.
##
##   Godot --path . -- --ring [--speed=X] [--every=S]
##
## Runs a scripted sequence of cases, printing PASS/FAIL for each, then loops
## the four ring sizes forever so the tell and the fusion effect can be
## watched. Works headless (the assertions are the point) and windowed (the
## animation is the point).
##
## Each case builds a regular N-gon of orphaned Wells one vein short, holds
## it long enough for the tell to bloom, then draws the closing vein.

const CENTER := Vector2(270.0, 800.0)
## Ring edge length, comfortably under Vein.MAX_LEN (340) — and the radius is
## additionally capped so even a hexagon fits between EDGE_MARGIN_X.
const EDGE := 300.0
const R_MAX := 200.0

## Seconds the ring is held open before the closing vein is drawn. Long
## enough to read the tell; the fusion effect itself runs ~1.15s.
const HOLD := 2.0
const SETTLE := 1.6

var _game: Node
var every := 8.0
var speed := 1.0

var _cases: Array[Dictionary] = []
var _idx := -1
var _phase := ""
var _t := 0.0
var _ring: Array[VNode] = []
var _open: Array[VNode] = []
var _budget_before := 0
var _buried_before := 0
var _looping := false
var _loop_n := Ring.MIN
var _fails := 0
var _run_seed := 7311

## `--shots=DIR` captures the tell and each stage of the fusion off the first
## couple of cases, so the visual half of this mechanic can be checked without
## sitting and watching it. Needs a window — there is nothing to grab headless.
var _shot_dir := ""
var _shot_done := {}


func _ready() -> void:
	_game = get_parent()
	Engine.time_scale = speed
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shot_dir = a.get_slice("=", 1)
	_game.start_run(_run_seed)
	_freeze_budget_income()
	if "--ringbench" in OS.get_cmdline_user_args():
		_bench()
		get_tree().quit()
		return
	_cases = [
		{"name": "3 wells -> FORGE", "n": 3, "expect": VNode.Kind.FORGE},
		{"name": "4 wells -> LOOM", "n": 4, "expect": VNode.Kind.LOOM},
		{"name": "5 wells -> KILN", "n": 5, "expect": VNode.Kind.KILN},
		{"name": "6 wells -> CRUCIBLE", "n": 6, "expect": VNode.Kind.CRUCIBLE},
		# Inherited life: half-spent material makes a half-spent tool.
		{"name": "half-spent 3-ring inherits ~0.5", "n": 3,
			"expect": VNode.Kind.FORGE, "reserve": 0.5},
		# A ring touching the Heart is not ring material at all.
		{"name": "Heart-connected ring REFUSES", "n": 3, "expect": -1, "heart": true},
		# Burial would drop the budget under MIN_BUDGET_AFTER_FORGE.
		{"name": "budget floor REFUSES", "n": 3, "expect": -1, "poor": true},
		# Smallest ring wins, and the consequence is that a CHORDED ring can
		# never exist on the board at all: four Wells wired 0-1-2-3, then
		# closed with the 0-2 diagonal, fuse the TRIANGLE the diagonal just
		# made — well 3 is left standing, untouched. Any chord is itself a
		# closing vein, so the smaller ring always fires first and there is
		# never a chorded polygon left over to be ambiguous about.
		#
		# r is forced down because 0-2 is a diagonal: at the default radius
		# a square's is 400, past Vein.MAX_LEN, and _add_vein refuses it.
		{"name": "diagonal fuses the SMALLER ring", "n": 4, "radius": 160.0,
			"expect": VNode.Kind.FORGE, "close": [0, 2], "buries": 3,
			"survivors": 1},
	]
	_next_case()


func _radius(n: int) -> float:
	return minf(R_MAX, EDGE / (2.0 * sin(PI / float(n))))


## Budget must be the lab's alone, or the run's own income clock lands a
## grant mid-case and the burial assertion drifts by one.
func _freeze_budget_income() -> void:
	_game._next_budget_time = INF


func _process(delta: float) -> void:
	if _game == null:
		return
	# Every Well this lab builds is deliberately ORPHANED, so nothing ever
	# feeds the Heart and it starves out long before the cases finish. Hold
	# it full: this harness is testing the ring rules, not survival.
	_game.fuel = _game.fuel_cap()
	_game.misses = 0
	if not _game.alive:
		return
	_t += delta
	if _shot_dir != "":
		_maybe_snap()
	match _phase:
		"hold":
			if _t >= HOLD:
				_close()
		"settle":
			if _t >= SETTLE:
				_check()
		"idle":
			if _t >= every:
				_next_case()


## Everything the previous case left standing, gone — including whatever it
## forged, which is why this clears by area rather than by a tracked list.
func _clear_area() -> void:
	for n in _game.nodes.duplicate():
		if n == _game.heart:
			continue
		if n.position.distance_to(CENTER) <= R_MAX + 90.0:
			_game._remove_node(n)


func _next_case() -> void:
	_clear_area()
	_idx += 1
	if _idx >= _cases.size():
		if not _looping:
			_looping = true
			print("ring_lab: %s" % ("ALL PASS" if _fails == 0 else "%d FAILED" % _fails))
			# Headless is the assertion run — say the result and get out.
			# With a window, keep going so the tell and the fusion can be
			# watched on a loop.
			if DisplayServer.get_name() == "headless":
				get_tree().quit(1 if _fails > 0 else 0)
				return
			print("ring_lab: looping ring sizes for visual inspection")
		_build_loop()
		return
	_build(_cases[_idx])


func _build_loop() -> void:
	_loop_n += 1
	if _loop_n > Ring.MAX:
		_loop_n = Ring.MIN
	_build({"name": "loop %d" % _loop_n, "n": _loop_n, "expect": Ring.kind_for(_loop_n)})


func _build(c: Dictionary) -> void:
	var n: int = c["n"]
	var r: float = float(c.get("radius", _radius(n)))
	_freeze_budget_income()
	_ring = []
	for i in n:
		var a := TAU * float(i) / float(n) - PI * 0.5
		var w: VNode = _game._make_node(VNode.Kind.WELL, CENTER + Vector2(cos(a), sin(a)) * r)
		if c.get("reserve", 0.0) > 0.0:
			w.reserve = VNode.WELL_YIELD * float(c["reserve"])
		_ring.append(w)

	# _add_vein spends the run's real budget — set it rather than fight it.
	# N + 4 is exactly enough: MIN_BUDGET_AFTER_FORGE is 4. The "poor" case
	# sits one under, so the ring closes but the burial is refused.
	var need := n + (3 if c.get("poor", false) else 4)
	_game.budget = _game.veins_used() + need

	var want_veins := 0
	for i in n - 1:
		_game._add_vein(_ring[i], _ring[i + 1])
		want_veins += 1
	if c.get("heart", false):
		_game._add_vein(_ring[0], _game.heart)
		want_veins += 1
	# _add_vein refuses out-of-reach pairs SILENTLY, which is exactly how the
	# chord case came to test nothing at all.
	if _game.veins_used() != want_veins:
		print("ring_lab: SETUP  %s  (wanted %d veins, drew %d)"
			% [c["name"], want_veins, _game.veins_used()])
		_fails += 1

	# Which pair the player "draws" to close. Defaults to the one edge the
	# ring is missing; a case can name any other pair instead.
	var close_pair: Array = c.get("close", [n - 1, 0])
	_open = [_ring[int(close_pair[0])], _ring[int(close_pair[1])]]
	_budget_before = _game.budget
	_buried_before = _game._buried
	_t = 0.0
	_phase = "hold"


func _close() -> void:
	# Phase advances FIRST. A runtime error inside _add_vein aborts the rest
	# of this function, and when that left the phase on "hold" the harness
	# retried the same broken call every frame forever instead of failing the
	# case and moving on.
	_t = 0.0
	_phase = "settle"
	if not is_instance_valid(_open[0]) or not is_instance_valid(_open[1]):
		print("ring_lab: SETUP  a ring member was consumed before the closing vein")
		_fails += 1
		return
	_game._add_vein(_open[0], _open[1])


func _forged() -> VNode:
	for n in _game.nodes:
		if n == _game.heart or n.kind == VNode.Kind.WELL:
			continue
		if n.position.distance_to(CENTER) <= R_MAX + 40.0:
			return n
	return null


func _check() -> void:
	_t = 0.0
	_phase = "idle"
	if _looping:
		return
	var c := _cases[_idx]
	var want: int = c["expect"]
	var got := _forged()
	var ok := true
	var why := ""

	if want < 0:
		if got != null:
			ok = false
			why = "expected no fusion, got kind %d" % got.kind
		elif _game.budget != _budget_before or _game._buried != _buried_before:
			ok = false
			why = "budget/burial moved (%d->%d, buried %d->%d) on a refused ring" % [
				_budget_before, _game.budget, _buried_before, _game._buried]
	elif got == null:
		ok = false
		why = "no shape forged"
	elif got.kind != want:
		ok = false
		why = "expected kind %d, got %d" % [want, got.kind]
	else:
		# Burial: exactly the ring's own veins, gone for good.
		var buried: int = int(c.get("buries", c["n"]))
		if _game._buried - _buried_before != buried:
			ok = false
			why = "expected %d slots buried, got %d" % [buried, _game._buried - _buried_before]
		elif _game.budget != _budget_before - buried:
			ok = false
			why = "expected budget %d, got %d" % [_budget_before - buried, _game.budget]
		elif c.has("survivors"):
			var left := 0
			for w in _ring:
				if is_instance_valid(w):
					left += 1
			if left != int(c["survivors"]):
				ok = false
				why = "expected %d Well(s) left standing, got %d" % [c["survivors"], left]
		elif c.has("reserve"):
			var want_ratio := float(c["reserve"])
			var ratio := got.reserve_ratio()
			if absf(ratio - want_ratio) > 0.06:
				ok = false
				why = "expected reserve_ratio ~%.2f, got %.2f" % [want_ratio, ratio]

	if not ok:
		_fails += 1
		var alive_wells := 0
		for w in _ring:
			if is_instance_valid(w):
				alive_wells += 1
		print("ring_lab:   diag veins=%d budget=%d buried=%d ring_alive=%d/%d nodes=%d"
			% [_game.veins_used(), _game.budget, _game._buried, alive_wells,
				_ring.size(), _game.nodes.size()])
	print("ring_lab: %s  %s%s" % ["PASS" if ok else "FAIL", c["name"],
		"" if ok else "  (%s)" % why])


## Grabs the two things worth looking at: the tell fully bloomed with the ring
## still open, and each stage of the fusion once it closes. Only for the first
## case (a triangle) and the fourth (a hexagon, the expensive one).
func _maybe_snap() -> void:
	if _idx != 0 and _idx != 3:
		return
	var tag := "tri" if _idx == 0 else "hex"
	if _phase == "hold" and _t >= HOLD * 0.85:
		_snap("%s-1-tell" % tag)
	elif _phase == "settle":
		if _t >= 0.22:
			_snap("%s-2-close" % tag)
		if _t >= 0.62:
			_snap("%s-3-collapse" % tag)
		if _t >= 1.05:
			_snap("%s-4-pop" % tag)
		if _t >= 1.45:
			_snap("%s-5-done" % tag)


func _snap(name: String) -> void:
	if _shot_done.has(name):
		return
	_shot_done[name] = true
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [_shot_dir, name])


## Worst-case cost of the tell search, which is the only thing this mechanic
## added to a hot path: Ring.find_pending runs on every _rebuild_graph, i.e.
## on every vein added or removed and every node that dies.
##
## The probe barely exercises it (the bot leaves almost no orphaned Wells
## wired to each other, so find_pending returns at its first guard), so the
## honest measurement is a hand-built worst case: MAX_LIVE_WELLS orphans with
## a dense mesh of veins among them, which is more than a real board can hold
## given the budget those veins would cost.
func _bench() -> void:
	# Two boards. The first is what a real late run can actually hold: every
	# vein costs budget, and late-run budget tops out around 24 TOTAL, so a
	# handful of orphaned Wells wired to each other is the honest worst case.
	# The second is a deliberately impossible mesh, as a ceiling.
	_bench_one("realistic", 8, 0)
	_bench_one("impossible mesh", 20, 3)


func _bench_one(label: String, count: int, chord_stride: int) -> void:
	for n in _game.nodes.duplicate():
		if n != _game.heart:
			_game._remove_node(n)
	var wells: Array[VNode] = []
	for i in count:
		var a := TAU * float(i) / float(count)
		wells.append(_game._make_node(VNode.Kind.WELL,
			Vector2(270.0, 600.0) + Vector2(cos(a), sin(a)) * 240.0))
	# Wiring this would fuse rings as fast as they close, eating the very
	# Wells being measured. _fusing is exactly the guard for that — it is what
	# stops _check_ring re-entering while a fusion tears the board down.
	_game._fusing = true
	_game.budget = 400
	for i in wells.size():
		_game._add_vein(wells[i], wells[(i + 1) % wells.size()])
	if chord_stride > 0:
		for i in wells.size():
			_game._add_vein(wells[i], wells[(i + chord_stride) % wells.size()])
	_game._fusing = false

	const ITER := 2000
	var t0 := Time.get_ticks_usec()
	for _i in ITER:
		Ring.find_pending(_game.nodes, _game.veins, _game.budget,
			_game.MIN_BUDGET_AFTER_FORGE)
	var us := float(Time.get_ticks_usec() - t0) / float(ITER)
	# A 60fps frame is 16667us. This runs on graph EDITS, never per frame.
	print("ringbench: %-16s %2d wells %2d veins -> %6.1f us/call (%.2f%% of a frame)"
		% [label, wells.size(), _game.veins_used(), us, us / 166.67])
