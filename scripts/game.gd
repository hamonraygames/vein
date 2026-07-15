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

# --- Tuning. Everything the balance depends on lives here. -------------------
const START_BUDGET := 5
const FUEL_CAP := 6.0
const FUEL_PER_ITEM := 1.0

## Appetite grows on a smooth exponential. Lower tau = crueller run.
const APPETITE_BASE := 0.5
const APPETITE_TAU := 420.0

## Beats of exertion before the heart is fully racing.
const EXERTION_SPAN := 800.0

## Missed feedings before the beat stops for good.
const MISSES_STRAINED := 1
const MISSES_DYING := 3
const MISSES_FATAL := 6

const FIRST_WELL_BEAT := 40
const WELL_GAP_START := 58.0
const WELL_GAP_DECAY := 3.0    # wells arrive faster and faster
const WELL_GAP_MIN := 34.0

const FIRST_BUDGET_BEAT := 100
const BUDGET_GAP_START := 130.0
const BUDGET_GAP_GROWTH := 20.0  # ...while veins arrive slower and slower

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
@onready var budget_hint: Node2D = $BudgetHint

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

var _next_well_beat := FIRST_WELL_BEAT
var _well_gap := WELL_GAP_START
var _next_budget_beat := FIRST_BUDGET_BEAT
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
	start_run(0)
	_maybe_attach_harness()


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

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--probe"):
			probe_runs = int(a.get_slice("=", 1)) if a.contains("=") else 5
		elif a.begins_with("--shot="):
			shot_path = a.get_slice("=", 1)
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
		add_child(p)
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
	_rescue = 0.0
	_drain_amt = 0.0
	_next_well_beat = FIRST_WELL_BEAT
	_well_gap = WELL_GAP_START
	_next_budget_beat = FIRST_BUDGET_BEAT
	_budget_gap = BUDGET_GAP_START

	var vp := get_viewport_rect().size
	heart = _make_node(VNode.Kind.HEART, Vector2(vp.x * 0.5, vp.y * 0.44))

	# Two wells to open with. Close enough that the first connection is obvious
	# and the player learns the verb without being told it.
	_make_node(VNode.Kind.WELL, Vector2(vp.x * 0.20, vp.y * 0.70))
	_make_node(VNode.Kind.WELL, Vector2(vp.x * 0.80, vp.y * 0.64))

	death_ui.hide()
	alive = true
	Beat.reset()
	_rebuild_graph()


func _make_node(kind: int, pos: Vector2) -> VNode:
	var n: VNode = VNodeScene.new()
	n.kind = kind
	n.position = pos
	n.produces = VNode.Res.RAW
	node_layer.add_child(n)
	nodes.append(n)
	return n


func _on_stopped(total: int) -> void:
	alive = false
	# The run can die mid panic-pinch; never leave the world dilated. Only undo
	# our own dilation — blindly writing 1.0 here would stomp the time scale the
	# dev harnesses set, which silently dropped the probe back to real time.
	_end_dilation()
	score_label.text = "Your heart beat %s times." % _commas(total)
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

	fuel -= appetite(index)
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

	Beat.set_exertion(float(index) / EXERTION_SPAN)

	if index >= _next_well_beat:
		_spawn_well()
		_next_well_beat += int(_well_gap)
		_well_gap = maxf(WELL_GAP_MIN, _well_gap - WELL_GAP_DECAY)

	if index >= _next_budget_beat:
		budget += 1
		_next_budget_beat += int(_budget_gap)
		_budget_gap += BUDGET_GAP_GROWTH
		budget_hint.queue_redraw()


func appetite(index: int) -> float:
	return APPETITE_BASE * exp(float(index) / APPETITE_TAU)


## New Wells spawn in awkward places, forcing rerouting. Bias to the lower two
## thirds so everything stays in one-thumb reach.
func _spawn_well() -> void:
	var vp := get_viewport_rect().size
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
		# Prefer awkward: far from the heart, but not hugging another node.
		var s := p.distance_to(heart.position) * 0.6 + near * 0.4
		if s > best_score:
			best_score = s
			best = p

	if best_score == -INF:
		return
	_make_node(VNode.Kind.WELL, best)
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


func _add_vein(a: VNode, b: VNode) -> void:
	if a == b or not can_afford() or _find_vein(a, b) != null:
		return
	var v: Vein = VeinScene.new()
	# Alternate the bend so parallel veins fan out instead of overlapping.
	v.setup(a, b, 1.0 if veins.size() % 2 == 0 else -1.0)
	vein_layer.add_child(v)
	veins.append(v)
	_rebuild_graph()


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

	_push_from_nodes()
	for v in veins:
		for kind in v.advance(delta):
			_deliver(kind, v.sink())

	budget_hint.queue_redraw()
	drag_layer.queue_redraw()


## Every node with something buffered tries to hand it downhill.
func _push_from_nodes() -> void:
	for n in nodes:
		if n.kind == VNode.Kind.HEART or n.buffer.is_empty():
			continue
		var outs: Array[Vein] = []
		for v in veins:
			if v.source() == n and v.has_room():
				outs.append(v)
		if outs.is_empty():
			continue
		var pick := outs[n.next_out(outs.size())]
		if pick.inject(n.buffer[0]):
			n.buffer.remove_at(0)
			n.pulse = 1.0


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
		fuel = minf(FUEL_CAP, fuel + FUEL_PER_ITEM)
		to.pulse = 1.0
	else:
		if not to.take(kind):
			# Nowhere to put it. Weekend 2 turns this into a rupture; for now the
			# item is simply lost and the pips upstream stack visibly.
			pass


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
	var to := _node_at(_drag_pos)
	var end := _drag_pos if to == null else to.position
	var col := Palette.VEIN_LIVE
	col.a = 0.75
	drag_layer.draw_line(_drag_from.position, end, col, 3.0, true)

	var ok := to != null and to != _drag_from and can_afford() and _find_vein(_drag_from, to) == null
	if to != null:
		var ring := Palette.WARM if ok else Palette.VEIN_LIVE
		ring.a = 0.8
		drag_layer.draw_arc(to.position, to.radius() + 8.0, 0.0, TAU, 28, ring, 2.0, true)
