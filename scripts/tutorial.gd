extends Node2D
## First-run tutorial, Cut-the-Rope style — now an OVERLAY on a real run, not
## a frozen sandbox. Feedback: "it should be the beginning of a real game,
## even you could die; we only get rid of the tutorial when you completed it
## successfully." So the world runs normally — real drain, real spawns, real
## escalation, real death — and the tutorial only draws ghost-thumb hints on
## top, riding the run's own natural events. Nothing here freezes or scripts
## the world; it just points at the next thing to do.
##
## The game's opening is already gentle (START_FUEL buffer, low base
## appetite), so a first-timer has room to read the board and make the first
## connection before anything can kill them — that IS the "start slow" the
## tutorial needs, without a special mode.
##
## Lessons, each armed by the real event that makes it matter and persisted
## separately (game.tut_* flags) so a death mid-tutorial resumes rather than
## repeats — you keep the verbs you've already performed and the tutorial is
## only fully "done" once all three are learned:
##   CONNECT  — drag the two starter Wells into the Heart.
##   CHAIN    — once a Well spawns too far to reach the Heart directly but
##              within reach of one already wired in: connect it THROUGH the
##              nearer Well. Teaches that reach is per-vein and the network
##              grows outward in chains, not just spokes off the Heart.
##   COMBINE  — once the Heart demands the triangle and a Forge exists: link
##              Forge->Heart, then feed a Well->Forge and watch it smelt.
##   REROUTE  — the old circle lines now feed the wrong shape: cut them.
##   CUT      — when a Well goes necrotic on its own: sever the poisoned vein.

enum Step { CONNECT, FEED2, WATCH, CHAIN, COMBINE_LINK, COMBINE_FEED, REROUTE, CUT, DONE }

## Cleared by game.gd when a harness attaches. While false this node draws
## nothing and never touches the save.
var enabled := true

var step: int = Step.CONNECT
var _t := 0.0
var _forge: VNode = null
var _chain_well: VNode = null
var _chain_relay: VNode = null
var _chain_start := 0.0
## When the held-back triangle demand is allowed to arrive (set after chaining
## is taught). INF while still teaching connect/chain.
var _demand_flip_time := INF
## When to force a corruption for the cut lesson if none has happened on its
## own. INF until the forge lesson is done.
var _cut_inject_time := INF
var _cut_armed := false

@onready var game: Node2D = get_parent()

const LOOP_TIME := 2.4
const THUMB_R := 13.0
## The tutorial owns pacing so lessons land in order and never blindside a
## first-timer. Chaining auto-skips if ignored this long; the triangle demand
## waits this long after chaining before it arrives; a corruption is forced
## this long after the forge lesson if none happened naturally.
const CHAIN_SKIP_TIME := 22.0
const DEMAND_GRACE := 10.0
const CUT_GRACE := 7.0


func _ready() -> void:
	z_index = 18


## Called by game.start_run — resumes at the first unlearned lesson so a
## death never re-teaches a verb already performed.
func reset() -> void:
	_t = 0.0
	_forge = null
	_chain_well = null
	_chain_relay = null
	_chain_start = 0.0
	_demand_flip_time = INF
	_cut_inject_time = INF
	_cut_armed = false
	if not game.tut_connect:
		step = Step.CONNECT
	elif not (game.tut_chain and game.tut_forge and game.tut_cut):
		# Mid-tutorial resume: chaining already learned means the pace gates
		# are lifted, so let demand and the cut lesson proceed immediately.
		step = Step.WATCH
		if game.tut_chain:
			_demand_flip_time = game.run_time
		if game.tut_forge:
			_cut_inject_time = game.run_time + CUT_GRACE
	else:
		step = Step.DONE


func active() -> bool:
	return enabled and step != Step.DONE and game != null \
		and not game.tutorial_done and game.alive


## While true, game.gd suspends its DEMAND_TIERS schedule and the tutorial
## owns `demand`: RAW through connect+chain, then REFINED after DEMAND_GRACE,
## so the triangle never arrives "very quick" before the player is ready.
func holds_demand() -> bool:
	return active()


## While true, game.gd suspends Well AND tool spawns. The opening stays the two
## starter Wells until they're connected, then the tutorial injects exactly one
## far Well for the chaining lesson — no flood. Lifts the moment chaining is
## taught (or skipped), after which the real spawn cadence takes over.
func gates_spawns() -> bool:
	return active() and not game.tut_chain


func _process(delta: float) -> void:
	if not active():
		visible = false
		return
	visible = true
	_t += delta
	_advance()
	queue_redraw()


func _advance() -> void:
	# The tutorial owns the demand clock (see holds_demand): hold RAW until the
	# grace after chaining, then bring the triangle in once, on time.
	if not game.tut_forge and game.demand != VNode.Res.REFINED \
			and game.run_time >= _demand_flip_time:
		game.demand = VNode.Res.REFINED
		game.heart.demand = VNode.Res.REFINED
		game.heart.pulse = 1.0
		if not game._unlocked_res.has(VNode.Res.REFINED):
			game._unlocked_res.append(VNode.Res.REFINED)

	match step:
		Step.CONNECT:
			if _heart_links() >= 1:
				step = Step.FEED2
				_t = 0.0
		Step.FEED2:
			if _heart_links() >= 2:
				_finish_lesson("tut_connect")
				# Only NOW does the third circle arrive — placed out of the
				# Heart's reach so it must chain through one of the two just
				# connected.
				_inject_chain_well()
				_chain_start = game.run_time
				step = Step.CHAIN
				_t = 0.0
		Step.WATCH:
			# Between lessons, riding the real run. Poison outranks the Forge —
			# it's actively killing the Heart.
			if not game.tut_cut and _rotten_vein() != null:
				step = Step.CUT
				_t = 0.0
				_cut_armed = false
			elif not game.tut_forge and game.demand == VNode.Res.REFINED \
					and _pick_forge() != null:
				_forge = _pick_forge()
				step = Step.COMBINE_LINK
				_t = 0.0
			elif game.tut_forge and not game.tut_cut and _rotten_vein() == null \
					and game.run_time >= _cut_inject_time:
				# The forge lesson is done and nothing rotted on its own —
				# force one so the cut lesson can actually happen.
				_inject_corruption()
		Step.CHAIN:
			# Done the instant the far Well is connected THROUGH something
			# (depth >= 2: Heart is 0, a direct Well 1, a relayed Well 2+).
			if not _chain_valid():
				# The injected Well was lost — re-inject once; if that fails,
				# the player has clearly moved on, so skip the lesson.
				_inject_chain_well()
				if _chain_well == null:
					_finish_lesson("tut_chain")
					_after_chain()
			elif _chain_well.depth >= 2:
				_finish_lesson("tut_chain")
				_after_chain()
			elif game.run_time - _chain_start > CHAIN_SKIP_TIME:
				# Not paying attention — don't stall the whole tutorial on it.
				_finish_lesson("tut_chain")
				_after_chain()
		Step.COMBINE_LINK:
			if not _forge_valid():
				_to_watch()
			elif _forge.depth >= 0:
				step = Step.COMBINE_FEED
				_t = 0.0
		Step.COMBINE_FEED:
			if not _forge_valid():
				_to_watch()
			elif _forge_fed(_forge):
				step = Step.REROUTE
				_t = 0.0
		Step.REROUTE:
			if _stale_heart_vein() == null:
				_finish_lesson("tut_forge")
				# Arm the cut lesson: give the run a moment to rot a Well on its
				# own, and force one if it doesn't.
				_cut_inject_time = game.run_time + CUT_GRACE
				_to_watch()
		Step.CUT:
			if _rotten_vein() != null:
				_cut_armed = true
			elif _cut_armed:
				_finish_lesson("tut_cut")
				_to_watch()


## Chaining taught (or skipped): lift the pace gates and let the triangle
## demand arrive after a grace, so it never lands the instant chaining ends.
func _after_chain() -> void:
	_demand_flip_time = game.run_time + DEMAND_GRACE
	_to_watch()


func _to_watch() -> void:
	step = Step.WATCH
	_t = 0.0
	_forge = null
	_chain_well = null
	_chain_relay = null
	if game.tut_connect and game.tut_chain and game.tut_forge and game.tut_cut:
		step = Step.DONE
		game.tutorial_done = true
		game._store_save()


func _finish_lesson(flag: String) -> void:
	game.set(flag, true)
	game._store_save()


# --- Scripted injections (only the tutorial's own props) ---------------------

## Places ONE Well that cannot reach the Heart directly but CAN reach a
## connected Well — the exact setup the chaining lesson explains. Sets
## _chain_well / _chain_relay to it. Leaves _chain_well null if (somehow) no
## valid spot is found, so the caller can skip the lesson gracefully.
func _inject_chain_well() -> void:
	_chain_well = null
	_chain_relay = null
	var vp: Vector2 = game.design_size()
	# Grow outward from a connected Well, away from the Heart, far enough that
	# the Heart is out of reach but the relay Well is not.
	var relays: Array[VNode] = []
	for n in game.nodes:
		if n.kind == VNode.Kind.WELL and not n.corrupted and n.depth >= 0:
			relays.append(n)
	# Sweep bearings around each relay, not just the straight-away-from-Heart
	# vector: the two starter Wells sit near opposite screen corners, so their
	# radial-outward direction always lands off-screen and got rejected — which
	# is why the chaining lesson silently never fired. Prefer the placement that
	# reaches deepest past the Heart's rim while staying on-screen and in relay
	# reach, so the "this is beyond the Heart" read is unmistakable.
	var best_p := Vector2.ZERO
	var best_relay: VNode = null
	var best_score := -INF
	for relay in relays:
		for i in 24:
			var bearing := TAU * float(i) / 24.0
			for f in [0.9, 0.8, 0.7, 0.6]:
				var p: Vector2 = relay.position + Vector2(cos(bearing), sin(bearing)) * (Vein.MAX_LEN * f)
				if p.x < 70.0 or p.x > vp.x - 70.0 or p.y < 90.0 or p.y > vp.y - 90.0:
					continue
				var d_heart := p.distance_to(game.heart.position)
				if d_heart <= Vein.MAX_LEN + 12.0:
					continue  # must NOT be directly reachable — that's the point
				if p.distance_to(relay.position) > Vein.MAX_LEN:
					continue  # relay must be able to reach it
				var crowded := false
				for n in game.nodes:
					if p.distance_to(n.position) < 96.0:
						crowded = true
						break
				if crowded:
					continue
				# Just past reach is the clearest lesson; farther is fine too.
				if d_heart > best_score:
					best_score = d_heart
					best_p = p
					best_relay = relay
	if best_relay != null:
		_chain_well = game._make_node(VNode.Kind.WELL, best_p)
		_chain_relay = best_relay
		game._rebuild_graph()
		return


## Corrupts a Well the player wired in, so the cut lesson has a real poisoned
## vein to point at. Prefers one feeding the Heart directly.
func _inject_corruption() -> void:
	var victim: VNode = null
	for v in game.veins:
		var o: VNode = null
		if v.a == game.heart:
			o = v.b
		elif v.b == game.heart:
			o = v.a
		if o != null and o.kind == VNode.Kind.WELL and not o.corrupted:
			victim = o
			break
	if victim == null:
		for n in game.nodes:
			if n.kind == VNode.Kind.WELL and not n.corrupted and n.depth >= 0:
				victim = n
				break
	if victim != null:
		victim.corrupt()
		Audio.play("corrupt", -4.0, 0.62)


# --- Board queries -----------------------------------------------------------

func _heart_links() -> int:
	var c := 0
	for v in game.veins:
		if v.a == game.heart or v.b == game.heart:
			c += 1
	return c


func _rotten_vein() -> Vein:
	for v in game.veins:
		if v.a.corrupted or v.b.corrupted:
			return v
	return null


func _forge_valid() -> bool:
	return _forge != null and is_instance_valid(_forge) and _forge in game.nodes \
		and not _forge.corrupted


## Finds a teachable chaining moment: a fresh orphan Well that CANNOT reach the
## Heart directly, but CAN reach a Well already wired into the network. Returns
## [far_well, relay_well] or null. This is the exact situation the lesson
## exists to explain — reach is per-vein, so you grow through what you've got.
func _pick_chain() -> Array:
	var best: Array = []
	var best_d := INF
	for n in game.nodes:
		if n.kind != VNode.Kind.WELL or n.corrupted or n.depth >= 0 or n.reserve <= 0.0:
			continue
		if game.in_reach(n, game.heart):
			continue  # a direct connection is possible — not a chaining lesson
		# Nearest connected Well it could relay through.
		for m in game.nodes:
			if m.kind != VNode.Kind.WELL or m.corrupted or m.depth < 0:
				continue
			if not game.in_reach(n, m):
				continue
			var d: float = n.position.distance_to(m.position)
			if d < best_d:
				best_d = d
				best = [n, m]
	return best if not best.is_empty() else []


func _chain_valid() -> bool:
	if _chain_well == null or not is_instance_valid(_chain_well) \
			or _chain_well not in game.nodes or _chain_well.corrupted:
		return false
	# Relay must still be a live, connected Well in reach; re-pick if it died.
	if _chain_relay == null or not is_instance_valid(_chain_relay) \
			or _chain_relay not in game.nodes or _chain_relay.corrupted \
			or _chain_relay.depth < 0 or not game.in_reach(_chain_well, _chain_relay):
		var relay: VNode = null
		var best_d := INF
		for m in game.nodes:
			if m.kind != VNode.Kind.WELL or m.corrupted or m.depth < 0:
				continue
			if not game.in_reach(_chain_well, m):
				continue
			var d: float = _chain_well.position.distance_to(m.position)
			if d < best_d:
				best_d = d
				relay = m
		_chain_relay = relay
	return _chain_relay != null


## A Forge that eats RAW (a real chain entry for the triangle), furthest along
## if several exist, nearest the Heart as tie-break.
func _pick_forge() -> VNode:
	var best: VNode = null
	var best_key := -INF
	for n in game.nodes:
		if n.kind != VNode.Kind.FORGE or n.corrupted or not n.recipe.has(VNode.Res.RAW):
			continue
		var stage := 0
		if n.depth >= 0:
			stage = 2 if _forge_fed(n) else 1
		var key: float = float(stage) * 100000.0 - n.position.distance_to(game.heart.position)
		if key > best_key:
			best_key = key
			best = n
	return best


func _forge_fed(forge: VNode) -> bool:
	for v in game.veins:
		var o: VNode = null
		if v.a == forge:
			o = v.b
		elif v.b == forge:
			o = v.a
		if o != null and o.kind == VNode.Kind.WELL and not o.corrupted:
			return true
	return false


## A healthy circle still wired straight into the Heart while it wants a
## triangle — a stale line the reroute should reclaim. Rotten wells excluded:
## their veins belong to the CUT lesson.
func _stale_heart_vein() -> Vein:
	for v in game.veins:
		var o: VNode = null
		if v.a == game.heart:
			o = v.b
		elif v.b == game.heart:
			o = v.a
		if o != null and o.kind == VNode.Kind.WELL and not o.corrupted \
				and o.produces != game.demand:
			return v
	return null


## Nearest fresh Well to `target` that can reach it, orphans preferred so the
## hint never suggests tearing up a working line.
func _demo_well(target: VNode) -> VNode:
	var best: VNode = null
	var best_d := INF
	var best_orphan: VNode = null
	var best_orphan_d := INF
	for n in game.nodes:
		if n.kind != VNode.Kind.WELL or n.corrupted or n.reserve <= 0.0:
			continue
		if not game.in_reach(n, target):
			continue
		var d: float = n.position.distance_to(target.position)
		if d < best_d:
			best_d = d
			best = n
		if n.depth < 0 and d < best_orphan_d:
			best_orphan_d = d
			best_orphan = n
	return best_orphan if best_orphan != null else best


# --- Drawing -----------------------------------------------------------------

func _draw() -> void:
	match step:
		Step.CONNECT, Step.FEED2:
			var well := _demo_well(game.heart)
			if well != null and well.depth < 0:
				_draw_drag_ghost(well.position, game.heart.position)
		Step.CHAIN:
			# Point from the unreachable Well to the connected Well it should
			# relay through — plus a faint hint of the reach it's beyond.
			if _chain_valid():
				_draw_reach_hint(game.heart)
				_draw_drag_ghost(_chain_well.position, _chain_relay.position)
		Step.COMBINE_LINK:
			if _forge_valid() and _forge.depth < 0:
				_draw_drag_ghost(_forge.position, game.heart.position)
		Step.COMBINE_FEED:
			if _forge_valid():
				var well := _demo_well(_forge)
				if well != null:
					_draw_drag_ghost(well.position, _forge.position)
		Step.REROUTE:
			var stale := _stale_heart_vein()
			if stale != null:
				_draw_cut_ghost(stale)
		Step.CUT:
			var v := _rotten_vein()
			if v != null:
				_draw_cut_ghost(v)


## A faint ring at the Heart's reach, so "this Well is beyond it" is visible —
## the far Well sits outside this ring, the relay Well inside it.
func _draw_reach_hint(from: VNode) -> void:
	var c := Palette.HEART
	c.a = 0.10
	draw_arc(from.position, Vein.MAX_LEN, 0.0, TAU, 64, c, 1.2, true)


## A looping ghost drag: thumb fades in on the source, eases to the target
## leaving a breadcrumb trail, a ring lands on arrival — the exact motion the
## player's own thumb must make.
func _draw_drag_ghost(from: Vector2, to: Vector2) -> void:
	var p := fmod(_t, LOOP_TIME) / LOOP_TIME
	var chord := to - from
	var mid := (from + to) * 0.5 + chord.orthogonal().normalized() * chord.length() * 0.10

	var col := Palette.WARM
	if p < 0.12:
		col.a = p / 0.12 * 0.7
		draw_circle(from, THUMB_R, _faint(col, 0.25))
		draw_arc(from, THUMB_R, 0.0, TAU, 24, col, 2.0, true)
		return

	if p < 0.72:
		var t := (p - 0.12) / 0.60
		var eased := t * t * (3.0 - 2.0 * t)
		var crumbs := int(eased * 9.0)
		for i in crumbs:
			var ct := eased * float(i + 1) / float(crumbs + 1)
			var cp := _bezier(from, mid, to, ct)
			var cc := Palette.WARM
			cc.a = 0.28
			draw_circle(cp, 2.4, cc)
		var tip := _bezier(from, mid, to, eased)
		col.a = 0.7
		draw_circle(tip, THUMB_R, _faint(col, 0.25))
		draw_arc(tip, THUMB_R, 0.0, TAU, 24, col, 2.0, true)
		return

	var t2 := (p - 0.72) / 0.28
	col.a = (1.0 - t2) * 0.8
	draw_arc(to, 40.0 + t2 * 18.0, 0.0, TAU, 32, col, 2.5 * (1.0 - t2) + 0.5, true)


## A bold scissor-cross sitting directly ON the vein: this IS the "cut here"
## instruction, full stop. Feedback: the old fingertip-and-ripple version was
## too small and subtle to read as an instruction at all. This is unmissable —
## two thick blades, sized well past the vein's own width, that visibly snap
## shut on the point in a loop, with a bright snip flash at the moment of
## closure so the exact instant to tap is obvious even at a glance.
const CUT_ICON_CYCLE := 1.15
const CUT_BLADE_LEN := 26.0

func _draw_cut_ghost(v: Vein) -> void:
	var at := v.sample(0.5)
	var cyc := fmod(_t, CUT_ICON_CYCLE) / CUT_ICON_CYCLE
	# 0 = blades open wide, 1 = fully shut. Eased so the close reads as a snap.
	var close := clampf((cyc - 0.12) / 0.5, 0.0, 1.0)
	close = close * close * (3.0 - 2.0 * close)
	var half_angle := lerpf(0.95, 0.05, close)

	var warm := Palette.WARM
	var col := warm
	col.a = 0.95

	# Two blades crossing at `at`, swinging shut like open scissors. Thick and
	# long enough to read as the whole instruction on its own, no matter what
	# else is happening on screen.
	for sgn in [-1.0, 1.0]:
		var a: float = PI * 0.5 + sgn * half_angle
		var dir := Vector2(cos(a), sin(a))
		draw_line(at - dir * CUT_BLADE_LEN, at + dir * CUT_BLADE_LEN, col, 5.0, true)

	var hinge := warm
	hinge.a = 0.9
	draw_circle(at, 4.5, hinge)

	# The snip: once the blades are nearly shut, a bright ring and four short
	# radiating cut-marks flash outward — the moment of the cut is loud, not a
	# quiet detail you could miss.
	if close > 0.82:
		var t := (close - 0.82) / 0.18
		var fcol := Palette.HEART
		fcol.a = (1.0 - t) * 0.9
		draw_circle(at, 8.0 + t * 12.0, _faint(fcol, 0.4))
		for i in 4:
			var ang := TAU * float(i) / 4.0 + PI * 0.25
			var p0 := at + Vector2(cos(ang), sin(ang)) * (9.0 + t * 5.0)
			var p1 := at + Vector2(cos(ang), sin(ang)) * (16.0 + t * 16.0)
			var mc := fcol
			mc.a = (1.0 - t) * 0.85
			draw_line(p0, p1, mc, 2.4, true)


func _bezier(a: Vector2, c: Vector2, b: Vector2, t: float) -> Vector2:
	return a.lerp(c, t).lerp(c.lerp(b, t), t)


func _faint(col: Color, mult: float) -> Color:
	var f := col
	f.a = col.a * mult
	return f
