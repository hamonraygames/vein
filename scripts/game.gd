extends Node2D
## VEIN — run controller.
##
## Weekend-1 slice: Wells, the Heart, vein drawing, dots flowing, appetite
## escalation, death. No Forges yet.
##
## The whole sim is deterministic given a seed, which is what later buys the
## Daily, replays and offline balancing for free. Keep it that way: no randomness
## outside `rng`, no logic that reads wall-clock time.

# Instantiate through preloaded consts, not the `class_name` globals: global
# class resolution is unreliable when the game is driven from a `--script` main
# loop, which is exactly how tests/ runs it.
const VNodeScene := preload("res://scripts/vnode.gd")
const VeinScene := preload("res://scripts/vein.gd")
const BurstScene := preload("res://scripts/burst.gd")

const SAVE_PATH := "user://vein.cfg"

## Bump whenever tuning changes what a score is worth. A best set on an easier
## curve is not a target, it is a wall — the 1244 from the 0.008 appetite build
## was unreachable after the rebalance and would just read as broken.
const TUNING_VERSION := 2

# --- Tuning. Everything the balance depends on lives here. -------------------
const START_BUDGET := 5
const FUEL_CAP := 6.0

## Fuel per item by resource. A Forge burns two RAW (2.0 of fuel) into one
## REFINED (3.0), so refining is worth 1.5x — but it costs an extra vein and
## adds latency, which is the trade. The bigger prize is that it HALVES the item
## count carrying that fuel, so a Forge in front of a bursting trunk is the tool
## for congestion, not just a multiplier.
## VOID is negative fuel: a corrupted Well doesn't stop feeding you, it feeds you
## poison, down the vein you built and came to rely on. Cutting it costs the
## throughput you were depending on — which is the point.
const FUEL_BY_RES := {
	VNode.Res.RAW: 1.0,
	VNode.Res.REFINED: 3.0,
	VNode.Res.CLOTH: 7.0,
	VNode.Res.VOID: -2.5,
}

## Forges arrive once the Heart's appetite has outgrown raw supply.
const FIRST_FORGE_TIME := 55.0
const FORGE_GAP := 70.0

## Appetite grows LINEARLY, on the CLOCK. Both halves of that matter.
##
## Linear, because against an exponential curve doubling your supply only buys a
## fixed increment, so skill is nearly worthless: measured 1 Well -> 109 beats,
## 2 -> 211, 4 -> 254, 10 -> 266. Five times the supply bought 26% more score.
## Against a linear curve, survival time scales with supply, so ten Wells is
## worth roughly ten times one — which is where the doc's 10x expert gap lives.
##
## On the clock rather than per beat, because a starving Heart SLOWS (see
## Beat.RATE_BY_STATE). With beat-indexed escalation, dying slowed the very curve
## that was killing you — the run stabilised into an endless limp instead of
## dying. Time doesn't care that you are dying.
##
## The pairing is the design: escalation on time, score on beats. A healthy Heart
## races, so it scores faster AND survives; a dying one crawls, scores nothing,
## and the curve keeps coming.
## Bisected against the bot: 0.008 -> ~1060 beats (far too easy), 0.021 -> ~176
## and the skill gap collapses to 4x because escalation outruns budget growth
## before you can build anything. 0.016 flattens the spread to 190-216, which
## means the run is over-determined and your choices stopped mattering. 0.013
## keeps the bot near 400 beats with a healthy 228-649 spread.
const APPETITE_BASE := 0.35
const APPETITE_RATE := 0.013    # per second

## Seconds of exertion before the heart is fully racing.
const EXERTION_SPAN := 300.0

## Missed feedings before the beat stops for good.
const MISSES_STRAINED := 1
const MISSES_DYING := 3
const MISSES_FATAL := 6

# Spawns and budget are on the clock for the same reason as appetite.
const FIRST_WELL_TIME := 10.0
const WELL_GAP_START := 14.0
const WELL_GAP_DECAY := 0.8     # wells arrive faster and faster
const WELL_GAP_MIN := 8.0

const FIRST_BUDGET_TIME := 22.0
const BUDGET_GAP_START := 30.0
const BUDGET_GAP_GROWTH := 5.0  # ...while veins arrive slower and slower

const SNAP := 48.0             # magnetic radius; imprecise thumbs feel precise
const LONG_PRESS := 0.32
const DILATION := 0.3
const DRAG_SLOP := 12.0

# --- Scene ------------------------------------------------------------------
@onready var vein_layer: Node2D = $VeinLayer
@onready var node_layer: Node2D = $NodeLayer
@onready var drag_layer: Node2D = $DragLayer
@onready var drain: ColorRect = $Fx/Drain
@onready var death_ui: Control = $Ui/Death
@onready var score_label: Label = $Ui/Death/Score
@onready var best_label: Label = $Ui/Death/Best
@onready var budget_hint: Node2D = $BudgetHint
@onready var score_hud: Node2D = $ScoreHud

var rng := RandomNumberGenerator.new()
var seed_used := 0

var nodes: Array[VNode] = []
var veins: Array[Vein] = []
var heart: VNode

var budget := START_BUDGET
var fuel := FUEL_CAP
var misses := 0
var alive := false
## Mirrors Beat.index. The score, and what the harnesses read.
var beats := 0

## The number to beat. There is no winning in VEIN — every run ends — so the
## only thing that can pull a player back is their own last best.
var best := 0
var lifetime_beats := 0
var beat_best_this_run := false
## Ruptures this run. If this stays at zero, trunk capacity never binds and
## layout still does not matter — the probe watches it for exactly that reason.
var ruptures := 0
## Items destroyed on arrival at a node whose buffer was already full. Every one
## of these is pressure that vanished instead of backing up the network.
var dropped := 0
## VOID items that reached the Heart. If this is 0 across a run, the enemy never
## engaged and corruption is decorative.
var poisoned := 0
## Wells that ran dry and turned this run.
var corruptions := 0

## Seconds this run has been alive. The escalation clock — see APPETITE_RATE.
var run_time := 0.0
var _next_well_time := FIRST_WELL_TIME
var _next_forge_time := FIRST_FORGE_TIME
var _well_gap := WELL_GAP_START
var _next_budget_time := FIRST_BUDGET_TIME
var _budget_gap := BUDGET_GAP_START

var _drag_from: VNode = null
var _drag_pos := Vector2.ZERO
var _touch_start := Vector2.ZERO
var _touch_time := 0.0
var _touching := false
var _dilating := false
var _moved := false

var _rescue := 0.0
var _drain_amt := 0.0
## Time scale to restore when the panic-pinch ends. Captured on engage so the
## harnesses' scale survives.
var _pre_dilation_scale := 1.0


func _end_dilation() -> void:
	if not _dilating:
		return
	_dilating = false
	Engine.time_scale = _pre_dilation_scale


func _ready() -> void:
	drag_layer.draw.connect(_draw_drag)
	death_ui.hide()
	Beat.beat.connect(_on_beat)
	Beat.stopped.connect(_on_stopped)
	_load_save()
	start_run(0)
	_maybe_attach_harness()


func _load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	# Lifetime beats survive a rebalance; a best score does not.
	lifetime_beats = int(cfg.get_value("run", "lifetime", 0))
	if int(cfg.get_value("run", "tuning", 0)) == TUNING_VERSION:
		best = int(cfg.get_value("run", "best", 0))


func _store_save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("run", "best", best)
	cfg.set_value("run", "lifetime", lifetime_beats)
	cfg.set_value("run", "tuning", TUNING_VERSION)
	cfg.save(SAVE_PATH)


## Dev harnesses, driven off the command line so they run inside a normal project
## launch — autoload singletons like Beat do not resolve as globals under a
## `--script` main loop, which is why these are attached rather than standalone.
##
##   --probe=N [--speed=X]        headless balance run
##   --shot=PATH [--after=S] [--speed=X]   render a frame (needs a window)
##
## Loaded dynamically so an exported build without tests/ still runs.
func _maybe_attach_harness() -> void:
	var probe_runs := 0
	var shot_path := ""
	var speed := 0.0
	var after := 20.0
	var cap := 0

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--probe"):
			probe_runs = int(a.get_slice("=", 1)) if a.contains("=") else 5
		elif a.begins_with("--shot="):
			shot_path = a.get_slice("=", 1)
		elif a.begins_with("--cap="):
			cap = int(a.get_slice("=", 1))
		elif a.begins_with("--speed="):
			speed = float(a.get_slice("=", 1))
		elif a.begins_with("--after="):
			after = float(a.get_slice("=", 1))

	if probe_runs > 0:
		var p: Node = _load_harness("res://tests/probe.gd")
		if p == null:
			return
		p.runs = probe_runs
		p.speed = speed if speed > 0.0 else 60.0
		p.cap = cap
		add_child(p)
	elif "--audiocheck" in OS.get_cmdline_user_args():
		var a: Node = _load_harness("res://tests/audiocheck.gd")
		if a != null:
			add_child(a)
	elif shot_path != "":
		var s: Node = _load_harness("res://tests/shot.gd")
		if s == null:
			return
		s.out_path = shot_path
		s.after = after
		s.speed = speed if speed > 0.0 else 3.0
		add_child(s)


func _load_harness(path: String) -> Node:
	if not ResourceLoader.exists(path):
		push_error("harness missing: %s" % path)
		return null
	var script: Script = load(path)
	return null if script == null else script.new()


# --- Run lifecycle ----------------------------------------------------------

func start_run(run_seed: int) -> void:
	Audio.start()
	for n in nodes:
		n.queue_free()
	for v in veins:
		v.queue_free()
	nodes.clear()
	veins.clear()

	seed_used = run_seed if run_seed != 0 else randi()
	rng.seed = seed_used

	budget = START_BUDGET
	fuel = FUEL_CAP
	misses = 0
	beats = 0
	ruptures = 0
	dropped = 0
	poisoned = 0
	corruptions = 0
	_rescue = 0.0
	_drain_amt = 0.0
	run_time = 0.0
	_next_well_time = FIRST_WELL_TIME
	_next_forge_time = FIRST_FORGE_TIME
	_well_gap = WELL_GAP_START
	_next_budget_time = FIRST_BUDGET_TIME
	_budget_gap = BUDGET_GAP_START

	var vp := design_size()
	heart = _make_node(VNode.Kind.HEART, Vector2(vp.x * 0.5, vp.y * 0.44))

	# Two wells to open with, placed relative to the Heart and inside its reach:
	# the first connection must be obvious, so the player learns the verb by
	# doing it rather than being told. Anchoring these to the viewport corners
	# instead would put them out of reach and open the run already lost.
	# One above, one below. New Wells only spawn within reach of an existing node,
	# so the network grows outward from these two — seeding both below the Heart
	# meant it could only ever creep downward and the top third of the screen
	# stayed empty for the whole run.
	_make_node(VNode.Kind.WELL, heart.position + Vector2(-142, -118))
	_make_node(VNode.Kind.WELL, heart.position + Vector2(146, 122))

	death_ui.hide()
	alive = true
	Beat.reset()
	_rebuild_graph()


## The playfield, in design space — NOT get_viewport_rect().
##
## One screen is the whole world (no pan, no zoom), and the stretch mode maps
## this rect onto whatever the device is. Reading the live viewport instead
## breaks the sim wherever the window is not 540x1170: headless reports a square
## 1170x1170, which pushed every Well past Vein.MAX_LEN and quietly made the
## probe unwinnable. Layout must not depend on the window, or the seed no longer
## determines the run.
func design_size() -> Vector2:
	return Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 540)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 1170)),
	)


func _make_node(kind: int, pos: Vector2) -> VNode:
	var n: VNode = VNodeScene.new()
	n.kind = kind
	n.position = pos
	n.produces = VNode.Res.REFINED if kind == VNode.Kind.FORGE else VNode.Res.RAW
	node_layer.add_child(n)
	nodes.append(n)
	return n


func _on_stopped(total: int) -> void:
	alive = false
	Audio.stop_all()
	# The run can die mid panic-pinch; never leave the world dilated. Only undo
	# our own dilation — blindly writing 1.0 here would stomp the time scale the
	# dev harnesses set, which silently dropped the probe back to real time.
	_end_dilation()

	lifetime_beats += total
	beat_best_this_run = total > best
	if beat_best_this_run:
		best = total
	_store_save()

	score_label.text = "Your heart beat %s times." % _commas(total)
	# The target. Without something to beat, "one more run" has no hook — and
	# VEIN has no win state to offer instead.
	if beat_best_this_run:
		best_label.text = "Your best yet."
	else:
		best_label.text = "Best  %s" % _commas(best)
	death_ui.show()


func _commas(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


# --- The beat: consumption, escalation, death -------------------------------

func _on_beat(index: int) -> void:
	beats = index
	if not alive:
		return

	fuel -= appetite()
	if fuel < 0.0:
		fuel = 0.0
		misses += 1
	elif misses > 0:
		misses -= 1

	if misses >= MISSES_FATAL:
		Beat.stop()
		return
	elif misses >= MISSES_DYING:
		Beat.set_state(Beat.State.DYING)
	elif misses >= MISSES_STRAINED:
		Beat.set_state(Beat.State.STRAINED)
	else:
		Beat.set_state(Beat.State.HEALTHY)

	Beat.set_exertion(run_time / EXERTION_SPAN)
	# The bed escalates on the same clock as the appetite that is killing you.
	Audio.set_intensity(run_time / EXERTION_SPAN)


## Fuel the Heart burns per beat, rising linearly on the run clock.
func appetite() -> float:
	return APPETITE_BASE + APPETITE_RATE * run_time


## Drives the spawn and budget clocks. Kept out of _on_beat so a slowing Heart
## cannot slow its own escalation.
func _tick_escalation(delta: float) -> void:
	run_time += delta

	if run_time >= _next_well_time:
		_spawn_well()
		_next_well_time += _well_gap
		_well_gap = maxf(WELL_GAP_MIN, _well_gap - WELL_GAP_DECAY)

	if run_time >= _next_forge_time:
		_spawn_node(VNode.Kind.FORGE)
		_next_forge_time += FORGE_GAP

	if run_time >= _next_budget_time:
		budget += 1
		_next_budget_time += _budget_gap
		_budget_gap += BUDGET_GAP_GROWTH
		budget_hint.queue_redraw()


func _spawn_well() -> void:
	_spawn_node(VNode.Kind.WELL)


## New nodes spawn in awkward places, forcing rerouting. Bias to the lower two
## thirds so everything stays in one-thumb reach.
##
## A Forge is placed by the opposite rule to a Well: it wants to sit CLOSE to the
## Heart, because its job is to stand between a cluster of Wells and the trunk
## they overload. Spawning it out at the rim like a Well would make it unroutable
## and it would never be worth the veins.
func _spawn_node(kind: int) -> void:
	var vp := design_size()
	var best := Vector2.ZERO
	var best_score := -INF

	for _i in 48:
		var p := Vector2(
			rng.randf_range(56.0, vp.x - 56.0),
			# Squaring the roll pulls the distribution downward.
			lerpf(vp.y * 0.14, vp.y * 0.93, sqrt(rng.randf()))
		)
		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near < 104.0:
			continue
		# Must be joinable to *something*, or it is scenery rather than a choice.
		if near > Vein.MAX_LEN * 0.92:
			continue
		var to_heart := p.distance_to(heart.position)
		var s := 0.0
		if kind == VNode.Kind.FORGE:
			s = -to_heart
		else:
			# Prefer awkward: far from the heart, but not hugging another node.
			s = to_heart * 0.6 + near * 0.4
		if s > best_score:
			best_score = s
			best = p

	if best_score == -INF:
		return
	_make_node(kind, best)
	_rebuild_graph()


# --- Graph: everything flows downhill toward demand -------------------------

func _rebuild_graph() -> void:
	for n in nodes:
		n.depth = -1
	if heart == null:
		return
	heart.depth = 0
	var q: Array[VNode] = [heart]
	while not q.is_empty():
		var cur: VNode = q.pop_front()
		for v in veins:
			var o := v.other(cur)
			if o != null and o.depth < 0:
				o.depth = cur.depth + 1
				q.append(o)
	for v in veins:
		v.update_dir()
	budget_hint.queue_redraw()


func veins_used() -> int:
	return veins.size()


func can_afford() -> bool:
	return veins_used() < budget


func _find_vein(a: VNode, b: VNode) -> Vein:
	for v in veins:
		if (v.a == a and v.b == b) or (v.a == b and v.b == a):
			return v
	return null


## Can these two ever be joined directly? Reach is the constraint the whole
## puzzle rests on — see Vein.MAX_LEN.
func in_reach(a: VNode, b: VNode) -> bool:
	return a.position.distance_to(b.position) <= Vein.MAX_LEN


func _add_vein(a: VNode, b: VNode) -> void:
	if a == b or not can_afford() or _find_vein(a, b) != null or not in_reach(a, b):
		return
	var v: Vein = VeinScene.new()
	# Alternate the bend so parallel veins fan out instead of overlapping.
	v.setup(a, b, 1.0 if veins.size() % 2 == 0 else -1.0)
	v.ruptured.connect(_on_ruptured)
	vein_layer.add_child(v)
	veins.append(v)
	_rebuild_graph()


## A trunk carried more than it could bear. The dots in flight scatter and die,
## the vein is destroyed, and the budget point comes back — so a rupture is a
## loss of throughput and position, never of resources you can't rebuild.
func _on_ruptured(v: Vein) -> void:
	ruptures += 1
	var pts: Array[Vector2] = []
	var kinds: Array[int] = []
	for d in v.dots:
		pts.append(v.sample(d.t))
		kinds.append(d.kind)

	if not pts.is_empty():
		var burst: Node2D = BurstScene.new()
		vein_layer.add_child(burst)
		burst.spawn(pts, kinds, rng.randi())

	Audio.play("rupture", -3.0, randf_range(0.9, 1.1))
	if OS.has_feature("mobile"):
		Input.vibrate_handheld(180)

	_remove_vein(v)


func _remove_vein(v: Vein) -> void:
	veins.erase(v)
	v.queue_free()
	_rebuild_graph()


# --- Sim --------------------------------------------------------------------

func _process(delta: float) -> void:
	_rescue = maxf(0.0, _rescue - delta * 2.2)

	var target_drain := 0.0
	if not alive:
		target_drain = 1.0
	elif Beat.state == Beat.State.DYING:
		target_drain = 0.55
	elif Beat.state == Beat.State.STRAINED:
		target_drain = 0.2
	_drain_amt = Vein._smooth(_drain_amt, target_drain, 1.6, delta)
	drain.material.set_shader_parameter("drain", _drain_amt)
	drain.material.set_shader_parameter("warm", _rescue)

	if _touching and not _moved and not _dilating:
		_touch_time += delta
		if _touch_time >= LONG_PRESS and _drag_from == null:
			_dilating = true
			_pre_dilation_scale = Engine.time_scale
			Engine.time_scale = _pre_dilation_scale * DILATION

	if not alive:
		return

	_tick_escalation(delta)
	_tick_corruption(delta)
	heart.fuel_ratio = fuel / FUEL_CAP
	_push_from_nodes()
	for v in veins:
		for kind in v.advance(delta):
			_deliver(kind, v.sink())

	budget_hint.queue_redraw()
	drag_layer.queue_redraw()


## Rot spreads down live veins. Leaving a necrotic Well wired in doesn't just
## poison the Heart — it takes the neighbours with it, so the punishment for
## ignoring one dead lifeline is losing that whole limb of your network.
func _tick_corruption(delta: float) -> void:
	var newly: Array[VNode] = []
	for n in nodes:
		if not n.corrupted:
			continue
		n.spread_accum += delta
		if n.spread_accum < VNode.SPREAD_TIME:
			continue
		n.spread_accum = 0.0
		for v in veins:
			var o := v.other(n)
			if o != null and not o.corrupted and o.kind == VNode.Kind.WELL:
				newly.append(o)

	for n in newly:
		n.corrupt()
		corruptions += 1
		Audio.play("corrupt", -4.0, 0.62)
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(140)


## Every node with something buffered tries to hand it downhill.
func _push_from_nodes() -> void:
	for n in nodes:
		if n.kind == VNode.Kind.HEART or n.buffer.is_empty():
			continue
		var outs: Array[Vein] = []
		for v in veins:
			if v.source() == n:
				outs.append(v)
		if outs.is_empty():
			continue

		# Sample the backlog BEFORE pushing: the push below removes an item, so
		# checking afterwards always reads one short of full and never trips.
		var was_full := n.buffer.size() >= VNode.BUFFER_CAP

		# Round-robin so a node with two downhill veins splits between them, but
		# fall through to the others rather than stalling on a full one.
		var placed := false
		var start := n.next_out(outs.size())
		for i in outs.size():
			var v: Vein = outs[(start + i) % outs.size()]
			if v.inject(n.buffer[0]):
				n.buffer.remove_at(0)
				n.pulse = 1.0
				placed = true
				break

		# Strain is "this node cannot clear its backlog through these veins", not
		# "nothing moved this frame". A node pushes at most one item per frame but
		# can receive several from its children in the same frame, so it sits
		# permanently full — dropping the excess — while still placing one item
		# every frame. Keying off `placed` alone therefore reported healthy veins
		# right up until the run starved.
		# Only a genuinely full backlog counts as strain. A failed push on its own
		# does not: items must sit DOT_SPACING apart, so every vein refuses on
		# most frames simply waiting for the gap to open, and treating that as
		# blockage ruptured healthy direct links carrying a quarter of capacity.
		if was_full:
			for v in outs:
				v.note_blocked()


func _deliver(kind: int, to: VNode) -> void:
	if to == null:
		return
	if to.kind == VNode.Kind.HEART:
		# Near-miss engineering: a save when the heart is nearly gone must feel
		# enormous.
		if misses >= MISSES_DYING:
			_rescue = 1.0
			if OS.has_feature("mobile"):
				Input.vibrate_handheld(120)
		fuel = clampf(fuel + float(FUEL_BY_RES.get(kind, 1.0)), 0.0, FUEL_CAP)
		to.pulse = 1.0
		Audio.swallow(kind, fuel / FUEL_CAP)
		if kind == VNode.Res.VOID:
			poisoned += 1
			if OS.has_feature("mobile"):
				Input.vibrate_handheld(90)
	elif not to.take(kind):
		dropped += 1


# --- Input: one thumb, one verb ---------------------------------------------

func _node_at(p: Vector2) -> VNode:
	var best: VNode = null
	var best_d := SNAP
	for n in nodes:
		var d := p.distance_to(n.position)
		if d <= maxf(best_d, n.radius()):
			best_d = d
			best = n
	return best


func _vein_at(p: Vector2) -> Vein:
	var best: Vein = null
	var best_d := Vein.HIT_RADIUS
	for v in veins:
		var d := v.distance_to_point(p)
		if d < best_d:
			best_d = d
			best = v
	return best


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_on_press(event.position)
		else:
			_on_release(event.position)
	elif event is InputEventScreenDrag:
		_on_move(event.position)


func _on_press(p: Vector2) -> void:
	if not alive:
		start_run(0)
		return
	_touching = true
	_touch_time = 0.0
	_moved = false
	_touch_start = p
	_drag_pos = p
	_drag_from = _node_at(p)


func _on_move(p: Vector2) -> void:
	_drag_pos = p
	if p.distance_to(_touch_start) > DRAG_SLOP:
		_moved = true


func _on_release(p: Vector2) -> void:
	_touching = false
	if _dilating:
		_end_dilation()
		_drag_from = null
		return

	if _drag_from != null:
		var to := _node_at(p)
		if to != null and to != _drag_from:
			_add_vein(_drag_from, to)
		_drag_from = null
		return

	if not _moved:
		var v := _vein_at(p)
		if v != null:
			_remove_vein(v)


## The provisional vein under the thumb, plus a highlight on whatever it would
## snap to. This is the only affordance the game ever shows.
func _draw_drag() -> void:
	if _drag_from == null or not alive:
		return

	# How far this node can reach. Only shown while dragging — the constraint
	# appears exactly when it is the question being asked, and never otherwise.
	var reach := Palette.HEART
	reach.a = 0.10
	drag_layer.draw_arc(_drag_from.position, Vein.MAX_LEN, 0.0, TAU, 64, reach, 1.5, true)

	var to := _node_at(_drag_pos)
	var end := _drag_pos if to == null else to.position
	var stretched := _drag_from.position.distance_to(end) > Vein.MAX_LEN

	var col := Palette.VEIN_STRAINED if stretched else Palette.VEIN_LIVE
	col.a = 0.75
	drag_layer.draw_line(_drag_from.position, end, col, 3.0, true)

	if to == null:
		return
	var ok := to != _drag_from and can_afford() and _find_vein(_drag_from, to) == null \
		and in_reach(_drag_from, to)
	var ring := Palette.WARM if ok else Palette.VEIN_STRAINED
	ring.a = 0.85
	drag_layer.draw_arc(to.position, to.radius() + 8.0, 0.0, TAU, 28, ring, 2.0, true)
