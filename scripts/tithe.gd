extends Node2D
## The tithe — the last Well.
##
## When the Heart is close to death, the score itself becomes a node: a circle
## blooms around the running total and a ghosted vein reaches for the Heart —
## the game making, in its only language, the one move it ever makes:
## connecting supply to demand. Hold the Heart, the score-circle, or the
## ghost vein between them and the circle emits one dot per beat down that
## vein; each dot is score given back
## as fuel, at a loss (see game.gd's TITHE_INTEREST_START). You cannot buy
## forever — every purchase brings the end closer in absolute terms. In vain,
## literally.
##
## This node is purely presentational plus a dot store: game.gd owns every
## decision (when to offer, what a dot costs, what it pays) and drives this
## via offer()/retract()/inhale()/emit_dot()/advance() — the same
## division of labour Vein has with game.gd's _push_from_nodes/_deliver.
## Deliberately NOT a VNode and its path deliberately NOT a Vein: the score is
## not part of the sim (no corruption, no reach, no budget, no graph), and the
## offer must read as *proposed, not owned* — dashed, dimmer, uncuttable — so
## nothing here may accidentally join `nodes`/`veins` and start being counted
## by rescue guarantees or the probe.

## Dots FALL — twice a vein's crawl. Partly the read (this is blood dropping,
## not cargo routed), but mostly rescue math: the offer appears at
## TITHE_OFFER_MISSES and death lands at MISSES_FATAL, so the whole
## grab->windup->emit->travel pipeline has only a handful of slowed DYING
## beats to deliver its first fuel. At Vein.SPEED the score->Heart span
## (~430px) costs ~2.6s and the rescue arrives dead; at 2x it can land in
## time — if the player grabbed promptly. Late grabs still lose, on purpose.
const FALL_SPEED := Vein.SPEED * 2.0

## Circle drawn around the score numerals. Sized to swallow a 4-digit total
## at score_hud's 30px mono without the ring crossing the glyphs.
const CIRCLE_R := 40.0
## Grab radius around the circle's centre — deliberately wider than CIRCLE_R
## and a hair over game.gd's SNAP, same "imprecise thumbs feel precise"
## reasoning, and this is a panic gesture: the one moment precision is worst.
const GRAB := 56.0
## Grab corridor around the ghost vein itself — see hit_path.
const PATH_GRAB := 26.0

const SEG := 22
## Bloom/retract pacing, 1/s exponential-ish. Bloom is brisk (the invitation
## must land while it still matters); retract is calmer (danger passing is
## relief, not an event that needs the eye).
const GROW_RATE := 2.4
const RETRACT_RATE := 1.5

## Ghost-register alphas. The offer must sit BELOW every real vein in
## presence — Palette.SCORE ink at these levels reads as an annotation on the
## board, not a member of the network.
const RING_ALPHA := 0.34
const DASH_ALPHA := 0.24

var offered := false

var _grow := 0.0
## Windup contraction — the circle inhales on the first held beat, before
## anything is spent. See game.gd's _tick_tithe_beat: that grace beat is what
## turns an accidental hold into a near-miss lesson instead of a stealth tax.
var _inhale := 0.0
var _emit_flash := 0.0
var _swell := 0.0

var _score_pos := Vector2.ZERO
var _heart_pos := Vector2.ZERO
var _heart_r := 46.0

var pts := PackedVector2Array()
var _cum := PackedFloat32Array()
var _length := 0.0

## [{t, cost, fuel, worth}] — same lightweight structs-on-a-path scheme as
## Vein.dots. `worth` (0..1) dims later dots: rising interest means the same
## falling point buys visibly less life, and the dot itself should say so.
var dots: Array[Dictionary] = []

var _was_visible := false


func _ready() -> void:
	# Under score_hud (z 6): the ring frames the numerals, never covers them.
	z_index = 5
	Beat.beat.connect(func(_i: int) -> void: _swell = 1.0)


## Endpoints come from game.gd every frame (score anchor + Heart), not read
## off other nodes here — same "layout must not depend on the window" rule as
## design_size(): this path has to match wherever score_hud actually draws.
func sync(score_pos: Vector2, heart_pos: Vector2, heart_r: float) -> void:
	if score_pos.distance_to(_score_pos) < 0.5 \
			and heart_pos.distance_to(_heart_pos) < 0.5 and heart_r == _heart_r:
		return
	_score_pos = score_pos
	_heart_pos = heart_pos
	_heart_r = heart_r
	_rebuild()


## Quadratic Bézier from the circle's rim down to the Heart's rim — the same
## slightly-organic curve family as Vein.rebuild, fixed bend sign (there is
## only ever one of these; it doesn't need to avoid a twin).
func _rebuild() -> void:
	var p0 := _score_pos + Vector2(0.0, CIRCLE_R)
	var to_score := (p0 - _heart_pos).normalized()
	var p2 := _heart_pos + to_score * _heart_r
	var chord := p2 - p0
	var p1 := (p0 + p2) * 0.5 + chord.orthogonal().normalized() * chord.length() * 0.10

	pts.clear()
	for i in SEG + 1:
		var t := float(i) / float(SEG)
		pts.append(p0.lerp(p1, t).lerp(p1.lerp(p2, t), t))

	_cum.clear()
	_cum.append(0.0)
	_length = 0.0
	for i in pts.size() - 1:
		_length += pts[i].distance_to(pts[i + 1])
		_cum.append(_length)


func offer() -> void:
	offered = true


func retract() -> void:
	offered = false


## Death / new run: no retract animation, no lingering dots. The board is
## shattering or being rebuilt; a ghost offer floating over either is wrong.
func vanish() -> void:
	offered = false
	_grow = 0.0
	_inhale = 0.0
	_emit_flash = 0.0
	dots.clear()
	queue_redraw()


func hit(p: Vector2) -> bool:
	return offered and p.distance_to(_score_pos) <= GRAB


## A press anywhere along the ghost vein is also a grab — the offer is one
## gesture (score, path, Heart are a single proposed connection), and a thumb
## that lands mid-line is still clearly answering it. Radius is deliberately
## tighter than GRAB: the path crosses live board where real veins get cut,
## and a fat corridor there would swallow slices aimed at neighbours.
func hit_path(p: Vector2) -> bool:
	if not offered or pts.size() < 2:
		return false
	for i in pts.size() - 1:
		var q := Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])
		if q.distance_to(p) <= PATH_GRAB:
			return true
	return false


func inhale() -> void:
	_inhale = 1.0


func emit_dot(cost: int, fuel: float, worth: float) -> void:
	dots.append({"t": 0.0, "cost": cost, "fuel": fuel, "worth": worth})
	_emit_flash = 1.0


## Advance falling dots; return the ones that reached the Heart this frame,
## for game.gd to convert into fuel — mirror of Vein.advance/_deliver.
## Runs on the in-flight dots regardless of hold state: releasing stops
## EMISSION, never recalls what is already airborne (same commitment rule as
## a cut vein's in-flight cargo).
func advance(delta: float) -> Array[Dictionary]:
	var arrived: Array[Dictionary] = []
	if _length <= 0.0:
		return arrived
	var step := FALL_SPEED * delta / _length
	var keep: Array[Dictionary] = []
	for d in dots:
		d.t += step
		if d.t >= 1.0:
			arrived.append(d)
		else:
			keep.append(d)
	dots = keep
	return arrived


func _sample(t: float) -> Vector2:
	var target := clampf(t, 0.0, 1.0) * _length
	for i in _cum.size() - 1:
		if target <= _cum[i + 1]:
			var span := _cum[i + 1] - _cum[i]
			var f := 0.0 if span <= 0.0 else (target - _cum[i]) / span
			return pts[i].lerp(pts[i + 1], f)
	return pts[pts.size() - 1]


func _process(delta: float) -> void:
	if offered:
		_grow = Vein._smooth(_grow, 1.0, GROW_RATE, delta)
	else:
		_grow = Vein._smooth(_grow, 0.0, RETRACT_RATE, delta)
	_inhale = maxf(0.0, _inhale - delta * 2.6)
	_emit_flash = maxf(0.0, _emit_flash - delta * 3.4)
	_swell = maxf(0.0, _swell - delta * 4.0)

	# Same skip-when-idle discipline as game.gd's drain ColorRect: this node
	# exists for the whole run but only matters near death — don't pay a
	# redraw all run for it. One extra frame after going invisible clears the
	# last drawn state.
	var vis := _grow > 0.003 or not dots.is_empty()
	if vis or _was_visible:
		queue_redraw()
	_was_visible = vis


func _draw() -> void:
	if pts.size() < 2:
		return
	if _grow <= 0.003 and dots.is_empty():
		return

	var ink := Palette.SCORE

	# The circle: the score becoming a node. Dashed, never solid — a real
	# node's outline is owned; this one is proposed. Contracts on the windup
	# inhale, flashes on each emission, and swells gently on the beat so it
	# reads as part of the organism, same trick as score_hud.
	var r := CIRCLE_R * (1.0 - _inhale * 0.12 + _swell * 0.03)
	var ring := ink
	ring.a = (RING_ALPHA + _emit_flash * 0.30 + _swell * 0.08) * _grow
	var spin := float(Time.get_ticks_msec()) * 0.0002
	const DASHES := 10
	for i in DASHES:
		var a0 := spin + TAU * float(i) / float(DASHES)
		draw_arc(_score_pos, r, a0, a0 + TAU / float(DASHES) * 0.62, 6, ring, 1.6, true)

	# The offer vein, growing from the score TOWARD the Heart — supply
	# reaching for demand, the direction the blood will actually fall.
	# Dashed via every-other-segment, half the ink of a real idle vein.
	var line := ink
	line.a = DASH_ALPHA * _grow
	var last := int(floor(float(pts.size() - 1) * _grow))
	for i in last:
		if i % 2 == 0:
			draw_line(pts[i], pts[i + 1], line, 2.0, true)

	# Falling dots: the score's own near-white ink, not a resource tint —
	# this blood is made of points. `worth` dims what interest has cheapened.
	for d in dots:
		var p := _sample(float(d.t))
		var w := float(d.worth)
		var halo := ink
		halo.a = 0.16 * w
		var core := ink
		core.a = clampf(0.35 + 0.65 * w, 0.0, 1.0)
		draw_circle(p, 7.0, halo)
		draw_circle(p, 3.4, core)
