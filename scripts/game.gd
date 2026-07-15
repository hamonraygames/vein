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
const TUNING_VERSION := 3

# --- Tuning. Everything the balance depends on lives here. -------------------
const START_BUDGET := 4
const FUEL_CAP := 5.0

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

## A sloppy redraw is surgery while the body is awake. Cutting a live vein spills
## whatever was in flight and costs Heart fuel immediately. Rot is the exception:
## amputating poison is already punishment enough because it costs throughput.
const CUT_BLEED_BY_DOT := 0.35

## Tools arrive before the Heart asks for them. Seeing the piece first makes the
## demand flip feel like a test, not a hidden rule.
const FIRST_FORGE_TIME := 10.0
const FORGE_GAP := 21.0
const FIRST_LOOM_TIME := 29.0
const LOOM_GAP := 36.0

## What the Heart DEMANDS, by run-second. This is the game.
##
## The Forge was built as an optional fuel multiplier — an abstract 1.5x you
## cannot see — and playtest was blunt: "the red triangle is not understandable
## even to me." Correct, because an optional thing explains nothing. The doc
## always said it: "the Heart starts demanding refined shapes, not raw ones."
##
## Now the Heart wants ONE shape at a time and shows you which. Off-demand items
## are near-worthless (WRONG_SHAPE_FUEL), so when it flips to triangles your
## entire circle network is suddenly feeding it garbage and you must re-plumb
## every Well through a Forge, against the budget, against reach, while it
## starves. That is the strategy that was missing: the board you built is
## invalidated on a clock, and the whole run is about restructuring under fire.
##
## It also makes the Forge self-teaching — the Heart is visibly asking for a
## triangle, and only the triangle node makes triangles.
const DEMAND_TIERS := [
	{"at": 0.0, "res": VNode.Res.RAW},
	{"at": 14.0, "res": VNode.Res.REFINED},
	{"at": 37.0, "res": VNode.Res.CLOTH},
]

## Feeding the Heart something it did not ask for. This is not "less efficient";
## it is wrong blood. The triangle/square demand must be a survival gate, not a
## suggestion a careless player can ignore.
const WRONG_SHAPE_FUEL := -0.85

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
## The slap in the face is START_FUEL, not APPETITE_BASE.
##
## Raising BASE to 0.9 did open hard — and collapsed the skill gap to ~1.1x
## (2 Wells died at 137, the bot managed 146). A steep floor kills everyone
## early, so extra supply buys nothing and mastery stops paying. Same failure as
## the old exponential curve, wearing a different hat.
##
## Elden Ring doesn't raise the floor for the whole game; it demands you play
## correctly IMMEDIATELY and then pays mastery for hours. So the Heart now OPENS
## nearly empty: connect both Wells in the first seconds or die, no grace period,
## nothing explained. That is a slap skill can answer, and it leaves the curve's
## headroom intact.
const START_FUEL := 0.95
const APPETITE_BASE := 0.50
const APPETITE_RATE := 0.024    # per second

## Seconds of exertion before the heart is fully racing.
const EXERTION_SPAN := 150.0

## Missed feedings before the beat stops for good.
const MISSES_STRAINED := 1
const MISSES_DYING := 3
const MISSES_FATAL := 6

## Hard cap on live Wells. Playtest: "the circles grow and grow" — the board
## only ever accumulated. Wither alone can't hold the line, because it only
## catches Wells that are ORPHANED, and doubling the spawn rate doubled the
## inflow. Past this cap, a new Well displaces the most-neglected existing one
## (the oldest orphan) rather than piling on: the board churns instead of
## silting up, and the screen stays readable at phone size. Connected Wells are
## never displaced — you never lose something you were actually using.
const MAX_LIVE_WELLS := 14

# Spawns and budget are on the clock for the same reason as appetite.
const FIRST_WELL_TIME := 3.0
const WELL_GAP_START := 5.5
const WELL_GAP_DECAY := 0.45     # wells arrive faster and faster
const WELL_GAP_MIN := 3.25

const FIRST_BUDGET_TIME := 8.0
const BUDGET_GAP_START := 12.0
const BUDGET_GAP_GROWTH := 3.5  # ...while veins arrive slower and slower

## Boosts — the "build your own strategy" lever. A rare, self-consuming pickup:
## connecting ANY vein to one triggers it immediately, no new verb, no waiting
## for a dot to arrive. It grants one random effect and both the node and the
## vein that reached it vanish (refunded — a Boost never costs a permanent slot).
## This is a real branch, not a freebie: every second spent detouring toward one
## is a second not spent re-plumbing for the next demand flip.
## Playtest: "no boosts, combos, crazy features" — they existed, but at 24s/46s
## a run barely contained one, and after halving the escalation clock it would
## have contained none. A mechanic the player never sees may as well not be
## implemented. Frequent enough that a Boost is a recurring decision ("detour
## for it, or hold the line?") rather than a once-a-run curiosity.
const FIRST_BOOST_TIME := 7.0
const BOOST_GAP := 14.0

enum BoostFx { SURGE, EASE, CLEANSE }
## Weighted so CLEANSE never wastes itself as a no-op reroll when nothing is
## corrupted — see _roll_boost.
const BOOST_WEIGHTS := [0.4, 0.35, 0.25]

const BOOST_SURGE_BUDGET := 1
## Halved with everything else on the escalation clock — a 9s freeze against a
## 150s span would be twice the reprieve it used to be.
const BOOST_EASE_TIME := 4.5

## Rot that is never cut does not get to sit there forever as free clutter,
## poisoning at your leisure — it collapses outright, taking the asset with it.
## This is what makes the board turn over instead of only ever accumulating.
## The fade-warning threshold lives on VNode.COLLAPSE_FADE_AT, next to the
## corrupt_age it reads.

## Corruption gets meaner as the run does — this is the second half of "the
## enemy gets worse", on top of the fixed per-Well depletion. Both the vein-borne
## spread AND a new airborne jump (corruption leaping to an unconnected Well
## with no vein at all — a roaming blight, not just a plumbing hazard) scale in
## with intensity, gated to the back half of the run so the opening stays
## learnable and the mid-late game is where it goes feral.
const SPREAD_TIME_LATE := 5.0     ## VNode.SPREAD_TIME at intensity 1.0
const AIRBORNE_AT := 0.42         ## intensity floor before blight can jump gaps
const AIRBORNE_RADIUS := 190.0
const AIRBORNE_CHANCE := 0.35     ## per spread-tick, once AIRBORNE_AT is crossed

## Veins cannot cross — this is the spatial skill check: spaghetti is not a
## strategy. A bad draw is simply REFUSED (see _add_vein), not punished; it used
## to bleed fuel and destroy the crossed vein instead, which silently ate the
## Heart's most-needed rescue connection right where veins most converge.
const OFFBEAT_BLEED := 0.45
const SYNC_FUEL := 0.18
const PERFECT_WINDOW := 0.11
const GOOD_WINDOW := 0.22
const COMBO_GAIN := 0.07
const COMBO_CAP := 10

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
var fuel := START_FUEL
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
## Wells withered from neglect, and rot collapsed outright. Both remove the
## node itself, so `nodes` undercounts everything that ever appeared once
## either of these fires — these are the cumulative truth the probe reads
## instead.
var withered := 0
var collapsed := 0
## Every node ever created, by kind — `nodes.size()` alone undercounts once
## withering/collapse can remove them mid-run.
var spawned_wells := 0
## Items the Heart accepted but did not want. High counts mean the player (or
## bot) failed to re-plumb after a demand flip.
var wasted := 0
## Consecutive edits made on the heartbeat. This is the mastery layer: elite
## play is not just topology, it is surgery in rhythm.
var combo := 0

## The shape the Heart wants right now. Drawn inside it — see VNode._draw_hex.
var demand: int = VNode.Res.RAW

## Seconds this run has been alive. The escalation clock — see APPETITE_RATE.
var run_time := 0.0
var _next_well_time := FIRST_WELL_TIME
var _next_forge_time := FIRST_FORGE_TIME
var _next_loom_time := FIRST_LOOM_TIME
var _next_boost_time := FIRST_BOOST_TIME
var _well_gap := WELL_GAP_START
var _next_budget_time := FIRST_BUDGET_TIME
var _budget_gap := BUDGET_GAP_START

## Seconds left of an EASE boost. While positive, run_time keeps advancing (the
## clock, spawns, tempo, and mix all keep escalating) but the separate
## `_appetite_clock` does not — so EASE is a fuel-economy reprieve, not a pause,
## and does not trivialise a boosted run.
var _ease_remaining := 0.0
var _appetite_clock := 0.0
## Boosts collected this run, and which effect fired — useful for the probe to
## confirm they are actually being reached rather than sitting decorative.
var boosts_taken := 0

var _drag_from: VNode = null
var _drag_pos := Vector2.ZERO
var _touch_start := Vector2.ZERO
var _touch_time := 0.0
var _touching := false
var _dilating := false
var _moved := false

var _rescue := 0.0
var _drain_amt := 0.0
var _sync_flash := 0.0
var _bad_tempo_flash := 0.0
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
	fuel = START_FUEL
	misses = 0
	beats = 0
	ruptures = 0
	dropped = 0
	withered = 0
	collapsed = 0
	spawned_wells = 0
	poisoned = 0
	corruptions = 0
	wasted = 0
	combo = 0
	demand = VNode.Res.RAW
	_rescue = 0.0
	_drain_amt = 0.0
	_sync_flash = 0.0
	_bad_tempo_flash = 0.0
	_ease_remaining = 0.0
	_appetite_clock = 0.0
	boosts_taken = 0
	run_time = 0.0
	_next_well_time = FIRST_WELL_TIME
	_next_forge_time = FIRST_FORGE_TIME
	_next_loom_time = FIRST_LOOM_TIME
	_next_boost_time = FIRST_BOOST_TIME
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
	if kind == VNode.Kind.WELL:
		spawned_wells += 1
	match kind:
		VNode.Kind.FORGE:
			n.produces = VNode.Res.REFINED
		VNode.Kind.LOOM:
			n.produces = VNode.Res.CLOTH
		_:
			n.produces = VNode.Res.RAW
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

	Beat.set_exertion(intensity())


## 0..1, how far into the escalation curve this run is. The single number
## everything downstream — exertion, the mix, corruption speed, particle
## violence — reads to know how crazy things should be right now.
func intensity() -> float:
	return clampf(run_time / EXERTION_SPAN, 0.0, 1.0)


## Fuel the Heart burns per beat, rising linearly on the run clock — except
## while an EASE boost is active, when it rises on `_appetite_clock` instead,
## which simply stops advancing for BOOST_EASE_TIME seconds.
func appetite() -> float:
	return APPETITE_BASE + APPETITE_RATE * _appetite_clock


## Drives the spawn and budget clocks. Kept out of _on_beat so a slowing Heart
## cannot slow its own escalation.
func _tick_escalation(delta: float) -> void:
	run_time += delta

	if _ease_remaining > 0.0:
		_ease_remaining = maxf(0.0, _ease_remaining - delta)
	else:
		_appetite_clock += delta

	var want: int = demand
	for t in DEMAND_TIERS:
		if run_time >= t.at:
			want = t.res
	if want != demand:
		demand = want
		heart.demand = want
		# The Heart changing its mind is the loudest event in the run: everything
		# you built is now feeding it the wrong thing.
		heart.pulse = 1.0
		Audio.play("corrupt", -6.0, 1.5)
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(220)

	if run_time >= _next_well_time:
		_spawn_well()
		_next_well_time += _well_gap
		_well_gap = maxf(WELL_GAP_MIN, _well_gap - WELL_GAP_DECAY)

	if run_time >= _next_forge_time:
		_spawn_node(VNode.Kind.FORGE)
		_next_forge_time += FORGE_GAP

	if run_time >= _next_loom_time:
		_spawn_node(VNode.Kind.LOOM)
		_next_loom_time += LOOM_GAP

	if run_time >= _next_boost_time:
		_spawn_node(VNode.Kind.BOOST)
		_next_boost_time += BOOST_GAP

	if run_time >= _next_budget_time:
		budget += 1
		_next_budget_time += _budget_gap
		_budget_gap += BUDGET_GAP_GROWTH
		budget_hint.queue_redraw()


## New Wells displace the most-neglected old one once the board is full, so the
## count stays flat and readable instead of climbing all run. Only orphans are
## ever displaced — a Well you actually wired in is safe.
func _spawn_well() -> void:
	var live: Array[VNode] = []
	for n in nodes:
		if n.kind == VNode.Kind.WELL and not n.corrupted:
			live.append(n)

	if live.size() >= MAX_LIVE_WELLS:
		var oldest: VNode = null
		for n in live:
			if n.depth >= 0:
				continue
			if oldest == null or n.orphan_age > oldest.orphan_age:
				oldest = n
		# Everything is connected and we're at cap: the player has earned a full
		# board, so skip this spawn rather than deleting something in use.
		if oldest == null:
			return
		withered += 1
		_remove_node(oldest)

	_spawn_node(VNode.Kind.WELL)


## New nodes spawn in awkward places, forcing rerouting. Bias to the lower two
## thirds so everything stays in one-thumb reach.
##
## A tool is placed by the opposite rule to a Well: it wants to sit CLOSE to the
## Heart, because its job is to stand between a cluster of Wells and the trunk
## they overload. Spawning it out at the rim like a Well would make it
## unroutable and it would never be worth the veins.
func _spawn_node(kind: int) -> void:
	var vp := design_size()
	var best := Vector2.ZERO
	var best_score := -INF

	# Grow OUTWARD from a node already on the board, at a uniformly random angle.
	#
	# Playtest: "the circles mostly spawn at the bottom." Two biases were stacked
	# and compounded: sqrt(randf()) pulled the y-roll downward, AND the score
	# rewarded distance from the Heart — which sits at 44% height, so the bottom
	# edge (573px away) beat the top (351px) every single time. Rejection
	# sampling over the whole rect also wasted most candidates, since anything
	# beyond MAX_LEN of everything is unjoinable. Seeding from an existing node
	# at a random bearing fills the board evenly and every candidate is reachable
	# by construction.
	for _i in 64:
		var anchor: VNode = nodes[rng.randi() % nodes.size()]
		var bearing := rng.randf() * TAU
		var dist := rng.randf_range(112.0, Vein.MAX_LEN * 0.9)
		var p := anchor.position + Vector2(cos(bearing), sin(bearing)) * dist
		if p.x < 56.0 or p.x > vp.x - 56.0 or p.y < 70.0 or p.y > vp.y - 70.0:
			continue

		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near < 104.0:
			continue

		var to_heart := p.distance_to(heart.position)
		var s := 0.0
		if kind == VNode.Kind.FORGE or kind == VNode.Kind.LOOM:
			# Tools must stand between a cluster of supply and the Heart.
			s = -to_heart
		else:
			# Prefer awkward — elbow room from neighbours — WITHOUT preferring a
			# compass direction. Distance from the Heart is deliberately not a
			# term here; that was the bias.
			s = near
		if s > best_score:
			best_score = s
			best = p

	if best_score == -INF:
		return
	var n := _make_node(kind, best)
	if kind == VNode.Kind.BOOST:
		n.boost_effect = _roll_boost()
	_rebuild_graph()


## Rolled from the seeded run RNG, not global randf() — the whole sim stays
## deterministic given a seed, which is what the Daily and the probe both rely
## on. CLEANSE only makes sense with something to cleanse; falling back to
## SURGE when nothing is corrupted means a boost is never a wasted no-op.
func _roll_boost() -> int:
	var has_target := false
	for n in nodes:
		if n.corrupted:
			has_target = true
			break

	var weights := BOOST_WEIGHTS.duplicate()
	if not has_target:
		weights[BoostFx.CLEANSE] = 0.0

	var total := 0.0
	for w in weights:
		total += w
	var roll := rng.randf() * total
	var acc := 0.0
	for i in weights.size():
		acc += weights[i]
		if roll <= acc:
			return i
	return BoostFx.SURGE


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

	# A Boost is not part of the flow graph — reaching for one is a detour, not
	# a route. It triggers the instant a vein touches it, at full value: no
	# crossing-vein penalty, no tempo requirement, because punishing a reward
	# pickup for incidental geometry would just feel arbitrary.
	if a.kind == VNode.Kind.BOOST or b.kind == VNode.Kind.BOOST:
		_take_boost(a if a.kind == VNode.Kind.BOOST else b)
		return

	# Crossing BLOCKS the connection — it does not destroy the crossed vein.
	#
	# Playtest: "when the heart changes to square and I connect square to it, I
	# die." Root cause: the Heart is where the most veins converge, so the
	# rescue connection you most need to complete is also the one geometrically
	# likeliest to cross something. The old behaviour silently failed to create
	# the new vein AND bled fuel AND ruptured a different, unrelated vein — from
	# the player's side the drag visually snapped, nothing looked wrong, and the
	# game had actually destroyed a load-bearing connection and cost fuel while
	# never delivering the CLOTH that would have saved them. Spaghetti-avoidance
	# is still a real constraint (the drag preview still warns in red and the
	# connection is refused), it just no longer punishes you for a geometry
	# mistake with more than "try a different angle."
	if _crossing_vein(a, b) != null:
		return

	var synced := _tempo_action()
	var v: Vein = VeinScene.new()
	# Alternate the bend so parallel veins fan out instead of overlapping.
	v.setup(a, b, 1.0 if veins.size() % 2 == 0 else -1.0)
	v.tempo_grade = combo if synced else -1
	v.ruptured.connect(_on_ruptured)
	vein_layer.add_child(v)
	veins.append(v)
	_rebuild_graph()


func _tempo_action() -> bool:
	var q := _tempo_quality()
	if q <= GOOD_WINDOW:
		combo = mini(combo + (2 if q <= PERFECT_WINDOW else 1), COMBO_CAP)
		_sync_flash = 1.0
		fuel = clampf(fuel + SYNC_FUEL * (1.0 + float(combo) * 0.08), 0.0, FUEL_CAP)
		Audio.sync_hit(combo, q <= PERFECT_WINDOW)
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(30 + combo * 6)
		return true

	combo = 0
	_bad_tempo_flash = 1.0
	fuel = maxf(0.0, fuel - OFFBEAT_BLEED)
	Audio.play("corrupt", -14.0, 0.58)
	if OS.has_feature("mobile"):
		Input.vibrate_handheld(90)
	return false


func _tempo_quality() -> float:
	return minf(Beat.phase, 1.0 - Beat.phase)


## Apply a Boost's effect and remove the node. This is the payoff for the
## detour — it has to be as visible and audible as a rupture, just warm instead
## of violent.
func _take_boost(n: VNode) -> void:
	boosts_taken += 1
	match n.boost_effect:
		BoostFx.SURGE:
			budget += BOOST_SURGE_BUDGET
			budget_hint.queue_redraw()
		BoostFx.EASE:
			_ease_remaining += BOOST_EASE_TIME
		BoostFx.CLEANSE:
			var target: VNode = null
			var best := INF
			for c in nodes:
				if not c.corrupted:
					continue
				var d := c.position.distance_to(n.position)
				if d < best:
					best = d
					target = c
			if target != null:
				target.uncorrupt()
			else:
				budget += BOOST_SURGE_BUDGET

	var burst: Node2D = BurstScene.new()
	vein_layer.add_child(burst)
	var ring: Array[Vector2] = []
	var kinds: Array[int] = []
	for i in 10:
		var a := TAU * float(i) / 10.0
		ring.append(n.position + Vector2(cos(a), sin(a)) * 6.0)
		kinds.append(0)
	burst.spawn(ring, kinds, rng.randi(), Palette.BOOST)

	Audio.play("refined", -2.0, 1.8)
	if OS.has_feature("mobile"):
		Input.vibrate_handheld(160)

	_remove_node(n)


## Shared teardown for a node leaving the board outside of the normal
## rupture/cut paths — Boost pickups, withered Wells, collapsed rot. Always
## drops any vein still attached (there should be at most one for a Boost;
## a withered/collapsed node is by definition orphaned or about to be cut).
func _remove_node(n: VNode) -> void:
	for v in veins.duplicate():
		if v.a == n or v.b == n:
			_remove_vein(v)
	nodes.erase(n)
	n.queue_free()
	if heart == n:
		heart = null
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
		burst.spawn(pts, kinds, rng.randi(), Color(0, 0, 0, 0), intensity())

	Audio.play("rupture", -3.0, randf_range(0.9, 1.1))
	if OS.has_feature("mobile"):
		Input.vibrate_handheld(180)

	_remove_vein(v)


func _remove_vein(v: Vein, surgical := false) -> void:
	var synced := true
	if surgical:
		synced = _tempo_action()
	if surgical and not (v.a.corrupted or v.b.corrupted) and not v.dots.is_empty():
		var bleed := float(v.dots.size()) * CUT_BLEED_BY_DOT
		if synced:
			bleed *= 0.25
		fuel = maxf(0.0, fuel - bleed)
		var pts: Array[Vector2] = []
		var kinds: Array[int] = []
		for d in v.dots:
			pts.append(v.sample(d.t))
			kinds.append(d.kind)
		var burst: Node2D = BurstScene.new()
		vein_layer.add_child(burst)
		burst.spawn(pts, kinds, rng.randi(), Color(0, 0, 0, 0), intensity())
		Audio.play("rupture", -8.0, 0.75)
	veins.erase(v)
	v.queue_free()
	_rebuild_graph()


func _crossing_vein(a: VNode, b: VNode) -> Vein:
	for v in veins:
		if v.a == a or v.a == b or v.b == a or v.b == b:
			continue
		if _segments_cross(a.position, b.position, v.a.position, v.b.position):
			return v
	return null


func _segments_cross(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> bool:
	var r := a1 - a0
	var s := b1 - b0
	var den := r.cross(s)
	if absf(den) < 0.001:
		return false
	var t := (b0 - a0).cross(s) / den
	var u := (b0 - a0).cross(r) / den
	return t > 0.04 and t < 0.96 and u > 0.04 and u < 0.96


# --- Sim --------------------------------------------------------------------

func _process(delta: float) -> void:
	# A frame hitch must not teleport the sim — see Beat.MAX_DELTA.
	delta = minf(delta, Beat.MAX_DELTA)
	_rescue = maxf(0.0, _rescue - delta * 2.2)
	_sync_flash = maxf(0.0, _sync_flash - delta * 3.8)
	_bad_tempo_flash = maxf(0.0, _bad_tempo_flash - delta * 4.4)

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
	_tick_lifecycle(delta)
	heart.fuel_ratio = fuel / FUEL_CAP
	_push_from_nodes()
	for v in veins:
		for kind in v.advance(delta):
			_deliver(kind, v.sink())

	# Driven every frame, not per-beat: a dying run's beats slow way down, and
	# the mix must keep evolving smoothly through that instead of freezing
	# between rare beats. This is the whole fix for "the sound doesn't
	# progress" — it is now a continuous function of the run, not a state
	# machine that jumps between fixed stages.
	Audio.set_intensity(intensity())
	Audio.set_tension(float(combo) / float(COMBO_CAP))
	Audio.set_corruption(_corruption_ratio())

	budget_hint.queue_redraw()
	drag_layer.queue_redraw()
	queue_redraw()


## Fraction of live Wells currently corrupted. Drives the corruption drone —
## the mix should sicken continuously as rot spreads, not just spike once per
## infection event.
func _corruption_ratio() -> float:
	var wells := 0
	var rotted := 0
	for n in nodes:
		if n.kind == VNode.Kind.WELL:
			wells += 1
			if n.corrupted:
				rotted += 1
	return 0.0 if wells == 0 else float(rotted) / float(wells)


func _draw() -> void:
	if heart == null or not alive:
		return

	var centre := heart.position
	var exert := clampf(run_time / EXERTION_SPAN, 0.0, 1.0)
	var phase := Beat.phase
	var beat_r := 48.0 + phase * (44.0 + exert * 54.0)

	var ring := Palette.HEART
	ring.a = (1.0 - phase) * (0.22 + exert * 0.22)
	draw_arc(centre, beat_r, 0.0, TAU, 72, ring, 1.5 + exert * 2.0, true)

	var window := Palette.WARM
	window.a = 0.25 + _sync_flash * 0.45
	draw_arc(centre, 58.0, -PI * 0.5 - PERFECT_WINDOW * TAU,
		-PI * 0.5 + PERFECT_WINDOW * TAU, 18, window, 3.0 + _sync_flash * 3.0, true)

	if _bad_tempo_flash > 0.0:
		var bad := Palette.VEIN_STRAINED
		bad.a = _bad_tempo_flash * 0.65
		draw_arc(centre, 74.0 + (1.0 - _bad_tempo_flash) * 24.0, 0.0, TAU, 44,
			bad, 4.0 * _bad_tempo_flash, true)

	if combo > 0:
		var teeth := combo
		for i in teeth:
			var a := TAU * (float(i) / float(COMBO_CAP)) - PI * 0.5
			var p0 := centre + Vector2(cos(a), sin(a)) * 72.0
			var p1 := centre + Vector2(cos(a), sin(a)) * (82.0 + _sync_flash * 8.0)
			var c := Palette.WARM.lerp(Palette.CLOTH, float(i) / float(COMBO_CAP))
			c.a = 0.65 + _sync_flash * 0.35
			draw_line(p0, p1, c, 3.0, true)

	if exert > 0.18:
		var chaos := (exert - 0.18) / 0.82
		var storm := Palette.VEIN_STRAINED
		storm.a = 0.05 + chaos * 0.12
		var spin := float(Time.get_ticks_msec()) * 0.001 * (0.8 + chaos * 2.6)
		for i in 5:
			var a0 := spin + float(i) * TAU / 5.0
			draw_arc(centre, 108.0 + float(i) * 17.0 + chaos * 26.0,
				a0, a0 + PI * (0.45 + chaos * 0.35), 20, storm, 1.2 + chaos * 2.2, true)


## Rot spreads down live veins. Leaving a necrotic Well wired in doesn't just
## poison the Heart — it takes the neighbours with it, so the punishment for
## ignoring one dead lifeline is losing that whole limb of your network.
func _tick_corruption(delta: float) -> void:
	# Rot gets meaner as the run does: the vein-borne spread tightens toward
	# SPREAD_TIME_LATE, and past AIRBORNE_AT it can also leap to an unconnected
	# Well with no vein at all — a second, distinct threat (a roaming blight,
	# not a plumbing hazard) that only matters once the run is far enough along
	# that the opening stays learnable.
	var exert := intensity()
	var spread_time := lerpf(VNode.SPREAD_TIME, SPREAD_TIME_LATE, exert)
	var airborne := exert >= AIRBORNE_AT

	var newly: Array[VNode] = []
	for n in nodes:
		if not n.corrupted:
			continue
		n.spread_accum += delta
		if n.spread_accum < spread_time:
			continue
		n.spread_accum = 0.0

		for v in veins:
			var o := v.other(n)
			if o != null and not o.corrupted and o.kind == VNode.Kind.WELL and o not in newly:
				newly.append(o)

		if airborne and rng.randf() < AIRBORNE_CHANCE:
			var jumped := _nearest_orphan_well(n.position, AIRBORNE_RADIUS)
			if jumped != null and jumped not in newly:
				newly.append(jumped)

	for n in newly:
		n.corrupt()
		corruptions += 1
		Audio.play("corrupt", -4.0, 0.62)
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(140)


func _nearest_orphan_well(from: Vector2, within: float) -> VNode:
	var best: VNode = null
	var best_d := within
	for n in nodes:
		if n.kind != VNode.Kind.WELL or n.corrupted:
			continue
		var d := from.distance_to(n.position)
		if d < best_d:
			best_d = d
			best = n
	return best


## Wells nobody ever wired in wither away; rot nobody ever cut collapses
## outright. Both remove the node itself (see _remove_node), which is what
## keeps the board turning over instead of only ever accumulating — every
## object that appears either gets used, gets cut, or eventually leaves.
func _tick_lifecycle(_delta: float) -> void:
	for n in nodes.duplicate():
		if n.wither_ratio() >= 1.0:
			withered += 1
			_remove_node(n)
		elif n.collapse_ratio() >= 1.0:
			collapsed += 1
			var burst: Node2D = BurstScene.new()
			vein_layer.add_child(burst)
			var pts: Array[Vector2] = [n.position]
			var kinds: Array[int] = [VNode.Res.VOID]
			burst.spawn(pts, kinds, rng.randi(), Color(0, 0, 0, 0), intensity())
			Audio.play("corrupt", -6.0, 0.4)
			_remove_node(n)


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
		var gain := float(FUEL_BY_RES.get(kind, 1.0))
		if kind != demand and kind != VNode.Res.VOID:
			gain = WRONG_SHAPE_FUEL * (1.0 + float(combo) * 0.04)
			wasted += 1
			combo = 0
			_bad_tempo_flash = 1.0
			Audio.play("corrupt", -10.0, 0.82)
			if OS.has_feature("mobile"):
				Input.vibrate_handheld(60)
		elif kind != VNode.Res.VOID:
			gain *= 1.0 + minf(float(combo), float(COMBO_CAP)) * COMBO_GAIN
		fuel = clampf(fuel + gain, 0.0, FUEL_CAP)
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
			_remove_vein(v, true)


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
	var crossing := to != null and to != _drag_from and _crossing_vein(_drag_from, to) != null

	var col := Palette.VEIN_STRAINED if stretched or crossing else Palette.VEIN_LIVE
	col.a = 0.75
	drag_layer.draw_line(_drag_from.position, end, col, 3.0, true)

	if to == null:
		return
	var ok := to != _drag_from and can_afford() and _find_vein(_drag_from, to) == null \
		and in_reach(_drag_from, to) and not crossing
	var ring := Palette.WARM if ok else Palette.VEIN_STRAINED
	ring.a = 0.85
	drag_layer.draw_arc(to.position, to.radius() + 8.0, 0.0, TAU, 28, ring, 2.0, true)
