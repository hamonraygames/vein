extends Node2D
class_name VNode
## A node in the circulatory diagram: the Heart, or a Well that feeds it.
##
## Shape is the type. Motion is the throughput. Nothing here is ever labelled.

enum Kind { HEART, WELL, FORGE, LOOM, KILN, CRUCIBLE }
## HEXAGON appended after VOID (not inserted before it) — VOID's numeric
## value must not move, nothing else in the file ever assumes the LAST
## entry is the deepest tier, everything reaches tiers by name.
enum Res { RAW, REFINED, CLOTH, PRISM, VOID, HEXAGON }

## Fired once, from inside corrupt() itself, the instant this node turns —
## the only way to catch both paths that can trigger it (game.gd's spread/
## airborne contagion in _tick_corruption, AND this node's own _emit/_smelt
## calling corrupt() internally on reserve depletion). game.gd listens on
## every node (connected in _make_node) to spawn a same-family replacement
## the moment a shape starts dying, not just when it's already gone — same
## convention as Vein's own `ruptured(vein: Vein)` signal (see vein.gd).
signal corruption_started(node: VNode)

## Tools condense inputs into one stronger output — but WHICH inputs is now
## per-instance: every tool spawns with its own `recipe` (see below), rolled
## by game.gd. A Forge still makes REFINED, a Loom CLOTH, a Kiln PRISM; what
## each one EATS varies — the plain ones want two of the tier below, the
## exotic ones demand mixed shapes ("1 square and 1 circle", "2 x 1 y", up
## to three inputs). The tool's body wears a colour hashed from its recipe
## (stable within a run, rerolled between runs) and its interior shows ONLY
## the requirement glyphs — the silhouette already says what it is; inside
## it says what it needs.

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
## Nudged from 32 to 42 alongside WELL_PERIOD's cut above (1.45 -> 1.1) so
## total lifetime stays ~46s either way — this pass is about raising the
## RATE a Well produces at, not how long it lives.
const WELL_YIELD := 42.0

## Tools deplete too — by SMELT, not by clock. Each conversion spends one charge;
## when a tool runs out it goes necrotic exactly like a spent Well, but its
## poison is stronger (see POISON_POT_BY_KIND). "The more you milk them, the
## sooner they die" — a Forge you lean on hard corrupts faster than one you use
## lightly. Deliberately LONGER-lived than a circle: a tool is a bottleneck you
## build a whole chain around, so losing one hurts, and it shouldn't happen as
## casually as a Well running dry. Higher tiers get fewer charges (each smelt is
## worth much more), but all outlast a single Well in practice because smelts are
## gated by input arrival.
const FORGE_YIELD := 26.0
const LOOM_YIELD := 20.0
const KILN_YIELD := 16.0
## The Crucible is the one VEIN.md always promised and the game never had:
## "the Heart demands hexagons, which only a rare Crucible can make." Fewer
## charges than a Kiln, continuing the same "higher tiers get fewer charges"
## curve — a Crucible existing at all is already a huge investment (2 PRISM
## in, each of which was already 2 CLOTH, each of which was already 2
## REFINED...), so losing one should sting more than losing a Kiln does.
const CRUCIBLE_YIELD := 10.0

## How much more a corrupted node's poison hurts the Heart, per delivered VOID
## dot, relative to a circle's (see game.FUEL_BY_RES[VOID] and _deliver). A
## spent tool is a nastier corpse than a spent Well — it gave you more alive, it
## costs you more dead.
const POISON_POT_BY_KIND := {
	Kind.WELL: 1.0,
	Kind.FORGE: 1.35,
	Kind.LOOM: 1.7,
	Kind.KILN: 2.1,
	Kind.CRUCIBLE: 2.5,
}

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
## A corrupted node with no path to the Heart (depth < 0) is no longer
## poisoning anything but its own remaining neighbours (see game.gd's
## _tick_corruption rage spread) — once it is done raging there is nothing
## left for it to threaten, so it collapses far faster than a Heart-
## connected corpse, which earns the long COLLAPSE_TIME above because it is
## still actively poisoning the Heart every beat.
const ORPHAN_COLLAPSE_TIME := 1.6

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

const RADIUS := 22.0
const HEART_RADIUS := 34.0

## What a Well produces, in seconds. Deliberately not beat-locked: wells drift
## against the heartbeat, so supply and demand slide in and out of phase.
## Was 1.45 — real playtest: circle supply couldn't keep pace with what the
## Heart wanted, especially once a lineage needs several Wells at once to
## clear a refined tier's throughput floor. Cut by ~25% so each Well pulls its
## own weight harder, on top of the spawn-cadence cut in game.gd's
## WELL_GAP_*. WELL_YIELD raised alongside it (below) to keep a Well's total
## lifetime roughly where it was — this is a rate fix, not a lifespan one.
const WELL_PERIOD := 1.1

var kind: int = Kind.WELL
var produces: int = Res.RAW

## Distance to the Heart over the vein graph. -1 means orphaned — nothing this
## node makes can reach anything that wants it.
var depth := -1

## Distance to the nearest Well WITHIN a heart-disconnected component, -1 when
## unset. This is the SECONDARY orientation: a subgraph with no path to the
## Heart still flows — outward from its Wells — so resources pool at the far
## dead-end (a Forge banks its REFINED, a chain's tail node fills up) instead
## of sitting frozen. Lets you pre-stage supply before you've wired it to the
## Heart, "saving resources for when you need them." Only meaningful while
## depth < 0; a heart-connected node uses `depth` and ignores this.
var feed_depth := -1

## Items waiting here for an outgoing vein with room. When this fills, a Well
## stops producing and the pips stack up visibly.
var buffer: Array[int] = []

## Tools only: input waiting to be smelted. Separate from `buffer` so a
## tool's backlog of input doesn't block the output it has already made.
var intake: Array[int] = []

## Tools only: the multiset of input resources this instance eats (2-3
## entries, e.g. [RAW, RAW] or [RAW, CLOTH, RAW]). Rolled by game.gd at
## spawn from the seeded rng — see _roll_recipe there. take() only accepts
## what the recipe still needs; _smelt fires when every slot is filled. What
## a tool NEEDS varies per instance; what it makes (and therefore its body
## colour, via Palette.of_res(produces)) does not — a Forge is always the
## REFINED hue no matter what it eats, so a resource keeps ONE colour
## everywhere. The per-instance appetite reads from the requirement glyphs
## inside, not from the body colour.
var recipe: Array[int] = []

## 0..1, decays. Drives the swell when the node emits or consumes.
var pulse := 0.0

## Items left in a Well. Drawn as the ring itself, so a Well literally erodes
## away as you drain it — you can see which of your lifelines is nearly gone
## without a number, and plan the reroute before it kills you.
var reserve := WELL_YIELD
var corrupted := false
## How hard this node's poison hits once corrupted, relative to a circle's — set
## from POISON_POT_BY_KIND the moment it turns. 1.0 until then.
var poison_pot := 1.0
## The identity colour this node had the instant before it corrupted —
## `produces` gets overwritten to VOID by corrupt() below, so without this
## the glitch render has no way to know what it USED to be. Drives
## _draw_necrotic's tint: each corrupted object glitches in a darkened
## version of its own colour, not a single generic violet for everything.
var _corrupt_tint := Palette.VOID
## Tools only: reserve spent per smelt. Externally driven by game.gd from run
## intensity (see game._process/TOOL_DEPLETION_EARLY), NOT a flat 1.0. "Start
## gentle, get hardcore" — same shape every other escalating threat in this
## game already uses (corruption spread, airborne blight, demand rotation),
## just applied to tool death too: early in a run this is small, so a first
## Forge/Loom/Kiln feels like a reliable new toy while the player is still
## learning the recipe, not a ticking time bomb. By late-run it reaches 1.0,
## the rate FORGE_YIELD/LOOM_YIELD/KILN_YIELD were actually tuned against.
var depletion_rate := 1.0
## 0..1, decays. The visible "two went in, one came out" moment.
var smelt_flash := 0.0
## Seconds this node has been rotting its neighbours.
var spread_accum := 0.0
## Seconds this node has been corrupted, total. Drives COLLAPSE_TIME.
var corrupt_age := 0.0
## Seconds this Well has sat orphaned (depth < 0). Drives WITHER_TIME. Reset to
## 0 the instant it joins the network, even briefly — only NEGLECT withers.
var orphan_age := 0.0

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

## Heart only: how full it is, 0..1. Drawn as a level inside the heart so the
## goal of the game is legible on sight — the vessel is emptying, fill it. This
## is the one thing the player must understand and it must never need a number.
var fuel_ratio := 1.0

## Heart only: the shape it is asking for. Drawn as a glyph inside the heart,
## which is the entire teaching mechanism for Forges — the Heart visibly wants a
## triangle, and the only thing on the board that makes triangles is the triangle
## node. No text, no tutorial, no red-triangle mystery.
var demand: int = Res.RAW

## Heart only, decorative use only: main_menu.gd stands up a real Heart VNode
## at its exact in-run spawn position so the menu and the game share one
## silhouette, not a redrawn lookalike — but the menu Heart has no demand to
## show yet (no run has started), so this skips _draw_demand entirely rather
## than drawing a meaningless default glyph. False everywhere a real run
## ever sees.
var suppress_demand := false

## Heart only, rotation phase only (see game._tick_escalation): the shape
## `demand` is about to become, and how close that flip is (0..1, 1 = about
## to land). -1/0 means nothing pending — the ordinary state outside the
## last few seconds before a rotation flip. This is the ONLY forward
## knowledge the Heart ever gives: not the shape after that, not a queue,
## just "the next one is already decided and it's this." Turns a rotation
## flip from a pure ambush into a warning you can read on the Heart itself.
var tell_res: int = -1
var tell_ratio := 0.0

var _emit_accum := 0.0
var _round_robin := 0


func _ready() -> void:
	z_index = 10
	# Tools carry their own charge pool (spent per smelt); a Well keeps the
	# default WELL_YIELD set on the field.
	match kind:
		Kind.FORGE: reserve = FORGE_YIELD
		Kind.LOOM: reserve = LOOM_YIELD
		Kind.KILN: reserve = KILN_YIELD
		Kind.CRUCIBLE: reserve = CRUCIBLE_YIELD
	Beat.beat.connect(_on_beat)


func radius() -> float:
	if kind == Kind.HEART:
		return HEART_RADIUS
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
	elif kind == Kind.FORGE or kind == Kind.LOOM or kind == Kind.KILN or kind == Kind.CRUCIBLE:
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

	queue_redraw()


## 0..1 toward collapse. Game reads this to know when to remove the node.
func collapse_ratio() -> float:
	if not corrupted:
		return 0.0
	var span := ORPHAN_COLLAPSE_TIME if depth < 0 else COLLAPSE_TIME
	return clampf(corrupt_age / span, 0.0, 1.0)


## 0..1 toward withering away from neglect.
func wither_ratio() -> float:
	if corrupted or depth >= 0:
		return 0.0
	if kind == Kind.WELL:
		return clampf(orphan_age / WITHER_TIME, 0.0, 1.0)
	return 0.0


func _emit() -> void:
	if buffer.size() >= buffer_cap():
		return
	if corrupted:
		buffer.append(Res.VOID)
		pulse = 1.0
		return
	buffer.append(produces)
	pulse = 1.0
	# Reserve is only spent on an item that actually left, so a Well backed up
	# behind a full buffer is not quietly bleeding out. It is ALSO only spent
	# while actually connected to the Heart (depth >= 0) — a Well feeding a
	# not-yet-connected stockpile (see feed_depth) is staging supply for
	# later, not spending it. Charging reserve for that defeated the entire
	# point of pre-building a reserve before you need it: "I start filling
	# disconnected shapes to have reserve... but before I use them they get
	# poisonous."
	if depth >= 0:
		reserve -= 1.0
		if reserve <= 0.0:
			corrupt()


func corrupt() -> void:
	if corrupted:
		return
	corrupted = true
	reserve = 0.0
	_corrupt_tint = Palette.of_res(produces)
	produces = Res.VOID
	# A tool's corpse is nastier than a circle's — its poison hits the Heart
	# harder per dot (see game._deliver). Set at the moment of turning so it
	# reflects what kind of node just died.
	poison_pot = float(POISON_POT_BY_KIND.get(kind, 1.0))
	# Whatever it was still holding turns with it.
	buffer.clear()
	intake.clear()
	pulse = 1.0
	corruption_started.emit(self)


func reserve_ratio() -> float:
	if corrupted:
		return 0.0
	var cap := 0.0
	match kind:
		Kind.WELL: cap = WELL_YIELD
		Kind.FORGE: cap = FORGE_YIELD
		Kind.LOOM: cap = LOOM_YIELD
		Kind.KILN: cap = KILN_YIELD
		Kind.CRUCIBLE: cap = CRUCIBLE_YIELD
		_: return 0.0
	return clampf(reserve / cap, 0.0, 1.0)


## Non-mutating mirror of take(): would it currently succeed? Used by the push
## logic (game._push_from_nodes) to decide whether to even SEND an item down a
## vein at all. Without this, a source kept shoving items at a sink it already
## knew would refuse them — they'd travel the whole vein only to be discarded
## on arrival (`dropped`), which quietly burned the SOURCE's reserve for
## nothing every time. This is what lets a pooled, not-yet-connected-to-the-
## Heart chain (see feed_depth) actually STOP and hold once its dead end fills,
## instead of grinding its own Wells to death feeding a sink with no room left.
func can_accept(kind_in: int) -> bool:
	if kind == Kind.HEART:
		return true
	if _accepts_tool_input(kind_in):
		return true
	# Same-shape pass-through, generalized from Wells (which never had a
	# recipe gate at all) to every tool kind: a Forge's OWN output arriving
	# from another Forge is not a recipe ingredient, it's a relay — "the
	# furthest-from-the-Heart node flows through the nearer one of the same
	# kind" now applies uniformly, not just circle-to-circle. It rides
	# straight into this tool's own outgoing buffer below, same as anything
	# else that isn't a wrong ingredient.
	if (kind == Kind.FORGE or kind == Kind.LOOM or kind == Kind.KILN or kind == Kind.CRUCIBLE) \
			and kind_in != Res.VOID and kind_in != produces:
		return false
	return buffer.size() < buffer_cap()


func take(kind_in: int) -> bool:
	if _accepts_tool_input(kind_in):
		# Capped at the RECIPE's own size, not buffer_cap() — a Forge's cap is 3
		# (its triangle's edge count, see buffer_cap), but an exotic recipe can
		# ask for 4 of its ingredient (see game._roll_recipe's EXOTIC_FOUR_CHANCE).
		# Capping intake at buffer_cap() there silently refused the 4th item
		# forever: intake sat at 3/4 filled, _smelt() never saw enough to fire,
		# and the triangle just never converted — "the four-circle triangles
		# aren't working."
		if intake.size() >= recipe.size():
			return false
		intake.append(kind_in)
		return true
	# A Forge/Loom fed the wrong raw material (e.g. RAW wired straight into a
	# Loom, skipping the Forge) is refused, not passed through as phantom
	# cargo — otherwise it silently rides the output buffer untouched and
	# reaches the Heart still mislabeled, which read as "I built the chain and
	# died anyway." VOID is the one deliberate exception: tools cannot launder
	# rot into food, so poison still passes straight through to the Heart.
	# Its OWN produce is a second, deliberate exception — see can_accept.
	if (kind == Kind.FORGE or kind == Kind.LOOM or kind == Kind.KILN or kind == Kind.CRUCIBLE) \
			and kind_in != Res.VOID and kind_in != produces:
		return false
	if buffer.size() >= buffer_cap():
		return false
	buffer.append(kind_in)
	pulse = maxf(pulse, 0.6)
	return true


## Accepts `kind_in` only while the recipe still has an unfilled slot of that
## kind — a tool never hoards inputs it cannot use, so a mis-routed shape is
## refused at the door instead of silently clogging the intake.
func _accepts_tool_input(kind_in: int) -> bool:
	if corrupted or recipe.is_empty():
		return false
	var need := 0
	for r in recipe:
		if r == kind_in:
			need += 1
	if need == 0:
		return false
	var have := 0
	for i in intake:
		if i == kind_in:
			have += 1
	return have < need


## Every recipe slot filled, one stronger shape out. The conversion shrinks
## the item count carrying the same run of fuel, which is why a tool is the
## answer to a bursting trunk and not just a fuel multiplier.
func _smelt() -> void:
	if recipe.is_empty() or intake.size() < recipe.size() or buffer.size() >= buffer_cap():
		return
	intake.clear()
	buffer.append(produces)
	pulse = 1.0
	# The moment many become one, made loud. A tool that silently swaps pips
	# teaches nothing — it just sits there as an unexplained red triangle, which
	# is exactly how it read in playtest.
	smelt_flash = 1.0
	Audio.play("refined", -20.0, 1.35)
	# A tool spends itself as it works: milk it and it dies sooner, then goes
	# necrotic like a spent Well but with nastier poison (see corrupt()). The
	# rate itself ramps with the run — see depletion_rate. Same stockpiling
	# exemption as a Well's _emit(): only while actually connected to the
	# Heart (depth >= 0) — smelting into a pre-staged, not-yet-connected
	# buffer must not be able to kill the tool before that buffer is ever used.
	if depth >= 0:
		reserve -= depletion_rate
		if reserve <= 0.0:
			corrupt()


## Round-robin so a node with two downhill veins splits its output between them
## instead of starving one.
func next_out(count: int) -> int:
	_round_robin = (_round_robin + 1) % maxi(count, 1)
	return _round_robin


func _draw() -> void:
	var col := Palette.HEART if kind == Kind.HEART else Palette.of_res(produces)
	var r := radius() * (1.0 + pulse * (0.16 if kind == Kind.HEART else 0.10))

	# Corruption overrides shape identity — a necrotic tool is rot now, not a
	# Forge/Loom/Kiln, and must wear the same broken glitch a spent Well does so
	# it reads as "cut me" at a glance instead of a healthy tool.
	if corrupted and kind != Kind.HEART:
		_draw_necrotic(r)
		_draw_buffer(r, col)
		return

	match kind:
		Kind.HEART: _draw_heart_shape(r, col)
		Kind.FORGE: _draw_tri(r, col)
		Kind.LOOM: _draw_square(r, col)
		Kind.KILN: _draw_pentagon(r, col)
		Kind.CRUCIBLE: _draw_hexagon(r, col)
		_: _draw_ring(r, col)

	_draw_buffer(r, col)


## Eighth design for this shape. Smooth heart curves are gone per explicit
## direction: straight lines only, sharp geometric edges, no curves at all —
## the same vector language every other node already uses (a triangle, a
## square, a hexagon are all hand-placed vertices, not sampled arcs). The
## very first straight-edge pass (ten vertices) read as a diamond/arrow
## rather than a heart; eighteen read as a heart but busier than this shape
## needs. Fourteen — three straight segments per lobe instead of four — is
## the settled middle: still unmistakably a heart, still every edge a
## straight line. Hand-placed and left-right symmetric by construction, so
## the origin already sits at the shape's visual centre without needing a
## computed area centroid the way an asymmetric sampled curve would.
## HEART_WIDTH_MULT stretches the whole silhouette horizontally afterward —
## kept as its own factor rather than baked into the points so "wider" stays
## a one-number knob independent of the vertex count/placement above it.
const HEART_POINTS: Array[Vector2] = [
	Vector2(0.00, -0.48), Vector2(0.22, -0.82), Vector2(0.55, -0.85), Vector2(0.88, -0.55),
	Vector2(1.00, -0.15), Vector2(0.75, 0.43), Vector2(0.46, 0.72), Vector2(0.00, 1.05),
	Vector2(-0.46, 0.72), Vector2(-0.75, 0.43), Vector2(-1.00, -0.15), Vector2(-0.88, -0.55),
	Vector2(-0.55, -0.85), Vector2(-0.22, -0.82),
]
const HEART_WIDTH_MULT := 1.18

func _heart_points(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for p in HEART_POINTS:
		pts.append(Vector2(p.x * HEART_WIDTH_MULT, p.y) * r)
	return pts


## The Heart's buffer-pip slot count (see buffer_cap()/_draw_buffer below) —
## deliberately its OWN constant, not HEART_POINTS.size(). Pips are placed on
## a plain circular ring by angle, never aligned to the Heart's actual
## vertices the way a triangle/square/pentagon/hexagon's are (see
## _draw_buffer's own comment), so this was always just "a reasonably large
## capacity," borrowed from the old curve's sample count — decoupling it here
## keeps the ten-vertex silhouette purely cosmetic and leaves the Heart's
## actual buffer capacity, a real balance number, untouched by it.
const HEART_EDGES := 48

func _draw_heart_shape(r: float, col: Color) -> void:
	var heart := _heart_points(r)

	# A dim wash so an empty Heart is still a shape, not a hole.
	var base := col
	base.a = 0.07 + pulse * 0.10
	draw_colored_polygon(heart, base)

	# The level itself: clip to everything below the fuel line. A falling
	# waterline is read instantly and without instruction; a bar or a number
	# would be neither. Bounds come from the heart's own extent (it isn't
	# symmetric top/bottom — the tip reaches further than the lobes rise).
	if fuel_ratio > 0.001:
		var min_y := INF
		var max_y := -INF
		for p in heart:
			min_y = minf(min_y, p.y)
			max_y = maxf(max_y, p.y)
		var line_y := max_y - (max_y - min_y) * clampf(fuel_ratio, 0.0, 1.0)
		var below := PackedVector2Array([
			Vector2(-r * 2.0, line_y), Vector2(r * 2.0, line_y),
			Vector2(r * 2.0, max_y), Vector2(-r * 2.0, max_y),
		])
		var fill := col
		fill.a = 0.34 + pulse * 0.34
		for poly in Geometry2D.intersect_polygons(heart, below):
			draw_colored_polygon(poly, fill)

	var outline := heart.duplicate()
	outline.append(heart[0])
	draw_polyline(outline, col, 3.0, true)

	if not suppress_demand:
		_draw_demand(r)


## Traces `pts` (an open, ordered polygon outline) from its first vertex
## around the perimeter for `ratio` of its total length, then stops — the
## polygon equivalent of a circle's eroding reserve arc (see _draw_ring),
## so a tool's own body outline IS its remaining-charge gauge, not a
## separate ring floating outside the shape. "Reserve" in feedback always
## meant _draw_buffer's dots, never this border — this stays the plain
## continuous eroding outline.
func _draw_partial_outline(pts: PackedVector2Array, ratio: float, col: Color, width: float) -> void:
	if ratio <= 0.0:
		return
	var closed := pts.duplicate()
	closed.append(pts[0])
	if ratio >= 0.999:
		draw_polyline(closed, col, width, true)
		return
	var total := 0.0
	var seg_len: Array[float] = []
	for i in closed.size() - 1:
		var l := closed[i].distance_to(closed[i + 1])
		seg_len.append(l)
		total += l
	var target := total * ratio
	var out := PackedVector2Array()
	out.append(closed[0])
	var acc := 0.0
	for i in seg_len.size():
		var l: float = seg_len[i]
		if acc + l >= target:
			var f := 0.0 if l <= 0.0 else (target - acc) / l
			out.append(closed[i].lerp(closed[i + 1], f))
			break
		out.append(closed[i + 1])
		acc += l
	draw_polyline(out, col, width, true)


## The shape the Heart is asking for, floating inside it. This is the only
## instruction VEIN ever gives, and it gives it wordlessly.
##
## When a rotation-phase flip is close (tell_ratio > 0, see game.gd's
## DEMAND_TELL_LEAD), the current glyph destabilises — fading and wobbling —
## while the next one fades in on top of it, so the Heart visibly changes
## its mind a few seconds before it actually does. Outside that window
## (always true during the teaching schedule) this draws exactly one glyph,
## same as before.
func _draw_demand(r: float) -> void:
	var s := r * 0.34
	if tell_ratio > 0.0 and tell_res != -1 and tell_res != demand:
		var wobble := sin(Time.get_ticks_msec() * 0.02) * s * 0.08 * tell_ratio
		var cur: Color = Palette.of_res(demand)
		cur.a = (0.85 + pulse * 0.15) * (1.0 - tell_ratio * 0.65)
		_draw_demand_glyph(demand, s, cur, Vector2(wobble, 0.0))

		var nxt: Color = Palette.of_res(tell_res)
		nxt.a = (0.85 + pulse * 0.15) * tell_ratio
		_draw_demand_glyph(tell_res, s, nxt, Vector2.ZERO)
	else:
		var c: Color = Palette.of_res(demand)
		c.a = 0.85 + pulse * 0.15
		_draw_demand_glyph(demand, s, c, Vector2.ZERO)


## Local-space, origin-centred outline for a demand glyph at scale `s` — the
## exact vertex math _draw_demand_glyph draws with, factored out so a caller
## OUTSIDE this node (tutorial.gd's demand-match highlight) can trace the
## same silhouette family at whatever size and position it needs, instead of
## always ringing a shape with a generic circle. Empty for RAW/VOID — those
## are circular, not a polygon, so the caller draws a plain arc instead (see
## demand_glyph_is_circular).
static func demand_glyph_points(res: int, s: float) -> PackedVector2Array:
	match res:
		Res.REFINED:
			var tri := PackedVector2Array()
			for i in 3:
				var a := TAU * (float(i) / 3.0) - PI * 0.5
				tri.append(Vector2(cos(a), sin(a)) * s * 1.2)
			tri.append(tri[0])
			return tri
		Res.CLOTH:
			var h := s * 0.8
			return PackedVector2Array([
				Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h), Vector2(-h, -h),
			])
		Res.PRISM:
			var pent := PackedVector2Array()
			for i in 5:
				var a := TAU * (float(i) / 5.0) - PI * 0.5
				pent.append(Vector2(cos(a), sin(a)) * s * 1.15)
			pent.append(pent[0])
			return pent
		Res.HEXAGON:
			var hex := PackedVector2Array()
			for i in 6:
				var a := TAU * (float(i) / 6.0) - PI * 0.5
				hex.append(Vector2(cos(a), sin(a)) * s * 1.1)
			hex.append(hex[0])
			return hex
	return PackedVector2Array()


## RAW/VOID have no polygon (demand_glyph_points returns empty for them) —
## the arc radius those cases draw at, so a caller building its own circular
## fallback (tutorial.gd) uses the identical proportion instead of guessing.
const DEMAND_GLYPH_CIRCLE_RATIO := 0.85


func _draw_demand_glyph(res: int, s: float, c: Color, offset: Vector2) -> void:
	var pts := demand_glyph_points(res, s)
	if pts.is_empty():
		draw_arc(offset, s * DEMAND_GLYPH_CIRCLE_RATIO, 0.0, TAU, 22, c, 2.4, true)
		return
	if offset != Vector2.ZERO:
		var shifted := PackedVector2Array()
		for p in pts:
			shifted.append(p + offset)
		pts = shifted
	draw_polyline(pts, c, 2.4, true)


func _draw_ring(r: float, col: Color) -> void:
	if corrupted:
		_draw_necrotic(r)
		return

	# Softer than it was: playtest called the Wells "very bold and dominant,
	# both border width and colour." Thin the ring and drop the fill so a
	# circle reads as a quiet vessel, not a loud disc.
	var fill := col
	fill.a = 0.06 + pulse * 0.16
	draw_circle(Vector2.ZERO, r, fill)

	# The ring IS the reserve. A full Well is a closed circle; a drained one is a
	# vanishing arc. No number, and you can read your whole board's life
	# expectancy in one glance.
	var ghost := col
	ghost.a = 0.11
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, ghost, 1.3, true)

	var left := reserve_ratio()
	if left > 0.0:
		var start := -PI * 0.5
		draw_arc(Vector2.ZERO, r, start, start + TAU * left, 32, col, 1.7, true)


## A spent node, gone necrotic — and WRONG in a way nothing healthy ever is:
## it glitches. The shape stutters off its own centre, splits into offset
## ghost copies, grows unstable spikes, and gets sliced by scanline tears.
## Everything healthy in VEIN moves smoothly; this is the one thing on the
## board that moves BROKEN, which is exactly the alarm it should be.
##
## Tinted with the object's OWN colour (see _corrupt_tint, captured the
## instant it turned), darkened and pulled partway toward VOID — a corrupted
## Well glitches in dead gold, a corrupted Loom in dead stone, not every
## corpse on the board wearing the identical violet. The violet pull keeps
## "this is rot" legible at a glance even for a resource whose colour reads
## close to it already.
func _draw_necrotic(r: float) -> void:
	var ms := Time.get_ticks_msec()
	# Coarse time buckets so the glitch STUTTERS between held poses instead
	# of smearing smoothly — smooth is alive, stutter is wrong.
	var frame := ms / 90
	var g := _noise01(frame * 7 + int(position.x))

	var jit := Vector2.ZERO
	if g > 0.62:
		jit = Vector2(_noise01(frame * 13 + 5) - 0.5, _noise01(frame * 17 + 9) - 0.5) * r * 0.55

	var tint := _corrupt_tint.lerp(Palette.VOID, 0.3).darkened(0.35)
	var tint_dim := tint.darkened(0.4)

	var fill := tint_dim
	fill.a = 0.55 + pulse * 0.35
	draw_circle(jit, r * (0.9 + pulse * 0.15), fill)

	# Split ghost copies: the same corpse, displaced.
	if g > 0.45:
		var ghost := tint
		ghost.a = 0.22
		var off := Vector2(r * (0.28 + g * 0.3), 0.0).rotated(g * TAU)
		draw_arc(jit + off, r * 0.9, 0.0, TAU, 20, ghost, 1.6, true)
		draw_arc(jit - off, r * 0.9, 0.0, TAU, 20, ghost, 1.2, true)

	var spikes := PackedVector2Array()
	for i in 14:
		var a := TAU * (float(i) / 14.0)
		var wob := _noise01(frame * 3 + i * 11)
		var rr := r * ((1.05 + wob * 0.45) if i % 2 == 0 else (0.6 + wob * 0.2))
		spikes.append(jit + Vector2(cos(a), sin(a)) * rr)
	spikes.append(spikes[0])
	draw_polyline(spikes, tint, 2.0 + g * 1.4, true)

	# Scanline tears: horizontal slices through the node, the visual language
	# of a corrupted signal rather than a living thing.
	if g > 0.55:
		for i in 3:
			var y := (_noise01(frame * 5 + i * 23) - 0.5) * r * 1.7
			var wl := r * (0.7 + _noise01(frame * 9 + i * 31) * 0.9)
			var tear := tint
			tear.a = 0.35 + g * 0.3
			draw_line(jit + Vector2(-wl, y), jit + Vector2(wl * 0.6, y), tear, 1.4, true)


## Cheap deterministic per-bucket noise for the glitch — cosmetic only, never
## part of the sim, so it deliberately does NOT touch the seeded rng.
static func _noise01(n: int) -> float:
	return float(absi((n * 2654435761) % 4096)) / 4096.0


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

	# A dim full-silhouette ghost, same two-part language as a circle's
	# reserve ring (see _draw_ring): a faint complete outline underneath...
	var ghost := col
	ghost.a = 0.14
	var full := tri.duplicate()
	full.append(tri[0])
	draw_polyline(full, ghost, 1.3, true)

	# ...and the border ITSELF is the remaining charge, same eroding-arc
	# design as a Well, just traced around a triangle. Full-bodied while
	# fresh; it visibly shortens as the Forge is milked toward corruption.
	var edge := col
	edge.a = 0.88 + pulse * 0.12 + smelt_flash * 0.12
	_draw_partial_outline(tri, reserve_ratio(), edge, 2.6 + smelt_flash * 1.8)

	_draw_recipe_slots(r)
	if teach:
		_draw_teach_demo(r)

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
	var half := side * 0.5
	var sq := PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half),
	])

	var fill := col
	fill.a = 0.06 + pulse * 0.16 + smelt_flash * 0.38
	draw_colored_polygon(sq, fill)

	var ghost := col
	ghost.a = 0.14
	var full := sq.duplicate()
	full.append(sq[0])
	draw_polyline(full, ghost, 1.3, true)

	var edge := col
	edge.a = 0.88 + pulse * 0.12 + smelt_flash * 0.12
	_draw_partial_outline(sq, reserve_ratio(), edge, 2.6 + smelt_flash * 1.8)

	_draw_recipe_slots(r)
	if teach:
		_draw_teach_demo(r)

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

	var ghost := col
	ghost.a = 0.14
	var full := pent.duplicate()
	full.append(pent[0])
	draw_polyline(full, ghost, 1.3, true)

	var edge := col
	edge.a = 0.88 + pulse * 0.12 + smelt_flash * 0.12
	_draw_partial_outline(pent, reserve_ratio(), edge, 2.6 + smelt_flash * 1.8)

	_draw_recipe_slots(r)
	if teach:
		_draw_teach_demo(r)

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


## A Crucible. The fifth tool and rarest by far — VEIN.md always promised it:
## "the Heart demands hexagons, which only a rare Crucible can make." Same
## ladder logic as every silhouette before it (one more side than the shape
## before), so a hexagon reads as "one step past the pentagon" the instant
## you see it, no new visual language needed even at the deepest tier.
func _draw_hexagon(r: float, col: Color) -> void:
	var s := r * (1.28 + smelt_flash * 0.12)
	var hex := PackedVector2Array()
	for i in 6:
		var a := TAU * (float(i) / 6.0) - PI * 0.5
		hex.append(Vector2(cos(a), sin(a)) * s)

	var fill := col
	fill.a = 0.07 + pulse * 0.20 + smelt_flash * 0.42
	draw_colored_polygon(hex, fill)

	var ghost := col
	ghost.a = 0.14
	var full := hex.duplicate()
	full.append(hex[0])
	draw_polyline(full, ghost, 1.3, true)

	var edge := col
	edge.a = 0.88 + pulse * 0.12 + smelt_flash * 0.12
	_draw_partial_outline(hex, reserve_ratio(), edge, 2.6 + smelt_flash * 1.8)

	_draw_recipe_slots(r)
	if teach:
		_draw_teach_demo(r)

	if smelt_flash > 0.0:
		var halo := Palette.HEXAGON
		halo.a = smelt_flash * 0.68
		var pts := PackedVector2Array()
		var hs := s * (1.25 + (1.0 - smelt_flash) * 0.9)
		for i in 6:
			var a := TAU * (float(i) / 6.0) - PI * 0.5
			pts.append(Vector2(cos(a), sin(a)) * hs)
		pts.append(pts[0])
		draw_polyline(pts, halo, 2.0 + smelt_flash * 2.0, true)


## Loops a few times on this tool's first-ever appearance: ghost dots of the
## recipe's inputs fall in from outside, the node flashes, one ghost dot of
## `produces` (the output) leaves. This is the exact motion a real feed will
## later cause — showing it before the player has built anything teaches the
## recipe without a word, where the static requirement glyphs alone did not.
func _draw_teach_demo(r: float) -> void:
	var phase := fmod(_teach_t, TEACH_REP_TIME) / TEACH_REP_TIME
	var n := maxi(recipe.size(), 2)

	if phase < 0.55:
		var t := phase / 0.55
		var ease := t * t
		for i in mini(recipe.size(), 3):
			var col := Palette.of_res(recipe[i])
			col.a = 0.85 * (1.0 - ease * 0.3)
			var side := (float(i) - float(n - 1) * 0.5) * 1.4
			var from := Vector2(side * r * 0.9, -r * 2.6)
			var to := Vector2(side * r * 0.22, -r * 0.1)
			draw_circle(from.lerp(to, ease), 3.2, col)
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


## The tool's interior is its SHOPPING LIST, nothing else — feedback: "don't
## show their own shape anymore, only show what they need so you can make
## them bigger." One glyph per recipe slot, in the slot's own resource
## colour, drawn dim while empty and lit once an intake item fills it — the
## interior IS the progress bar toward the next smelt.
func _draw_recipe_slots(r: float) -> void:
	if recipe.is_empty():
		return
	var n := recipe.size()
	var s := r * (0.42 if n <= 2 else 0.32)
	var gap := s * 2.4
	var have := intake.duplicate()
	for i in n:
		var res: int = recipe[i]
		var p := Vector2((float(i) - float(n - 1) * 0.5) * gap, 0.0)
		var filled := false
		var hi := have.find(res)
		if hi >= 0:
			filled = true
			have.remove_at(hi)
		# Feedback: the unfilled state read as too pale/washed-out to register
		# as "a shape" at all, and even the filled one was thinner than it
		# needed to be against the body fill. Sharper on both counts again —
		# unfilled 0.58 -> 0.8, filled 0.95 -> 1.0 — while keeping a clear
		# filled/unfilled contrast (still the whole point of the gauge).
		var col := Palette.of_res(res)
		col.a = (1.0 if filled else 0.8) + smelt_flash * 0.1
		var w := 2.9 if filled else 2.4
		match res:
			Res.REFINED:
				_draw_mini_tri(p, s, col, w, filled)
			Res.CLOTH:
				_draw_mini_square(p, s * 0.85, col, w, filled)
			Res.PRISM:
				_draw_mini_pentagon(p, s, col, w, filled)
			Res.HEXAGON:
				_draw_mini_hexagon(p, s, col, w, filled)
			_:
				draw_arc(p, s * 0.8, 0.0, TAU, 20, col, w, true)
				if filled:
					var fill := col
					fill.a *= 0.75
					draw_circle(p, s * 0.8, fill)


## `filled` (a slot an intake item has actually reached) gets a solid, sharp
## fill on top of the outline, not just a brighter line — "when blood comes
## inside a shape... make it sharper and filled, that way it's more
## visible." An empty slot stays outline-only, still legible as "this is
## what's needed" without reading as already satisfied.
func _draw_mini_tri(center: Vector2, size: float, col: Color, width: float, filled: bool) -> void:
	var tri := PackedVector2Array()
	for i in 3:
		var a := TAU * (float(i) / 3.0) - PI * 0.5
		tri.append(center + Vector2(cos(a), sin(a)) * size)
	if filled:
		var fill_c := col
		fill_c.a *= 0.75
		draw_colored_polygon(tri, fill_c)
	tri.append(tri[0])
	draw_polyline(tri, col, width, true)


func _draw_mini_square(center: Vector2, half: float, col: Color, width: float, filled: bool) -> void:
	var rect := Rect2(center - Vector2(half, half), Vector2(half * 2.0, half * 2.0))
	if filled:
		var fill_c := col
		fill_c.a *= 0.75
		draw_rect(rect, fill_c, true)
	draw_rect(rect, col, false, width)


func _draw_mini_pentagon(center: Vector2, size: float, col: Color, width: float, filled: bool) -> void:
	var pent := PackedVector2Array()
	for i in 5:
		var a := TAU * (float(i) / 5.0) - PI * 0.5
		pent.append(center + Vector2(cos(a), sin(a)) * size)
	if filled:
		var fill_c := col
		fill_c.a *= 0.75
		draw_colored_polygon(pent, fill_c)
	pent.append(pent[0])
	draw_polyline(pent, col, width, true)


func _draw_mini_hexagon(center: Vector2, size: float, col: Color, width: float, filled: bool) -> void:
	var hex := PackedVector2Array()
	for i in 6:
		var a := TAU * (float(i) / 6.0) - PI * 0.5
		hex.append(center + Vector2(cos(a), sin(a)) * size)
	if filled:
		var fill_c := col
		fill_c.a *= 0.75
		draw_colored_polygon(hex, fill_c)
	hex.append(hex[0])
	draw_polyline(hex, col, width, true)


## How many items this node's buffer/intake can hold, AND how many pip slots
## it has to show them in — explicit direction: "the reserved capacity of
## each shape is equal to the number of their edges." One function serves
## both, so capacity and layout can never drift apart: the shape's own
## vertex count for a tool (triangle -> 3, square -> 4, pentagon -> 5,
## hexagon -> 6), a reasonable circular subdivision for a Well/Heart
## (neither has real edges to align to).
func buffer_cap() -> int:
	match kind:
		Kind.FORGE: return 3
		Kind.LOOM: return 4
		Kind.KILN: return 5
		Kind.CRUCIBLE: return 6
		Kind.HEART: return HEART_EDGES
		_: return 6


## Buffered items orbit the node as pips, ONE SLOT PER EDGE — the count of
## slots is the shape's own edge count (triangle -> 3, square -> 4, and so
## on), and each pip centers on an edge's own bearing rather than a vertex's,
## so a full buffer visibly maps one item per side. A backed-up node wears
## its congestion — kept small and slightly soft so it reads as texture, not
## a second bold ring. Past one lap around (buffer.size() > slot count), the
## next lap's pips sit a little further out on the same bearings rather than
## inventing a new ring pattern.
func _draw_buffer(r: float, col: Color) -> void:
	if buffer.is_empty():
		return
	var slots := buffer_cap()
	# Every trig-built shape (triangle/pentagon/hexagon, see _draw_tri etc.)
	# has its first VERTEX at the top — a = TAU*i/n - PI/2 — so reaching an
	# EDGE center needs the extra half-slot rotation below. The Loom's square
	# is the one shape not built that way: _draw_square places flat corners
	# at (±half, ±half), a top EDGE rather than a top vertex, so its real
	# edge centers already sit at the un-rotated positions — adding the same
	# half-slot offset there put every pip on a corner instead of a side.
	var phase := 0.0 if kind == Kind.LOOM else (TAU / float(slots)) * 0.5
	for i in buffer.size():
		var edge_i := i % slots
		var lap := i / slots
		var a := TAU * (float(edge_i) / float(slots)) - PI * 0.5 + phase
		var p := Vector2(cos(a), sin(a)) * (r + 8.0 + float(lap) * 7.0)
		var pc := Palette.of_res(buffer[i])
		pc.a = 0.9
		draw_circle(p, 2.1, pc)
