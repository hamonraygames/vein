extends Node2D
## A visible poison dot travelling from a raging corrupted node to the
## neighbour it is about to hit — see game.gd's _start_poison_burst.
##
## Rides the vein's own curve (see _point_at), not a straight line between
## the two node positions — that read as "shooting" the neighbour. Drawn to
## match vein.gd's own _draw_poison_dot as closely as this self-contained
## scene can (same writhing jitter, pulsing halo, thorn spikes, VOID
## colour) so it reads as the same poison the rest of the game already
## shows, not a lookalike.
##
## Deliberately its OWN reliable system rather than a real Vein.inject() —
## that was tried and reverted: a real injected dot only travels a vein's
## fixed flow direction and only actually resolves anything when it arrives
## through the ordinary delivery pipeline (which just treats VOID as
## harmless pass-through for a non-Heart destination, see game._deliver) —
## so the visual dot and the actual kill ended up decoupled, unreliable,
## and firing in ways that did not match what was on screen. This scene is
## purely cosmetic; game.gd's own timer decides who actually dies and when.

const TRAVEL_TIME := 0.22

var _vein: Vein
## True if `vein.a` is the attacker — vein.pts always runs geometrically
## a->b regardless of the vein's own flow direction (see vein.gd's rebuild),
## so this is what decides whether travelling attacker->target walks pts
## forward or backward.
var _forward := true
var _t := 0.0
var _seed := 0.0


func spawn(vein: Vein, forward: bool) -> void:
	_vein = vein
	_forward = forward
	_seed = randf() * 1000.0
	z_index = 20


func _process(delta: float) -> void:
	if not is_instance_valid(_vein):
		# The vein got cut out from under an in-flight dart — nothing sane
		# left to draw a curve along, so just disappear rather than error.
		queue_free()
		return
	_t += delta
	if _t >= TRAVEL_TIME:
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
	var p := clampf(_t / TRAVEL_TIME, 0.0, 1.0)
	# Ease-in: a slow wind-up, a fast strike — reads as a lunge, not a dot
	# gliding evenly across.
	var eased := p * p
	var u := eased if _forward else 1.0 - eased
	var pos := _point_at(u)

	# Same writhe as vein.gd's _draw_poison_dot: a small jittering offset and
	# pulsing halo/thorns, phase-offset per dart (_seed) so a burst of two or
	# three doesn't writhe in lockstep.
	var t := float(Time.get_ticks_msec()) * 0.001
	var jitter := Vector2(sin(t * 13.0 + _seed), cos(t * 17.0 + _seed * 1.3)) * 2.2
	var jp := pos + jitter
	var pulse := 0.5 + 0.5 * sin(t * 9.0 + _seed)
	var c := Palette.VOID
	var halo := c
	halo.a = 0.12 + pulse * 0.18
	draw_circle(jp, 9.0 + pulse * 2.0, halo)
	for i in 5:
		var a := TAU * float(i) / 5.0 + t * 1.4
		var dir := Vector2(cos(a), sin(a))
		draw_line(jp + dir * 3.6, jp + dir * (6.5 + pulse * 3.0), c, 1.5)
	draw_circle(jp, 3.4, c)
