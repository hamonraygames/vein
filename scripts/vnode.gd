extends Node2D
class_name VNode
## A node in the circulatory diagram: the Heart, or a Well that feeds it.
##
## Shape is the type. Motion is the throughput. Nothing here is ever labelled.

## Three booster families, one shared pickup mechanic (see game.gd's
## _add_vein): BOOST is a ONE_OFF, instant single-use grab. MUTATION is a
## PERSISTENT perk — permanent for the rest of the run, one slot, taking a
## new one replaces whichever you already hold. RELIC is a TIME_BASED perk —
## same effect pool as MUTATION but stronger and temporary, also one slot.
## Kind names are kept as-is from an earlier design pass; game.gd's
## OneOff/BoosterEffect enums are the ones that actually define what each
## pickup grants now.
enum Kind { HEART, WELL, FORGE, LOOM, KILN, BOOST, RELIC, MUTATION }
enum Res { RAW, REFINED, CLOTH, PRISM, VOID }

## Tools condense two inputs into one stronger output. A Forge eats RAW and makes
## REFINED; a Loom eats REFINED and makes CLOTH; a Kiln eats CLOTH and makes
## PRISM — the fourth tier, per feedback wanting more than three shapes in
## play ("triangle, square, 5-edge... like wood/gold/metal/water/stone in a
## resource-management game") so a fully-escalated run has a real network to
## keep alive, not just one final pipe.
const TOOL_RATIO := 2

## Items a Well holds before it runs dry. Depletion is by USE, not by clock:
## a Well only spends reserve when it actually emits, and it only emits when
## something downstream will take the item. So the trunk you lean on hardest is
## the one that dies first, and an unconnected Well keeps its reserve forever.
## That is the whole enemy design — every strength eats itself.
##
## Was 72 (WELL_PERIOD=1.45s -> ~104s of continuous output). Playtest:
## "circles are long-living, that's not ideal" — against a run that's mostly
## over well before that, a connected Well read as a permanent, safe income
## rather than something that also costs you upkeep. Cut by more than half so
## even your first, best-placed Wells force a rewire mid-run, not just the
## ones you neglect.
const WELL_YIELD := 32.0

## A spent Well does not politely stop. It goes necrotic and starts pumping VOID
## down the vein you built to it, faster than it ever gave you RAW. You must cut
## it — which costs you the throughput you had come to depend on.
const CORRUPT_PERIOD := 1.0

## Seconds a corrupted node takes to rot its live neighbours. Neglect cascades,
## and it cascades fast enough that hesitating costs you the limb.
const SPREAD_TIME := 6.0

## A necrotic node that is never cut eventually collapses outright — you don't
## just get to sit on a dead Well forever, poisoning at your leisure and never
## paying for it. This is what makes rot "come and go" instead of accumulating
## as permanent board clutter: ignore it long enough and the asset itself is
## gone, on top of whatever it already cost you.
const COLLAPSE_TIME := 8.0
## Fraction of COLLAPSE_TIME at which visible fading begins — the collapse
## equivalent of WITHER_WARN_AT below.
const COLLAPSE_FADE_AT := 0.6

## An orphaned Well (nothing downstream will ever take what it makes) that sits
## unconnected this long withers and vanishes. Without this the board only ever
## grows — every Well you don't use becomes permanent scenery, and playtest read
## that as "lazy" and static. Wells you ignore are USE-IT-OR-LOSE-IT, which also
## means the board keeps turning over instead of just filling up.
##
## This MUST stay comfortably longer than a budget tier, or it is an economy
## bug rather than a pacing fix. Budget grows far slower than Wells spawn BY
## DESIGN — that gap is the core scarcity puzzle, and having more Wells on the
## board than you can currently afford is the normal, intended state, not
## neglect. Measured (via the probe's cumulative `withered` counter, added
## because the live node count alone hid this): when this was set to ~2.7x the
## budget gap the bot lost 5-11 Wells a run before it could ever reach them and
## survival collapsed ~185 -> ~120 beats. Keep it near 3x BUDGET_GAP_START so
## wither only ever catches a Well nobody was going to route to.
## Scales with the escalation clock: halved when everything else halved.
const WITHER_TIME := 35.0
## Fraction of WITHER_TIME at which visible fading begins, so vanishing is
## always something you saw coming, never a surprise deletion.
const WITHER_WARN_AT := 0.6

## A Boost left unclaimed also withers — same USE-IT-OR-LOSE-IT rule as a Well,
## reusing the exact same age/fade/removal pipeline (see wither_ratio()), just
## against a much shorter clock: it's a bonus pickup, not a supply line, so
## ignoring one should read as a small, prompt "that one's gone" rather than
## sitting around as permanent decoration on the board. Roughly one
## ONE_OFF_GAP (game.gd), so a Boost you skip is usually gone before the next
## one arrives.
const BOOST_LIFE := 13.0

## An unpicked RELIC/MUTATION fork withers too — on a longer clock than a
## Boost (it's a real decision, it deserves deliberation time), but it must
## NOT sit forever: an ignored pair used to permanently block every future
## offer of its family (the spawn gates check _has_*_pair) AND accumulate as
## board clutter, so skipping one fork silently switched that whole system
## off for the rest of the run. When either half withers, game.gd removes
## both (see _tick_lifecycle) — the fork expires as a unit, same as it
## resolves as a unit.
const PICKUP_LIFE := 24.0

const RADIUS := 22.0
const HEART_RADIUS := 34.0
const BOOST_RADIUS := 16.0
## Bigger than Boost (16) despite the same "one-shot pickup" verb — a
## Mutation is a permanent, run-defining choice picked once under time
## pressure with no chance to learn it by feel like a Forge/Loom recipe, so
## it has to read clearly on the first glance, not the tenth.
const MUTATION_RADIUS := 24.0
## Between Boost and Mutation: a bigger decision than an instant grab (it's a
## fork, and it costs the other half), but a smaller one than a Mutation
## (temporary, not run-long).
const RELIC_RADIUS := 20.0
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

## BOOST only: which OneOff effect this pickup grants (game.gd's OneOff enum,
## plain int to avoid a circular preload). Assigned by the game at spawn so
## the roll comes from the seeded run RNG and stays deterministic.
var boost_effect: int = 0

## RELIC only: which BoosterEffect this half of the fork grants (game.gd's
## BoosterEffect enum, plain int to avoid a circular preload).
var relic_id: int = 0
## RELIC only: the other half of this choice. Taking either one removes both
## — same fork rule as MUTATION, just for a temporary effect instead of a
## permanent one.
var relic_pair: VNode = null

## MUTATION only: which BoosterEffect this choice grants (game.gd's
## BoosterEffect enum, referenced here only as a plain int to avoid a
## circular preload).
var mutation_id: int = 0
## MUTATION only: the other half of this choice. Taking either one removes
## both — it is a fork, not two separate pickups.
var mutation_pair: VNode = null

## BOOST/RELIC/MUTATION only: the readable icon text set by game.gd at spawn
## time ("1.15×", "+25", "⇄", "+1 slot", ...) — see _draw_pickup_label. Kept
## as a plain string set from outside rather than computed here so the
## numbers live in exactly one place (game.gd's booster constants).
var label: String = ""

## Heart only: every PERSISTENT perk currently held, pushed in from game.gd's
## _active_persistent the moment it changes (same pattern as demand/
## fuel_ratio below). Drawn orbiting the Heart itself — not a separate HUD
## tray — because the Heart is the one thing in VEIN that already carries
## every other piece of run state (fuel level, demand) on its own body, and
## a permanent rule change belongs on the thing whose rules it changed, the
## same way Notcoin's coin or Hamster Kombat's hamster visibly wears every
## upgrade instead of parking them in a sidebar.
var mutation_marks: Array[int] = []

## Forge/Loom/Kiln only: true for the first of each kind the player ever sees
## (persisted across runs in game.gd's save, see seen_forge/seen_loom/
## seen_kiln) — plays a short looping demonstration of its own recipe before
## settling into the normal idle rendering. Playtest: the static recipe pips
## alone ("what is the red triangle, I don't know what it's about") were not
## enough — this shows the exact motion the player will later cause
## themselves, without a word of text.
var teach := false
var _teach_t := 0.0
const TEACH_REPS := 3
const TEACH_REP_TIME := 1.8

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
	if kind == Kind.RELIC:
		return RELIC_RADIUS
	if kind == Kind.MUTATION:
		return MUTATION_RADIUS
	return RADIUS


func _on_beat(_i: int) -> void:
	if kind == Kind.HEART:
		# The Heart's swell IS the beat.
		pulse = 1.0


func _process(delta: float) -> void:
	# A frame hitch must not teleport the sim — see Beat.MAX_DELTA.
	delta = minf(delta, Beat.MAX_DELTA)
	pulse = maxf(0.0, pulse - delta * 3.2)
	smelt_flash = maxf(0.0, smelt_flash - delta * 2.4)
	if teach:
		_teach_t += delta
		if _teach_t >= TEACH_REPS * TEACH_REP_TIME:
			teach = false
	if kind == Kind.WELL or corrupted:
		_emit_accum += delta
		var period := CORRUPT_PERIOD if corrupted else WELL_PERIOD
		if _emit_accum >= period:
			_emit_accum -= period
			_emit()
	elif kind == Kind.FORGE or kind == Kind.LOOM or kind == Kind.KILN:
		_smelt()

	if corrupted:
		corrupt_age += delta
	if (kind == Kind.WELL or kind == Kind.BOOST or kind == Kind.RELIC
			or kind == Kind.MUTATION) and not corrupted:
		# A pickup never joins the flow graph even while sitting on the board
		# (see game.gd's _add_vein) — depth stays -1 for its whole life until
		# taken, so this is exactly "seconds since it appeared, unclaimed".
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

	if kind == Kind.BOOST or kind == Kind.RELIC or kind == Kind.MUTATION:
		_boost_pulse += delta
		pulse = maxf(pulse, 0.35 + 0.35 * sin(_boost_pulse * 3.4))

	queue_redraw()


## 0..1 toward collapse. Game reads this to know when to remove the node.
func collapse_ratio() -> float:
	return clampf(corrupt_age / COLLAPSE_TIME, 0.0, 1.0) if corrupted else 0.0


## 0..1 toward withering away from neglect.
func wither_ratio() -> float:
	if corrupted or depth >= 0:
		return 0.0
	if kind == Kind.WELL:
		return clampf(orphan_age / WITHER_TIME, 0.0, 1.0)
	if kind == Kind.BOOST:
		return clampf(orphan_age / BOOST_LIFE, 0.0, 1.0)
	if kind == Kind.RELIC or kind == Kind.MUTATION:
		return clampf(orphan_age / PICKUP_LIFE, 0.0, 1.0)
	return 0.0


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
	if _accepts_tool_input(kind_in):
		if intake.size() >= BUFFER_CAP:
			return false
		intake.append(kind_in)
		return true
	# A Forge/Loom fed the wrong raw material (e.g. RAW wired straight into a
	# Loom, skipping the Forge) is refused, not passed through as phantom
	# cargo — otherwise it silently rides the output buffer untouched and
	# reaches the Heart still mislabeled, which read as "I built the chain and
	# died anyway." VOID is the one deliberate exception: tools cannot launder
	# rot into food, so poison still passes straight through to the Heart.
	if (kind == Kind.FORGE or kind == Kind.LOOM or kind == Kind.KILN) and kind_in != Res.VOID:
		return false
	if buffer.size() >= BUFFER_CAP:
		return false
	buffer.append(kind_in)
	pulse = maxf(pulse, 0.6)
	return true


func _accepts_tool_input(kind_in: int) -> bool:
	return not corrupted and (
		(kind == Kind.FORGE and kind_in == Res.RAW)
		or (kind == Kind.LOOM and kind_in == Res.REFINED)
		or (kind == Kind.KILN and kind_in == Res.CLOTH)
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
		Kind.KILN: _draw_pentagon(r, col)
		Kind.BOOST: _draw_boost(r)
		Kind.RELIC: _draw_relic(r)
		Kind.MUTATION: _draw_mutation(r)
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
	_draw_mutation_marks(r)


## Every PERSISTENT perk currently held, orbiting the Heart permanently — the
## Heart wears every rule change on its own body, same spot every time, so
## which marks are out there becomes as learnable as the demand glyph itself.
func _draw_mutation_marks(r: float) -> void:
	if mutation_marks.is_empty():
		return
	var n := mutation_marks.size()
	for i in n:
		var a := TAU * (float(i) / float(maxi(n, 5))) - PI * 0.5
		var p := Vector2(cos(a), sin(a)) * (r + 16.0)
		var ring := Palette.PERSISTENT
		ring.a = 0.16
		draw_circle(p, 11.0, ring)
		var col := Palette.PERSISTENT
		col.a = 0.6 + pulse * 0.2
		draw_mark(self, mutation_marks[i], p, 6.5, col)


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
		Res.PRISM:
			var pent := PackedVector2Array()
			for i in 5:
				var a := TAU * (float(i) / 5.0) - PI * 0.5
				pent.append(Vector2(cos(a), sin(a)) * s * 1.15)
			pent.append(pent[0])
			draw_polyline(pent, c, 2.4, true)
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

	_draw_pickup_label(r, Palette.BOOST)


## A Relic: a six-point hexagram, always spawned in a contradictory pair.
## Deliberately a different silhouette from both Boost's four-point star (an
## instant grab) and Mutation's diamond (a permanent choice) — a Relic is a
## fork like Mutation, but the effect is temporary, and it needs to read as
## its own category at a glance, not a reskin of either. Palette.RELIC (burnt
## orange) is the colour half of that; the extra points are the shape half.
func _draw_relic(r: float) -> void:
	var s := r * 1.2
	var spin := float(Time.get_ticks_msec()) * 0.0008
	var star := PackedVector2Array()
	for i in 12:
		var a := TAU * (float(i) / 12.0) + spin
		var rr := s if i % 2 == 0 else s * 0.5
		star.append(Vector2(cos(a), sin(a)) * rr)
	star.append(star[0])

	var fill := Palette.RELIC
	fill.a = 0.13 + pulse * 0.24
	draw_colored_polygon(star, fill)
	var edge := Palette.RELIC
	edge.a = 0.68 + pulse * 0.3
	draw_polyline(star, edge, 2.3 + pulse * 1.3, true)

	var halo := Palette.RELIC
	halo.a = 0.09 + 0.05 * sin(spin * 2.4)
	draw_arc(Vector2.ZERO, r * 1.85, 0.0, TAU, 24, halo, 1.2, true)

	# TIME_BASED shares its glyph vocabulary with PERSISTENT (see draw_mark)
	# — both draw from game.gd's same BoosterEffect enum now, so one shared
	# static function is the whole vocabulary, not two parallel ones.
	draw_mark(self, relic_id, Vector2.ZERO, r * 0.6, Palette.RELIC)
	_draw_pickup_label(r, Palette.RELIC)


## A Mutation: a slow diamond, always spawned in a pair. Taking either one
## removes both — a fork, not a freebie, so its silhouette must read as
## "deliberate choice" rather than "gift". Coloured Palette.PERSISTENT, not
## Palette.WARM or Palette.RELIC — a Mutation's perk outlives the run even
## longer than a Relic's timer outlives its own pickup, so it gets its own
## hue rather than sharing either the "instant grab" or "temporary" family's.
## The inner mark (see draw_mark) is the only thing distinguishing which
## perk this half grants.
func _draw_mutation(r: float) -> void:
	var s := r * 1.15
	var spin := float(Time.get_ticks_msec()) * 0.0009
	var dia := PackedVector2Array()
	for i in 4:
		var a := TAU * (float(i) / 4.0) + spin + PI * 0.25
		dia.append(Vector2(cos(a), sin(a)) * s)
	dia.append(dia[0])

	var fill := Palette.PERSISTENT
	fill.a = 0.12 + pulse * 0.22
	draw_colored_polygon(dia, fill)
	var edge := Palette.PERSISTENT
	edge.a = 0.65 + pulse * 0.3
	draw_polyline(dia, edge, 2.2 + pulse * 1.3, true)

	var halo := Palette.PERSISTENT
	halo.a = 0.08 + 0.05 * sin(spin * 2.1)
	draw_arc(Vector2.ZERO, r * 1.8, 0.0, TAU, 24, halo, 1.2, true)

	draw_mark(self, mutation_id, Vector2.ZERO, r * 0.62, Palette.PERSISTENT)
	_draw_pickup_label(r, Palette.PERSISTENT)


## The readable icon text ("1.15×", "+25", "⇄", "14s", ...) every booster
## pickup carries — see the `label` field. Same font/centring pattern as
## score_hud.gd and float_text.gd (ThemeDB.fallback_font, no custom font
## resource in the project), sitting just below the shape so it never
## competes with the inner glyph or the Heart's own score readout.
func _draw_pickup_label(r: float, col: Color) -> void:
	if label == "":
		return
	var font := ThemeDB.fallback_font
	var size := 13
	var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var lc := col
	lc.a = 0.75 + pulse * 0.25
	draw_string(font, Vector2(-w * 0.5, r + 22.0), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, lc)


## Shape-only, per the palette rule ("colour is a redundant channel"). Static
## so every rendering of a given BoosterEffect — the PERSISTENT diamond, the
## TIME_BASED hexagram, and the Heart's own persistent tray/active-effect
## ring (game.gd) — all draw the exact same glyph, the shared vocabulary a
## returning player learns once and recognises everywhere.
static func draw_mark(ci: CanvasItem, effect_id: int, center: Vector2, s: float, col: Color) -> void:
	match effect_id:
		0: # score — a rising chevron, climbing
			var pts := PackedVector2Array([
				center + Vector2(-s, s * 0.5), center + Vector2(0.0, -s * 0.6),
				center + Vector2(s, s * 0.5),
			])
			ci.draw_polyline(pts, col, 2.8, true)
		1: # appetite — concentric still rings, calm
			ci.draw_arc(center, s * 0.35, 0.0, TAU, 16, col, 2.2, true)
			ci.draw_arc(center, s * 0.75, 0.0, TAU, 20, col, 2.0, true)
		2: # capacity — two bold parallel bars, a fat pipe
			ci.draw_line(center + Vector2(-s, -s * 0.35), center + Vector2(s, -s * 0.35), col, 3.0)
			ci.draw_line(center + Vector2(-s, s * 0.35), center + Vector2(s, s * 0.35), col, 3.0)
		_: # reach — a four-point burst, reaching outward
			for i in 4:
				var a := TAU * float(i) / 4.0
				ci.draw_line(center, center + Vector2(cos(a), sin(a)) * s * 1.3, col, 2.8)


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
	if teach:
		_draw_teach_demo(r, Res.RAW)

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
	if teach:
		_draw_teach_demo(r, Res.REFINED)

	if smelt_flash > 0.0:
		var halo := Palette.CLOTH
		halo.a = smelt_flash * 0.66
		var h := side * (0.72 + (1.0 - smelt_flash) * 0.55)
		draw_rect(Rect2(Vector2(-h, -h), Vector2(h * 2.0, h * 2.0)), halo, false,
			2.0 + smelt_flash * 2.0)


## A Kiln. The fourth tool, one silhouette further from a circle than a Loom's
## square — a pentagon reads as "further along the same ladder" at a glance,
## the same way triangle->square already does, without needing a new visual
## grammar for it.
func _draw_pentagon(r: float, col: Color) -> void:
	var s := r * (1.35 + smelt_flash * 0.12)
	var pent := PackedVector2Array()
	for i in 5:
		var a := TAU * (float(i) / 5.0) - PI * 0.5
		pent.append(Vector2(cos(a), sin(a)) * s)

	var fill := col
	fill.a = 0.07 + pulse * 0.20 + smelt_flash * 0.42
	draw_colored_polygon(pent, fill)

	var edge := col
	edge.a = 0.44 + pulse * 0.3 + smelt_flash * 0.54
	var outline := pent.duplicate()
	outline.append(pent[0])
	draw_polyline(outline, edge, 2.5 + smelt_flash * 2.0, true)

	_draw_kiln_recipe(r)
	if teach:
		_draw_teach_demo(r, Res.CLOTH)

	if smelt_flash > 0.0:
		var halo := Palette.PRISM
		halo.a = smelt_flash * 0.68
		var pts := PackedVector2Array()
		var hs := s * (1.25 + (1.0 - smelt_flash) * 0.9)
		for i in 5:
			var a := TAU * (float(i) / 5.0) - PI * 0.5
			pts.append(Vector2(cos(a), sin(a)) * hs)
		pts.append(pts[0])
		draw_polyline(pts, halo, 2.0 + smelt_flash * 2.0, true)


## Loops a few times on this tool's first-ever appearance: two ghost dots of
## `input_res` fall in from outside, the node flashes, one ghost dot of
## `produces` (the output) leaves. This is the exact motion a real feed will
## later cause — showing it before the player has built anything teaches the
## recipe without a word, where the static recipe pips alone did not.
func _draw_teach_demo(r: float, input_res: int) -> void:
	var phase := fmod(_teach_t, TEACH_REP_TIME) / TEACH_REP_TIME

	if phase < 0.55:
		var t := phase / 0.55
		var ease := t * t
		var col := Palette.of_res(input_res)
		col.a = 0.85 * (1.0 - ease * 0.3)
		for side in [-1.0, 1.0]:
			var from := Vector2(side * r * 0.9, -r * 2.6)
			var to := Vector2(side * r * 0.22, -r * 0.1)
			var p := from.lerp(to, ease)
			draw_circle(p, 3.2, col)
	elif phase < 0.65:
		var burst := 1.0 - (phase - 0.55) / 0.10
		var ring := Palette.WARM
		ring.a = burst * 0.55
		draw_arc(Vector2.ZERO, r * 1.15, 0.0, TAU, 24, ring, 2.0 + burst * 2.0, true)
	else:
		var t2 := (phase - 0.65) / 0.35
		var ease2 := t2 * t2
		var col2 := Palette.of_res(produces)
		col2.a = 0.9 * (1.0 - ease2)
		var from2 := Vector2(0.0, r * 0.1)
		var to2 := Vector2(0.0, r * 2.6)
		draw_circle(from2.lerp(to2, ease2), 3.6, col2)


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


func _draw_kiln_recipe(r: float) -> void:
	var cloth := Palette.CLOTH
	cloth.a = 0.42 + smelt_flash * 0.35
	_draw_mini_square(Vector2(-r * 0.25, r * 0.15), r * 0.13, cloth, 1.4)
	_draw_mini_square(Vector2(r * 0.25, r * 0.15), r * 0.13, cloth, 1.4)

	var prism := Palette.PRISM
	prism.a = 0.58 + smelt_flash * 0.32
	_draw_mini_pentagon(Vector2(0.0, -r * 0.16), r * 0.16, prism, 1.7)


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


func _draw_mini_pentagon(center: Vector2, size: float, col: Color, width: float) -> void:
	var pent := PackedVector2Array()
	for i in 5:
		var a := TAU * (float(i) / 5.0) - PI * 0.5
		pent.append(center + Vector2(cos(a), sin(a)) * size)
	pent.append(pent[0])
	draw_polyline(pent, col, width, true)


## Input waiting to be smelted, drawn INSIDE the tool so a starved tool (one pip,
## waiting forever for its pair) is distinguishable from a busy one.
func _draw_intake(r: float) -> void:
	if (kind != Kind.FORGE and kind != Kind.LOOM and kind != Kind.KILN) or intake.is_empty():
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
