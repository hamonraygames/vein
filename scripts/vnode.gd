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

## How far, in DESIGN-space pixels, a drawn arc may bow away from the true
## circle it approximates — the error budget behind arc_points() below.
##
## Design-space is the operative word: the 540x1170 board is stretched to
## whatever the device is (see game.gd's design_size), which is about 2x on a
## 1080-wide phone and ~2.4x on a large one, so this budget is multiplied by
## that before anyone sees it. At 0.5 a Well's ring showed faint flat spots
## under magnification; a quarter pixel keeps the worst case comfortably
## sub-pixel on real hardware while still cutting the old hardcoded counts by
## roughly a third. The arcs are also only 1.3-1.7px wide and antialiased, so
## the stroke's own softness absorbs more error than this on top.
const ARC_MAX_SAG := 0.25


## UNMET NEED IS THE ONLY THING ON THIS BOARD THAT SHIVERS.
##
## Playtest's central failure: nobody grasped "feed the Heart what it wants."
## The demand glyph sat inside the Heart perfectly still, so it read as
## decoration rather than an instruction. A satisfied need is STILL; an
## unsatisfied one grows visibly agitated. That rule applies recursively —
## the Heart's demand glyph is a need, and a wired-in tool's unfilled recipe
## slots are needs too — so the chain reads as a sentence: "nothing on this
## board makes triangles" (Heart) vs "I make triangles but nobody feeds me
## circles" (Forge).
##
## Two states, deliberately placed in the gaps of the motion vocabulary this
## game already speaks (tell wobble = 20 rad/s horizontal at 0.93px, "about
## to change"; Vein._wrong_jiggle = 110 rad/s at 3.2px, "wrong"):
##
##   STARVE — a horizontal waver that grows and breathes. Sustained for as
##            long as the need goes unanswered.
##   REJECT — the same axis, four times faster and over in ~0.4s. A
##            head-shake meaning "not that."
##
## Both are horizontal: a want shaking side to side is the gesture the eye
## already reads. They stay apart by rate and duration, not direction.
##
## All amplitudes are DESIGN-space px (540x1170), so they read at roughly 2x
## on a phone — see ARC_MAX_SAG above for the same caveat.
## A debounce, not suspense. Nothing is plugged in to answer this need, and no
## amount of waiting changes that — so the only job here is to not flash while
## the player is mid-drag rerouting something.
const STARVE_GRACE := 1.2
## 0 -> 1 after the grace, so ~4.7s from onset to full agitation. Tuned
## against instrumented probe runs rather than by eye — an earlier 6.0 grace
## plus 5.0 ramp needed ELEVEN seconds before the Heart shivered at all and
## never got near full agitation across two full runs.
const STARVE_RAMP := 3.5
## Two incommensurate frequencies, so the shiver never settles into a clean
## repeating oscillation the eye can dismiss as a loop.
##
## 1.4 and 2.2 Hz, summed on ONE axis. The first pass used 1.5 and 2.3 RAD/s
## — 0.24 Hz, one full cycle every four seconds — reasoning that at two pixels
## a buzz disappears and drift is what reads. Half right: buzz does disappear,
## but drift that slow does not read as agitation either, it reads as nothing
## at all, and a starve spell often ended before one cycle finished. This is
## fast enough to register as trembling and still nowhere near _wrong_jiggle's
## 17 Hz, the band that already means "wrong". Two incommensurate frequencies
## rather than one so the wobble never settles into a clean repeating loop the
## eye can dismiss.
const STARVE_FREQ_A := 9.0
const STARVE_FREQ_B := 13.7
## The breath (alpha, stroke width, scale) keeps its own much slower cadence,
## near the tutorial halo's proven 0.9 Hz "look here" pulse — so the two
## channels stay separable: a slow swell carrying a fast tremble.
const STARVE_FREQ_BREATH := 5.0
const STARVE_AMP_GLYPH := 3.0
const STARVE_AMP_SLOT := 1.6
## Scale breath. At a tool's 7-9px mini-glyph, displacement alone is half a
## stroke width and invisible against the node's own outline — a shape that
## changes silhouette AREA reads where one that shifts 1.2px does not.
const STARVE_BREATH := 0.10
## ~0.38s of visible NO, sitting next to smelt_flash's 2.4.
const REJECT_DECAY := 2.6
## 5.4 Hz. Deliberately not faster: Beat.MAX_DELTA is 0.25, and an oscillator
## much above this teleports across a hitched frame instead of shaking.
const REJECT_FREQ := 34.0
## Just above _wrong_jiggle's 3.2, so a rejecting tool and a wrong-flowing
## vein read as one family of "no" rather than two unrelated effects.
const REJECT_AMP := 3.6
## _push_from_nodes retries every frame at 60Hz, so an unthrottled re-arm
## would re-set reject to 1.0 before the decay ever ran — seizing at maximum
## amplitude forever instead of shaking once. This makes a repeated refusal
## beat "no ... no ... no" instead of buzzing.
const REJECT_COOLDOWN := 0.9
## Sustained floor while wrong cargo is in flight toward the Heart (game.gd
## drives this). Low on purpose: arrival is what snaps to 1.0.
const REJECT_INFLIGHT := 0.3


## Point count for a draw_arc of this radius spanning this many radians, sized
## so the result still reads as a smooth curve and no finer.
##
## Every draw_arc here used to pass a hardcoded count — almost always 32 —
## regardless of both radius and span. At the Well's RADIUS of 22 a
## 32-segment circle sits about 0.1px off true: perhaps eight times more
## geometry than the shape can actually show. Worse, a partial arc (the
## reserve ring, which spends most of a Well's life well under a quarter
## turn) paid the SAME 32 points for a sliver, so the shorter the arc got
## the more oversampled it became.
##
## Solved from the sagitta: for a segment spanning angle t, a polyline bows
## r*(1-cos(t/2)) away from the arc, so the widest allowed step is
## t = 2*acos(1 - ARC_MAX_SAG/r), and the count scales with span from there.
## Returns POINTS (segments + 1), matching draw_arc's own parameter.
static func arc_points(r: float, span: float = TAU) -> int:
	span = absf(span)
	if r <= ARC_MAX_SAG or span <= 0.0:
		return 2
	var step := 2.0 * acos(clampf(1.0 - ARC_MAX_SAG / r, -1.0, 1.0))
	if step <= 0.0:
		return 65
	return clampi(int(ceil(span / step)) + 1, 3, 65)

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

## Where the Wells stood that this shape was forged from — empty for anything
## that spawned normally. Kept so the shape can hand them back where they were
## when it dies (see game.gd's _release_ring): a ring is a place on the board
## you chose and rerouted around, and answering its death with one replacement
## somewhere else erased both the count and the layout.
var forged_from: Array[Vector2] = []

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

## 0..1. How badly this node's need is going unanswered. On the Heart it is
## mirrored in from game.gd (which owns the graph knowledge, same as
## fuel_ratio/demand/tell_ratio already are); on a tool it is derived locally
## from `fed` below. 0 means satisfied, or means "not the kind of thing that
## can starve." See the STARVE_* constants for what it drives.
var starve := 0.0
## Seconds this node's need has gone unanswered, feeding `starve` through
## STARVE_GRACE/STARVE_RAMP. Tools own theirs; the Heart's lives in game.gd.
var _starve_t := 0.0
## 0..1, decays. "That isn't what I asked for." Set at the moment a wrong
## shape is refused or lands — see would_reject and game._push_from_nodes.
var reject := 0.0
var _reject_cool := 0.0

## Tools only, maintained by game._rebuild_graph: does this tool have an
## adjacent vein whose source actually makes its ingredient? A tool that is
## wired into the chain but has nothing supplying it is starving BY
## CONSTRUCTION — no timer needed, and no false alarm on a slow-but-working
## exotic recipe (see the note on _starve_t in _process).
var fed := false

## Accumulated animation phase, advanced by the clamped delta rather than
## read from Time.get_ticks_msec(). Three things depend on that difference:
## ticks_msec ignores Engine.time_scale, so the panic pinch would slow the
## world while the shiver kept buzzing at full speed; a hitched frame
## (Beat.MAX_DELTA = 0.25) would teleport a fast oscillator instead of
## shaking it; and tutorial.gd reads demand_glyph_offset() from its own
## _draw, which must see a settled value, not a fresh clock sample. Seeded
## per instance in _ready so eight tools don't shiver in perfect lockstep —
## identical mini-glyphs moving as one read as a rendering artifact, not as
## eight independent anxious objects.
var _anim_phase := 0.0
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
	# Decorrelate the need shiver per instance — see _anim_phase.
	_anim_phase = float(get_instance_id() % 1000) * 0.0137
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
	reject = maxf(0.0, reject - delta * REJECT_DECAY)
	_reject_cool = maxf(0.0, _reject_cool - delta)
	_anim_phase += delta
	_tick_starve(delta)
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
	# RAGING (depth < 0) is the one case that skips the collapse fade
	# entirely — game.gd no longer removes an orphaned node on its own
	# collapse_ratio (see _island_ready_to_collapse: it waits for the whole
	# still-connected island to finish), but this fade curve is driven by
	# THIS node's own corrupt_age regardless, with no way to know about that
	# wait. Left alone, a node that turned early faded to fully invisible by
	# its own COLLAPSE_FADE_AT/ORPHAN_COLLAPSE_TIME and then sat there
	# see-through for however much longer the rest of the island took —
	# LOOKING like it had already died well before it actually was removed.
	# Playtest: "still the source and closer shapes die sooner." Staying
	# fully opaque the whole time it rages, and only vanishing at the actual
	# synchronized removal, is what makes that removal read as sudden and
	# simultaneous instead of each one having visibly been fading out on its
	# own schedule the entire time.
	if depth >= 0:
		var cr := collapse_ratio()
		if cr > COLLAPSE_FADE_AT:
			fade = minf(fade, 1.0 - (cr - COLLAPSE_FADE_AT) / (1.0 - COLLAPSE_FADE_AT))
	modulate.a = clampf(fade, 0.0, 1.0)

	# Redraw only when this node's appearance actually CHANGED.
	#
	# This used to be an unconditional queue_redraw(), which meant every node
	# on the board re-recorded its whole command list every frame — and for
	# these shapes that is not a cheap bookkeeping step: each antialiased
	# draw_arc/draw_polyline tessellates its geometry (plus an AA fringe) on
	# the CPU at record time, so a full board was rebuilding thousands of
	# triangles 60x a second to emit the exact same picture as the frame
	# before. A Well sitting at a full reserve between emissions, which is
	# most Wells most of the time, is a still image; it has no business
	# costing anything to hold.
	#
	# The things here that animate off a CLOCK rather than off state still
	# redraw unconditionally, so nothing that is supposed to move stops
	# moving: the necrotic glitch (see _draw_necrotic, which buckets
	# Time.get_ticks_msec), the demand tell's wobble (see _draw_demand), and
	# the unmet-need shiver (see _need_anim). `teach` is included for the
	# same reason — it runs off _teach_t. Everything else is a pure function
	# of the state in _visual_sig below.
	#
	# _was_anim is what makes the clock-driven branch safe to LEAVE. That
	# branch never writes _visual_sig_last, so a node whose animation ends
	# while its state is otherwise unchanged would compare equal to the
	# signature it had before the animation started, skip the redraw, and
	# hold its last drawn frame — mid-offset — forever. Clearing the cached
	# signature on the way out forces exactly one settling redraw. (The two
	# original cases only avoided this by luck: `teach` ends on a node whose
	# _visual_sig_last is still [] from spawn, and a tell ends by flipping
	# demand/tell_res, both of which are IN the signature. Neither was a
	# designed invariant.)
	var anim := corrupted or teach or tell_ratio > 0.0 or _need_anim()
	if anim:
		_was_anim = true
		queue_redraw()
	else:
		if _was_anim:
			_was_anim = false
			_visual_sig_last = []
		var sig := _visual_sig()
		if sig != _visual_sig_last:
			_visual_sig_last = sig
			queue_redraw()


## A tool's own hunger, derived from `fed` rather than from elapsed time.
##
## Elapsed time is the wrong instrument here and it is worth saying why:
## _smelt() fires the instant intake is full and immediately empties it, so a
## HEALTHY tool's steady state is partially unfilled essentially always — an
## exotic 4-slot Forge on a single Well sits unfilled ~4.5s of every cycle
## while working perfectly. Any grace short enough to catch a genuinely
## starved tool would also flag that one. `fed` asks the honest question
## instead: is anything adjacent actually making what I eat?
##
## The Heart is excluded — game.gd drives its `starve` directly, because the
## question there ("can anything on the board answer my demand?") is graph
## knowledge this node doesn't have.
func _tick_starve(delta: float) -> void:
	if kind == Kind.HEART or recipe.is_empty():
		return
	# `visible` matters: ghost_spawn/fuse hide a node and reveal it later
	# while _process keeps running, so without this a ring-forged Crucible
	# would pop into existence already shivering at full amplitude, having
	# redrawn invisibly at 60Hz the whole time it was hidden. An orphan
	# (depth < 0) stays still too — it already has the wither fade saying
	# "you never used me", and the shiver has to keep meaning exactly one
	# thing: this is IN your chain and it is starving.
	var hungry := visible and depth >= 0 and not fed and intake.size() < recipe.size()
	_starve_t = _starve_t + delta if hungry else 0.0
	starve = clampf((_starve_t - STARVE_GRACE) / STARVE_RAMP, 0.0, 1.0)


## Whether this node is currently animating off the clock rather than off
## state, and therefore has to redraw unconditionally — see _process.
## Self-limiting by design: a satisfied board has nothing in here, so the
## "stop redrawing unchanged nodes" win survives intact for exactly the calm
## case it was measured on. Only the nodes actually asking for something pay.
func _need_anim() -> bool:
	if not visible or suppress_demand:
		return false
	return starve > 0.0 or reject > 0.0


## The shared displacement behind both need states, at `amp` design-px and
## offset `phase_off` radians so sibling glyphs in one row don't move as a
## rigid block. REJECT wins outright while it lasts: being fed the wrong
## thing is the more actionable message than being fed nothing.
##
## Horizontal only, both states. A want shaking side to side is the gesture
## the eye already reads as refusal or agitation; the earlier two-axis version
## wandered instead of shook. STARVE and REJECT share the axis and stay
## distinct by rate and duration — a sustained 1.4/2.2 Hz waver that is also
## breathing, versus a ~0.4s burst at 5.4 Hz that is not.
func _need_offset(amp: float, phase_off: float) -> Vector2:
	if reject > 0.0:
		return Vector2(sin(_anim_phase * REJECT_FREQ + phase_off) * REJECT_AMP * reject, 0.0)
	if starve <= 0.0:
		return Vector2.ZERO
	var x := sin(_anim_phase * STARVE_FREQ_A + phase_off) * 0.7 \
		+ sin(_anim_phase * STARVE_FREQ_B + phase_off + 1.1) * 0.3
	return Vector2(x * amp * starve, 0.0)


## 0..1 breath factor for a starving glyph's scale, alpha and stroke width.
func _need_breath() -> float:
	if starve <= 0.0:
		return 0.0
	return (sin(_anim_phase * STARVE_FREQ_BREATH) * 0.5 + 0.5) * starve


## Everything _draw (and every helper it dispatches to) reads, packed for a
## cheap frame-to-frame equality test — see _process. Anything new that
## _draw starts depending on has to be added here too, or the node will hold
## a stale frame once it goes quiet. Arrays are folded in by hash() rather
## than duplicated so this stays allocation-light.
##
## Two deliberate omissions, both safe:
##   - `position`, read by _draw_necrotic to seed its glitch noise, is only
##     ever reached when `corrupted` is true — which redraws unconditionally
##     above, so it never depends on this signature.
##   - `scars` is folded in by size() alone rather than by content, because
##     add_scar only ever APPENDS and nothing mutates an existing scar's
##     weight; a run's scars are cleared by start_run rebuilding the Heart
##     outright. If a scar ever becomes mutable, hash the array instead.
##
## The derived helpers are covered by their own inputs rather than by being
## called here: reserve_ratio() is a pure function of (corrupted, kind,
## reserve), and radius()/buffer_cap() of kind alone — all already present.
func _visual_sig() -> Array:
	return [
		kind, produces, pulse, reserve, corrupted, depth < 0, modulate.a,
		fuel_ratio, demand, suppress_demand, tell_res, smelt_flash,
		wears_crown, scars.size(), buffer.hash(), intake.hash(), recipe.hash(),
	]


## Empty on purpose: never equal to a real signature, so the first _process
## after this node is built always draws.
var _visual_sig_last: Array = []

## Whether the previous frame took the clock-driven redraw branch — see the
## _was_anim note in _process. Deliberately NOT in _visual_sig(): a flag that
## reads false on both sides of an animation can never make the signature
## differ, so putting it there would fix nothing.
var _was_anim := false


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


## "That is not what I asked for" — strictly narrower than `not can_accept`.
##
## can_accept fails three ways and only ONE of them is a wrong shape. The
## other two are congestion wearing the same mask: a tool whose intake is
## already full of exactly the right ingredient falls through
## _accepts_tool_input and then trips the `kind_in != produces` gate, and a
## tool with a full output buffer refuses everything. Shaking "no" at either
## would be a lie — the first is the OPPOSITE message, and the second is what
## vein strain already reports.
func would_reject(kind_in: int) -> bool:
	if kind == Kind.HEART or corrupted or recipe.is_empty():
		return false
	# The two deliberate pass-throughs, same as can_accept/take: rot cannot be
	# laundered by a tool, and a tool's own produce arriving from a sibling is
	# a relay, not an ingredient.
	if kind_in == Res.VOID or kind_in == produces:
		return false
	return not recipe.has(kind_in)


## Fires the "no" shake, at most once per REJECT_COOLDOWN. The throttle is not
## cosmetic: _push_from_nodes retries a blocked push every frame at 60Hz, so an
## unthrottled re-arm would re-set `reject` to 1.0 before the decay ever ran
## and the node would seize at full amplitude forever instead of shaking once.
func flash_reject() -> void:
	if _reject_cool > 0.0:
		return
	reject = 1.0
	_reject_cool = REJECT_COOLDOWN


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

	# Worn, not swapped in — the Heart stays a heart (fuel level, demand
	# glyph, scars all still read off its own silhouette); the crown is an
	# ornament on top of it, same as the leaderboard hangs one on the #1
	# row instead of replacing that row's own shape.
	if kind == Kind.HEART and wears_crown:
		_draw_crown(r)


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

# --- Scar tissue -------------------------------------------------------------
## Permanent marks of the wounds this run survived. game.gd etches one when a
## wound actually CLOSES — a tithe episode whose danger passed, misses clawing
## back from DYING (see _tick_tithe_beat/_on_beat there) — never when it opens:
## an open wound is the waterline's job, a scar is the record of having lived.
## The tithe's interest math was already called "the scar" in its own comment
## (TITHE_INTEREST_GROWTH); this draws it. Heart-only, purely cosmetic, and
## cleared for free every run because start_run() rebuilds the Heart node.
##
## Placement is by index on a golden-angle walk, not RNG: the same wounds heal
## into the same tissue on any machine, without touching the seeded sim rng
## for something the sim must never depend on.
const SCAR_GOLDEN := 2.399963
## Beyond this the Heart reads as texture, not marks — and every seam is a
## polygon clip per frame, so the count stays bounded on principle.
const SCAR_MAX := 32

## [{w}] — weight 0..1, how bad the wound was; sets the seam's length and ink.
var scars: Array[Dictionary] = []

## Set by game.gd every frame from lb_you.rank — true only once this
## session has actually heard back that you hold leaderboard rank 1 (see
## leaderboard_panel.gd's own crown on that row). Heart-only, purely
## cosmetic, and never persisted here — game.gd owns the leaderboard state,
## this just reads it.
var wears_crown := false


func add_scar(weight: float) -> void:
	if kind != Kind.HEART or scars.size() >= SCAR_MAX:
		return
	scars.append({"w": clampf(weight, 0.0, 1.0)})


## Thin kinked seams across the body, in the tithe's ghost ink (Palette.SCORE),
## never the Heart's own red — scarred tissue is score that became flesh, and
## it should say so at a glance. Straight segments only, the same vector
## language as every shape here. Clipped against a slightly inset silhouette
## so no seam ever touches the outline, wherever the golden walk puts it.
func _draw_scars(heart: PackedVector2Array, r: float) -> void:
	if scars.is_empty():
		return
	var inset := PackedVector2Array()
	for p in heart:
		inset.append(p * 0.93)
	for i in scars.size():
		var w := float(scars[i].w)
		var ang := float(i) * SCAR_GOLDEN
		# Spread across the whole body, not clustered near the centre — a
		# tight radius range here made every mark converge into one starburst
		# at the tip instead of reading as scattered tissue.
		var c := Vector2.from_angle(ang) * r * (0.32 + 0.5 * fposmod(float(i) * 0.618034, 1.0))
		c.x *= HEART_WIDTH_MULT
		# A direction independent of `ang` — tying it to the placement angle
		# made every seam point toward/away from the centre, which read as
		# spikes radiating out rather than individual wounds.
		var dir := Vector2.from_angle(float(i) * 5.317 + 1.7)
		var half := r * (0.05 + 0.06 * w)
		var seam := PackedVector2Array([
			c - dir * half,
			c + dir.orthogonal() * half * 0.35,
			c + dir * half,
		])
		var col := Palette.SCORE
		col.a = 0.22 + 0.22 * w
		for piece in Geometry2D.intersect_polyline_with_polygon(seam, inset):
			draw_polyline(piece, col, 1.5, true)


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

	# Over the waterline, under the outline: scars sit IN the flesh — the
	# fuel level moves behind them, the border still owns the silhouette.
	_draw_scars(heart, r)

	var outline := heart.duplicate()
	outline.append(heart[0])
	draw_polyline(outline, col, 3.0, true)

	if not suppress_demand:
		_draw_demand(r)


## The same minimal, straight-edged crown leaderboard_panel.gd hangs on the
## #1 row (own copy there, sized for a HUD row instead of the Heart) — a
## single "W" silhouette on top (left point, valley, centre point, valley,
## right point — the two valleys reaching all the way down to the bottom
## line, same as the letter), each outer point then dropping straight down
## to that bottom line instead of a separate band underneath. The centre
## point is the tallest; the left/right points sit a little lower, so it
## doesn't read as a flat-topped comb. Nothing sampled or curved, matching
## every other hand-placed shape in this file.
## The two valley points sit well clear of the bottom line (0.30 vs the
## corners' 0.62) — they need to read as two separate dips poking up from
## the band, not as touching/fusing into that bottom edge. (They still
## can't be exactly flush with it in any case — that would make the edge
## collinear with the bottom line, which Godot's polygon triangulator
## rejects outright, logged as "triangulation failed".)
const CROWN_POINTS: Array[Vector2] = [
	Vector2(-1.0, 0.62), Vector2(-1.0, -0.42), Vector2(-0.5, 0.02), Vector2(0.0, -0.85),
	Vector2(0.5, 0.02), Vector2(1.0, -0.42), Vector2(1.0, 0.62),
]
const CROWN_SCALE := 0.5
## Worn at a jaunty tilt over the Heart's left lobe rather than centred and
## upright — "a cool hat," not a formal one — per explicit direction.
## Flip the sign to flip which way it leans.
const CROWN_TILT_DEG := -28.0
## In units of r: left of centre, over the left lobe itself — HEART_POINTS'
## left peak sits at x=-0.55*HEART_WIDTH_MULT ≈ -0.65, so this needs to sit
## close to THAT, not merely left of the Heart's own centre.
const CROWN_OFFSET := Vector2(-0.82, -0.92)

func _draw_crown(r: float) -> void:
	var s := r * CROWN_SCALE
	var angle := deg_to_rad(CROWN_TILT_DEG)
	var offset := CROWN_OFFSET * r
	var pts := PackedVector2Array()
	for p in CROWN_POINTS:
		pts.append(p.rotated(angle) * s + offset)
	draw_colored_polygon(pts, Palette.GOLD)
	var outline := pts.duplicate()
	outline.append(pts[0])
	draw_polyline(outline, Palette.GOLD.darkened(0.25), 2.0, true)


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
## (always true during the teaching schedule) this draws exactly one glyph.
##
## That single-glyph case is where STARVE lives: while nothing on the board
## can answer this demand (see game._demand_suppliable), the glyph drifts,
## breathes and dims — a want going unanswered, getting worse. The tell
## branch is deliberately left alone; it already destabilises the glyph for
## a different reason, and game.gd suppresses starve outright while a tell
## is up so the two can never talk over each other.
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
		if starve <= 0.0:
			_draw_demand_glyph(demand, s, c, Vector2.ZERO)
			return
		# Three channels at once, because at s ~= 11.6px displacement alone is
		# too small to carry the read: it drifts, it breathes bigger and
		# smaller (a change in silhouette AREA, which registers where a
		# two-pixel shift does not), and its alpha pulses.
		#
		# PULSES, not dims. A constant fade was the obvious version and it is
		# backwards: this glyph is the only instruction VEIN ever gives, and
		# starving is exactly the moment the player most needs to read WHICH
		# shape it is asking for. Oscillating instead keeps every peak fully
		# legible while still reading as a want guttering in and out — the
		# same trick the recipe slots use (see _draw_recipe_slots).
		var breath := _need_breath()
		c.a *= lerpf(1.0, lerpf(0.45, 1.0, breath), starve)
		_draw_demand_glyph(demand, s * (1.0 + STARVE_BREATH * breath * 2.0), c,
			_need_offset(STARVE_AMP_GLYPH, 0.6))


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
		draw_arc(offset, s * DEMAND_GLYPH_CIRCLE_RATIO, 0.0, TAU,
			arc_points(s * DEMAND_GLYPH_CIRCLE_RATIO), c, 2.4, true)
		return
	if offset != Vector2.ZERO:
		var shifted := PackedVector2Array()
		for p in pts:
			shifted.append(p + offset)
		pts = shifted
	draw_polyline(pts, c, 2.4, true)


## Where the Heart's demand glyph actually IS this frame, relative to the
## Heart's own position. Only tutorial.gd needs this, so its highlight halo
## can track a jiggling glyph instead of visibly sliding off it (see
## _draw_demand_match_hint).
##
## A getter over stored state, never a fresh clock read: the tutorial is a
## sibling CanvasItem calling this from its own _draw, and Godot runs every
## _process before every _draw, so what it reads here is the same settled
## _anim_phase this node drew with.
func demand_glyph_offset() -> Vector2:
	if kind != Kind.HEART or suppress_demand or starve <= 0.0:
		return Vector2.ZERO
	return _need_offset(STARVE_AMP_GLYPH, 0.6)


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
	# The ghost is only ever VISIBLE where the reserve arc below isn't: the
	# reserve is opaque and drawn wider (1.7 vs 1.3), so it completely covers
	# whatever ghost sits under it. Drawing the ghost as a full circle anyway
	# meant a brimming Well paid for two complete rings to show one — so this
	# draws only the missing span, and the two arcs together now always add
	# up to exactly one circle's worth of geometry instead of up to two.
	var left := reserve_ratio()
	var start := -PI * 0.5
	var spent := TAU * (1.0 - left)
	if spent > 0.001:
		var ghost := col
		ghost.a = 0.11
		var g0 := start + TAU * left
		draw_arc(Vector2.ZERO, r, g0, g0 + spent, arc_points(r, spent), ghost, 1.3, true)

	if left > 0.0:
		var span := TAU * left
		draw_arc(Vector2.ZERO, r, start, start + span, arc_points(r, span), col, 1.7, true)


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
##
## RAGING (depth < 0 — orphaned, so actively attacking whatever it's still
## wired to, see game.gd's _tick_corruption/_start_poison_dart) overrides all
## of that with a flat Palette.RAGE instead: a corpse quietly poisoning the
## Heart and an active attacker are different threats, and direct feedback
## asked for the difference to be visible — "when the rage starts, the
## poisonous shapes turn red, and others that get poisonous turn red too."
## A freshly-turned victim is already orphaned the instant it corrupts (it
## was only ever reached because it was still wired to something raging), so
## this same depth check is exactly the "just got poisonous" moment too —
## no separate flag needed.
func _draw_necrotic(r: float) -> void:
	var ms := Time.get_ticks_msec()
	# Coarse time buckets so the glitch STUTTERS between held poses instead
	# of smearing smoothly — smooth is alive, stutter is wrong.
	var frame := ms / 90
	var g := _noise01(frame * 7 + int(position.x))

	var jit := Vector2.ZERO
	if g > 0.62:
		jit = Vector2(_noise01(frame * 13 + 5) - 0.5, _noise01(frame * 17 + 9) - 0.5) * r * 0.55

	var raging := depth < 0
	var tint := Palette.RAGE.darkened(0.15) if raging else _corrupt_tint.lerp(Palette.VOID, 0.3).darkened(0.35)
	var tint_dim := tint.darkened(0.4)

	var fill := tint_dim
	fill.a = 0.55 + pulse * 0.35
	draw_circle(jit, r * (0.9 + pulse * 0.15), fill)

	# Split ghost copies: the same corpse, displaced.
	if g > 0.45:
		var ghost := tint
		ghost.a = 0.22
		var off := Vector2(r * (0.28 + g * 0.3), 0.0).rotated(g * TAU)
		draw_arc(jit + off, r * 0.9, 0.0, TAU, arc_points(r * 0.9), ghost, 1.6, true)
		draw_arc(jit - off, r * 0.9, 0.0, TAU, arc_points(r * 0.9), ghost, 1.2, true)

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
		draw_arc(Vector2.ZERO, r * 1.15, 0.0, TAU, arc_points(r * 1.15), ring, 2.0 + burst * 2.0, true)
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
##
## An UNFILLED slot on a starving tool (see _tick_starve) breathes that
## existing dim/lit distinction rather than just jittering: at s = 7-9px a
## drift of a pixel is half a stroke width and loses outright against the
## node's own 2.6px outline, its ghost under-outline and the dots crawling
## along the veins. Alpha, stroke width and scale all move instead, which
## turns a difference the player is ALREADY reading into one that moves.
## Displacement stays, as the top note that makes it read as anxious rather
## than merely glowing. Colour is never the only channel here (see palette.gd)
## and it still isn't — alpha is not hue.
func _draw_recipe_slots(r: float) -> void:
	if recipe.is_empty():
		return
	var n := recipe.size()
	var s := r * (0.42 if n <= 2 else 0.32)
	var gap := s * 2.4
	# `intake` is always k copies of ONE resource, so a slot is filled purely
	# by its index: _roll_recipe's exotic path varies the COUNT of the
	# canonical ingredient and never the type (see its header, and
	# CANONICAL_RECIPE). A mixed recipe cannot occur, so the old
	# duplicate/find/remove_at bookkeeping was matching against a case the
	# game does not have.
	var breath := _need_breath()
	for i in n:
		var res: int = recipe[i]
		var p := Vector2((float(i) - float(n - 1) * 0.5) * gap, 0.0)
		var filled := i < intake.size()
		# Feedback: the unfilled state read as too pale/washed-out to register
		# as "a shape" at all, and even the filled one was thinner than it
		# needed to be against the body fill. Sharper on both counts again —
		# unfilled 0.58 -> 0.8, filled 0.95 -> 1.0 — while keeping a clear
		# filled/unfilled contrast (still the whole point of the gauge).
		var col := Palette.of_res(res)
		col.a = (1.0 if filled else 0.8) + smelt_flash * 0.1
		var w := 2.9 if filled else 2.4
		var ss := s
		if not filled and (starve > 0.0 or reject > 0.0):
			col.a = lerpf(col.a, lerpf(0.42, 0.95, breath), starve)
			w = lerpf(w, lerpf(2.0, 3.2, breath), starve)
			ss = s * (1.0 + STARVE_BREATH * breath)
			# Per-slot phase offset, so the row shivers as several hungry
			# things and not as one rigid block sliding sideways.
			p += _need_offset(STARVE_AMP_SLOT, float(i) * 0.7)
		match res:
			Res.REFINED:
				_draw_mini_tri(p, ss, col, w, filled)
			Res.CLOTH:
				_draw_mini_square(p, ss * 0.85, col, w, filled)
			Res.PRISM:
				_draw_mini_pentagon(p, ss, col, w, filled)
			Res.HEXAGON:
				_draw_mini_hexagon(p, ss, col, w, filled)
			_:
				draw_arc(p, ss * 0.8, 0.0, TAU, arc_points(ss * 0.8), col, w, true)
				if filled:
					var fill := col
					fill.a *= 0.75
					draw_circle(p, ss * 0.8, fill)


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
