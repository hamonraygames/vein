extends Node2D
class_name Vein
## A drawn connection. Resources ease along it, always downhill toward demand.
##
## Veins are not straight lines — they are slightly organic Béziers that thicken
## with flow. At full health the screen should read as a living circulatory
## diagram, not a graph.

const SPEED := 168.0        # px/sec. Long veins are slow veins — that is the cost.

## Minimum gap between items, which sets a vein's throughput at SPEED/DOT_SPACING
## items per second. This number is the whole difficulty curve: at 15px a vein
## carried ~11/s against a Well's 0.69/s, so no trunk could ever be overloaded
## and layout was free. Measured peak occupancy under a naive nearest-first
## chain: 0.72 at 46px — close but never bursting. At 60px a trunk tops out
## near four Wells, so *which hub you route through* finally costs something.
const DOT_SPACING := 60.0
const SEG := 22
const HIT_RADIUS := 18.0

## A vein cannot span more than this. Without it the network is a free tree —
## every Well costs exactly one vein however you arrange it, straight-to-the-Heart
## is never worse, and layout is meaningless. The cap forces distant Wells to
## chain through nearer ones, which makes trunks shared, which makes RUPTURE_AT
## bite, which is where the actual puzzle lives.
##
## Must stay well under the playfield's short axis (540). At 300 the Heart still
## reached a third of the board and could take unlimited direct links, so load
## never concentrated and nothing ever ruptured.
const MAX_LEN := 200.0

## How long a vein may sit under backpressure before it bursts.
##
## Strain is measured as backpressure — a full backlog upstream that this vein
## cannot clear — and NOT as an occupancy threshold. Occupancy
## (dots * DOT_SPACING / length) is length-dependent: a short vein only has room
## for two dots, so it reads as saturated while carrying a single Well, and leaf
## links were bulging red and bursting for no reason. Backpressure is
## length-independent and is exactly what "carrying more than it can bear" means.
##
## This MUST exceed the time to drain one full buffer, or connecting an orphaned
## Well bursts its own fresh vein: an orphan sits at VNode.BUFFER_CAP, and
## clearing it takes BUFFER_CAP / (SPEED/DOT_SPACING - 1/WELL_PERIOD) ~= 2.9s,
## which at 2.5s meant every new link ruptured on contact. Keep roughly 2x that
## drain time so only sustained oversubscription bursts.
const RUPTURE_TIME := 6.0

signal ruptured(vein: Vein)

enum Dir { INERT, A_TO_B, B_TO_A }

var a: VNode
var b: VNode
var dir: int = Dir.INERT

var pts := PackedVector2Array()
var cum := PackedFloat32Array()
var length := 0.0

## [{kind:int, t:float}] — lightweight structs on a path, not physics bodies.
## The whole sim is deterministic given a seed.
var dots: Array[Dictionary] = []

var _bend := 1.0
var _flow := 0.0    # 0..1 smoothed, drives width and brightness
## Seconds spent over-carrying. Shown as a bulge and a darkening long before it
## bursts, so a rupture is always something the player was warned about.
var stress := 0.0
## Highest occupancy this vein ever reached. Diagnostic only — the probe reads it
## to answer "did any trunk ever come near its limit?"
var peak_occupancy := 0.0
var peak_stress := 0.0
var _blocked := false


func setup(from: VNode, to: VNode, bend_sign: float) -> void:
	a = from
	b = to
	_bend = bend_sign
	z_index = 0
	rebuild()


func rebuild() -> void:
	var p0 := a.position
	var p2 := b.position
	var chord := p2 - p0
	var mid := (p0 + p2) * 0.5
	var p1 := mid + chord.orthogonal().normalized() * chord.length() * 0.10 * _bend

	pts.clear()
	for i in SEG + 1:
		var t := float(i) / float(SEG)
		pts.append(p0.lerp(p1, t).lerp(p1.lerp(p2, t), t))

	cum.clear()
	cum.append(0.0)
	length = 0.0
	for i in pts.size() - 1:
		length += pts[i].distance_to(pts[i + 1])
		cum.append(length)


func other(n: VNode) -> VNode:
	if n == a:
		return b
	if n == b:
		return a
	return null


## Flow is decided by the graph, not by the direction the player happened to drag.
func update_dir() -> void:
	if a.depth < 0 or b.depth < 0 or a.depth == b.depth:
		dir = Dir.INERT
	elif a.depth > b.depth:
		dir = Dir.A_TO_B
	else:
		dir = Dir.B_TO_A


func source() -> VNode:
	match dir:
		Dir.A_TO_B: return a
		Dir.B_TO_A: return b
	return null


func sink() -> VNode:
	match dir:
		Dir.A_TO_B: return b
		Dir.B_TO_A: return a
	return null


func has_room() -> bool:
	if dir == Dir.INERT or length <= 0.0:
		return false
	for d in dots:
		if d.t * length < DOT_SPACING:
			return false
	return true


func inject(kind: int) -> bool:
	if not has_room():
		return false
	dots.append({"kind": kind, "t": 0.0})
	return true


## Called by the game when a source node had material waiting and this vein would
## not take it. Sustained refusal is what a rupture actually is.
func note_blocked() -> void:
	_blocked = true


func sample(t: float) -> Vector2:
	var target := clampf(t, 0.0, 1.0) * length
	for i in cum.size() - 1:
		if target <= cum[i + 1]:
			var span := cum[i + 1] - cum[i]
			var f := 0.0 if span <= 0.0 else (target - cum[i]) / span
			return pts[i].lerp(pts[i + 1], f)
	return pts[pts.size() - 1]


## Returns items that reached the far end this frame, for the game to hand over.
func advance(delta: float) -> Array[int]:
	var arrived: Array[int] = []
	if dir == Dir.INERT or length <= 0.0:
		_flow = _smooth(_flow, 0.0, 4.0, delta)
		queue_redraw()
		return arrived

	var step := SPEED * delta / length
	var keep: Array[Dictionary] = []
	for d in dots:
		d.t += step
		if d.t >= 1.0:
			arrived.append(d.kind)
		else:
			keep.append(d)
	dots = keep

	var occupancy := clampf(float(dots.size()) * DOT_SPACING / maxf(length, 1.0), 0.0, 1.0)
	peak_occupancy = maxf(peak_occupancy, occupancy)
	_flow = _smooth(_flow, occupancy, 3.0, delta)

	if _blocked:
		stress += delta
		peak_stress = maxf(peak_stress, stress)
		if stress >= RUPTURE_TIME:
			stress = 0.0
			ruptured.emit(self)
	else:
		# Relief is faster than strain: easing a trunk should visibly rescue it.
		stress = maxf(0.0, stress - delta * 1.6)
	_blocked = false

	queue_redraw()
	return arrived


## 0..1 — how close this vein is to bursting.
func strain() -> float:
	return clampf(stress / RUPTURE_TIME, 0.0, 1.0)


## Frame-rate-independent smoothing. A plain `lerp(a, b, rate * delta)` overshoots
## once `rate * delta > 1` — which the probe's 60x time scale hits immediately —
## and drove `_flow` negative, then polyline widths negative. This never leaves
## the a..b interval no matter how large `delta` gets.
static func _smooth(from: float, to: float, rate: float, delta: float) -> float:
	return lerpf(from, to, 1.0 - exp(-rate * maxf(delta, 0.0)))


func distance_to_point(p: Vector2) -> float:
	var best := INF
	for i in pts.size() - 1:
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])))
	return best


func _draw() -> void:
	if pts.size() < 2:
		return

	var col: Color
	var width := 3.0
	if dir == Dir.INERT:
		# A vein that connects nothing to nothing. It cost a budget point and it
		# does nothing — the player should be able to see that at a glance.
		col = Palette.VEIN_INERT
	else:
		col = Palette.VEIN_IDLE.lerp(Palette.VEIN_LIVE, _flow)
		width += _flow * 4.5

	# Over-carrying: the vein bulges and darkens, and the throb quickens as it
	# nears bursting. This is the only warning, and it has to be felt as dread
	# rather than read as a gauge.
	var s := strain()
	if s > 0.0:
		var throb := 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) * 0.001 * (6.0 + s * 14.0))
		col = col.lerp(Palette.VEIN_STRAINED, 0.35 + s * 0.65)
		width += s * (3.0 + throb * 3.5)

	draw_polyline(pts, col, width, true)

	for d in dots:
		var p := sample(d.t)
		var c := Palette.of_res(d.kind)
		var halo := c
		halo.a = 0.16
		draw_circle(p, 7.0, halo)
		draw_circle(p, 3.4, c)


## Sink-side easing: items accelerate into a node — they are being swallowed.
static func ease_in(t: float) -> float:
	return t * t
