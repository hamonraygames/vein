extends Node2D
## The ring's proposal: "one more vein and this becomes that."
##
## This is the whole teaching apparatus for the mechanic, and it is
## deliberately the only one. When the board is one vein short of a closed
## ring of orphaned Wells (see Ring.find_pending), the missing edge appears as
## a dashed ghost and the shape those circles would become breathes at the
## centre of them. The player sees a triangle wanting to exist, draws the one
## line, and gets a triangle. The lesson and the moment of decision are the
## same instant — which is more than rage ever gets, and rage is understood.
##
## Presentational only: game.gd's _update_ring_tell decides what (if
## anything) is proposed, this decides nothing. It is also
## deliberately NOT a Vein and NOT a VNode — nothing here may end up in
## `nodes`/`veins` and start being counted by the rescue guarantees, the
## budget, or the probe.
##
## Ghost register: dimmer than any real vein, dashed where a real one is
## solid, so "proposed, not owned" reads without a word.

const SEG := 20
const GROW_RATE := 2.4
const RETRACT_RATE := 1.5

const RING_ALPHA := 0.34
const DASH_ALPHA := 0.24

## Dash geometry on the missing edge, in px along the curve.
const DASH := 11.0
const DASH_GAP := 8.0

## The glyph at the centre, as a multiple of a real node's radius. Larger than
## the node it previews on purpose — it is an announcement, not a to-scale
## mockup, and it has to survive being read across a busy board.
const GLYPH_SCALE := 1.5
## Breath. Slow and shallow: this is an invitation sitting there waiting, not
## an alarm. Frequency well under the Heart's own pulse so the two never look
## like they are saying the same thing.
const BREATH_AMP := 0.09
const BREATH_FREQ := 1.5

## The first ring a player is ever offered gets a harder sell — brighter, and
## breathing wider — because that one has to carry the entire rule on its own.
## Every one after it is a reminder, not a lesson.
const FIRST_BOOST := 0.5

var _ring: Array[VNode] = []
var _from: VNode
var _to: VNode
var _res := VNode.Res.REFINED
var _first := false

var _grow := 0.0
var _t := 0.0


## `d` is Ring.find_pending's result, or {} for nothing on offer.
func offer(d: Dictionary, seen_before: bool) -> void:
	if d.is_empty():
		clear()
		return
	_ring = d["ring"]
	_from = d["from"]
	_to = d["to"]
	_res = Ring.res_for_kind(d["kind"])
	_first = not seen_before


func clear() -> void:
	_ring = []
	_from = null
	_to = null


func _offered() -> bool:
	return _from != null


## Every reference here is to a live board object that can wither, corrupt or
## be cut between graph rebuilds, so nothing is trusted across a frame.
func _valid() -> bool:
	if not _offered():
		return false
	if not is_instance_valid(_from) or not is_instance_valid(_to):
		return false
	for n in _ring:
		if not Ring.usable(n):
			return false
	return true


func _process(delta: float) -> void:
	if not _valid():
		clear()
	var target := 1.0 if _offered() else 0.0
	var rate := GROW_RATE if _offered() else RETRACT_RATE
	_grow = Vein._smooth(_grow, target, rate, delta)
	# Fully retracted and nothing on offer: stop drawing entirely rather than
	# animating a transparent overlay every frame for the rest of the run.
	if _grow <= 0.002 and not _offered():
		if _t != 0.0:
			_t = 0.0
			queue_redraw()
		return
	_t += delta
	queue_redraw()


func _draw() -> void:
	if _grow <= 0.002 or not _valid():
		return
	var boost := FIRST_BOOST if _first else 0.0
	var col := Palette.of_res(_res)

	# 1. Which veins are part of this. On a busy board the ring is not
	#    obvious, and a proposal the player cannot locate teaches nothing.
	var lit := col
	lit.a = RING_ALPHA * _grow * (1.0 + boost) * 0.7
	for i in _ring.size():
		var a: VNode = _ring[i]
		var b: VNode = _ring[(i + 1) % _ring.size()]
		if (a == _from and b == _to) or (a == _to and b == _from):
			continue
		draw_line(a.position, b.position, lit, 3.0, true)

	# 2. The missing edge, dashed — the one line that isn't there yet.
	var dash := col
	dash.a = DASH_ALPHA * _grow * (1.0 + boost * 1.6)
	_draw_dashed(_bow(_from.position, _to.position), dash)

	# 3. What they become, at the centre of them. The ring's own outline
	#    already draws the polygon through the Wells themselves (that IS the
	#    veins), so this only has to answer "and then what" — the shape as an
	#    object, sitting where it will actually be born.
	var glyph := col
	glyph.a = (0.30 + 0.22 * _grow) * _grow * (1.0 + boost)
	var breath := 1.0 + BREATH_AMP * (1.0 + boost) * sin(_t * BREATH_FREQ)
	var s := VNode.RADIUS * GLYPH_SCALE * breath * _grow
	var at := Ring.centroid(_ring)
	var pts := VNode.demand_glyph_points(_res, s)
	if pts.is_empty():
		return
	var shifted := PackedVector2Array()
	for p in pts:
		shifted.append(p + at)
	draw_polyline(shifted, glyph, 2.6, true)


## The same quadratic bow Vein.rebuild gives every real vein, so the proposal
## sits in the board's geometry rather than cutting a straight line across it.
## Bend sign is always positive here — which side _add_vein would actually
## alternate to is not knowable before the vein exists, and at this alpha the
## difference is invisible.
func _bow(p0: Vector2, p2: Vector2) -> PackedVector2Array:
	var chord := p2 - p0
	var p1 := (p0 + p2) * 0.5 + chord.orthogonal().normalized() * chord.length() * 0.10
	var out := PackedVector2Array()
	for i in SEG + 1:
		var t := float(i) / float(SEG)
		out.append(p0.lerp(p1, t).lerp(p1.lerp(p2, t), t))
	return out


## Walks the curve by arc length so dashes stay evenly spaced regardless of
## how the Bezier bunches its samples.
func _draw_dashed(path: PackedVector2Array, col: Color) -> void:
	var carry := 0.0
	var drawing := true
	for i in path.size() - 1:
		var a := path[i]
		var b := path[i + 1]
		var seg := a.distance_to(b)
		if seg <= 0.0:
			continue
		var pos := 0.0
		while pos < seg:
			var want := (DASH if drawing else DASH_GAP) - carry
			var step := minf(want, seg - pos)
			if drawing:
				draw_line(a.lerp(b, pos / seg), a.lerp(b, (pos + step) / seg),
					col, 2.4, true)
			pos += step
			carry += step
			if carry >= (DASH if drawing else DASH_GAP) - 0.0001:
				drawing = not drawing
				carry = 0.0
