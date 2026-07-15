extends Node2D
class_name VNode
## A node in the circulatory diagram: the Heart, or a Well that feeds it.
##
## Shape is the type. Motion is the throughput. Nothing here is ever labelled.

enum Kind { HEART, WELL, FORGE, LOOM, BOOST }
enum Res { RAW, REFINED, CLOTH, VOID }

## Tools condense two inputs into one stronger output. A Forge eats RAW and makes
## REFINED; a Loom eats REFINED and makes CLOTH.
const TOOL_RATIO := 2

## Items a Well holds before it runs dry. Depletion is by USE, not by clock:
## a Well only spends reserve when it actually emits, and it only emits when
## something downstream will take the item. So the trunk you lean on hardest is
## the one that dies first, and an unconnected Well keeps its reserve forever.
## That is the whole enemy design — every strength eats itself.
const WELL_YIELD := 72.0

## A spent Well does not politely stop. It goes necrotic and starts pumping VOID
## down the vein you built to it, faster than it ever gave you RAW. You must cut
## it — which costs you the throughput you had come to depend on.
const CORRUPT_PERIOD := 1.0

## Seconds a corrupted node takes to rot its live neighbours. Neglect cascades,
## and it cascades fast enough that hesitating costs you the limb.
const SPREAD_TIME := 12.0

## A necrotic node that is never cut eventually collapses outright — you don't
## just get to sit on a dead Well forever, poisoning at your leisure and never
## paying for it. This is what makes rot "come and go" instead of accumulating
## as permanent board clutter: ignore it long enough and the asset itself is
## gone, on top of whatever it already cost you.
const COLLAPSE_TIME := 16.0
## Fraction of COLLAPSE_TIME at which visible fading begins — the collapse
## equivalent of WITHER_WARN_AT below.
const COLLAPSE_FADE_AT := 0.6

## An orphaned Well (nothing downstream will ever take what it makes) that sits
## unconnected this long withers and vanishes. Without this the board only ever
## grows — every Well you don't use becomes permanent scenery, and playtest read
## that as "lazy" and static. Wells you ignore are USE-IT-OR-LOSE-IT, which also
## means the board keeps turning over instead of just filling up.
##
## 26s was measured (via the probe's cumulative `withered` counter, added
## because the live node count alone hid this) to be a severe economy bug, not
## a pacing fix: budget grows far slower than Wells spawn BY DESIGN — that gap
## is the core scarcity puzzle, and having more Wells on the board than you can
## currently afford is the normal, intended state, not neglect. At 26s the bot
## lost 5-11 Wells a run to wither before it ever got a chance at them, and
## survival collapsed from ~185 beats to ~120. 70s clears a full budget tier
## (BUDGET_GAP_START=24 plus growth) with room to spare, so wither only ever
## catches a Well nobody was ever going to route to, not the normal backlog.
const WITHER_TIME := 70.0
## Fraction of WITHER_TIME at which visible fading begins, so vanishing is
## always something you saw coming, never a surprise deletion.
const WITHER_WARN_AT := 0.6

const RADIUS := 22.0
const HEART_RADIUS := 34.0
const BOOST_RADIUS := 16.0
const BUFFER_CAP := 6

## What a Well produces, in seconds. Deliberately not beat-locked: wells drift
## against the heartbeat, so supply and demand slide in and out of phase.
const WELL_PERIOD := 1.45

var kind: int = Kind.WELL
var produces: int = Res.RAW

## Distance to the Heart over the vein graph. -1 means orphaned — nothing this
## node makes can reach anything that wants it.
var depth := -1

## Items waiting here for an outgoing vein with room. When this fills, a Well
## stops producing and the pips stack up visibly.
var buffer: Array[int] = []

## Forge only: RAW waiting to be smelted. Separate from `buffer` so a Forge's
## backlog of input doesn't block the REFINED it has already made.
var intake: Array[int] = []

## 0..1, decays. Drives the swell when the node emits or consumes.
var pulse := 0.0

## Items left in a Well. Drawn as the ring itself, so a Well literally erodes
## away as you drain it — you can see which of your lifelines is nearly gone
## without a number, and plan the reroute before it kills you.
var reserve := WELL_YIELD
var corrupted := false
## 0..1, decays. The visible "two went in, one came out" moment.
var smelt_flash := 0.0
## Seconds this node has been rotting its neighbours.
var spread_accum := 0.0
## Seconds this node has been corrupted, total. Drives COLLAPSE_TIME.
var corrupt_age := 0.0
## Seconds this Well has sat orphaned (depth < 0). Drives WITHER_TIME. Reset to
## 0 the instant it joins the network, even briefly — only NEGLECT withers.
var orphan_age := 0.0

## Boost only: which effect this pickup grants. Assigned by the game at spawn so
## the roll comes from the seeded run RNG and stays deterministic.
var boost_effect: int = 0

## Heart only: how full it is, 0..1. Drawn as a level inside the hexagon so the
## goal of the game is legible on sight — the vessel is emptying, fill it. This
## is the one thing the player must understand and it must never need a number.
var fuel_ratio := 1.0

## Heart only: the shape it is asking for. Drawn as a glyph inside the hexagon,
## which is the entire teaching mechanism for Forges — the Heart visibly wants a
## triangle, and the only thing on the board that makes triangles is the triangle
## node. No text, no tutorial, no red-triangle mystery.
var demand: int = Res.RAW

var _emit_accum := 0.0
var _round_robin := 0
var _boost_pulse := 0.0


func _ready() -> void:
	z_index = 10
	Beat.beat.connect(_on_beat)


func radius() -> float:
	if kind == Kind.HEART:
		return HEART_RADIUS
	if kind == Kind.BOOST:
		return BOOST_RADIUS
	return RADIUS


func _on_beat(_i: int) -> void:
	if kind == Kind.HEART:
		# The Heart's swell IS the beat.
		pulse = 1.0


func _process(delta: float) -> void:
	pulse = maxf(0.0, pulse - delta * 3.2)
	smelt_flash = maxf(0.0, smelt_flash - delta * 2.4)
	if kind == Kind.WELL or corrupted:
		_emit_accum += delta
		var period := CORRUPT_PERIOD if corrupted else WELL_PERIOD
		if _emit_accum >= period:
			_emit_accum -= period
			_emit()
	elif kind == Kind.FORGE or kind == Kind.LOOM:
		_smelt()

	if corrupted:
		corrupt_age += delta
	if kind == Kind.WELL and not corrupted:
		if depth < 0:
			orphan_age += delta
		else:
			orphan_age = 0.0

	# A single modulate fade covers every draw call below, so withering/collapse
	# never needs touching each shape's alpha by hand. Nothing fades before the
	# warn point — the whole point is that vanishing is never a surprise.
	var fade := 1.0
	var wr := wither_ratio()
	if wr > WITHER_WARN_AT:
		fade = 1.0 - (wr - WITHER_WARN_AT) / (1.0 - WITHER_WARN_AT)
	var cr := collapse_ratio()
	if cr > COLLAPSE_FADE_AT:
		fade = minf(fade, 1.0 - (cr - COLLAPSE_FADE_AT) / (1.0 - COLLAPSE_FADE_AT))
	modulate.a = clampf(fade, 0.0, 1.0)

	if kind == Kind.BOOST:
		_boost_pulse += delta
		pulse = maxf(pulse, 0.35 + 0.35 * sin(_boost_pulse * 3.4))

	queue_redraw()


## 0..1 toward collapse. Game reads this to know when to remove the node.
func collapse_ratio() -> float:
	return clampf(corrupt_age / COLLAPSE_TIME, 0.0, 1.0) if corrupted else 0.0


## 0..1 toward withering away from neglect.
func wither_ratio() -> float:
	if kind != Kind.WELL or corrupted or depth >= 0:
		return 0.0
	return clampf(orphan_age / WITHER_TIME, 0.0, 1.0)


func _emit() -> void:
	if buffer.size() >= BUFFER_CAP:
		return
	if corrupted:
		buffer.append(Res.VOID)
		pulse = 1.0
		return
	buffer.append(produces)
	pulse = 1.0
	# Reserve is only spent on an item that actually left, so a Well backed up
	# behind a full buffer is not quietly bleeding out.
	reserve -= 1.0
	if reserve <= 0.0:
		corrupt()


func corrupt() -> void:
	if corrupted:
		return
	corrupted = true
	reserve = 0.0
	produces = Res.VOID
	# Whatever it was still holding turns with it.
	buffer.clear()
	intake.clear()
	pulse = 1.0


## Reverses corrupt(). Only ever called by a CLEANSE boost — the sole way rot
## is ever undone rather than merely amputated or outrun.
func uncorrupt() -> void:
	if not corrupted:
		return
	corrupted = false
	reserve = WELL_YIELD
	produces = Res.RAW
	corrupt_age = 0.0
	spread_accum = 0.0
	pulse = 1.0


func reserve_ratio() -> float:
	if kind != Kind.WELL or corrupted:
		return 0.0
	return clampf(reserve / WELL_YIELD, 0.0, 1.0)


func take(kind_in: int) -> bool:
	# Tools cannot launder rot into food — VOID passes straight through them and
	# on to the Heart, so routing poison through equipment is not an escape hatch.
	if _accepts_tool_input(kind_in):
		if intake.size() >= BUFFER_CAP:
			return false
		intake.append(kind_in)
		return true
	if buffer.size() >= BUFFER_CAP:
		return false
	buffer.append(kind_in)
	pulse = maxf(pulse, 0.6)
	return true


func _accepts_tool_input(kind_in: int) -> bool:
	return not corrupted and (
		(kind == Kind.FORGE and kind_in == Res.RAW)
		or (kind == Kind.LOOM and kind_in == Res.REFINED)
	)


## Two in, one stronger shape out. The conversion halves the item count carrying
## the same run of fuel, which is why a tool is the answer to a bursting trunk
## and not just a fuel multiplier.
func _smelt() -> void:
	if intake.size() < TOOL_RATIO or buffer.size() >= BUFFER_CAP:
		return
	for i in TOOL_RATIO:
		intake.pop_front()
	buffer.append(produces)
	pulse = 1.0
	# The moment two become one, made loud. A tool that silently swaps pips
	# teaches nothing — it just sits there as an unexplained red triangle, which
	# is exactly how it read in playtest.
	smelt_flash = 1.0
	Audio.play("refined", -20.0, 1.35)


## Round-robin so a node with two downhill veins splits its output between them
## instead of starving one.
func next_out(count: int) -> int:
	_round_robin = (_round_robin + 1) % maxi(count, 1)
	return _round_robin


func _draw() -> void:
	var col := Palette.HEART if kind == Kind.HEART else Palette.of_res(produces)
	var r := radius() * (1.0 + pulse * (0.16 if kind == Kind.HEART else 0.10))

	match kind:
		Kind.HEART: _draw_hex(r, col)
		Kind.FORGE: _draw_tri(r, col)
		Kind.LOOM: _draw_square(r, col)
		Kind.BOOST: _draw_boost(r)
		_: _draw_ring(r, col)

	_draw_buffer(r, col)
	_draw_intake(r)


func _draw_hex(r: float, col: Color) -> void:
	var hex := PackedVector2Array()
	for i in 6:
		var a := TAU * (float(i) / 6.0) - PI * 0.5
		hex.append(Vector2(cos(a), sin(a)) * r)

	# A dim wash so an empty Heart is still a shape, not a hole.
	var base := col
	base.a = 0.07 + pulse * 0.10
	draw_colored_polygon(hex, base)

	# The level itself: clip the hexagon to everything below the fuel line. A
	# falling waterline is read instantly and without instruction; a bar or a
	# number would be neither.
	if fuel_ratio > 0.001:
		var line_y := r - 2.0 * r * clampf(fuel_ratio, 0.0, 1.0)
		var below := PackedVector2Array([
			Vector2(-r, line_y), Vector2(r, line_y), Vector2(r, r), Vector2(-r, r),
		])
		var fill := col
		fill.a = 0.34 + pulse * 0.34
		for poly in Geometry2D.intersect_polygons(hex, below):
			draw_colored_polygon(poly, fill)

	var outline := hex.duplicate()
	outline.append(hex[0])
	draw_polyline(outline, col, 3.0, true)

	_draw_demand(r)


## The shape the Heart is asking for, floating inside it. This is the only
## instruction VEIN ever gives, and it gives it wordlessly.
func _draw_demand(r: float) -> void:
	var c: Color = Palette.of_res(demand)
	c.a = 0.85 + pulse * 0.15
	var s := r * 0.34

	match demand:
		Res.REFINED:
			var tri := PackedVector2Array()
			for i in 3:
				var a := TAU * (float(i) / 3.0) - PI * 0.5
				tri.append(Vector2(cos(a), sin(a)) * s * 1.2)
			tri.append(tri[0])
			draw_polyline(tri, c, 2.4, true)
		Res.CLOTH:
			draw_rect(Rect2(-s * 0.8, -s * 0.8, s * 1.6, s * 1.6), c, false, 2.4)
		_:
			draw_arc(Vector2.ZERO, s * 0.85, 0.0, TAU, 22, c, 2.4, true)


func _draw_ring(r: float, col: Color) -> void:
	if corrupted:
		_draw_necrotic(r)
		return

	var fill := col
	fill.a = 0.10 + pulse * 0.22
	draw_circle(Vector2.ZERO, r, fill)

	# The ring IS the reserve. A full Well is a closed circle; a drained one is a
	# vanishing arc. No number, and you can read your whole board's life
	# expectancy in one glance.
	var ghost := col
	ghost.a = 0.13
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, ghost, 2.0, true)

	var left := reserve_ratio()
	if left > 0.0:
		var start := -PI * 0.5
		draw_arc(Vector2.ZERO, r, start, start + TAU * left, 32, col, 2.5, true)


## A Boost: a four-pointed star that never stops twinkling, the one shape on the
## board that is not part of the circulatory system. Distinctness IS the message
## — it does not carry, buffer, or demand; it is a gift, and it disappears the
## instant a vein reaches it.
func _draw_boost(r: float) -> void:
	var s := r * 1.35
	var spin := float(Time.get_ticks_msec()) * 0.0011
	var pts := PackedVector2Array()
	for i in 8:
		var a := TAU * (float(i) / 8.0) + spin
		var rr := s if i % 2 == 0 else s * 0.34
		pts.append(Vector2(cos(a), sin(a)) * rr)
	pts.append(pts[0])

	var fill := Palette.BOOST
	fill.a = 0.16 + pulse * 0.3
	draw_colored_polygon(pts, fill)
	var edge := Palette.BOOST
	edge.a = 0.7 + pulse * 0.3
	draw_polyline(pts, edge, 2.2 + pulse * 1.6, true)

	# A slow halo ring, always present, so a Boost reads as "special" even from
	# across the board before the player is close enough to see the star.
	var halo := Palette.BOOST
	halo.a = 0.10 + 0.06 * sin(spin * 2.3)
	draw_arc(Vector2.ZERO, r * 2.0, 0.0, TAU, 28, halo, 1.4, true)


## A spent Well, gone necrotic: cold, jagged, and beating out of time with you.
func _draw_necrotic(r: float) -> void:
	var wobble := 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) * 0.004)
	var fill := Palette.VOID_DIM
	fill.a = 0.55 + pulse * 0.35
	draw_circle(Vector2.ZERO, r * (0.9 + pulse * 0.15), fill)

	var spikes := PackedVector2Array()
	for i in 14:
		var a := TAU * (float(i) / 14.0)
		var rr := r * (1.18 if i % 2 == 0 else 0.72 - wobble * 0.08)
		spikes.append(Vector2(cos(a), sin(a)) * rr)
	spikes.append(spikes[0])
	draw_polyline(spikes, Palette.VOID, 2.0, true)


## A Forge. Playtest: "what is the red triangle, I don't know what it's about."
##
## Two failures, both mine. A hard-edged red triangle is a universal HAZARD sign,
## so the factory wore the costume of a warning — now that VOID owns danger
## (cold violet), a Forge is drawn dimmer and softer when idle so it reads as
## equipment rather than an alarm. And it never demonstrated itself: it silently
## swapped pips. The smelt is now an event you can see and hear.
func _draw_tri(r: float, col: Color) -> void:
	var tri := PackedVector2Array()
	for i in 3:
		var a := TAU * (float(i) / 3.0) - PI * 0.5
		tri.append(Vector2(cos(a), sin(a)) * r * (1.25 + smelt_flash * 0.12))

	var fill := col
	fill.a = 0.07 + pulse * 0.20 + smelt_flash * 0.45
	draw_colored_polygon(tri, fill)

	var edge := col
	# Idle equipment sits back; a working Forge lights up.
	edge.a = 0.45 + pulse * 0.3 + smelt_flash * 0.55
	var outline := tri.duplicate()
	outline.append(tri[0])
	draw_polyline(outline, edge, 2.5 + smelt_flash * 2.0, true)

	_draw_forge_recipe(r)

	# The output leaving: a ring blooming outward on the beat it was made.
	if smelt_flash > 0.0:
		var halo := Palette.REFINED
		halo.a = smelt_flash * 0.7
		draw_arc(Vector2.ZERO, r * (1.3 + (1.0 - smelt_flash) * 1.1), 0.0, TAU, 26,
			halo, 2.0 + smelt_flash * 2.0, true)


## A Loom. It is intentionally calm and orthogonal against the Forge's point: a
## new silhouette for a deeper strategic ask.
func _draw_square(r: float, col: Color) -> void:
	var side := r * (1.65 + smelt_flash * 0.14)
	var rect := Rect2(Vector2(-side * 0.5, -side * 0.5), Vector2(side, side))

	var fill := col
	fill.a = 0.06 + pulse * 0.16 + smelt_flash * 0.38
	draw_rect(rect, fill, true)

	var edge := col
	edge.a = 0.42 + pulse * 0.28 + smelt_flash * 0.52
	draw_rect(rect, edge, false, 2.5 + smelt_flash * 2.0)

	_draw_loom_recipe(r)

	if smelt_flash > 0.0:
		var halo := Palette.CLOTH
		halo.a = smelt_flash * 0.66
		var h := side * (0.72 + (1.0 - smelt_flash) * 0.55)
		draw_rect(Rect2(Vector2(-h, -h), Vector2(h * 2.0, h * 2.0)), halo, false,
			2.0 + smelt_flash * 2.0)


func _draw_forge_recipe(r: float) -> void:
	var a := 0.42 + smelt_flash * 0.35
	var raw := Palette.RAW
	raw.a = a
	draw_circle(Vector2(-r * 0.28, r * 0.16), 3.0, raw)
	draw_circle(Vector2(r * 0.28, r * 0.16), 3.0, raw)

	var out := Palette.REFINED
	out.a = 0.58 + smelt_flash * 0.32
	_draw_mini_tri(Vector2.ZERO + Vector2(0.0, -r * 0.16), r * 0.18, out, 1.7)


func _draw_loom_recipe(r: float) -> void:
	var refined := Palette.REFINED
	refined.a = 0.42 + smelt_flash * 0.35
	_draw_mini_tri(Vector2(-r * 0.25, r * 0.15), r * 0.13, refined, 1.4)
	_draw_mini_tri(Vector2(r * 0.25, r * 0.15), r * 0.13, refined, 1.4)

	var cloth := Palette.CLOTH
	cloth.a = 0.58 + smelt_flash * 0.32
	_draw_mini_square(Vector2(0.0, -r * 0.16), r * 0.16, cloth, 1.7)


func _draw_mini_tri(center: Vector2, size: float, col: Color, width: float) -> void:
	var tri := PackedVector2Array()
	for i in 3:
		var a := TAU * (float(i) / 3.0) - PI * 0.5
		tri.append(center + Vector2(cos(a), sin(a)) * size)
	tri.append(tri[0])
	draw_polyline(tri, col, width, true)


func _draw_mini_square(center: Vector2, half: float, col: Color, width: float) -> void:
	draw_rect(Rect2(center - Vector2(half, half), Vector2(half * 2.0, half * 2.0)),
		col, false, width)


## Input waiting to be smelted, drawn INSIDE the tool so a starved tool (one pip,
## waiting forever for its pair) is distinguishable from a busy one.
func _draw_intake(r: float) -> void:
	if (kind != Kind.FORGE and kind != Kind.LOOM) or intake.is_empty():
		return
	for i in mini(intake.size(), BUFFER_CAP):
		var p := Vector2(-6.0 + 6.0 * float(i % 3), 4.0 + 6.0 * float(i / 3))
		draw_circle(p, 2.0, Palette.of_res(intake[i]))


## Buffered items orbit the node as pips. A backed-up Well wears its congestion.
func _draw_buffer(r: float, col: Color) -> void:
	if buffer.is_empty():
		return
	var n := buffer.size()
	for i in n:
		var a := TAU * (float(i) / float(BUFFER_CAP)) - PI * 0.5
		var p := Vector2(cos(a), sin(a)) * (r + 9.0)
		draw_circle(p, 2.6, Palette.of_res(buffer[i]))
