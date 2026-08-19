class_name Hint
extends RefCounted
## The visual vocabulary VEIN teaches with, factored out of tutorial.gd so the
## struggle coach (see coach.gd) can aim the very same devices at whatever the
## player is stuck on right now.
##
## This exists because the lessons were welded to a linear script. Every one of
## these drawings was written, tuned and playtested for the opening tutorial and
## then became unreachable the moment it ended — a player who forgets how to
## chain in minute twelve got nothing, even though the game already owned a
## perfectly good animation of exactly that. Same reasoning, and the same
## static-on-a-CanvasItem shape, as Vein.draw_reach.
##
## Everything here takes an explicit `t` rather than reading a clock, so the
## caller owns the loop's phase and two overlays can never drift apart.

const LOOP_TIME := 2.4
const THUMB_R := 13.0
const CUT_ICON_CYCLE := 1.15
const CUT_BLADE_LEN := 26.0


static func _faint(col: Color, mult: float) -> Color:
	var f := col
	f.a = col.a * mult
	return f


static func _bezier(a: Vector2, c: Vector2, b: Vector2, t: float) -> Vector2:
	return a.lerp(c, t).lerp(c.lerp(b, t), t)


## A halo tracing the same shape family as `res`'s own demand glyph (see
## VNode.demand_glyph_points) at world position `center`, radius-ish scale `s`
## — the polygon case just needs the origin-centred points shifted into place;
## the circular RAW/VOID case (empty points) falls back to a plain arc at the
## identical proportion VNode itself draws that circle at.
static func shape_halo(ci: CanvasItem, center: Vector2, res: int, s: float,
		col: Color, width: float) -> void:
	var pts := VNode.demand_glyph_points(res, s)
	if pts.is_empty():
		var r := s * VNode.DEMAND_GLYPH_CIRCLE_RATIO
		ci.draw_arc(center, r, 0.0, TAU, VNode.arc_points(r), col, width, true)
		return
	var world := PackedVector2Array()
	for p in pts:
		world.append(p + center)
	ci.draw_polyline(world, col, width, true)


## A looping ghost drag: thumb fades in on the source, eases to the target
## leaving a breadcrumb trail, a ring lands on arrival — the exact motion the
## player's own thumb must make.
static func drag_ghost(ci: CanvasItem, from: Vector2, to: Vector2, t: float) -> void:
	var p := fmod(t, LOOP_TIME) / LOOP_TIME
	var chord := to - from
	var mid := (from + to) * 0.5 + chord.orthogonal().normalized() * chord.length() * 0.10

	var col := Palette.WARM
	if p < 0.12:
		col.a = p / 0.12 * 0.7
		ci.draw_circle(from, THUMB_R, _faint(col, 0.25))
		ci.draw_arc(from, THUMB_R, 0.0, TAU, VNode.arc_points(THUMB_R), col, 2.0, true)
		return

	if p < 0.72:
		var tt := (p - 0.12) / 0.60
		var eased := tt * tt * (3.0 - 2.0 * tt)
		var crumbs := int(eased * 9.0)
		for i in crumbs:
			var ct := eased * float(i + 1) / float(crumbs + 1)
			var cp := _bezier(from, mid, to, ct)
			var cc := Palette.WARM
			cc.a = 0.28
			ci.draw_circle(cp, 2.4, cc)
		var tip := _bezier(from, mid, to, eased)
		col.a = 0.7
		ci.draw_circle(tip, THUMB_R, _faint(col, 0.25))
		ci.draw_arc(tip, THUMB_R, 0.0, TAU, VNode.arc_points(THUMB_R), col, 2.0, true)
		return

	var t2 := (p - 0.72) / 0.28
	col.a = (1.0 - t2) * 0.8
	var rr := 40.0 + t2 * 18.0
	ci.draw_arc(to, rr, 0.0, TAU, VNode.arc_points(rr), col, 2.5 * (1.0 - t2) + 0.5, true)


## A bold scissor-cross sitting directly ON a point: this IS the "cut here"
## instruction, full stop. Feedback: the old fingertip-and-ripple version was
## too small and subtle to read as an instruction at all. This is unmissable —
## two thick blades, sized well past the vein's own width, that visibly snap
## shut on the point in a loop, with a bright snip flash at the moment of
## closure so the exact instant to tap is obvious even at a glance.
static func cut_ghost(ci: CanvasItem, at: Vector2, t: float) -> void:
	var cyc := fmod(t, CUT_ICON_CYCLE) / CUT_ICON_CYCLE
	# 0 = blades open wide, 1 = fully shut. Eased so the close reads as a snap.
	var close := clampf((cyc - 0.12) / 0.5, 0.0, 1.0)
	close = close * close * (3.0 - 2.0 * close)
	var half_angle := lerpf(0.95, 0.05, close)

	var warm := Palette.WARM
	var col := warm
	col.a = 0.95
	for sgn in [-1.0, 1.0]:
		var a: float = PI * 0.5 + sgn * half_angle
		var dir := Vector2(cos(a), sin(a))
		ci.draw_line(at - dir * CUT_BLADE_LEN, at + dir * CUT_BLADE_LEN, col, 5.0, true)

	var hinge := warm
	hinge.a = 0.9
	ci.draw_circle(at, 4.5, hinge)

	# The snip: once the blades are nearly shut, a bright ring and four short
	# radiating cut-marks flash outward — the moment of the cut is loud, not a
	# quiet detail you could miss.
	if close > 0.82:
		var ft := (close - 0.82) / 0.18
		var fcol := Palette.HEART
		fcol.a = (1.0 - ft) * 0.9
		ci.draw_circle(at, 8.0 + ft * 12.0, _faint(fcol, 0.4))
		for i in 4:
			var ang := TAU * float(i) / 4.0 + PI * 0.25
			var p0 := at + Vector2(cos(ang), sin(ang)) * (9.0 + ft * 5.0)
			var p1 := at + Vector2(cos(ang), sin(ang)) * (16.0 + ft * 16.0)
			var mc := fcol
			mc.a = (1.0 - ft) * 0.85
			ci.draw_line(p0, p1, mc, 2.4, true)
