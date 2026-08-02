extends Node2D
## A visible poison dot travelling from a raging corrupted node to ONE
## neighbour over ONE vein — see game.gd's _start_poison_dart. That neighbour
## does not end the attack: the moment it turns, IT fires its own dart onward
## to its own other neighbours, and so on — a relay hopping node to node
## through the whole disconnected island, not a single node computing every
## downstream target up front. Each hop is its own dart on its own vein, so
## the poison visibly passes through every node on the way, rather than
## stopping at the first one.
##
## Travels at Vein.SPEED — the same px/sec every ordinary resource dot rides
## — instead of a fixed duration. A fixed duration made a short hop crawl and
## a long one teleport; matching the real flow speed is what makes every hop
## of the relay read as the same poison moving at the same pace.
##
## Rides the vein's own curve (see _point_at), not a straight line between
## the two node positions — that read as "shooting" the target. Shaped to
## match vein.gd's own _draw_poison_dot as closely as this self-contained
## scene can (same writhing jitter, pulsing halo, thorn spikes) but coloured
## Palette.RAGE, not VOID — this dart only ever exists mid rage-attack, and
## the neighbour it's flying toward already renders that same red the
## instant it turns (see VNode._draw_necrotic's raging tint), so the attack
## in flight and the target it's about to hit read as the one threat.
##
## Deliberately its OWN reliable system rather than a real Vein.inject() —
## that was tried and reverted: a real injected dot only travels a vein's
## fixed flow direction and only actually resolves anything when it arrives
## through the ordinary delivery pipeline (which just treats VOID as
## harmless pass-through for a non-Heart destination, see game._deliver) —
## so the visual dot and the actual kill ended up decoupled, unreliable,
## and firing in ways that did not match what was on screen. This scene is
## purely cosmetic; game.gd's own timer decides who actually turns and when.

## Floor under the computed travel time so two nodes sitting almost on top of
## each other don't produce a divide-by-near-zero instant flash.
const MIN_TRAVEL_TIME := 0.08

var _vein: Vein
## True walks the vein's own pts forward (a->b), false walks it backward.
## vein.pts always runs geometrically a->b regardless of the vein's own flow
## direction (see vein.gd's rebuild), so this is what decides which way THIS
## hop is actually walked.
var _forward := true
var _travel_time := MIN_TRAVEL_TIME
var _t := 0.0
var _seed := 0.0


func spawn(vein: Vein, forward: bool) -> void:
	_vein = vein
	_forward = forward
	_travel_time = maxf(vein.length / Vein.SPEED, MIN_TRAVEL_TIME)
	_seed = randf() * 1000.0
	z_index = 20


func _process(delta: float) -> void:
	if not is_instance_valid(_vein):
		# The vein got cut out from under an in-flight dart — nothing sane
		# left to draw a curve along, so just disappear rather than error.
		queue_free()
		return
	_t += delta
	if _t >= _travel_time:
		queue_free()
		return
	queue_redraw()


## Position at raw progress `u` (0 = vein.a, 1 = vein.b) along the vein's own
## sampled curve — index-lerp, not the arc-length-accurate spacing
## vein.sample() uses for steady-speed resource flow. A dart's flight is
## short and fast enough that the difference is not visible, and this
## avoids depending on vein.sample()'s own flow-direction mirroring, which
## answers a different question (which end is upstream) than the one this
## needs (which end is the attacker).
func _point_at(u: float) -> Vector2:
	var pts := _vein.pts
	if pts.size() < 2:
		return _vein.a.position
	var idx_f := clampf(u, 0.0, 1.0) * float(pts.size() - 1)
	var i := clampi(int(idx_f), 0, pts.size() - 2)
	return pts[i].lerp(pts[i + 1], idx_f - float(i))


func _draw() -> void:
	if not is_instance_valid(_vein):
		# _process() already frees the dart the frame AFTER the vein dies,
		# but queue_redraw() defers to the render pass later in the SAME
		# frame — the vein can still go from valid to freed in between
		# (e.g. its far node collapsing mid-frame), which _process() alone
		# never catches. Confirmed via --probe: "Invalid access to property
		# or key 'pts' on a base object of type 'previously freed'."
		return
	var p := clampf(_t / _travel_time, 0.0, 1.0)
	# Ease-in: a slow wind-up, a fast strike — reads as a lunge, not a dot
	# gliding evenly across.
	var eased := p * p
	var u := eased if _forward else 1.0 - eased
	var pos := _point_at(u)

	# Same writhe as vein.gd's _draw_poison_dot: a small jittering offset and
	# pulsing halo/thorns, phase-offset per dart (_seed) so several hops in
	# flight at once don't writhe in lockstep.
	var t := float(Time.get_ticks_msec()) * 0.001
	var jitter := Vector2(sin(t * 13.0 + _seed), cos(t * 17.0 + _seed * 1.3)) * 2.2
	var jp := pos + jitter
	var pulse := 0.5 + 0.5 * sin(t * 9.0 + _seed)
	# Palette.RAGE, not Palette.VOID — this dart only ever exists as a rage
	# attack (see game.gd's _start_poison_dart), and the target it's flying
	# toward already renders red the instant it turns (see VNode's
	# raging-tint in _draw_necrotic); the attack in flight should read as
	# the same threat, not the ordinary passive-poison violet.
	var c := Palette.RAGE
	var halo := c
	halo.a = 0.12 + pulse * 0.18
	draw_circle(jp, 9.0 + pulse * 2.0, halo)
	for i in 5:
		var a := TAU * float(i) / 5.0 + t * 1.4
		var dir := Vector2(cos(a), sin(a))
		draw_line(jp + dir * 3.6, jp + dir * (6.5 + pulse * 3.0), c, 1.5)
	draw_circle(jp, 3.4, c)
