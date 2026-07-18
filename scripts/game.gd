extends Node2D
## VEIN — run controller.
##
## Weekend-1 slice: Wells, the Heart, vein drawing, dots flowing, appetite
## escalation, death. No Forges yet.
##
## The whole sim is deterministic given a seed, which is what later buys the
## Daily, replays and offline balancing for free. Keep it that way: no randomness
## outside `rng`, no logic that reads wall-clock time.

# Instantiate through preloaded consts, not the `class_name` globals: global
# class resolution is unreliable when the game is driven from a `--script` main
# loop, which is exactly how tests/ runs it.
const VNodeScene := preload("res://scripts/vnode.gd")
const VeinScene := preload("res://scripts/vein.gd")
const BurstScene := preload("res://scripts/burst.gd")
const FloatTextScene := preload("res://scripts/float_text.gd")

const SAVE_PATH := "user://vein.cfg"

## Bump whenever tuning changes what a score is worth. A best set on an easier
## curve is not a target, it is a wall — the 1244 from the 0.008 appetite build
## was unreachable after the rebalance and would just read as broken.
const TUNING_VERSION := 6

# --- Tuning. Everything the balance depends on lives here. -------------------
const START_BUDGET := 4
const FUEL_CAP := 5.0

## Fuel per item by resource. A Forge burns two RAW (2.0 of fuel) into one
## REFINED (3.0), so refining is worth 1.5x — but it costs an extra vein and
## adds latency, which is the trade. The bigger prize is that it HALVES the item
## count carrying that fuel, so a Forge in front of a bursting trunk is the tool
## for congestion, not just a multiplier.
## VOID is negative fuel: a corrupted Well doesn't stop feeding you, it feeds you
## poison, down the vein you built and came to rely on. Cutting it costs the
## throughput you were depending on — which is the point.
const FUEL_BY_RES := {
	VNode.Res.RAW: 1.0,
	VNode.Res.REFINED: 3.0,
	VNode.Res.CLOTH: 7.0,
	VNode.Res.PRISM: 15.0,
	VNode.Res.VOID: -2.5,
}

## A sloppy redraw is surgery while the body is awake. Cutting a live vein spills
## whatever was in flight and costs Heart fuel immediately. Rot is the exception:
## amputating poison is already punishment enough because it costs throughput.
const CUT_BLEED_BY_DOT := 0.35

## Tools arrive before the Heart asks for them. Seeing the piece first makes the
## demand flip feel like a test, not a hidden rule.
##
## FIRST_FORGE_TIME used to be 10.0 against a REFINED flip at t=14 — only 4s to
## notice the Forge, draw 2 veins, and let material travel + smelt, which the
## probe showed was unwinnable BY ANYONE: cap=1/2/4 all died within a beat or
## two of each other (21/26/26-27), seed-independent, because nothing can
## reach the Heart as REFINED before ~t=18-20 no matter how fast you play.
## That is a scripted death, not a skill test. Pulled both tools' lead time
## forward so a fast, correct build can actually beat its flip; the flip
## itself stays exactly as sudden.
const FIRST_FORGE_TIME := 4.0
const FORGE_GAP := 21.0
const FIRST_LOOM_TIME := 19.0
const LOOM_GAP := 36.0
## A Kiln needs a full Well->Forge->Loom chain already functioning before it's
## worth anything, so it gets the longest lead time of any tool — arriving
## comfortably after the CLOTH flip has had time to settle, not while the
## player is still mid-scramble re-plumbing for it.
const FIRST_KILN_TIME := 40.0
const KILN_GAP := 50.0

## What the Heart DEMANDS, by run-second. This is the game.
##
## The Forge was built as an optional fuel multiplier — an abstract 1.5x you
## cannot see — and playtest was blunt: "the red triangle is not understandable
## even to me." Correct, because an optional thing explains nothing. The doc
## always said it: "the Heart starts demanding refined shapes, not raw ones."
##
## Now the Heart wants ONE shape at a time and shows you which. Off-demand items
## are near-worthless (WRONG_SHAPE_FUEL), so when it flips to triangles your
## entire circle network is suddenly feeding it garbage and you must re-plumb
## every Well through a Forge, against the budget, against reach, while it
## starves. That is the strategy that was missing: the board you built is
## invalidated on a clock, and the whole run is about restructuring under fire.
##
## It also makes the Forge self-teaching — the Heart is visibly asking for a
## triangle, and only the triangle node makes triangles.
##
## This is the TEACHING schedule, walked once, in order — RAW, then REFINED,
## then CLOTH, then PRISM. What happens after the last entry is a different
## system entirely; see ROTATE_GAP_START below. Playtest: "we get to square
## and it never changes at all" — holding at the final tier forever made the
## whole second half of a long run static. A PRISM tier here, and the
## rotation phase that follows it, are both direct answers to that.
const DEMAND_TIERS := [
	{"at": 0.0, "res": VNode.Res.RAW},
	{"at": 14.0, "res": VNode.Res.REFINED},
	{"at": 37.0, "res": VNode.Res.CLOTH},
	{"at": 100.0, "res": VNode.Res.PRISM},
]

## Once every tier above has been introduced, demand stops marching forward
## and starts jumping randomly among everything unlocked so far — the Heart
## can suddenly want RAW again even after you've built all the way to PRISM,
## so nothing you built early is ever safe to walk away from for good.
## "Start simple, slowly go crazy": the gap between rotations shrinks (and
## gets less predictable, via _jitter) as intensity climbs, so the opening of
## this phase still gives time to react and the tail end genuinely doesn't.
const ROTATE_GAP_START := 26.0
const ROTATE_GAP_MIN := 8.0

## Feeding the Heart something it did not ask for: WASTED, never poison.
##
## This was -0.85 and it was the bug behind "when the heart turns to square and
## I connect square, I die — what am I missing?" Nothing. Audited at a flip:
## fuel went 3.73 -> 0.00 in 0.7s, because the moment demand changed, every item
## already in flight across a healthy 6-vein network hit for -0.85. Your own
## working network instantly became a poison pump aimed at the Heart, and the
## square you connected to fix it could not possibly arrive in time.
##
## The rule that was violated: A WORKING NETWORK MUST NEVER BE WORSE THAN NO
## NETWORK. At -0.85 you were strictly better off having built nothing, which
## inverts the entire game. The demand flip is still a hard survival gate —
## off-demand fuel is ~nothing, so a stale network starves you on the clock —
## but starving is a deadline you can race, not an execution.
const WRONG_SHAPE_FUEL := 0.05

## Appetite grows LINEARLY, on the CLOCK. Both halves of that matter.
##
## Linear, because against an exponential curve doubling your supply only buys a
## fixed increment, so skill is nearly worthless: measured 1 Well -> 109 beats,
## 2 -> 211, 4 -> 254, 10 -> 266. Five times the supply bought 26% more score.
## Against a linear curve, survival time scales with supply, so ten Wells is
## worth roughly ten times one — which is where the doc's 10x expert gap lives.
##
## On the clock rather than per beat, because a starving Heart SLOWS (see
## Beat.RATE_BY_STATE). With beat-indexed escalation, dying slowed the very curve
## that was killing you — the run stabilised into an endless limp instead of
## dying. Time doesn't care that you are dying.
##
## The pairing is the design: escalation on time, score on beats. A healthy Heart
## races, so it scores faster AND survives; a dying one crawls, scores nothing,
## and the curve keeps coming.
## Bisected against the bot: 0.008 -> ~1060 beats (far too easy), 0.021 -> ~176
## and the skill gap collapses to 4x because escalation outruns budget growth
## before you can build anything. 0.016 flattens the spread to 190-216, which
## means the run is over-determined and your choices stopped mattering. 0.013
## keeps the bot near 400 beats with a healthy 228-649 spread.
## The slap in the face is START_FUEL, not APPETITE_BASE.
##
## Raising BASE to 0.9 did open hard — and collapsed the skill gap to ~1.1x
## (2 Wells died at 137, the bot managed 146). A steep floor kills everyone
## early, so extra supply buys nothing and mastery stops paying. Same failure as
## the old exponential curve, wearing a different hat.
##
## REVERSED (July 2026, real playtest, not a probe number): "the Heart now
## OPENS nearly empty, no grace period" above was the previous answer, and it
## was wrong for a first-time human even though the bot handled it fine — a
## bot doesn't need a moment to read the board, aim a thumb, and learn the one
## verb. "Connect both Wells or die in the first two beats" reads as "the game
## is just hard," not "I am bad at this and will get better," which is the
## entire hook a run-based game needs. The fix is NOT the same mistake as
## raising BASE to 0.9: that made the whole CURVE steeper (appetite forever
## after also punished), while this only widens the OPENING buffer — the
## late-game slope (APPETITE_RATE, unchanged) is what still has to produce the
## skill gap, and it does (see probe numbers below). Slow start, hard finish.
const START_FUEL := 2.6
const APPETITE_BASE := 0.22
const APPETITE_RATE := 0.024    # per second

## Seconds of exertion before the heart is fully racing.
const EXERTION_SPAN := 150.0

## Missed feedings before the beat stops for good.
const MISSES_STRAINED := 1
const MISSES_DYING := 3
const MISSES_FATAL := 6

## Hard cap on live Wells. Playtest: "the circles grow and grow" — the board
## only ever accumulated. Wither alone can't hold the line, because it only
## catches Wells that are ORPHANED, and doubling the spawn rate doubled the
## inflow. Past this cap, a new Well displaces the most-neglected existing one
## (the oldest orphan) rather than piling on: the board churns instead of
## silting up, and the screen stays readable at phone size. Connected Wells are
## never displaced — you never lose something you were actually using.
const MAX_LIVE_WELLS := 14

# Spawns and budget are on the clock for the same reason as appetite.
const FIRST_WELL_TIME := 3.0
const WELL_GAP_START := 5.5
const WELL_GAP_DECAY := 0.45     # wells arrive faster and faster
const WELL_GAP_MIN := 3.25

const FIRST_BUDGET_TIME := 8.0
const BUDGET_GAP_START := 12.0
const BUDGET_GAP_GROWTH := 3.5  # ...while veins arrive slower and slower

## BOOSTERS. Three families, one shared pickup mechanic (reach it with a vein
## from an already-live node — see _add_vein): ONE_OFF is a rare, self-
## consuming pickup, gone the instant it's taken; PERSISTENT is a permanent,
## run-long perk that replaces whichever persistent perk you already hold;
## TIME_BASED is a stronger, temporary version of the same perk pool that
## expires on its own clock. Every PERSISTENT/TIME_BASED effect pairs a real
## benefit with a real, felt cost — no free multipliers, per the
## WRONG_SHAPE_FUEL lesson (an invisible or costless bonus explains nothing
## and gets ignored). A ONE_OFF grab stays pure: the detour to reach it, and
## the vein budget spent doing so, is already the cost.
##
## Playtest: "no boosts, combos, crazy features" — they existed, but at
## 24s/46s a run barely contained one. A mechanic the player never sees may as
## well not be implemented; both families stay rare enough to be a recurring
## decision ("detour for it, or hold the line?"), never a once-a-run curiosity.
const FIRST_ONE_OFF_TIME := 50.0
const ONE_OFF_GAP := 22.0

## A pure grab, no paired cost — see the family comment above. CLEANSE only
## makes sense with something to cleanse; SWAP_SYMBOLS banks a charge spent on
## the next drag between two live producing nodes (see _add_vein) instead of
## drawing a vein. EXTRA_SLOT raises whichever category (persistent or
## time-based) you next take a pickup from, from 1 slot to 2, for the rest of
## the run — chosen implicitly by whatever you take next, not at pickup time.
enum OneOff { SCORE_BURST, SWAP_SYMBOLS, EXTRA_SLOT, EXTRA_VEIN, CLEANSE }
const ONE_OFF_SCORE_BURST := 25
const EXTRA_VEIN_BUDGET := 1
## Weighted so CLEANSE never wastes itself as a no-op reroll when nothing is
## corrupted — see _roll_one_off.
const ONE_OFF_WEIGHTS := [0.24, 0.19, 0.14, 0.24, 0.19]

## Shared by both PERSISTENT and TIME_BASED — the same four effect types,
## offered in two flavours: a weaker permanent version and a stronger
## temporary one. SCORE's cost lands on APPETITE and APPETITE's cost lands on
## SCORE — the two sit on each other's benefit axis, so you cannot cheaply
## stack both directions at once.
enum BoosterEffect { SCORE, APPETITE, CAPACITY, REACH }

const FIRST_PERSISTENT_TIME := 12.0
## Gap counted from calendar time, not from when the current perk is replaced
## — a persistent offer is a genuine ongoing choice (keep what you hold, or
## trade it for the new offer), so unlike time-based it keeps arriving even
## while a slot is already full.
const PERSISTENT_GAP := 34.0

const FIRST_TIME_BASED_TIME := 65.0
## Gap counted from calendar time; the spawn gate itself (see _tick_escalation)
## only opens once a slot is actually free.
const TIME_BASED_GAP := 20.0
const TIME_BASED_DURATION := 14.0

## [benefit, cost] per BoosterEffect. Persistent is the weaker, permanent
## half; time-based is the stronger, temporary half of the same idea.
const PERSISTENT_SCORE_MULT := 1.15
const PERSISTENT_SCORE_COST_APPETITE := 1.15
const PERSISTENT_APPETITE_MULT := 0.85
const PERSISTENT_APPETITE_COST_SCORE := 0.9
const PERSISTENT_CAPACITY_MULT := 1.3
const PERSISTENT_CAPACITY_COST_BUDGET_GAP := 1.25
const PERSISTENT_REACH_MULT := 1.2
const PERSISTENT_REACH_COST_APPETITE := 1.15

const TIME_SCORE_MULT := 1.4
const TIME_SCORE_COST_APPETITE := 1.3
const TIME_APPETITE_MULT := 0.6
const TIME_APPETITE_COST_SCORE := 0.75
## Capacity's time-based cost is stronger than persistent's: the whole budget
## freezes for the duration (mirrors the old VAULT trade), not just a slower
## grow-rate.
const TIME_CAPACITY_MULT := 1.6
const TIME_REACH_MULT := 1.5
const TIME_REACH_COST_APPETITE := 1.35

const PERSISTENT_BENEFIT := {
	BoosterEffect.SCORE: PERSISTENT_SCORE_MULT,
	BoosterEffect.APPETITE: PERSISTENT_APPETITE_MULT,
	BoosterEffect.CAPACITY: PERSISTENT_CAPACITY_MULT,
	BoosterEffect.REACH: PERSISTENT_REACH_MULT,
}
const TIME_BENEFIT := {
	BoosterEffect.SCORE: TIME_SCORE_MULT,
	BoosterEffect.APPETITE: TIME_APPETITE_MULT,
	BoosterEffect.CAPACITY: TIME_CAPACITY_MULT,
	BoosterEffect.REACH: TIME_REACH_MULT,
}

## Rot that is never cut does not get to sit there forever as free clutter,
## poisoning at your leisure — it collapses outright, taking the asset with it.
## This is what makes the board turn over instead of only ever accumulating.
## The fade-warning threshold lives on VNode.COLLAPSE_FADE_AT, next to the
## corrupt_age it reads.

## Corruption gets meaner as the run does — this is the second half of "the
## enemy gets worse", on top of the fixed per-Well depletion. Both the vein-borne
## spread AND a new airborne jump (corruption leaping to an unconnected Well
## with no vein at all — a roaming blight, not just a plumbing hazard) scale in
## with intensity, gated to the back half of the run so the opening stays
## learnable and the mid-late game is where it goes feral.
const SPREAD_TIME_LATE := 5.0     ## VNode.SPREAD_TIME at intensity 1.0
const AIRBORNE_AT := 0.42         ## intensity floor before blight can jump gaps
const AIRBORNE_RADIUS := 190.0
const AIRBORNE_CHANCE := 0.35     ## per spread-tick, once AIRBORNE_AT is crossed

## Veins cannot cross — this is the spatial skill check: spaghetti is not a
## strategy. A bad draw is simply REFUSED (see _add_vein), not punished; it used
## to bleed fuel and destroy the crossed vein instead, which silently ate the
## Heart's most-needed rescue connection right where veins most converge.
## Rhythm is a pure carrot: an on-beat edit pays SYNC_FUEL and builds combo, an
## off-beat one just doesn't. There is deliberately no OFFBEAT penalty — see
## _tempo_action.
const SYNC_FUEL := 0.18
const PERFECT_WINDOW := 0.11
const GOOD_WINDOW := 0.22
const COMBO_GAIN := 0.07
const COMBO_CAP := 10

const SNAP := 48.0             # magnetic radius; imprecise thumbs feel precise
const LONG_PRESS := 0.32
const DILATION := 0.3
const DRAG_SLOP := 12.0

# --- Scene ------------------------------------------------------------------
@onready var vein_layer: Node2D = $VeinLayer
@onready var node_layer: Node2D = $NodeLayer
@onready var drag_layer: Node2D = $DragLayer
@onready var drain: ColorRect = $Fx/Drain
@onready var death_ui: Control = $Ui/Death
@onready var score_label: Label = $Ui/Death/Score
@onready var best_label: Label = $Ui/Death/Best
@onready var budget_hint: Node2D = $BudgetHint
@onready var score_hud: Node2D = $ScoreHud
@onready var restart_hint: Node2D = $RestartHint

var rng := RandomNumberGenerator.new()
var seed_used := 0

var nodes: Array[VNode] = []
var veins: Array[Vein] = []
var heart: VNode

var budget := START_BUDGET
var fuel := START_FUEL
var misses := 0
var alive := false
## Mirrors Beat.index. Survival time in heartbeats — what the harnesses read.
## Not the score: "the heartbeat is not important, it's the blood it
## receives that's important" — see `score` below, which is what's actually
## shown to the player.
var beats := 0

## The live score, shown in the HUD and on the death screen, compared
## against `best`. Reactive to every popped delivery (see _pop_gain) — a
## "+3" pop is a +3 here — so it reads 0 when nothing was ever connected,
## not some unrelated survival-time number.
var score := 0

## The number to beat. There is no winning in VEIN — every run ends — so the
## only thing that can pull a player back is their own last best.
var best := 0
var lifetime_beats := 0
var beat_best_this_run := false
## Persisted across runs (see _load_save/_store_save) — drives VNode.teach so
## the recipe demonstration plays on the first Forge/Loom/Kiln the player EVER
## sees, not every run once they already understand it.
var seen_forge := false
var seen_loom := false
var seen_kiln := false
## Ruptures this run. If this stays at zero, trunk capacity never binds and
## layout still does not matter — the probe watches it for exactly that reason.
var ruptures := 0
## Items destroyed on arrival at a node whose buffer was already full. Every one
## of these is pressure that vanished instead of backing up the network.
var dropped := 0
## VOID items that reached the Heart. If this is 0 across a run, the enemy never
## engaged and corruption is decorative.
var poisoned := 0
## Wells that ran dry and turned this run.
var corruptions := 0
## Wells withered from neglect, and rot collapsed outright. Both remove the
## node itself, so `nodes` undercounts everything that ever appeared once
## either of these fires — these are the cumulative truth the probe reads
## instead.
var withered := 0
var collapsed := 0
## One-offs nobody claimed before VNode.BOOST_LIFE ran out.
var one_offs_expired := 0
## Every node ever created, by kind — `nodes.size()` alone undercounts once
## withering/collapse can remove them mid-run.
var spawned_wells := 0
## Items the Heart accepted but did not want. High counts mean the player (or
## bot) failed to re-plumb after a demand flip.
var wasted := 0
## Consecutive edits made on the heartbeat. This is the mastery layer: elite
## play is not just topology, it is surgery in rhythm.
var combo := 0

## The shape the Heart wants right now. Drawn inside it — see VNode._draw_hex.
var demand: int = VNode.Res.RAW
## Every resource DEMAND_TIERS has introduced so far this run — the pool the
## post-teaching rotation phase draws from (see _tick_escalation).
var _unlocked_res: Array[int] = [VNode.Res.RAW]
var _next_rotate_time := INF

## Seconds this run has been alive. The escalation clock — see APPETITE_RATE.
var run_time := 0.0
var _next_well_time := FIRST_WELL_TIME
var _next_forge_time := FIRST_FORGE_TIME
var _next_loom_time := FIRST_LOOM_TIME
var _next_kiln_time := FIRST_KILN_TIME
var _next_one_off_time := FIRST_ONE_OFF_TIME
var _well_gap := WELL_GAP_START
var _next_budget_time := FIRST_BUDGET_TIME
var _budget_gap := BUDGET_GAP_START
var _next_persistent_time := FIRST_PERSISTENT_TIME
var _next_time_based_time := FIRST_TIME_BASED_TIME

var _appetite_clock := 0.0
## One-offs collected this run — useful for the probe to confirm they are
## actually being reached rather than sitting decorative.
var one_offs_taken := 0
var persistents_taken := 0
var time_baseds_taken := 0

## PERSISTENT perks currently held, in pick order — BoosterEffect ids. Never
## expires on its own; taking a new one evicts the oldest once at cap (see
## _apply_persistent). Pushed into heart.mutation_marks the instant it
## changes so the Heart wears every held perk on its own body, same spot
## every time, the same way a Forge's triangle or a Loom's square are learned
## by sight — see VNode._draw_mutation_marks.
var _active_persistent: Array[int] = []
## TIME_BASED perks currently held: {effect: BoosterEffect, remaining: float}.
## Each entry counts down independently (see _tick_time_based) so a second
## slot from EXTRA_SLOT can expire on its own schedule.
var _active_time_based: Array[Dictionary] = []
## How many concurrent slots each category allows — both start at 1; a
## ONE_OFF EXTRA_SLOT pickup raises whichever category you next take a
## pickup from to 2, for the rest of the run (see _pending_extra_slot).
var _persistent_cap := 1
var _time_based_cap := 1
## Set by an EXTRA_SLOT one-off; consumed by the very next PERSISTENT or
## TIME_BASED pickup taken, whichever comes first — that pickup's category is
## the one that gets the extra slot.
var _pending_extra_slot := false
## Set by a SWAP_SYMBOLS one-off; consumed by the next drag between two live
## producing nodes, which swaps what they each produce instead of drawing a
## vein between them (see _add_vein).
var _swap_charge := false

## Folded from _active_persistent + _active_time_based every time either
## changes (see _recompute_boosters) — the single set of modifiers every
## other system actually reads, so appetite()/fuel math/vein creation never
## need to know which category or how many stacked perks produced a number.
var _boost_score_mult := 1.0
var _boost_appetite_mult := 1.0
var _boost_capacity_mult := 1.0
var _boost_reach_mult := 1.0
## CAPACITY's persistent cost (budget grows slower) and time-based cost
## (budget growth pauses entirely) — kept separate because they are
## different mechanisms, not different strengths of the same one.
var _boost_budget_gap_mult := 1.0
var _boost_budget_frozen := false

var _drag_from: VNode = null
var _drag_pos := Vector2.ZERO
var _touch_start := Vector2.ZERO
var _touch_time := 0.0
var _touching := false
var _dilating := false
var _moved := false
## What the press landed on, before we know whether it turns into a drag or
## stays a stationary tap — see _on_press/_on_move/_on_release.
var _press_node: VNode = null
var _press_vein: Vein = null

var _rescue := 0.0
var _drain_amt := 0.0
var _sync_flash := 0.0
var _bad_tempo_flash := 0.0
## Time scale to restore when the panic-pinch ends. Captured on engage so the
## harnesses' scale survives.
var _pre_dilation_scale := 1.0


func _end_dilation() -> void:
	if not _dilating:
		return
	_dilating = false
	Engine.time_scale = _pre_dilation_scale


func _ready() -> void:
	_fit_desktop_window()
	drag_layer.draw.connect(_draw_drag)
	death_ui.hide()
	Beat.beat.connect(_on_beat)
	Beat.stopped.connect(_on_stopped)
	_load_save()
	start_run(0)
	_maybe_attach_harness()


## Desktop windows launch at project.godot's fixed window_width/height_override,
## which is only ever right for the one screen it happened to be tuned against
## — "hit play" on a bigger laptop still opened the same small fixed window.
## Maximizing hands the window manager the job of finding "as big as this
## screen allows" (it already knows about menu bars, docks, and multi-monitor
## setups, which a hand-computed size does not); stretch/aspect="keep" then
## letterboxes VEIN's phone aspect (design_size()) inside that, same as it
## already does for an arbitrarily-sized browser tab.
func _fit_desktop_window() -> void:
	if OS.has_feature("web") or OS.has_feature("mobile"):
		return
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)


func _load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	# Lifetime beats survive a rebalance; a best score does not.
	lifetime_beats = int(cfg.get_value("run", "lifetime", 0))
	if int(cfg.get_value("run", "tuning", 0)) == TUNING_VERSION:
		best = int(cfg.get_value("run", "best", 0))
	seen_forge = bool(cfg.get_value("run", "seen_forge", false))
	seen_loom = bool(cfg.get_value("run", "seen_loom", false))
	seen_kiln = bool(cfg.get_value("run", "seen_kiln", false))


func _store_save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("run", "best", best)
	cfg.set_value("run", "lifetime", lifetime_beats)
	cfg.set_value("run", "tuning", TUNING_VERSION)
	cfg.set_value("run", "seen_forge", seen_forge)
	cfg.set_value("run", "seen_loom", seen_loom)
	cfg.set_value("run", "seen_kiln", seen_kiln)
	cfg.save(SAVE_PATH)


## Dev harnesses, driven off the command line so they run inside a normal project
## launch — autoload singletons like Beat do not resolve as globals under a
## `--script` main loop, which is why these are attached rather than standalone.
##
##   --probe=N [--speed=X]        headless balance run
##   --shot=PATH [--after=S] [--speed=X]   render a frame (needs a window)
##
## Loaded dynamically so an exported build without tests/ still runs.
func _maybe_attach_harness() -> void:
	var probe_runs := 0
	var shot_path := ""
	var speed := 0.0
	var after := 20.0
	var cap := 0

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--probe"):
			probe_runs = int(a.get_slice("=", 1)) if a.contains("=") else 5
		elif a.begins_with("--shot="):
			shot_path = a.get_slice("=", 1)
		elif a.begins_with("--cap="):
			cap = int(a.get_slice("=", 1))
		elif a.begins_with("--speed="):
			speed = float(a.get_slice("=", 1))
		elif a.begins_with("--after="):
			after = float(a.get_slice("=", 1))

	if probe_runs > 0:
		var p: Node = _load_harness("res://tests/probe.gd")
		if p == null:
			return
		p.runs = probe_runs
		p.speed = speed if speed > 0.0 else 60.0
		p.cap = cap
		add_child(p)
	elif "--audiocheck" in OS.get_cmdline_user_args():
		var a: Node = _load_harness("res://tests/audiocheck.gd")
		if a != null:
			add_child(a)
	elif shot_path != "":
		var s: Node = _load_harness("res://tests/shot.gd")
		if s == null:
			return
		s.out_path = shot_path
		s.after = after
		s.speed = speed if speed > 0.0 else 3.0
		add_child(s)


func _load_harness(path: String) -> Node:
	if not ResourceLoader.exists(path):
		push_error("harness missing: %s" % path)
		return null
	var script: Script = load(path)
	return null if script == null else script.new()


# --- Run lifecycle ----------------------------------------------------------

func start_run(run_seed: int) -> void:
	Audio.start()
	for n in nodes:
		n.queue_free()
	for v in veins:
		v.queue_free()
	nodes.clear()
	veins.clear()

	seed_used = run_seed if run_seed != 0 else randi()
	rng.seed = seed_used

	budget = START_BUDGET
	fuel = START_FUEL
	misses = 0
	beats = 0
	score = 0
	ruptures = 0
	dropped = 0
	withered = 0
	collapsed = 0
	one_offs_expired = 0
	spawned_wells = 0
	poisoned = 0
	corruptions = 0
	wasted = 0
	combo = 0
	demand = VNode.Res.RAW
	_unlocked_res = [VNode.Res.RAW]
	_next_rotate_time = INF
	_rescue = 0.0
	_drain_amt = 0.0
	_sync_flash = 0.0
	_bad_tempo_flash = 0.0
	_appetite_clock = 0.0
	one_offs_taken = 0
	persistents_taken = 0
	time_baseds_taken = 0
	_active_persistent.clear()
	_active_time_based.clear()
	_persistent_cap = 1
	_time_based_cap = 1
	_pending_extra_slot = false
	_swap_charge = false
	_boost_score_mult = 1.0
	_boost_appetite_mult = 1.0
	_boost_capacity_mult = 1.0
	_boost_reach_mult = 1.0
	_boost_budget_gap_mult = 1.0
	_boost_budget_frozen = false
	run_time = 0.0
	_next_well_time = FIRST_WELL_TIME
	_next_forge_time = FIRST_FORGE_TIME
	_next_loom_time = FIRST_LOOM_TIME
	_next_kiln_time = FIRST_KILN_TIME
	_next_one_off_time = FIRST_ONE_OFF_TIME
	_well_gap = WELL_GAP_START
	_next_budget_time = FIRST_BUDGET_TIME
	_budget_gap = BUDGET_GAP_START
	_next_persistent_time = FIRST_PERSISTENT_TIME
	_next_time_based_time = FIRST_TIME_BASED_TIME

	var vp := design_size()
	heart = _make_node(VNode.Kind.HEART, Vector2(vp.x * 0.5, vp.y * 0.44))

	# Two wells to open with, placed relative to the Heart and inside its reach:
	# the first connection must be obvious, so the player learns the verb by
	# doing it rather than being told. Anchoring these to the viewport corners
	# instead would put them out of reach and open the run already lost.
	# One above, one below. New Wells only spawn within reach of an existing node,
	# so the network grows outward from these two — seeding both below the Heart
	# meant it could only ever creep downward and the top third of the screen
	# stayed empty for the whole run.
	_make_node(VNode.Kind.WELL, heart.position + Vector2(-142, -118))
	_make_node(VNode.Kind.WELL, heart.position + Vector2(146, 122))

	death_ui.hide()
	alive = true
	Beat.reset()
	_rebuild_graph()


## The playfield, in design space — NOT get_viewport_rect().
##
## One screen is the whole world (no pan, no zoom), and the stretch mode maps
## this rect onto whatever the device is. Reading the live viewport instead
## breaks the sim wherever the window is not 540x1170: headless reports a square
## 1170x1170, which pushed every Well past Vein.MAX_LEN and quietly made the
## probe unwinnable. Layout must not depend on the window, or the seed no longer
## determines the run.
func design_size() -> Vector2:
	return Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 540)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 1170)),
	)


func _make_node(kind: int, pos: Vector2) -> VNode:
	var n: VNode = VNodeScene.new()
	n.kind = kind
	n.position = pos
	if kind == VNode.Kind.WELL:
		spawned_wells += 1
	match kind:
		VNode.Kind.FORGE:
			n.produces = VNode.Res.REFINED
		VNode.Kind.LOOM:
			n.produces = VNode.Res.CLOTH
		VNode.Kind.KILN:
			n.produces = VNode.Res.PRISM
		_:
			n.produces = VNode.Res.RAW
	node_layer.add_child(n)
	nodes.append(n)
	return n


func _on_stopped(total: int) -> void:
	alive = false
	Audio.stop_all()
	# The run can die mid panic-pinch; never leave the world dilated. Only undo
	# our own dilation — blindly writing 1.0 here would stomp the time scale the
	# dev harnesses set, which silently dropped the probe back to real time.
	_end_dilation()

	lifetime_beats += total
	# Best/the death screen both track `score` — what the Heart actually
	# received — not survival time. `total` (beats) still feeds
	# lifetime_beats, a separate lifetime stat the harnesses read.
	beat_best_this_run = score > best
	if beat_best_this_run:
		best = score
	_store_save()

	score_label.text = "Score  %s" % _commas(score)
	# The target. Without something to beat, "one more run" has no hook — and
	# VEIN has no win state to offer instead.
	if beat_best_this_run:
		best_label.text = "Your best yet."
	else:
		best_label.text = "Best  %s" % _commas(best)
	death_ui.show()


func _commas(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


# --- The beat: consumption, escalation, death -------------------------------

func _on_beat(index: int) -> void:
	beats = index
	if not alive:
		return

	fuel -= appetite()
	if fuel < 0.0:
		fuel = 0.0
		misses += 1
	elif misses > 0:
		misses -= 1

	if misses >= MISSES_FATAL:
		Beat.stop()
		return
	elif misses >= MISSES_DYING:
		Beat.set_state(Beat.State.DYING)
	elif misses >= MISSES_STRAINED:
		Beat.set_state(Beat.State.STRAINED)
	else:
		Beat.set_state(Beat.State.HEALTHY)

	Beat.set_exertion(intensity())


## 0..1, how far into the escalation curve this run is. The single number
## everything downstream — exertion, the mix, corruption speed, particle
## violence — reads to know how crazy things should be right now.
func intensity() -> float:
	return clampf(run_time / EXERTION_SPAN, 0.0, 1.0)


## Fuel the Heart burns per beat, rising on the run clock — scaled by
## `_boost_appetite_mult`, folded from every active PERSISTENT/TIME_BASED
## APPETITE perk plus the appetite cost of every SCORE/REACH perk (see
## _recompute_boosters).
##
## The climb used to be a flat ramp: predictable the moment you'd seen a
## minute of it. A sine wave riding on top makes the hunger itself feel
## alive rather than a metronome — amplitude starts at zero (the opening
## stays exactly as learnable as before) and grows with intensity, so late
## in a run the Heart is genuinely surging and easing, not just climbing.
## Averages out to the same long-run curve; only the moment-to-moment texture
## changes, not the tuned difficulty.
const APPETITE_WAVE_AMP := 0.09
const APPETITE_WAVE_PERIOD := 17.0

func appetite() -> float:
	var base := APPETITE_BASE + APPETITE_RATE * _appetite_clock
	var wave := sin(_appetite_clock * TAU / APPETITE_WAVE_PERIOD) * APPETITE_WAVE_AMP * intensity()
	return maxf(0.02, (base + wave) * _boost_appetite_mult)


func fuel_cap() -> float:
	return FUEL_CAP


## Every spawn cadence used to be a flat interval — the exact same gap, every
## time, seed after seed — which reads as a metronome once you've played a
## few runs: "I know exactly when the next Boost lands." Wobbling each gap
## by up to `spread` (still drawn from the seeded `rng`, so a given seed is
## still fully reproducible) keeps the same average pace but breaks the
## predictability that made the board feel inert between events.
func _jitter(base: float, spread: float) -> float:
	return base * rng.randf_range(1.0 - spread, 1.0 + spread)


## Drives the spawn and budget clocks. Kept out of _on_beat so a slowing Heart
## cannot slow its own escalation.
func _tick_escalation(delta: float) -> void:
	run_time += delta
	_appetite_clock += delta

	_tick_time_based(delta)

	# A fresh PERSISTENT offer keeps arriving on a flat calendar cadence even
	# while a slot is already full — taking one is always a real trade (give
	# up what you hold), not something you have to wait to become eligible
	# for. A TIME_BASED offer only appears once an actual slot is free.
	if run_time >= _next_persistent_time and not _has_persistent_pair():
		_spawn_persistent_pair()
		_next_persistent_time += _jitter(PERSISTENT_GAP, 0.3)

	if run_time >= _next_time_based_time and _active_time_based.size() < _time_based_cap \
			and not _has_time_based_pair():
		_spawn_time_based_pair()
		_next_time_based_time += _jitter(TIME_BASED_GAP, 0.3)

	var want: int = demand
	for t in DEMAND_TIERS:
		if run_time >= t.at:
			want = t.res
			if not _unlocked_res.has(t.res):
				_unlocked_res.append(t.res)

	# Teaching schedule is over once every DEMAND_TIERS entry has landed —
	# from here, demand jumps randomly among everything unlocked instead of
	# sitting at PRISM forever (see ROTATE_GAP_START/MIN above). _next_rotate_time
	# starts at INF (see start_run) so the first crossing just arms the timer
	# rather than firing an immediate switch the instant PRISM lands.
	if run_time >= DEMAND_TIERS[-1].at and _next_rotate_time == INF:
		_next_rotate_time = run_time + _jitter(ROTATE_GAP_START, 0.3)
	elif run_time >= _next_rotate_time:
		var pool := _unlocked_res.duplicate()
		pool.erase(want)
		if not pool.is_empty():
			want = pool[rng.randi() % pool.size()]
		var gap := lerpf(ROTATE_GAP_START, ROTATE_GAP_MIN, intensity())
		_next_rotate_time = run_time + _jitter(gap, 0.35)

	if want != demand:
		demand = want
		heart.demand = want
		# The Heart changing its mind is the loudest event in the run: everything
		# you built is now feeding it the wrong thing.
		heart.pulse = 1.0
		Audio.play("corrupt", -6.0, 1.5)
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(220)

	if run_time >= _next_well_time:
		_spawn_well()
		_next_well_time += _jitter(_well_gap, 0.3)
		_well_gap = maxf(WELL_GAP_MIN, _well_gap - WELL_GAP_DECAY)

	if run_time >= _next_forge_time:
		_spawn_node(VNode.Kind.FORGE)
		_next_forge_time += _jitter(FORGE_GAP, 0.25)

	if run_time >= _next_loom_time:
		_spawn_node(VNode.Kind.LOOM)
		_next_loom_time += _jitter(LOOM_GAP, 0.2)

	if run_time >= _next_kiln_time:
		_spawn_node(VNode.Kind.KILN)
		_next_kiln_time += _jitter(KILN_GAP, 0.2)

	if run_time >= _next_one_off_time:
		_spawn_one_off()
		_next_one_off_time += _jitter(ONE_OFF_GAP, 0.4)

	# A time-based CAPACITY perk (see _recompute_boosters) freezes this: the
	# network stops expanding for the duration in exchange for a much bigger
	# vein throughput. run_time keeps sailing past _next_budget_time while
	# frozen, so the tick fires the instant the freeze ends rather than
	# losing the progress entirely.
	if not _boost_budget_frozen and run_time >= _next_budget_time:
		budget += 1
		_next_budget_time += _jitter(_budget_gap, 0.15)
		_budget_gap += BUDGET_GAP_GROWTH * _boost_budget_gap_mult
		budget_hint.queue_redraw()


## New Wells displace the most-neglected old one once the board is full, so the
## count stays flat and readable instead of climbing all run. Only orphans are
## ever displaced — a Well you actually wired in is safe.
func _spawn_well() -> void:
	var live: Array[VNode] = []
	for n in nodes:
		if n.kind == VNode.Kind.WELL and not n.corrupted:
			live.append(n)

	if live.size() >= MAX_LIVE_WELLS:
		var oldest: VNode = null
		for n in live:
			if n.depth >= 0:
				continue
			if oldest == null or n.orphan_age > oldest.orphan_age:
				oldest = n
		# Everything is connected and we're at cap: the player has earned a full
		# board, so skip this spawn rather than deleting something in use.
		if oldest == null:
			return
		withered += 1
		_remove_node(oldest)

	_spawn_node(VNode.Kind.WELL)


## Only one instant one-off ever sits on the board. Feedback: "you can't have
## multiple boosters at the same time... let's say you can have one active
## booster at the time." A fresh one-off still displaces whichever one is
## already there rather than being skipped, so the cadence stays exactly as
## regular as before — there is just never more than one to choose from.
const MAX_LIVE_ONE_OFFS := 1


func _spawn_one_off() -> void:
	var live: Array[VNode] = []
	for n in nodes:
		if n.kind == VNode.Kind.BOOST:
			live.append(n)

	if live.size() >= MAX_LIVE_ONE_OFFS:
		var oldest: VNode = null
		for n in live:
			if oldest == null or n.orphan_age > oldest.orphan_age:
				oldest = n
		_remove_node(oldest)

	_spawn_node(VNode.Kind.BOOST)


## New nodes spawn in awkward places, forcing rerouting. Bias to the lower two
## thirds so everything stays in one-thumb reach.
##
## A tool is placed by the opposite rule to a Well: it wants to sit CLOSE to the
## Heart, because its job is to stand between a cluster of Wells and the trunk
## they overload. Spawning it out at the rim like a Well would make it
## unroutable and it would never be worth the veins.
func _spawn_node(kind: int) -> void:
	var vp := design_size()
	var best := Vector2.ZERO
	var best_score := -INF

	# Grow OUTWARD from a node already on the board, at a uniformly random angle.
	#
	# Playtest: "the circles mostly spawn at the bottom." Two biases were stacked
	# and compounded: sqrt(randf()) pulled the y-roll downward, AND the score
	# rewarded distance from the Heart — which sits at 44% height, so the bottom
	# edge (573px away) beat the top (351px) every single time. Rejection
	# sampling over the whole rect also wasted most candidates, since anything
	# beyond MAX_LEN of everything is unjoinable. Seeding from an existing node
	# at a random bearing fills the board evenly and every candidate is reachable
	# by construction — reachable from the ANCHOR, at least.
	#
	# The anchor pool used to be every node on the board, connected or not.
	# That let a new Well/tool spawn off an already-orphaned node, growing an
	# island that could end up in reach of nothing the Heart's live network
	# ever touches — reported as "sometimes there's no possible move at all."
	# Anchoring to the connected component only guarantees every new node is
	# reachable from something you can actually build to right now (the Heart
	# itself always qualifies, so this pool is never empty).
	#
	# A Forge/Loom is a single point of failure for an entire demand tier —
	# unlike a Well, there is no redundant backup a moment later. Anchoring it
	# to any connected node (rather than the Heart specifically) meant its
	# reach guarantee only held at the instant it spawned: if THAT anchor
	# later withered or was cut loose, the tool's position never moved, and it
	# could end up outside MAX_LEN of everything the live network still
	# touches — a demand flip with no possible move to answer it, fair by
	# construction at spawn time but not for the rest of the run. The Heart's
	# position never changes and the Heart is never removed, so a Forge
	# anchors to it specifically, keeping it within one direct vein of the
	# Heart for the run's entire duration, not just the moment it appeared.
	#
	# A Loom is different: it doesn't just need to reach the Heart, it needs
	# to RECEIVE from a Forge (2 REFINED in, 1 CLOTH out) — bug report: "heart
	# wanted square, there was no square anywhere" plus "square wants two
	# triangles, there should be triangles somehow in reach for it". Anchoring
	# a Loom to the Heart the same way a Forge does guarantees Loom-to-Heart
	# reach but NOT Forge-to-Loom reach — the two tools would land as
	# independent siblings around the Heart with nothing ensuring they were
	# ever close enough to hand off to each other, which makes the square
	# exist but leaves it permanently unfeedable. A Loom instead anchors to
	# the MIDPOINT between the Heart and an existing Forge: both are within
	# MAX_LEN of a point roughly half as far away as either, so Forge->Loom
	# and Loom->Heart are both always directly drawable — a complete,
	# guaranteed-buildable Well->Forge->Loom->Heart chain, not just two
	# separately-reachable dead ends. A Kiln repeats exactly the same trick
	# one link further down the chain: it anchors to the midpoint between the
	# Heart and an existing Loom, so Loom->Kiln->Heart is guaranteed the same
	# way Forge->Loom->Heart is.
	var connected: Array[VNode] = []
	for n in nodes:
		if n.depth >= 0:
			connected.append(n)
	if connected.is_empty():
		connected = nodes

	var is_tool := kind == VNode.Kind.FORGE or kind == VNode.Kind.LOOM or kind == VNode.Kind.KILN
	var anchor_point := heart.position
	var min_dist := 112.0
	var max_dist := Vein.MAX_LEN * 0.9
	if kind == VNode.Kind.LOOM:
		var forge := _random_node_of_kind(VNode.Kind.FORGE)
		if forge != null:
			anchor_point = (heart.position + forge.position) * 0.5
			min_dist = 40.0
			max_dist = 90.0
	elif kind == VNode.Kind.KILN:
		var loom := _random_node_of_kind(VNode.Kind.LOOM)
		if loom != null:
			anchor_point = (heart.position + loom.position) * 0.5
			min_dist = 40.0
			max_dist = 90.0

	for _i in 64:
		var p: Vector2
		if is_tool:
			var bearing := rng.randf() * TAU
			var dist := rng.randf_range(min_dist, max_dist)
			p = anchor_point + Vector2(cos(bearing), sin(bearing)) * dist
		else:
			var anchor: VNode = connected[rng.randi() % connected.size()]
			var bearing := rng.randf() * TAU
			var dist := rng.randf_range(112.0, Vein.MAX_LEN * 0.9)
			p = anchor.position + Vector2(cos(bearing), sin(bearing)) * dist
		if p.x < 56.0 or p.x > vp.x - 56.0 or p.y < 70.0 or p.y > vp.y - 70.0:
			continue

		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near < 104.0:
			continue

		var to_heart := p.distance_to(heart.position)
		var s := 0.0
		if is_tool:
			# Tools must stand between a cluster of supply and the Heart.
			s = -to_heart
		else:
			# Prefer awkward — elbow room from neighbours — WITHOUT preferring a
			# compass direction. Distance from the Heart is deliberately not a
			# term here; that was the bias.
			s = near
		if s > best_score:
			best_score = s
			best = p

	if best_score == -INF:
		if not is_tool:
			return
		# A tool is NOT allowed to just silently fail to spawn because its
		# usual ring is crowded — that IS the "no square anywhere" bug.
		# Guaranteed placement: whichever fixed bearing around the anchor
		# point is least crowded, elbow-room minimum ignored if it has to be.
		# A little visual overlap costs far less than the tool not existing.
		best = _least_crowded_spot(anchor_point, (min_dist + max_dist) * 0.5)
	var n := _make_node(kind, best)
	if kind == VNode.Kind.BOOST:
		n.boost_effect = _roll_one_off()
		n.label = _one_off_headline(n.boost_effect)
	elif kind == VNode.Kind.FORGE and not seen_forge:
		seen_forge = true
		n.teach = true
		_store_save()
	elif kind == VNode.Kind.LOOM and not seen_loom:
		seen_loom = true
		n.teach = true
		_store_save()
	elif kind == VNode.Kind.KILN and not seen_kiln:
		seen_kiln = true
		n.teach = true
		_store_save()
	_rebuild_graph()


func _random_node_of_kind(kind: int) -> VNode:
	var matches: Array[VNode] = []
	for n in nodes:
		if n.kind == kind:
			matches.append(n)
	return matches[rng.randi() % matches.size()] if not matches.is_empty() else null


## Guaranteed fallback placement for a tool when the normal rejection search
## above found nowhere valid: whichever of a fixed ring of bearings around
## `center` is farthest from every existing node, so a Forge/Loom always gets
## SOMEWHERE on the board rather than silently not spawning at all.
func _least_crowded_spot(center: Vector2, dist: float) -> Vector2:
	var best := center + Vector2(dist, 0.0)
	var best_near := -INF
	for i in 24:
		var a := TAU * float(i) / 24.0
		var p := center + Vector2(cos(a), sin(a)) * dist
		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near > best_near:
			best_near = near
			best = p
	return best


## Where the next Relic/Mutation fork centers. Reuses the exact same
## anchor-off-a-connected-node search Wells and Boosts already use to spread
## across the whole board, rather than the fixed 96px ring around the Heart
## both forks used to spawn on unconditionally. Feedback: "boosters should
## spawn anywhere in the screen not just near the heart."
##
## The two halves of a fork sit ANCHOR_HALF_SPREAD apart from this point, so
## the search keeps its own distance from a connected node short enough
## (well under Vein.MAX_LEN) that both halves stay in reach of it no matter
## which way the pair happens to be split.
const PICKUP_ANCHOR_MIN := 90.0
const PICKUP_ANCHOR_MAX := 140.0
const PICKUP_HALF_SPREAD := 40.0

func _random_pickup_anchor() -> Vector2:
	var vp := design_size()
	var connected: Array[VNode] = []
	for n in nodes:
		if n.depth >= 0:
			connected.append(n)
	if connected.is_empty():
		connected = nodes

	var best := heart.position
	var best_near := -INF
	for _i in 48:
		var anchor: VNode = connected[rng.randi() % connected.size()]
		var bearing := rng.randf() * TAU
		var dist := rng.randf_range(PICKUP_ANCHOR_MIN, PICKUP_ANCHOR_MAX)
		var p: Vector2 = anchor.position + Vector2(cos(bearing), sin(bearing)) * dist
		if p.x < 70.0 or p.x > vp.x - 70.0 or p.y < 90.0 or p.y > vp.y - 90.0:
			continue
		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near > best_near:
			best_near = near
			best = p
	return best


## Rolled from the seeded run RNG, not global randf() — the whole sim stays
## deterministic given a seed, which is what the Daily and the probe both rely
## on. CLEANSE only makes sense with something to cleanse; falling back to
## Rolled from the seeded run RNG, not global randf() — the whole sim stays
## deterministic given a seed. CLEANSE only makes sense with something to
## cleanse; weighted down to zero (see ONE_OFF_WEIGHTS) when nothing is
## corrupted so a one-off is never a wasted no-op.
func _roll_one_off() -> int:
	var has_target := false
	for n in nodes:
		if n.corrupted:
			has_target = true
			break

	var weights := ONE_OFF_WEIGHTS.duplicate()
	if not has_target:
		weights[OneOff.CLEANSE] = 0.0

	var total := 0.0
	for w in weights:
		total += w
	var roll := rng.randf() * total
	var acc := 0.0
	for i in weights.size():
		acc += weights[i]
		if roll <= acc:
			return i
	return OneOff.EXTRA_VEIN


## The readable icon label for a one-off — see the label field on VNode.
func _one_off_headline(id: int) -> String:
	match id:
		OneOff.SCORE_BURST:
			return "+%d" % ONE_OFF_SCORE_BURST
		OneOff.SWAP_SYMBOLS:
			return "⇄"
		OneOff.EXTRA_SLOT:
			return "+1 slot"
		OneOff.EXTRA_VEIN:
			return "+%d" % EXTRA_VEIN_BUDGET
		_: # CLEANSE — the cured node's own un-rotting is the confirmation.
			return ""


## Spawns the two halves of one PERSISTENT fork, symmetric about a random
## board anchor (see _random_pickup_anchor) so both are always in easy
## one-thumb reach. Rolled from the seeded rng, so a given seed always offers
## the same choice.
func _spawn_persistent_pair() -> void:
	var pool: Array = [
		BoosterEffect.SCORE, BoosterEffect.APPETITE,
		BoosterEffect.CAPACITY, BoosterEffect.REACH,
	]
	var i := rng.randi() % pool.size()
	var id_a: int = pool[i]
	pool.remove_at(i)
	var id_b: int = pool[rng.randi() % pool.size()]

	var vp := design_size()
	var center := _random_pickup_anchor()
	var ang := rng.randf() * TAU
	var a_pos: Vector2 = center + Vector2(cos(ang), sin(ang)) * PICKUP_HALF_SPREAD
	var b_pos: Vector2 = center + Vector2(cos(ang + PI), sin(ang + PI)) * PICKUP_HALF_SPREAD
	a_pos.x = clampf(a_pos.x, 40.0, vp.x - 40.0)
	a_pos.y = clampf(a_pos.y, 60.0, vp.y - 60.0)
	b_pos.x = clampf(b_pos.x, 40.0, vp.x - 40.0)
	b_pos.y = clampf(b_pos.y, 60.0, vp.y - 60.0)

	var na := _make_node(VNode.Kind.MUTATION, a_pos)
	var nb := _make_node(VNode.Kind.MUTATION, b_pos)
	na.mutation_id = id_a
	nb.mutation_id = id_b
	na.mutation_pair = nb
	nb.mutation_pair = na
	na.label = _booster_headline(true, id_a)
	nb.label = _booster_headline(true, id_b)
	_rebuild_graph()


func _has_persistent_pair() -> bool:
	for n in nodes:
		if n.kind == VNode.Kind.MUTATION:
			return true
	return false


## Same structural trick as _spawn_persistent_pair, drawing from the same
## four-effect pool — a TIME_BASED pair offers any two of the four, not a
## fixed opposed pair, same as PERSISTENT.
func _spawn_time_based_pair() -> void:
	var pool: Array = [
		BoosterEffect.SCORE, BoosterEffect.APPETITE,
		BoosterEffect.CAPACITY, BoosterEffect.REACH,
	]
	var i := rng.randi() % pool.size()
	var id_a: int = pool[i]
	pool.remove_at(i)
	var id_b: int = pool[rng.randi() % pool.size()]

	var vp := design_size()
	var center := _random_pickup_anchor()
	var ang := rng.randf() * TAU
	var a_pos: Vector2 = center + Vector2(cos(ang), sin(ang)) * PICKUP_HALF_SPREAD
	var b_pos: Vector2 = center + Vector2(cos(ang + PI), sin(ang + PI)) * PICKUP_HALF_SPREAD
	a_pos.x = clampf(a_pos.x, 40.0, vp.x - 40.0)
	a_pos.y = clampf(a_pos.y, 60.0, vp.y - 60.0)
	b_pos.x = clampf(b_pos.x, 40.0, vp.x - 40.0)
	b_pos.y = clampf(b_pos.y, 60.0, vp.y - 60.0)

	var na := _make_node(VNode.Kind.RELIC, a_pos)
	var nb := _make_node(VNode.Kind.RELIC, b_pos)
	na.relic_id = id_a
	nb.relic_id = id_b
	na.relic_pair = nb
	nb.relic_pair = na
	na.label = _booster_headline(false, id_a)
	nb.label = _booster_headline(false, id_b)
	_rebuild_graph()


func _has_time_based_pair() -> bool:
	for n in nodes:
		if n.kind == VNode.Kind.RELIC:
			return true
	return false


## A bare "×1.2" reads the same whether it multiplies score, appetite,
## capacity, or reach — real confusion in practice, not a hypothetical:
## reported as "I got a ×1.2 booster and my score didn't go up 1.2x" when
## the perk taken was actually REACH (×1.2), not SCORE (×1.15/×1.4). The
## small inner glyph alone (see draw_mark) wasn't legible enough on its own
## to prevent that read. This prefix ties the number to its own axis inline,
## so the two numbers most likely to be confused for each other — REACH's
## ×1.2 and SCORE's ×1.15 — are never shown without also saying which is
## which.
const EFFECT_GLYPH := {
	BoosterEffect.SCORE: "★",
	BoosterEffect.APPETITE: "♥",
	BoosterEffect.CAPACITY: "═",
	BoosterEffect.REACH: "↔",
}

## The headline number for a perk's primary effect — same "eat it, see the
## multiplier" confirmation Notcoin/Hamster Kombat give a booster, so the
## payoff is legible the instant it's taken, not just inferred later from
## how the run happens to feel.
func _booster_headline(persistent: bool, effect: int) -> String:
	var mult: float = (PERSISTENT_BENEFIT if persistent else TIME_BENEFIT)[effect]
	var glyph: String = EFFECT_GLYPH[effect]
	if effect == BoosterEffect.CAPACITY and not persistent:
		return "%s×%.1f" % [glyph, mult]
	return "%s×%.2f" % [glyph, mult]


## Folds every currently-held perk (both families) into the single set of
## modifiers appetite()/fuel_cap()/in_reach()/_add_vein/_tick_escalation
## actually read — see the field comments above. Called any time either
## active array changes, so a stale scalar can never linger after a perk is
## replaced or expires.
func _recompute_boosters() -> void:
	_boost_score_mult = 1.0
	_boost_appetite_mult = 1.0
	_boost_capacity_mult = 1.0
	_boost_reach_mult = 1.0
	_boost_budget_gap_mult = 1.0
	_boost_budget_frozen = false

	for effect in _active_persistent:
		match effect:
			BoosterEffect.SCORE:
				_boost_score_mult *= PERSISTENT_SCORE_MULT
				_boost_appetite_mult *= PERSISTENT_SCORE_COST_APPETITE
			BoosterEffect.APPETITE:
				_boost_appetite_mult *= PERSISTENT_APPETITE_MULT
				_boost_score_mult *= PERSISTENT_APPETITE_COST_SCORE
			BoosterEffect.CAPACITY:
				_boost_capacity_mult *= PERSISTENT_CAPACITY_MULT
				_boost_budget_gap_mult *= PERSISTENT_CAPACITY_COST_BUDGET_GAP
			BoosterEffect.REACH:
				_boost_reach_mult *= PERSISTENT_REACH_MULT
				_boost_appetite_mult *= PERSISTENT_REACH_COST_APPETITE

	for inst in _active_time_based:
		match int(inst.effect):
			BoosterEffect.SCORE:
				_boost_score_mult *= TIME_SCORE_MULT
				_boost_appetite_mult *= TIME_SCORE_COST_APPETITE
			BoosterEffect.APPETITE:
				_boost_appetite_mult *= TIME_APPETITE_MULT
				_boost_score_mult *= TIME_APPETITE_COST_SCORE
			BoosterEffect.CAPACITY:
				_boost_capacity_mult *= TIME_CAPACITY_MULT
				_boost_budget_frozen = true
			BoosterEffect.REACH:
				_boost_reach_mult *= TIME_REACH_MULT
				_boost_appetite_mult *= TIME_REACH_COST_APPETITE


## Counts down every held TIME_BASED perk independently (a second slot from
## EXTRA_SLOT expires on its own schedule) and folds the survivors back in
## the instant anything changes.
func _tick_time_based(delta: float) -> void:
	var changed := false
	for i in range(_active_time_based.size() - 1, -1, -1):
		_active_time_based[i].remaining -= delta
		if _active_time_based[i].remaining <= 0.0:
			_active_time_based.remove_at(i)
			changed = true
	if changed:
		_recompute_boosters()


## Adds a PERSISTENT perk. Evicts the oldest held perk first once at cap —
## this IS the trade-off: a persistent slot is never a free stack, it is
## always "keep what I have, or take the new offer instead."
func _apply_persistent(effect: int) -> void:
	if _active_persistent.size() >= _persistent_cap:
		_active_persistent.remove_at(0)
	_active_persistent.append(effect)
	_recompute_boosters()
	if heart != null:
		heart.mutation_marks = _active_persistent.duplicate()


## Adds a TIME_BASED perk with its own countdown. Evicts the oldest-held
## (soonest-to-expire, since they were added in order) once at cap.
func _apply_time_based(effect: int) -> void:
	if _active_time_based.size() >= _time_based_cap:
		_active_time_based.remove_at(0)
	_active_time_based.append({"effect": effect, "remaining": TIME_BASED_DURATION})
	_recompute_boosters()


func _swappable(n: VNode) -> bool:
	return n.kind == VNode.Kind.WELL or n.kind == VNode.Kind.FORGE \
		or n.kind == VNode.Kind.LOOM or n.kind == VNode.Kind.KILN


## Shared payoff FX for every booster pickup — burst + a floating headline (if
## it has one) + audio + haptic. Same visual weight for a rare grab as for a
## rupture, just warm instead of violent.
func _booster_fx(n: VNode, col: Color, headline: String) -> void:
	var burst: Node2D = BurstScene.new()
	vein_layer.add_child(burst)
	var ring: Array[Vector2] = []
	var kinds: Array[int] = []
	for i in 10:
		var a := TAU * float(i) / 10.0
		ring.append(n.position + Vector2(cos(a), sin(a)) * 6.0)
		kinds.append(0)
	burst.spawn(ring, kinds, rng.randi(), col)

	if headline != "":
		var pop: Node2D = FloatTextScene.new()
		vein_layer.add_child(pop)
		pop.spawn(headline, n.position, col, 20)

	Audio.play("refined", -2.0, 1.5)
	if OS.has_feature("mobile"):
		Input.vibrate_handheld(180)


## Apply a one-off's effect and remove the node — this is the payoff for the
## detour to reach it.
func _take_one_off(n: VNode) -> void:
	one_offs_taken += 1
	var headline := n.label
	match n.boost_effect:
		OneOff.SCORE_BURST:
			score += ONE_OFF_SCORE_BURST
		OneOff.SWAP_SYMBOLS:
			_swap_charge = true
		OneOff.EXTRA_SLOT:
			_pending_extra_slot = true
		OneOff.EXTRA_VEIN:
			budget += EXTRA_VEIN_BUDGET
			budget_hint.queue_redraw()
		OneOff.CLEANSE:
			var target: VNode = null
			var best := INF
			for c in nodes:
				if not c.corrupted:
					continue
				var d := c.position.distance_to(n.position)
				if d < best:
					best = d
					target = c
			if target != null:
				target.uncorrupt()
				# No clean number for "cured" — the target's own visible
				# un-rotting is the confirmation, not a popup here.
			else:
				budget += EXTRA_VEIN_BUDGET
				budget_hint.queue_redraw()
				headline = "+%d" % EXTRA_VEIN_BUDGET
	_booster_fx(n, Palette.BOOST, headline)
	_remove_node(n)


## A vein reaching either half of a fork resolves the WHOLE fork — the road
## not taken has to visibly vanish, or the choice never reads as a choice.
func _take_persistent(n: VNode) -> void:
	persistents_taken += 1
	if _pending_extra_slot:
		_persistent_cap += 1
		_pending_extra_slot = false
	_apply_persistent(n.mutation_id)
	_booster_fx(n, Palette.PERSISTENT, n.label)

	var sibling := n.mutation_pair
	n.mutation_pair = null
	_remove_node(n)
	if sibling != null and is_instance_valid(sibling):
		sibling.mutation_pair = null
		_remove_node(sibling)


## Same fork resolution as _take_persistent — taking either half removes both
## — but this one starts a timer instead of a permanent modifier.
func _take_time_based(n: VNode) -> void:
	time_baseds_taken += 1
	if _pending_extra_slot:
		_time_based_cap += 1
		_pending_extra_slot = false
	_apply_time_based(n.relic_id)
	_booster_fx(n, Palette.RELIC, n.label)

	var sibling := n.relic_pair
	n.relic_pair = null
	_remove_node(n)
	if sibling != null and is_instance_valid(sibling):
		sibling.relic_pair = null
		_remove_node(sibling)


# --- Graph: everything flows downhill toward demand -------------------------

func _rebuild_graph() -> void:
	for n in nodes:
		n.depth = -1
	if heart == null:
		return
	heart.depth = 0
	var q: Array[VNode] = [heart]
	while not q.is_empty():
		var cur: VNode = q.pop_front()
		for v in veins:
			var o := v.other(cur)
			if o != null and o.depth < 0:
				o.depth = cur.depth + 1
				q.append(o)
	for v in veins:
		v.update_dir()
	budget_hint.queue_redraw()


func veins_used() -> int:
	return veins.size()


func can_afford() -> bool:
	return veins_used() < budget


func _find_vein(a: VNode, b: VNode) -> Vein:
	for v in veins:
		if (v.a == a and v.b == b) or (v.a == b and v.b == a):
			return v
	return null


## Can these two ever be joined directly? Reach is the constraint the whole
## puzzle rests on — see Vein.MAX_LEN. A REACH perk raises the multiplier for
## as long as it's held.
func in_reach(a: VNode, b: VNode) -> bool:
	return a.position.distance_to(b.position) <= Vein.MAX_LEN * _boost_reach_mult


func _add_vein(a: VNode, b: VNode) -> void:
	if a == b or not can_afford() or _find_vein(a, b) != null or not in_reach(a, b):
		return

	# A booster pickup is not part of the flow graph — reaching for one is a
	# detour, not a route. It triggers the instant a vein touches it, at full
	# value: no crossing-vein penalty, no tempo requirement, because punishing
	# a reward pickup for incidental geometry would just feel arbitrary.
	#
	# But the OTHER end of that drag must already be live (depth >= 0, i.e.
	# reachable from the Heart right now) — feedback: dragging from any stray,
	# unclaimed node let you snag a pickup for free without ever touching your
	# actual network, which made a pickup read as "just tap anywhere near it"
	# instead of "your network reached this". A pickup still never joins the
	# graph itself once taken, this only gates who may reach it.
	if a.kind == VNode.Kind.BOOST or b.kind == VNode.Kind.BOOST \
			or a.kind == VNode.Kind.MUTATION or b.kind == VNode.Kind.MUTATION \
			or a.kind == VNode.Kind.RELIC or b.kind == VNode.Kind.RELIC:
		var pickup_is_a := a.kind == VNode.Kind.BOOST or a.kind == VNode.Kind.MUTATION \
			or a.kind == VNode.Kind.RELIC
		var pickup: VNode = a if pickup_is_a else b
		var anchor: VNode = b if pickup_is_a else a
		if anchor.depth < 0:
			return
		match pickup.kind:
			VNode.Kind.BOOST:
				_take_one_off(pickup)
			VNode.Kind.MUTATION:
				_take_persistent(pickup)
			_: # RELIC
				_take_time_based(pickup)
		return

	# A banked SWAP_SYMBOLS charge (see OneOff.SWAP_SYMBOLS) reuses this same
	# drag-connect verb — "one thumb, one verb" — rather than adding a second
	# gesture: while a charge is banked, dragging between two live producing
	# nodes swaps what they each make instead of drawing a vein between them.
	if _swap_charge and _swappable(a) and _swappable(b):
		var tmp := a.produces
		a.produces = b.produces
		b.produces = tmp
		_swap_charge = false
		_booster_fx(a, Palette.BOOST, "⇄")
		return

	# Crossing BLOCKS the connection — it does not destroy the crossed vein.
	#
	# Playtest: "when the heart changes to square and I connect square to it, I
	# die." Root cause: the Heart is where the most veins converge, so the
	# rescue connection you most need to complete is also the one geometrically
	# likeliest to cross something. The old behaviour silently failed to create
	# the new vein AND bled fuel AND ruptured a different, unrelated vein — from
	# the player's side the drag visually snapped, nothing looked wrong, and the
	# game had actually destroyed a load-bearing connection and cost fuel while
	# never delivering the CLOTH that would have saved them. Spaghetti-avoidance
	# is still a real constraint (the drag preview still warns in red and the
	# connection is refused), it just no longer punishes you for a geometry
	# mistake with more than "try a different angle."
	if _crossing_vein(a, b) != null:
		return

	var synced := _tempo_action()
	var v: Vein = VeinScene.new()
	# Alternate the bend so parallel veins fan out instead of overlapping.
	v.setup(a, b, 1.0 if veins.size() % 2 == 0 else -1.0)
	v.tempo_grade = combo if synced else -1
	# Baked in at creation, same as tempo_grade — see Vein.capacity_mult.
	v.capacity_mult = _boost_capacity_mult
	v.ruptured.connect(_on_ruptured)
	vein_layer.add_child(v)
	veins.append(v)
	_rebuild_graph()


func _tempo_action() -> bool:
	var q := _tempo_quality()
	if q <= GOOD_WINDOW:
		combo = mini(combo + (2 if q <= PERFECT_WINDOW else 1), COMBO_CAP)
		_sync_flash = 1.0
		var gain := SYNC_FUEL * (1.0 + float(combo) * 0.08)
		fuel = clampf(fuel + gain, 0.0, fuel_cap())
		Audio.sync_hit(combo, q <= PERFECT_WINDOW)
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(30 + combo * 6)
		return true

	# Off-beat costs you the COMBO and nothing else — no fuel, no hurt sound.
	#
	# It used to bleed OFFBEAT_BLEED fuel and play the "corrupt" (hurt) cue on
	# every edit. Two problems, both reported: it taxed the rescue connection at
	# the exact moment you could least afford it (see WRONG_SHAPE_FUEL for the
	# audit), and it fired the hurt sound when you were merely wiring two
	# ISOLATED nodes together to prepare a Forge — nowhere near the Heart, and
	# hurting nothing. The hurt cue now belongs exclusively to the Heart taking
	# damage (see _deliver). Rhythm is a carrot: play on the beat and you get
	# fuel and a rising combo; miss and you simply don't. Building is never
	# punished, so a vein is always safe to draw.
	combo = 0
	_bad_tempo_flash = 1.0
	return false


func _tempo_quality() -> float:
	return minf(Beat.phase, 1.0 - Beat.phase)


## Shared teardown for a node leaving the board outside of the normal
## rupture/cut paths — booster pickups, withered Wells, collapsed rot. Always
## drops any vein still attached (there should be at most one for a one-off
## pickup; a withered/collapsed node is by definition orphaned or about to be
## cut).
func _remove_node(n: VNode) -> void:
	for v in veins.duplicate():
		if v.a == n or v.b == n:
			_remove_vein(v)
	nodes.erase(n)
	n.queue_free()
	if heart == n:
		heart = null
	_rebuild_graph()


## A trunk carried more than it could bear. The dots in flight scatter and die,
## the vein is destroyed, and the budget point comes back — so a rupture is a
## loss of throughput and position, never of resources you can't rebuild.
func _on_ruptured(v: Vein) -> void:
	ruptures += 1
	var pts: Array[Vector2] = []
	var kinds: Array[int] = []
	for d in v.dots:
		pts.append(v.sample(d.t))
		kinds.append(d.kind)

	if not pts.is_empty():
		var burst: Node2D = BurstScene.new()
		vein_layer.add_child(burst)
		burst.spawn(pts, kinds, rng.randi(), Color(0, 0, 0, 0), intensity())

	Audio.play("rupture", -3.0, randf_range(0.9, 1.1))
	if OS.has_feature("mobile"):
		Input.vibrate_handheld(180)

	_remove_vein(v)


func _remove_vein(v: Vein, surgical := false) -> void:
	var synced := true
	if surgical:
		synced = _tempo_action()
	if surgical and not (v.a.corrupted or v.b.corrupted) and not v.dots.is_empty():
		# Only spilling something the Heart actually WANTS costs you. Cutting a
		# vein full of wrong-shape cargo is free, because that cargo was already
		# worth nothing — charging for it taxed exactly the re-plumbing a demand
		# flip forces you into, on top of the flip itself.
		var precious := 0
		for d in v.dots:
			if d.kind == demand:
				precious += 1
		var bleed := float(precious) * CUT_BLEED_BY_DOT
		if synced:
			bleed *= 0.25
		fuel = maxf(0.0, fuel - bleed)
		var pts: Array[Vector2] = []
		var kinds: Array[int] = []
		for d in v.dots:
			pts.append(v.sample(d.t))
			kinds.append(d.kind)
		var burst: Node2D = BurstScene.new()
		vein_layer.add_child(burst)
		burst.spawn(pts, kinds, rng.randi(), Color(0, 0, 0, 0), intensity())
		Audio.play("rupture", -8.0, 0.75)
	veins.erase(v)
	# die() lets the vein shrink-and-fade in place (see vein.gd) instead of
	# blinking out — the removal itself needs to be visible even when there
	# was nothing precious in flight to burst, which is the common case for a
	# vein you'd actually choose to cut.
	v.die()
	_rebuild_graph()


func _crossing_vein(a: VNode, b: VNode) -> Vein:
	for v in veins:
		if v.a == a or v.a == b or v.b == a or v.b == b:
			continue
		if _segments_cross(a.position, b.position, v.a.position, v.b.position):
			return v
	return null


func _segments_cross(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> bool:
	var r := a1 - a0
	var s := b1 - b0
	var den := r.cross(s)
	if absf(den) < 0.001:
		return false
	var t := (b0 - a0).cross(s) / den
	var u := (b0 - a0).cross(r) / den
	return t > 0.04 and t < 0.96 and u > 0.04 and u < 0.96


# --- Sim --------------------------------------------------------------------

func _process(delta: float) -> void:
	# A frame hitch must not teleport the sim — see Beat.MAX_DELTA.
	delta = minf(delta, Beat.MAX_DELTA)
	_rescue = maxf(0.0, _rescue - delta * 2.2)
	_sync_flash = maxf(0.0, _sync_flash - delta * 3.8)
	_bad_tempo_flash = maxf(0.0, _bad_tempo_flash - delta * 4.4)

	var target_drain := 0.0
	if not alive:
		target_drain = 1.0
	elif Beat.state == Beat.State.DYING:
		target_drain = 0.55
	elif Beat.state == Beat.State.STRAINED:
		target_drain = 0.2
	_drain_amt = Vein._smooth(_drain_amt, target_drain, 1.6, delta)
	drain.material.set_shader_parameter("drain", _drain_amt)
	drain.material.set_shader_parameter("warm", _rescue)

	if _touching and not _moved and not _dilating:
		_touch_time += delta
		if _touch_time >= LONG_PRESS and _drag_from == null:
			_dilating = true
			_pre_dilation_scale = Engine.time_scale
			Engine.time_scale = _pre_dilation_scale * DILATION

	if not alive:
		return

	_tick_escalation(delta)
	_tick_corruption(delta)
	_tick_lifecycle(delta)
	heart.fuel_ratio = fuel / fuel_cap()
	_push_from_nodes()
	for v in veins:
		for kind in v.advance(delta):
			_deliver(kind, v, v.sink())

	# Driven every frame, not per-beat: a dying run's beats slow way down, and
	# the mix must keep evolving smoothly through that instead of freezing
	# between rare beats. This is the whole fix for "the sound doesn't
	# progress" — it is now a continuous function of the run, not a state
	# machine that jumps between fixed stages.
	Audio.set_intensity(intensity())
	Audio.set_tension(float(combo) / float(COMBO_CAP))
	Audio.set_corruption(_corruption_ratio())

	budget_hint.queue_redraw()
	drag_layer.queue_redraw()
	queue_redraw()


## Fraction of live Wells currently corrupted. Drives the corruption drone —
## the mix should sicken continuously as rot spreads, not just spike once per
## infection event.
func _corruption_ratio() -> float:
	var wells := 0
	var rotted := 0
	for n in nodes:
		if n.kind == VNode.Kind.WELL:
			wells += 1
			if n.corrupted:
				rotted += 1
	return 0.0 if wells == 0 else float(rotted) / float(wells)


func _draw() -> void:
	if heart == null or not alive:
		return

	var centre := heart.position
	var exert := clampf(run_time / EXERTION_SPAN, 0.0, 1.0)
	var phase := Beat.phase
	var beat_r := 48.0 + phase * (44.0 + exert * 54.0)

	var ring := Palette.HEART
	ring.a = (1.0 - phase) * (0.22 + exert * 0.22)
	draw_arc(centre, beat_r, 0.0, TAU, 72, ring, 1.5 + exert * 2.0, true)

	# An active TIME_BASED perk used to have zero on-screen presence beyond
	# the pickup pop — nothing distinguished the active window from ordinary
	# play, or told you WHICH perk you'd chosen. A ring that counts down
	# (shrinking as TIME_BASED_DURATION runs out), in the family's own
	# colour, plus the same mark glyph the pick-time hexagram wore and a
	# ticking "Ns" label, makes "still active", "which one", and "how long
	# left" all visible for the whole duration, not just its start. Offset
	# side by side when a second slot (see _time_based_cap) is also active.
	var n_active := _active_time_based.size()
	for i in n_active:
		var inst: Dictionary = _active_time_based[i]
		var t: float = clampf(float(inst.remaining) / TIME_BASED_DURATION, 0.0, 1.0)
		var off := Vector2((float(i) - float(n_active - 1) * 0.5) * 42.0, -104.0)
		var col := Palette.RELIC
		col.a = 0.18 + t * 0.22
		draw_arc(centre + off, 20.0 + t * 6.0, 0.0, TAU * t, 32, col, 2.5, true)
		var mark_col := Palette.RELIC
		mark_col.a = 0.55 + t * 0.3
		VNode.draw_mark(self, int(inst.effect), centre + off, 8.0, mark_col)
		var label_col := Palette.RELIC
		label_col.a = 0.5 + t * 0.35
		var label := "%ds" % maxi(1, roundi(float(inst.remaining)))
		var w := ThemeDB.fallback_font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		draw_string(ThemeDB.fallback_font, centre + off - Vector2(w * 0.5, -20.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, label_col)

	# The rhythm target. Used to sit at a flat baseline brightness and only
	# flash AFTER a hit — pure confirmation, nothing that could be learned by
	# watching it before acting. It now breathes brighter as the live beat
	# phase nears either edge of the hittable window (_tempo_quality is
	# lowest right after a beat lands and right before the next one), the
	# same "get brighter as the good moment approaches" language every rhythm
	# game uses, so the target teaches its own timing just by being watched.
	var live_q := minf(phase, 1.0 - phase)
	var anticipate := 1.0 - clampf(live_q / GOOD_WINDOW, 0.0, 1.0)
	var window := Palette.WARM
	window.a = 0.12 + anticipate * 0.5 + _sync_flash * 0.45
	draw_arc(centre, 58.0, -PI * 0.5 - PERFECT_WINDOW * TAU,
		-PI * 0.5 + PERFECT_WINDOW * TAU, 18, window,
		2.0 + anticipate * 2.5 + _sync_flash * 3.0, true)

	if _bad_tempo_flash > 0.0:
		var bad := Palette.VEIN_STRAINED
		bad.a = _bad_tempo_flash * 0.65
		draw_arc(centre, 74.0 + (1.0 - _bad_tempo_flash) * 24.0, 0.0, TAU, 44,
			bad, 4.0 * _bad_tempo_flash, true)

	if combo > 0:
		var teeth := combo
		for i in teeth:
			var a := TAU * (float(i) / float(COMBO_CAP)) - PI * 0.5
			var p0 := centre + Vector2(cos(a), sin(a)) * 72.0
			var p1 := centre + Vector2(cos(a), sin(a)) * (82.0 + _sync_flash * 8.0)
			var c := Palette.WARM.lerp(Palette.CLOTH, float(i) / float(COMBO_CAP))
			c.a = 0.65 + _sync_flash * 0.35
			draw_line(p0, p1, c, 3.0, true)


## Rot spreads down live veins. Leaving a necrotic Well wired in doesn't just
## poison the Heart — it takes the neighbours with it, so the punishment for
## ignoring one dead lifeline is losing that whole limb of your network.
func _tick_corruption(delta: float) -> void:
	# Rot gets meaner as the run does: the vein-borne spread tightens toward
	# SPREAD_TIME_LATE, and past AIRBORNE_AT it can also leap to an unconnected
	# Well with no vein at all — a second, distinct threat (a roaming blight,
	# not a plumbing hazard) that only matters once the run is far enough along
	# that the opening stays learnable.
	var exert := intensity()
	var spread_time := lerpf(VNode.SPREAD_TIME, SPREAD_TIME_LATE, exert)
	var airborne := exert >= AIRBORNE_AT

	var newly: Array[VNode] = []
	for n in nodes:
		if not n.corrupted:
			continue
		n.spread_accum += delta
		if n.spread_accum < spread_time:
			continue
		n.spread_accum = 0.0

		for v in veins:
			var o := v.other(n)
			if o != null and not o.corrupted and o.kind == VNode.Kind.WELL and o not in newly:
				newly.append(o)

		if airborne and rng.randf() < AIRBORNE_CHANCE:
			var jumped := _nearest_orphan_well(n.position, AIRBORNE_RADIUS)
			if jumped != null and jumped not in newly:
				newly.append(jumped)

	for n in newly:
		n.corrupt()
		corruptions += 1
		Audio.play("corrupt", -4.0, 0.62)
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(140)


func _nearest_orphan_well(from: Vector2, within: float) -> VNode:
	var best: VNode = null
	var best_d := within
	for n in nodes:
		if n.kind != VNode.Kind.WELL or n.corrupted:
			continue
		var d := from.distance_to(n.position)
		if d < best_d:
			best_d = d
			best = n
	return best


## Wells nobody ever wired in wither away; Boosts nobody ever claimed do too;
## rot nobody ever cut collapses outright. All three remove the node itself
## (see _remove_node), which is what keeps the board turning over instead of
## only ever accumulating — every object that appears either gets used, gets
## cut, or eventually leaves.
func _tick_lifecycle(_delta: float) -> void:
	for n in nodes.duplicate():
		if n.wither_ratio() >= 1.0:
			# Kept separate from `withered`, which the probe reads specifically
			# to tune Well-neglect pacing (see VNode.WITHER_TIME) — folding
			# one-off expiry into the same number would muddy that signal.
			if n.kind == VNode.Kind.BOOST:
				one_offs_expired += 1
			else:
				withered += 1
			_remove_node(n)
		elif n.collapse_ratio() >= 1.0:
			collapsed += 1
			var burst: Node2D = BurstScene.new()
			vein_layer.add_child(burst)
			var pts: Array[Vector2] = [n.position]
			var kinds: Array[int] = [VNode.Res.VOID]
			burst.spawn(pts, kinds, rng.randi(), Color(0, 0, 0, 0), intensity())
			Audio.play("corrupt", -6.0, 0.4)
			_remove_node(n)


## Every node with something buffered tries to hand it downhill.
func _push_from_nodes() -> void:
	for n in nodes:
		if n.kind == VNode.Kind.HEART or n.buffer.is_empty():
			continue
		var outs: Array[Vein] = []
		for v in veins:
			if v.source() == n:
				outs.append(v)
		if outs.is_empty():
			continue

		# Sample the backlog BEFORE pushing: the push below removes an item, so
		# checking afterwards always reads one short of full and never trips.
		var was_full := n.buffer.size() >= VNode.BUFFER_CAP

		# Round-robin so a node with two downhill veins splits between them, but
		# fall through to the others rather than stalling on a full one.
		var placed := false
		var start := n.next_out(outs.size())
		for i in outs.size():
			var v: Vein = outs[(start + i) % outs.size()]
			if v.inject(n.buffer[0]):
				n.buffer.remove_at(0)
				n.pulse = 1.0
				placed = true
				break

		# Strain is "this node cannot clear its backlog through these veins", not
		# "nothing moved this frame". A node pushes at most one item per frame but
		# can receive several from its children in the same frame, so it sits
		# permanently full — dropping the excess — while still placing one item
		# every frame. Keying off `placed` alone therefore reported healthy veins
		# right up until the run starved.
		# Only a genuinely full backlog counts as strain. A failed push on its own
		# does not: items must sit DOT_SPACING apart, so every vein refuses on
		# most frames simply waiting for the gap to open, and treating that as
		# blockage ruptured healthy direct links carrying a quarter of capacity.
		if was_full:
			for v in outs:
				v.note_blocked()


func _deliver(kind: int, v: Vein, to: VNode) -> void:
	if to == null:
		return
	if to.kind == VNode.Kind.HEART:
		# Near-miss engineering: a save when the heart is nearly gone must feel
		# enormous.
		if misses >= MISSES_DYING:
			_rescue = 1.0
			if OS.has_feature("mobile"):
				Input.vibrate_handheld(120)
		var gain := float(FUEL_BY_RES.get(kind, 1.0))
		var off_demand := kind != demand and kind != VNode.Res.VOID
		if off_demand:
			# Wrong shape is wasted, not damaging — so no hurt cue and no fuel
			# penalty. It gets a flat, dull "wrong note" via swallow() instead:
			# you hear that it landed and gave you nothing. It still gets a
			# visible (not numeric, not score-costing) alarm below — see
			# _pop_gain — so a stale network reads as something to go fix, not
			# free clutter to ignore.
			gain = WRONG_SHAPE_FUEL
			wasted += 1
			combo = 0
			_bad_tempo_flash = 1.0
		elif kind == demand and kind != VNode.Res.VOID:
			gain *= (1.0 + minf(float(combo), float(COMBO_CAP)) * COMBO_GAIN)
		fuel = clampf(fuel + gain, 0.0, fuel_cap())
		to.pulse = 1.0
		Audio.swallow(kind, fuel / fuel_cap(), kind == demand)
		if kind == VNode.Res.VOID:
			poisoned += 1
			if OS.has_feature("mobile"):
				Input.vibrate_handheld(90)
		var entry := _vein_entry_point(v, to)
		var out_dir := entry - to.position
		out_dir = out_dir.normalized() if out_dir.length() > 0.001 else Vector2.UP
		_pop_gain(kind, gain, entry, out_dir, off_demand)
	elif not to.take(kind):
		dropped += 1


## Where a delivered item visibly crossed into `to` — the point on its rim
## facing back along the vein it just travelled, not the node's centre.
## Every vein converges on the same centre point, so a pop anchored there
## couldn't be read back to the delivery that caused it; anchoring it to the
## vein's own approach direction ties the number to the actual blood that
## just arrived.
func _vein_entry_point(v: Vein, to: VNode) -> Vector2:
	var near := v.sample(0.9)
	var approach := to.position - near
	if approach.length() < 0.001:
		return to.position
	return to.position - approach.normalized() * to.radius()


## The Notcoin/Hamster-Kombat confirmation: a number pops out of the Heart
## and fades, right where the value actually landed, instead of only ever
## showing up as a fuel line that rose too gradually to read as "that
## delivery was worth more than the last one." The score moves by exactly
## what pops — a "+3" here is a +3 there — because the score IS the blood
## the Heart has received, not survival time (see `beats`).
##
## Wrong-shape drops (off_demand) are worth ~0 fuel by design (see
## WRONG_SHAPE_FUEL) — a numeric "+0" would read as a bug, and charging the
## score for them would resurrect the exact failure the WRONG_SHAPE_FUEL
## rewrite fixed (a working network becoming worse than no network). They
## still get a mark instead of total silence: proof that the delivery landed
## and did nothing, so a stale network reads as something to go re-plumb, not
## free clutter to leave connected forever. First pass at this made the mark
## small, dim, and text-only (13px, no burst) — verified the code path fires
## correctly every time, but playtest still reported "I don't see anything":
## right next to the Heart's own busy ring of overlays, a tiny dim glyph
## alone just doesn't win the eye. Sized and colored to match the numeric
## pops now, plus the same little burst every other board event gets, so it
## competes on equal visual footing instead of trying to be quiet about a
## real (if fuel-free) event.
func _pop_gain(kind: int, gain: float, at: Vector2, out_dir: Vector2, off_demand := false) -> void:
	# Jitter across the direction of drift, not against it — a sideways nudge
	# reads as "the same arrival, imprecisely placed"; a nudge along `out_dir`
	# would just look like a longer or shorter drift.
	var jitter := out_dir.rotated(PI * 0.5) * rng.randf_range(-6.0, 6.0)
	if off_demand:
		var warn := Palette.VEIN_STRAINED.lerp(Palette.WARM, 0.4)
		var ring: Array[Vector2] = []
		var kinds: Array[int] = []
		for i in 8:
			var a := TAU * float(i) / 8.0
			ring.append(at + Vector2(cos(a), sin(a)) * 5.0)
			kinds.append(0)
		var burst: Node2D = BurstScene.new()
		vein_layer.add_child(burst)
		burst.spawn(ring, kinds, rng.randi(), warn)

		var mark: Node2D = FloatTextScene.new()
		vein_layer.add_child(mark)
		mark.spawn("×", at + jitter, warn, 20, out_dir)
		return
	if absf(gain) < 0.5:
		return
	# A SCORE perk (see _recompute_boosters) multiplies score earning only —
	# never the poison hit below, and never the raw fuel gain already applied
	# in _deliver. The pop shows exactly what scored, per the comment above.
	var score_gain := gain if kind == VNode.Res.VOID else gain * _boost_score_mult
	var rounded := roundi(score_gain)
	score = maxi(0, score + rounded)
	var col: Color
	var text: String
	if kind == VNode.Res.VOID:
		col = Palette.VOID
		text = "%d" % rounded
	else:
		col = Palette.HEART
		text = "+%d" % rounded
	var pop: Node2D = FloatTextScene.new()
	vein_layer.add_child(pop)
	pop.spawn(text, at + jitter, col, 16, out_dir)


# --- Input: one thumb, one verb ---------------------------------------------

func _node_at(p: Vector2) -> VNode:
	var best: VNode = null
	var best_d := SNAP
	for n in nodes:
		var d := p.distance_to(n.position)
		if d <= maxf(best_d, n.radius()):
			best_d = d
			best = n
	return best


func _vein_at(p: Vector2) -> Vein:
	var best: Vein = null
	var best_d := Vein.HIT_RADIUS
	for v in veins:
		var d := v.distance_to_point(p)
		if d < best_d:
			best_d = d
			best = v
	return best


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_on_press(event.position)
		else:
			_on_release(event.position)
	elif event is InputEventScreenDrag:
		_on_move(event.position)


func _on_press(p: Vector2) -> void:
	# The corner icon works whether the run is alive or already over — the
	# death screen's tap-anywhere only ever fires post-death; this lets a
	# bad run be abandoned early instead of waiting it out.
	if restart_hint != null and restart_hint.hit(p):
		start_run(0)
		return
	if not alive:
		start_run(0)
		return
	_touching = true
	_touch_time = 0.0
	_moved = false
	_touch_start = p
	_drag_pos = p
	# Don't commit to "start a new vein from this node" yet. Near the Heart,
	# every vein converges inside its own 48px SNAP radius — that radius
	# exists to make DRAGGING forgiving, but it used to also swallow a
	# stationary tap aimed at cutting one of those veins (18px HIT_RADIUS,
	# much tighter) before the vein hit-test ever got a look, so the tap
	# silently no-opped via _add_vein(heart, heart). Recording both
	# candidates and deciding at release/move time (see below) fixes that
	# without changing how an actual drag behaves.
	_press_node = _node_at(p)
	_press_vein = _vein_at(p)
	_drag_from = null


func _on_move(p: Vector2) -> void:
	_drag_pos = p
	if not _moved and p.distance_to(_touch_start) > DRAG_SLOP:
		_moved = true
		# The gesture just became a real drag: commit to "new connection from
		# the pressed node" even if a vein also happened to be under the
		# initial touch point — near the Heart that's the common case, not
		# an edge case, since veins fan out from point-blank range.
		_drag_from = _press_node


func _on_release(p: Vector2) -> void:
	_touching = false
	if _dilating:
		_end_dilation()
		_drag_from = null
		return

	if _drag_from != null:
		var to := _node_at(p)
		if to != null and to != _drag_from:
			_add_vein(_drag_from, to)
		_drag_from = null
		return

	if not _moved:
		# A stationary tap: prefer cutting whatever vein was precisely under
		# the thumb over starting a connection from a node that merely
		# caught it in its wider magnetic radius.
		if _press_vein != null:
			_remove_vein(_press_vein, true)


## The provisional vein under the thumb, plus a highlight on whatever it would
## snap to. This is the only affordance the game ever shows.
func _draw_drag() -> void:
	if _drag_from == null or not alive:
		return

	# How far this node can reach. Only shown while dragging — the constraint
	# appears exactly when it is the question being asked, and never otherwise.
	var reach := Palette.HEART
	reach.a = 0.10
	drag_layer.draw_arc(_drag_from.position, Vein.MAX_LEN, 0.0, TAU, 64, reach, 1.5, true)

	var to := _node_at(_drag_pos)
	var end := _drag_pos if to == null else to.position
	var stretched := _drag_from.position.distance_to(end) > Vein.MAX_LEN
	var crossing := to != null and to != _drag_from and _crossing_vein(_drag_from, to) != null

	var col := Palette.VEIN_STRAINED if stretched or crossing else Palette.VEIN_LIVE
	col.a = 0.75
	drag_layer.draw_line(_drag_from.position, end, col, 3.0, true)

	if to == null:
		return
	var ok := to != _drag_from and can_afford() and _find_vein(_drag_from, to) == null \
		and in_reach(_drag_from, to) and not crossing
	var ring := Palette.WARM if ok else Palette.VEIN_STRAINED
	ring.a = 0.85
	drag_layer.draw_arc(to.position, to.radius() + 8.0, 0.0, TAU, 28, ring, 2.0, true)
