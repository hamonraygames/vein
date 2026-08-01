extends Node2D
## A visible poison dot travelling from a raging corrupted node to the
## neighbour it is about to hit — see game.gd's _start_poison_burst. Rides
## the actual vein's curve, same as every ordinary resource dot (see
## vein.gd's own dot flow) — a straight line between the two node positions
## read as "shooting" the neighbour, which is not what a network-borne rot
## is supposed to look like. Same self-contained, self-freeing pattern as
## burst.gd/float_text.gd.

const TRAVEL_TIME := 0.22

var _vein: Vein
## True if `vein.a` is the attacker — vein.pts always runs geometrically
## a->b regardless of the vein's own flow direction (see vein.gd's rebuild),
## so this is what decides whether travelling attacker->target walks pts
## forward or backward.
var _forward := true
var _t := 0.0


func spawn(vein: Vein, forward: bool) -> void:
	_vein = vein
	_forward = forward
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
	var u_tail := maxf(0.0, eased - 0.14)
	var head := _point_at(u)
	var tail := _point_at(u_tail if _forward else 1.0 - u_tail)
	draw_line(tail, head, Palette.VOID, 3.0, true)
	draw_circle(head, 4.5, Palette.VOID)
