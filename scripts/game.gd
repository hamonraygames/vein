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
const ShatterScene := preload("res://scripts/shatter.gd")
const PoisonDartScene := preload("res://scripts/poison_dart.gd")
const SlashScene := preload("res://scripts/slash.gd")
const GhostScene := preload("res://scripts/ghost_spawn.gd")
const TitheScene := preload("res://scripts/tithe.gd")
const LeaderboardPanelScene := preload("res://scripts/leaderboard_panel.gd")
const NamePromptScene := preload("res://scripts/name_prompt.gd")
const RecoverPromptScene := preload("res://scripts/recover_prompt.gd")
const MainMenuScene := preload("res://scripts/main_menu.gd")

const SAVE_PATH := "user://vein.cfg"

## POST /score, POST /name, POST /rank, POST /run/start, POST /run/deliver,
## and POST /recover on server/leaderboard's AWS backend (Lambda + API
## Gateway, see there) — printed by server/leaderboard/deploy.sh on each
## deploy. Same host, six routes.
const LEADERBOARD_URL := "https://k5uxthoqdk.execute-api.eu-north-1.amazonaws.com/score"
const NAME_URL := "https://k5uxthoqdk.execute-api.eu-north-1.amazonaws.com/name"
const RANK_URL := "https://k5uxthoqdk.execute-api.eu-north-1.amazonaws.com/rank"
const RUN_START_URL := "https://k5uxthoqdk.execute-api.eu-north-1.amazonaws.com/run/start"
const DELIVER_URL := "https://k5uxthoqdk.execute-api.eu-north-1.amazonaws.com/run/deliver"
const RECOVER_URL := "https://k5uxthoqdk.execute-api.eu-north-1.amazonaws.com/recover"
## HTTPRequest has no timeout by default (0 = wait forever) — a flaky mobile
## connection or a WebView that silently never completes the request (both
## reported on real phones) left lb_state/name_state/rank_state stuck on
## "loading"/"Submitting..." with no way out. Every request node below gets
## this so a dead connection always resolves to "error" eventually instead
## of hanging the UI indefinitely.
const HTTP_TIMEOUT := 12.0

## Bump whenever tuning changes what a score is worth. A best set on an easier
## curve is not a target, it is a wall — the 1244 from the 0.008 appetite build
## was unreachable after the rebalance and would just read as broken.
const TUNING_VERSION := 15

# --- Tuning. Everything the balance depends on lives here. -------------------
## Was 4, which undercut VEIN.md's own pitch ("start with 5, earn more at
## milestones") — real playtest feedback said the opening felt vein-starved
## before a single Forge even existed. Back to the doc's number.
const START_BUDGET := 5
## Was a flat 5.0 that never grew while appetite (fuel burned per beat) climbs
## toward ~2.9 by late-game — the buffer against a single missed beat shrank
## to almost nothing exactly when supply gets hardest to keep up with. Real
## playtest (not the bot): "heart dying rate is very fast." Raised so a bad
## few seconds is survivable slack, not an instant strike against
## MISSES_FATAL — see START_FUEL below, sized to match.
const FUEL_CAP := 9.0

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
	VNode.Res.HEXAGON: 31.0,   # continues the 2^(n+1)-1 ladder: 1, 3, 7, 15, 31
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
## Was 4.0 — but that landed a Forge before the first extra Well even arrived,
## which is part of why the opening felt like a spawn flood. It now comes after
## a couple of Wells exist to feed it, still with lead time before the REFINED
## flip. During the tutorial the demand flip is held off entirely until the
## connect+chain lessons are done (see tutorial.gd), so the Forge is never a
## surprise there either.
const FIRST_FORGE_TIME := 9.0
## NOTE these gaps are throughput constants wearing a spawn constant's
## clothes: every tool dies by USE (vnode.gd's FORGE_YIELD/LOOM_YIELD/
## KILN_YIELD), so a tier's sustained rate is its yield divided by how fast a
## spent one is replaced — i.e. by this. Tightening them (22/36/50/70 ->
## 17/27/38/52) alongside raised tool caps was tried as the fix for the score
## ceiling and REJECTED — see MAX_LIVE_FORGES for the measurement and why
## more tools made the game harder rather than easier.
const FORGE_GAP := 22.0
const FIRST_LOOM_TIME := 22.0
const LOOM_GAP := 36.0
## A Kiln needs a full Well->Forge->Loom chain already functioning before it's
## worth anything, so it gets the longest lead time of any tool — arriving
## comfortably after the CLOTH flip has had time to settle, not while the
## player is still mid-scramble re-plumbing for it.
const FIRST_KILN_TIME := 40.0
const KILN_GAP := 50.0
## The Crucible — VEIN.md's own promised fifth tool, "only a rare Crucible
## can make" a hexagon. Needs the WHOLE Well->Forge->Loom->Kiln chain already
## standing before it is worth anything at all, one tier deeper than a Kiln
## needed, so its lead time is longer still — comfortably ahead of the
## HEXAGON flip in DEMAND_TIERS below, not a surprise dropped right as the
## Heart starts asking for one.
const FIRST_CRUCIBLE_TIME := 95.0
const CRUCIBLE_GAP := 70.0

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
## then CLOTH, then PRISM, then HEXAGON. What happens after the last entry is
## a different system entirely; see ROTATE_GAP_START below. Playtest: "we get
## to square and it never changes at all" — holding at the final tier forever
## made the whole second half of a long run static. A PRISM tier here, and
## the rotation phase that follows it, were the direct answer to that; the
## HEXAGON entry is the actual fifth tier the doc always promised, landing
## comfortably inside the EXERTION_SPAN=200 window (see pressure()) rather
## than past the point anyone survives to feel it.
## SPACED OUT (feedback: "we get to heart wants pentagon very fast — at 200
## points we go to pentagon, it's very quick"). These are seconds on
## _demand_clock, which only starts at the first feed, so they are already
## "seconds of actual play" rather than wall clock — the ladder was simply
## too steep past the tutorial. CLOTH 37 -> 50 and PRISM 100 -> 155 roughly
## double the time spent at the square, which is the tier where a player is
## first running a real Well->Forge->Loom chain and where the deep-chain
## skill actually gets learned; arriving at pentagon before that is solid is
## what made it feel both sudden AND lethal. HEXAGON follows it out to keep
## a comparable gap behind it.
##
## Tool lead times still clear these comfortably — FIRST_KILN_TIME is 40
## against a PRISM flip now at 155, FIRST_CRUCIBLE_TIME 95 against HEXAGON
## at 290 — so every tier is still introduced well before it is demanded.
const DEMAND_TIERS := [
	{"at": 0.0, "res": VNode.Res.RAW},
	{"at": 14.0, "res": VNode.Res.REFINED},
	{"at": 50.0, "res": VNode.Res.CLOTH},
	{"at": 155.0, "res": VNode.Res.PRISM},
	{"at": 290.0, "res": VNode.Res.HEXAGON},
]

## Feedback: the teaching-tier flips landed at the exact same _demand_clock
## second every single run — every OTHER clock in this file (Wells, Forges,
## Looms, budget, even the post-teaching rotation gap) goes through _jitter,
## this was the one schedule that didn't. Applied once per tier, at the
## moment the PREVIOUS tier lands, not re-rolled every frame — see
## _next_tier_time/_tier_time_idx and _tick_escalation. Kept tighter than the
## rotation-phase jitter (0.3-0.35): this schedule is still the TEACHING
## curve everything else's lead times (FIRST_FORGE_TIME etc.) are pinned
## against, so it shouldn't drift far enough to make a tool arrive after the
## demand that needs it.
const TEACHING_TIER_JITTER := 0.15

## Once every tier above has been introduced, demand stops marching forward
## and starts jumping randomly among everything unlocked so far — the Heart
## can suddenly want RAW again even after you've built all the way to PRISM,
## so nothing you built early is ever safe to walk away from for good.
## "Start simple, slowly go crazy": the gap between rotations shrinks (and
## gets less predictable, via _jitter) as intensity climbs, so the opening of
## this phase still gives time to react and the tail end genuinely doesn't.
const ROTATE_GAP_START := 26.0
## Physical floor under the tuned one below: the longest possible HEXAGON
## lineage — Well->Forge->Loom->Kiln->Crucible->Heart, five hops all at the
## single uniform Vein.MAX_LEN now that every pair shares one reach ceiling
## (see in_reach) — takes this long for a single item to physically cross,
## full stop. By the time rotation starts, HEXAGON (the deepest tier, added
## after PRISM) is always among the unlocked pool (see _tick_escalation), so
## this is the real worst case the floor has to clear, not a hypothetical one.
const WORST_CASE_HEXAGON_TRAVEL := (Vein.MAX_LEN * 5.0) / Vein.SPEED   # ~10.12s
## Absolute floor the rotation gap keeps creeping toward past EXERTION_SPAN
## (see pressure()) — below this a flip can't be answered at all, even in
## principle, and impossible stops being interesting. The 25% margin over
## WORST_CASE_HEXAGON_TRAVEL covers dot-spacing queueing and an unbalanced
## branch's assembly stall on top of pure travel.
const ROTATE_GAP_FLOOR := WORST_CASE_HEXAGON_TRAVEL * 1.25   # ~12.65s
## The lerp target intensity climbs toward — was a flat 8.0 from before the
## reach unification raised the physical floor (see MAX_LEN in vein.gd),
## which left it BELOW ROTATE_GAP_FLOOR: the hard clamp always overrode it and
## the lerp's own floor was dead code. Pinned to the real floor so the curve
## actually bottoms out where the clamp does, instead of asymptoting toward a
## number it can never reach.
const ROTATE_GAP_MIN := ROTATE_GAP_FLOOR

## How long before a rotation-phase flip lands the Heart starts telegraphing
## it — see VNode.tell_res/tell_ratio. Reddit playtest: knowing the TEACHING
## order (RAW->REFINED->CLOTH->PRISM->HEXAGON, fixed and learnable) but never
## the rotation order read as "chaos rather than planned resource
## management." A full advance queue would kill the point of rotation —
## "nothing you built early is ever safe to walk away from" only works if
## you can't see the whole schedule — so this gives exactly one step of
## warning, diegetically, on the Heart itself, instead of a HUD readout.
## Shorter than FIRST_FORGE_TIME-style lead times on purpose: this is a
## last-second brace, not prep time to build a whole new chain.
const DEMAND_TELL_LEAD := 3.0

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
##
## REVERSED AGAIN (the main menu's Heart, July 2026): the menu now shows a
## calm, full Heart at rest — starting the actual run at a half-empty tank
## read as a visual lie the instant Play was tapped, the one shape in the
## game that's supposed to be the SAME object suddenly missing half its
## fuel. Full tank on start, matching the menu.
##
## A time-windowed "burn off the extra half-tank fast, then drop back to the
## old rate" catch-up was tried here and rejected: it drained visibly faster
## for its first few seconds and then visibly slower the instant the window
## ended — a kink in the rate, not a constant one, and it was felt
## immediately in playtest ("it should be normal on all steps"). APPETITE_BASE
## just below is bumped instead: one constant rate, from beat one to the end,
## slightly higher everywhere so the extra buffer still burns down to an
## equivalent "half tank, like before" over roughly the same span — see the
## probe comparison there for how small "slightly" actually is.
const START_FUEL := FUEL_CAP
## Real playtest (not the bot bisection this was previously tuned against):
## reaching PRISM landed right as the run was already nearly maxed out (see
## EXERTION_SPAN below — PRISM unlocks at run-second 100, EXERTION_SPAN used
## to be 110), so pentagon was a near-death-experience milestone instead of
## the easy, generous one a first-time or non-expert player needs it to be.
## Both cut roughly in half: the long-run curve a couple gets good at is
## still there, it just takes longer to arrive.
##
## Nudged 0.16 -> 0.17 for the full-tank START_FUEL above — verified against
## the probe (20 seeds, FIRST_SEED/SEED_STRIDE): the old half-tank opening
## (4.5 fuel, 0.16 base) gave min 140 / avg 183 / max 229 beats; full tank at
## 0.17 gives min 140 / avg 180 / max 230 — same floor, same ceiling, average
## within 2%. 0.19 was tried first and rejected: avg matched (175) but one
## seed's min collapsed to 90 (was 140), the exact "steeper base quietly
## guts an unlucky opening" failure this file already warned about above.
##
## RAISED 0.17 -> 0.24 (feedback: "to not make the initial game too easy we
## can start at a faster rate but the gradual raise be very softer"). The
## 0.19 rejection above was measured against the OLD retroactive curve (see
## appetite()), where a soft opening was the only slack a run had against a
## brutal late game. With that curve fixed and APPETITE_RATE cut below, the
## late game is far gentler, so the opening can afford to carry more of the
## difficulty — which is exactly the trade asked for. The two curves cross
## at around t=37 (the CLOTH flip): harder than the shipped build for the
## whole learning phase, softer than it forever after.
const APPETITE_BASE := 0.24
## Was 0.013, then 0.011, now 0.006 — "we should slow the rate more ... the
## gradual raise be very softer." This is the long-run slope and nothing
## else; the opening is APPETITE_BASE's job, and it absorbed the difference.
const APPETITE_RATE := 0.006    # per second

## Seconds of exertion before the heart is fully racing.
##
## Was 150, then cut to 110 because bot probes were dying at ~100-105s and the
## back half of the threat curve never got felt. That reasoning still holds,
## but real (non-bot) playtest said the result was backwards for a human:
## PRISM unlocking at t=100 against a 110 span meant pentagon arrived at ~91%
## intensity — "easily reach pentagon" was never possible, the run was
## already almost fully feral by the time it was reachable at all. Pushed
## back out so PRISM has a real, generous window to be enjoyed at moderate
## intensity before the late curve bites — see HARDCORE_RAMP_TIME below for
## the other half of this fix.
##
## NOTE the headline above is no longer literally true, and the constant now
## means something slightly different: since pressure() integrates rather
## than rescaling the whole clock (see there), this is the denominator of the
## accumulation RATE, not the wall-clock time to full exertion. The teaching
## discount is now permanent for the seconds it covered instead of being
## repaid at pentagon, so full racing lands LATER than this number, not on
## it.
##
## Cut 200 -> 165 purely to compensate for that. At 200 the integrated curve
## did not reach full exertion until t=285, past where most runs end, so the
## endgame the whole design is built around ("collapse is the content") would
## simply never arrive.
##
## Left at 165 when DEMAND_TIERS was spaced out afterwards, deliberately, even
## though that pushed PRISM — and so _hardcore_ramp's start — ~55s later
## again. Probed rather than assumed: full racing now lands around t=280 and
## long runs do still reach it (the 469-beat seed did), while a run that dies
## near pentagon dies at ~0.33 intensity, which is exactly the "pentagon
## should not be the lethal part" the spacing was for. Cutting this further
## to force the climax earlier would only re-steepen the curve that every
## recent change has been flattening.
const EXERTION_SPAN := 165.0

## Missed feedings before the beat stops for good. DYING/FATAL both raised a
## notch alongside FUEL_CAP/APPETITE above — more real seconds of grace before
## the beat slows, more before it stops for good.
const MISSES_STRAINED := 1
const MISSES_DYING := 4
const MISSES_FATAL := 8

## Hard cap on live Wells. Playtest: "the circles grow and grow" — the board
## only ever accumulated. Wither alone can't hold the line, because it only
## catches Wells that are ORPHANED, and doubling the spawn rate doubled the
## inflow. Past this cap, a new Well displaces the most-neglected existing one
## (the oldest orphan) rather than piling on: the board churns instead of
## silting up, and the screen stays readable at phone size. Connected Wells are
## never displaced — you never lose something you were actually using.
## Raised alongside the spawn-cadence cut below: real playtest said circle
## supply couldn't keep pace with what the Heart wanted, especially by the
## time it's asking for refined tiers with several Wells committed to one
## lineage — more room for those lineages to coexist without evicting each
## other.
const MAX_LIVE_WELLS := 20

# Spawns and budget are on the clock for the same reason as appetite.
##
## Slowed at the open, ramping with the run. Playtest: "objects get spawned
## very quickly at the beginning; the spawning should match the game tempo and
## progression." The board used to fill with Wells inside the first ten
## seconds. It now opens sparse — a first Well only after the two starters have
## had time to be wired in — and the gap DECAYS as the run escalates, so late
## play stays busy. Slow start, quickening finish, same as appetite.
## Cadence cut further (11->8 start, 3.75->2.5 floor) on top of that shape:
## real playtest said circles simply weren't arriving fast enough against the
## Heart's pace, independent of the per-Well rate fix in VNode.WELL_PERIOD.
const FIRST_WELL_TIME := 5.0
const WELL_GAP_START := 8.0
const WELL_GAP_DECAY := 0.6      # wells arrive faster and faster as the run climbs
const WELL_GAP_MIN := 2.5

const FIRST_BUDGET_TIME := 8.0
const BUDGET_GAP_START := 12.0
## THE VEIN INCOME CURVE, and the single biggest reason a run has a ceiling.
##
## The gap between budget grants GROWS by this every time one lands, so vein
## income decays forever: at 2.5 the grants fell at t=8, 20, 34, 51, 71, 93,
## 118, 145, 174, 206, 240, 277 — decelerating without limit, so budget grows
## roughly with the square root of time while appetite grows linearly. Probed
## against six seeds, every single run died holding 16 or 17 veins. Not a
## range — the same number, every time, which is the signature of a wall the
## board imposes rather than one the player runs into.
##
## That is the "user doesn't have tools" half of "we die around 1000, a little
## more a little less, making vein a game you won't come back to." You cannot
## play a topology game strategically when the number of lines you are allowed
## to own is fixed by the clock and identical in every run. Mini Metro — the
## explicit comparison — hands you new lines and carriages on a steady
## cadence for as long as you survive; it never quietly stops paying you.
##
## Growth cut to 1.0 and, more importantly, the gap now CAPS (see
## BUDGET_GAP_MAX). Income still slows early, which is what keeps the opening
## from drowning a new player in choices, but it flattens into a steady drip
## instead of asymptoting to nothing.
const BUDGET_GAP_GROWTH := 1.0
## Hard ceiling on the gap above — past this, veins arrive on a fixed cadence
## forever. This is what actually removes the ceiling: a run that survives
## twice as long now genuinely gets more to work with, so skill has somewhere
## to express itself instead of everyone converging on the same board.
const BUDGET_GAP_MAX := 18.0

## How close a node (or its fallback/clamped position) may sit to the
## screen's edge, in design_size() units. X stays modest — the sides are
## never covered by device chrome in portrait. Y is deliberately wider:
## real phones cover both the top (status bar / camera notch / Dynamic
## Island) and bottom (home indicator) with a few dozen points of
## non-interactive, often non-VISIBLE-either chrome, especially inside the
## Telegram Mini App's own header — a shape or the live score sitting at the
## old 70.0 margin could land right under it. Every node-placement site
## (_spawn_node, _least_crowded_spot, and every rescue/corruption placement
## below) and score_hud.gd's live score share these two numbers so "clear of
## the edges" means the same thing everywhere on the board.
const EDGE_MARGIN_X := 56.0
const EDGE_MARGIN_Y := 96.0

## Nothing spawns inside this radius of the Heart. Playtest: "don't spawn
## objects too close to the Heart, it makes around the Heart very messy." Tools
## used to be scored to HUG the Heart and could land ~24px off its centre,
## piling up on top of it; Wells could creep in behind the starters. A clearance
## ring keeps the area around the Heart readable. It stays well under Vein.MAX_LEN
## so a tool can still always reach the Heart from just outside the ring.
const MIN_HEART_CLEARANCE := 132.0
## Where a tool prefers to sit: out in the reachable band, not on the Heart.
## Kept modest — far enough to clear the Heart's surroundings, close enough that
## the tool->Heart vein isn't so long that delivery latency starves the run.
const TOOL_IDEAL_HEART_DIST := 195.0

## A tool<->Heart pair used to link across a longer span than every other
## pair (TOOL_HEART_REACH, a 1.45x bonus on top of Vein.MAX_LEN) — that was
## what let the whole Well->Forge->Loom->Kiln chain live scattered out in the
## field near its supply instead of collapsing onto the Heart. Removed per
## explicit direction: the small radius is gone for good, and the ONE radius
## every pair now shares (Vein.MAX_LEN itself, raised to absorb the old
## bonus — see vein.gd) does the same job for every pair, not just the
## Heart-facing one.

## Live-tool BASE ceilings (see _max_live_for for the intensity-scaled cap
## actually used everywhere). Playtest: "after a while the screen is full of
## triangles and squares" — tools never die, so without a cap every gap tick
## added scenery forever. Enough for one canonical of each plus exotics, early
## on while a new player still needs a clutter-free board.
## RAISING THESE WAS TRIED AND REJECTED. Recorded because the reasoning for
## trying it is sound and someone will reach for it again.
##
## These caps, times each tool's yield over its replacement gap, look like the
## board's maximum sustainable fuel rate — and since appetite grows linearly
## forever, that crossing looks like where every run must end. So 4/3/3/2 with
## tightened gaps (see FORGE_GAP) was the obvious answer to the score ceiling.
## Measured over six seeds it made things WORSE: avg score 1636 -> 1007, and
## runs got SHORTER, not longer.
##
## Why: a tool is not only a throughput slot, it is also the board's main
## poison source. Spent tools go necrotic with stronger rot than a Well (see
## vnode.gd's POISON_POT_BY_KIND), so more tool slots plus faster replacement
## means more corruption arriving sooner. Adding supply added threat faster
## than it added supply.
##
## The caveat that keeps this from being conclusive: the probe bot barely
## cuts rot, and cutting rot is exactly the skill extra tools would reward.
## For a player who does cut, more tools may well be the win it looks like.
## It cannot be settled with this instrument — it needs real play.
const MAX_LIVE_FORGES := 3
const MAX_LIVE_LOOMS := 2
const MAX_LIVE_KILNS := 2
## Truly rare, per VEIN.md — "only a rare Crucible can make" a hexagon — but
## still ramps up alongside every other tier (see _max_live_for): late in an
## intense run the limiting factor should be the player's own reach and
## reaction speed, not a hard ceiling that leaves the rarest tier permanently
## one corruption away from a dead lineage.
const MAX_LIVE_CRUCIBLES := 1
## How many extra live-tool slots intensity adds on top of the base caps
## above — same "the world keeps getting meaner past EXERTION_SPAN" idiom as
## SPREAD_TIME_LATE/AIRBORNE_CHANCE_MAX.
const EXTRA_LIVE_CAP := 2
## Where on the pressure curve those extra slots start arriving. Was an
## inline literal 1.0 in _max_live_for; named here because it is currently
## DEAD and that should be visible rather than buried in an expression.
##
## It was written when pressure() hit 1.0 around EXERTION_SPAN=200, inside a
## normal run. Since pressure() was fixed to integrate rather than rescale
## the whole clock retroactively, 1.0 now lands near t=280 and full ramp
## (1.0 + CAP_RAMP_SPAN = 2.2) somewhere past t=480 — so in practice every
## run is now played start to finish at the base caps and this ramp never
## fires at all.
##
## Deliberately NOT moved down yet. Doing so is the same "more tools" lever
## the caps above tested and it measured worse; unlike those, it is at least
## restricted to the late game where the board has thinned out. It is a real
## unresolved decision, not an oversight — it wants real play to settle.
const CAP_RAMP_AT := 1.0
## Pressure units past CAP_RAMP_AT needed to reach full EXTRA_LIVE_CAP.
const CAP_RAMP_SPAN := 1.2

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
## Rot keeps tightening past EXERTION_SPAN (see pressure()) down to this.
const SPREAD_TIME_FLOOR := 3.0
const AIRBORNE_AT := 0.38         ## intensity floor before blight can jump gaps
const AIRBORNE_RADIUS := 190.0
const AIRBORNE_CHANCE := 0.35     ## per spread-tick, once AIRBORNE_AT is crossed
const AIRBORNE_CHANCE_MAX := 0.6  ## ...climbing toward this past EXERTION_SPAN
## Hard ceiling on how many nodes _tick_corruption can turn INSTANTLY in a
## single call — the airborne-jump path only now (vein-adjacency spread
## resolves through the deferred _start_poison_dart instead, which is NOT
## capped — see there for why the whole reachable island deliberately gets a
## dart, no truncation). A circuit breaker, not a tuning knob — the airborne
## fix in _tick_corruption addresses the actual runaway feedback loop a real
## report traced to (rage spread + airborne jump + the no-debounce
## same-family respawn all feeding each other, "the whole screen suddenly
## went poisonous" and the phone got hot), but this caps the worst case
## regardless of whatever interaction finds the next way in.
const MAX_CORRUPTIONS_PER_TICK := 6
## Mirrors poison_dart.gd's own MIN_TRAVEL_TIME — duplicated rather than read
## off PoisonDartScene directly so this stays a plain, easily-verified
## constant; keep both in sync if either changes. A dart's actual travel
## time is distance/Vein.SPEED (the same speed every ordinary resource dot
## rides — see _start_poison_dart), this is only the floor under it.
const MIN_RAGE_DART_TRAVEL_TIME := 0.08
## Gap between successive dart spawns on one attack's vein — see
## _start_poison_dart. Purely cosmetic, and deliberately open-ended rather
## than a fixed count or a count capped to one target's travel_time: "I want
## them flowing from the source... the source and closer shapes shouldn't
## vanish sooner, when the last one got poisonous all shapes and lines
## vanish together." A 3-dart burst read as one discrete event; even
## spawning "however many fit in travel_time" (5-6 for a typical hop) still
## stopped the moment that ONE neighbour turned. Now the pulse keeps going
## for as long as the vein and the node at the far end still exist — which,
## since a raging node no longer collapses alone (see
## _island_ready_to_collapse), is the island's WHOLE remaining lifetime, not
## one hop's travel time. The kill itself is unaffected: still one
## resolve, still fires at travel_time, same as before.
const RAGE_DART_INTERVAL := 0.1

## How fast a tool spends its reserve per smelt, at intensity 0 — see
## VNode.depletion_rate. Playtest: a Forge could go necrotic within the
## player's first minute, right as they were still learning the recipe
## mechanic, which reads as "the game is broken" rather than "the game is
## hard" — this game's whole design language is escalation ON THE CLOCK
## (see pressure()/intensity()), and tool death shipped as the one exception,
## a flat cost from beat one. 0.12 means an early tool effectively never dies
## from ordinary use; by EXERTION_SPAN it reaches the full 1.0 that
## FORGE_YIELD/LOOM_YIELD/KILN_YIELD were actually tuned against.
const TOOL_DEPLETION_EARLY := 0.12
## Keeps climbing past pressure 1.0, same rule as SPREAD_TIME/AIRBORNE_CHANCE
## above — the enemy never stops getting worse.
const TOOL_DEPLETION_POST_EXTRA := 0.6

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

## Combo thresholds that can earn a Callout.fire("combo") — see
## _maybe_combo_callout. Last entry is COMBO_CAP itself, the max-combo tier.
const COMBO_CALLOUT_TIERS := [5, 8, COMBO_CAP]
## Score gap between Callout.fire("milestone") checks — see _pop_gain. Not
## every crossing actually fires (Callout.fire itself rolls that), this is
## just how often the roll happens. Widened from 250 after playtest feedback
## that callouts overall were firing far too often — see callout.gd's own
## MIN_GAP/FIRE_CHANCE for the other half of that fix.
const MILESTONE_CALLOUT_STEP := 500

const SNAP := 48.0             # magnetic radius; imprecise thumbs feel precise
const LONG_PRESS := 0.32
const DILATION := 0.3
const DRAG_SLOP := 12.0

# --- The tithe ---------------------------------------------------------------
## Spend score to keep the Heart alive — see tithe.gd for the presentation
## (the score becomes a circle, a ghosted vein reaches for the Heart) and
## _tick_tithe_beat/_tithe_emit/_tithe_arrive below for the economics. The
## score is life already lived; spending it is the Heart consuming its own
## past to survive the present. The exchange is deliberately LOSSY (interest
## > 1 and rising), so a tithe is a bridge loan: worth it only if it carries
## you across a temporary gap you then out-earn. Taken in a losing position
## it just makes death cheaper — reading which is which IS the skill.

## Misses at which the offer blooms. NOT MISSES_DYING: the whole rescue
## pipeline (grab -> one windup beat -> emit per beat -> ~1.3s fall) costs
## 3-4 slowed beats before the first fuel lands, and DYING (4) to FATAL (8)
## is only ~4 beats — an offer at DYING is an offer to watch yourself die
## holding it. At 2 misses a prompt grab can land in time; a late one still
## loses. Matches VEIN.md's near-miss doctrine: saves common early in
## danger, rarer later.
const TITHE_OFFER_MISSES := 2
## The offer retracts only at 0 misses — wide hysteresis so it never flaps
## across the 1-2 boundary while fuel wobbles around empty.
##
## Beats of appetite one tithed dot refills. 2.0 means a held tithe out-earns
## the drain (~+1 appetite/beat net once dots are landing), so holding
## through a gap genuinely climbs back out instead of only slowing the fall.
const TITHE_DOT_BEATS := 2.0
## Floor on a dot's fuel, for early-run tithes where appetite is still tiny —
## below this a dot costs a real point and buys nothing readable.
const TITHE_MIN_FUEL_PER_DOT := 0.6
## Score cost per point of fuel, first dot of the run. Score and fuel are
## earned 1:1 (see _deliver/_pop_gain — the pop IS both), so anything > 1.0
## makes every tithe a net loss against just having been fed. That is the
## design: you can never buy forever, only postpone — every purchase brings
## the end closer in absolute terms. In vain, literally.
const TITHE_INTEREST_START := 1.4
## Added per dot already spent this run — the scar. Later tithes buy less
## per point (dots fall visibly dimmer — see tithe.gd's `worth`), so leaning
## on the mechanic gets worse the more it is leaned on. No reset between
## tithes within a run; a heavily-mortgaged Heart stays mortgaged.
const TITHE_INTEREST_GROWTH := 0.12
## A tithe is proportional or it is not a tithe. The interest price alone
## worked out to ~1 point per beat, which against a few-hundred score read as
## a rounding error — "reducing very low... not in proportion to user's
## score". Each dot now costs at least this fraction of the CURRENT score
## (the interest price below stays as the floor for small scores, and still
## sets what the dot is worth in fuel). Charging the current total, not the
## total at grab time, makes the drain exponential: every dot takes the same
## visible bite out of what remains, so a rich run bleeds in proportion to
## its riches and the number is seen to fall at any scale.
const TITHE_SCORE_FRACTION := 0.05
## Don't bloom a circle around a score too small to matter — an offer to
## spend 4 points is noise, and a ring around "0" is a joke at a funeral.
const TITHE_MIN_SCORE := 10
## Wire-protocol kind for a spend event in /run/deliver batches — mirrors
## server/leaderboard/submit.js's TITHE_KIND. NOT a VNode.Res member: a tithe
## never rides a real vein or reaches _deliver; it exists only so the
## server's validated_score can subtract what the player actually spent and
## the leaderboard matches the death screen. (This is bookkeeping, not proof
## of play: a client that hides its spends is just a client granting itself
## fuel, which no server can see — fuel was never validated. The deliveries
## that fuel then buys are still rate-checked like everyone else's.)
const TITHE_EVENT_KIND := 6

# --- Scene ------------------------------------------------------------------
@onready var vein_layer: Node2D = $VeinLayer
@onready var node_layer: Node2D = $NodeLayer
@onready var drag_layer: Node2D = $DragLayer
@onready var drain: ColorRect = $Fx/Drain
@onready var death_ui: Control = $Ui/Death
@onready var headline_label: Label = $Ui/Death/Headline
@onready var score_label: Label = $Ui/Death/Score
@onready var best_label: Label = $Ui/Death/Best
@onready var ui_layer: CanvasLayer = $Ui
@onready var budget_hint: Node2D = $BudgetHint
@onready var score_hud: Node2D = $ScoreHud
@onready var tutorial: Node2D = $Tutorial
@onready var replay_btn: Button = $Ui/Death/ReplayBtn
@onready var tutorial_btn: Button = $Ui/Death/TutorialBtn
@onready var share_btn: Button = $Ui/Death/ShareBtn
@onready var menu_btn: Button = $Ui/Death/MenuBtn
## Full-rect Control, always correctly viewport-sized (declared in the
## .tscn — see there for why: a same-shaped Control built purely in code and
## parented straight under a CanvasLayer measured its own rect as (0, 0),
## collapsing every anchored child inside it to one point). The one parent
## every dynamically-spawned modal (the name prompt, the leaderboard panel)
## uses instead of ui_layer directly.
@onready var modal_layer: Control = $Ui/Modal

var rng := RandomNumberGenerator.new()
var seed_used := 0

## True when any dev harness (probe/shot/audiocheck) is driving the game.
## Harness runs must never persist saves: the probe was writing every bot
## death into the player's own best/lifetime via _store_save — a bot-set
## best is a wall the player never earned and can't fairly chase.
var _harness_active := false

## Score seeded by `--neardeath[=N]` (0 = mode off). Re-applied by start_run
## on every run, so Replay keeps restarting at the tithe's doorstep — see
## _apply_neardeath.
var _neardeath_score := 0

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
## against `best`. Reactive to every popped delivery (see _pop_gain) — every
## pop that lands is exactly what score moved by — so it reads 0 when
## nothing was ever connected, not some unrelated survival-time number.
var score := 0
## Fractional score the combo bonus produced but hasn't rounded into a pop
## yet (a RAW delivery at combo ×1.07 is worth 1.07 score, and 0.07 can't
## pop on its own) — carried to the NEXT delivery instead of being silently
## discarded every time, so the fraction accumulates until it actually earns
## an extra point, then pops it.
var _score_carry := 0.0

## The number to beat. There is no winning in VEIN — every run ends — so the
## only thing that can pull a player back is their own last best.
var best := 0
var lifetime_beats := 0
var beat_best_this_run := false
## Arcade-style leaderboard identity (see server/leaderboard/README.md) — no
## login, just a random ID generated once on first launch and a random funny
## name claimed automatically the very first launch (see
## _start_random_name_claim, called from _ready()) — no more "type something
## before you're even in the game" friction. Both persisted the same way
## best/lifetime_beats are. A player can still change the name whenever they
## want from the main menu (see _on_open_rename), which reuses the same
## keyboard prompt this used to force on everyone up front.
var player_id := ""
var player_name := ""
## Short human-typeable secret the server hands back the first time a name
## is ever claimed for this player_id (see server/leaderboard/README.md's
## `/recover` section) — the one thing that lets a player pick their
## identity back up on a different device instead of starting over as a
## fresh random name (see _on_open_recover/_recover_account). Persisted the
## same as player_id/player_name; empty until the first successful /name
## response sets it.
var recovery_code := ""

## This run's leaderboard result — submitted automatically the moment the
## Heart stops (see _submit_score, called from _on_stopped), not behind a
## tap: "everyone chooses a name and that's it" was explicit direction, and
## a manual post step is one more thing between the player and seeing where
## they landed. "idle" before the first death this session, then
## "loading"/"loaded"/"error". ranks_strip.gd (the death screen's compact
## rank-2..rank+2 readout) and _on_open_leaderboard (the full top-10 panel)
## both just read these rather than fetching anything themselves.
var lb_state := "idle"
var lb_top: Array = []
var lb_nearby: Array = []
var lb_you := {"rank": 0, "score": 0, "isBest": false}
var lb_total_players := 0
var lb_total_plays := 0
var _lb_http: HTTPRequest

## Set by _start_run_ping once server/leaderboard's /run/start responds;
## empty until then (the response may land after gameplay has already
## started — that's fine, see _start_run_ping). Sent along with _submit_score
## so the server can verify this run's elapsed time against its own clock,
## not anything the client claims. Never persisted — a fresh value every
## start_run() call, same lifetime as score.
var _run_id := ""
var _run_start_http: HTTPRequest

## Round 2 of leaderboard anti-cheat: proof of play, not just a trusted
## score number — see server/leaderboard/submit.js's handleRunDeliver. Every
## Heart-bound delivery that actually affects score (see _deliver) appends
## {kind, combo, pot} here; _flush_deliveries periodically POSTs and clears
## this, and _submit_score folds in whatever's still buffered at death.
var _pending_deliveries: Array[Dictionary] = []
var _deliver_http: HTTPRequest
## How often real elapsed time _flush_deliveries fires on, while a run is
## alive — frequent enough to keep batches small (so the server's per-batch
## rate check stays meaningful), infrequent enough not to be chatty.
const DELIVER_FLUSH_INTERVAL := 4.0
var _deliver_flush_timer := 0.0

## Name-claim/rename result (see _claim_name, called from name_prompt.gd for
## both first-launch claim and rename) — same live-state-read pattern as
## lb_state above. "idle" until a claim is in flight, then
## "checking"/"ok"/"taken"/"error". name_suggestions is only populated on
## "taken", with a few guaranteed-free variations the server already checked.
var name_state := "idle"
var name_suggestions: Array = []
## The server's own `error` string on an "error" state, when the failure was
## a real rejection (a 400 like "bad player_id"/"bad_name", not a dropped
## connection) rather than a network-level miss — name_prompt.gd shows this
## instead of a generic "couldn't reach the server" when it's set, so a real
## rejection reads as what actually went wrong rather than a lie about the
## network. Cleared at the top of every new attempt.
var name_error := ""
var _name_http: HTTPRequest

## Account-recovery result (see _recover_account, called from
## recover_prompt.gd) — same live-state-read pattern as name_state above.
## "idle" until a lookup is in flight, then "checking"/"ok"/"not_found"/
## "error". Only ever reads, never writes player_id/player_name itself — the
## caller applies the recovered identity once it sees "ok" (see
## recover_prompt.gd's confirmed signal / _on_account_recovered).
var recover_state := "idle"
var recovered_player_id := ""
var recovered_name := ""
var _recover_http: HTTPRequest

## First-launch identity, now automatic — see _start_random_name_claim,
## called from _ready() instead of showing name_prompt.gd. Kept short
## (longest possible combo is well under server/leaderboard/submit.js's
## MAX_NAME_LEN=20) so the locally-shown name during the claim round trip
## can never end up mismatched against a server-side truncation.
const NAME_ADJECTIVES := [
	"rusty", "leaky", "swollen", "twitchy", "clogged", "wobbly", "feral",
	"cranky", "soggy", "crusty", "jittery", "gassy", "drowsy", "spicy",
	"greasy", "salty", "grumpy", "sneaky", "wonky", "clammy", "queasy",
	"brittle", "frantic", "rowdy", "zesty", "sturdy", "plucky", "shifty",
]
const NAME_NOUNS := [
	"vein", "pulse", "heart", "clot", "vessel", "artery", "plasma",
	"aorta", "gland", "spleen", "kidney", "liver", "valve", "nerve",
	"tendon", "node",
]
var _claiming_random_name := false
var _random_name_attempt := ""
var _random_name_used_suggestion := false
## See the returning-player branch in _ready() — a silent background re-fetch
## of an already-claimed name's recovery_code, polled the same way
## _claiming_random_name is, just to persist the result once it lands rather
## than leaving it to happen to get saved by some later, unrelated event.
var _fetching_recovery_code := false

## Read-only leaderboard-rank lookup for the main menu (see _fetch_rank,
## called from main_menu.gd's start()) — same live-state-read pattern as
## lb_state/name_state above. "idle" until requested, then
## "loading"/"loaded"/"error". rank_value is 0 (never played) until loaded.
var rank_state := "idle"
var rank_value := 0
var rank_total_players := 0
var _rank_http: HTTPRequest
## Persisted across runs (see _load_save/_store_save) — drives VNode.teach so
## the recipe demonstration plays on the first Forge/Loom/Kiln/Crucible the
## player EVER sees, not every run once they already understand it.
var seen_forge := false
var seen_loom := false
var seen_kiln := false
var seen_crucible := false
## The Cut-the-Rope-style first-run tutorial (see tutorial.gd). Each lesson
## persists separately so dying mid-tutorial never re-teaches a verb already
## performed; tutorial_done is the aggregate that switches the whole system
## off forever.
var tut_connect := false
var tut_chain := false
var tut_forge := false
var tut_cut := false
var tutorial_done := false
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
## Nodes with a poison dart in flight toward them (see _start_poison_dart)
## — excluded from being picked as a NEW target so two attackers never both
## send a dart at the same node.
var _poison_pending := {}
## Wells withered from neglect, and rot collapsed outright. Both remove the
## node itself, so `nodes` undercounts everything that ever appeared once
## either of these fires — these are the cumulative truth the probe reads
## instead.
var withered := 0
var collapsed := 0
## Every node ever created, by kind — `nodes.size()` alone undercounts once
## withering/collapse can remove them mid-run.
var spawned_wells := 0
## Items the Heart accepted but did not want. High counts mean the player (or
## bot) failed to re-plumb after a demand flip.
var wasted := 0
## Consecutive edits made on the heartbeat. This is the mastery layer: elite
## play is not just topology, it is surgery in rhythm.
var combo := 0
## Index into _COMBO_CALLOUT_TIERS of the highest tier this streak has
## already fired a Callout for (see _maybe_combo_callout) — reset everywhere
## combo itself resets to 0, so the next streak can earn them again.
var _combo_callout_tier := 0
## Score milestone gate for Callout.fire("milestone") — see _pop_gain.
var _next_milestone_callout := 0
## True once this run's score has crossed `best` and fired its one
## Callout.fire("best") — see _pop_gain.
var _best_callout_fired := false

## The shape the Heart wants right now. Drawn inside it — see VNode._draw_demand.
var demand: int = VNode.Res.RAW
## Every resource DEMAND_TIERS has introduced so far this run — the pool the
## post-teaching rotation phase draws from (see _tick_escalation).
var _unlocked_res: Array[int] = [VNode.Res.RAW]
## Which DEMAND_TIERS entry the teaching schedule is currently sitting at —
## an explicit index rather than re-derived from `demand` each frame, so
## advancing it is a deliberate one-step action gated by
## _current_demand_deliveries (see _tick_escalation), not just whatever the
## clock says. Playtest: "if you don't feed it during the triangle craving
## it goes to square without you dying" — a pure time-based schedule let an
## entirely under-fed tier expire into the next one for free. Now the clock
## can be ready to advance, but won't, until the Heart has actually been fed
## its CURRENT craving at least once.
var _demand_tier_idx := 0
## Successful (kind == demand) deliveries since the tier at _demand_tier_idx
## became active — reset to 0 on every advance (see _deliver/_tick_escalation).
var _current_demand_deliveries := 0
## Jittered stand-in for DEMAND_TIERS[_demand_tier_idx + 1].at — see
## TEACHING_TIER_JITTER. Rolled once when _demand_tier_idx changes, tracked
## via _tier_time_idx so re-reading it every frame in _tick_escalation
## doesn't reroll a fresh random threshold every frame.
var _next_tier_time := 0.0
var _tier_time_idx := -1
var _next_rotate_time := INF
## Pre-rolled outcome of the NEXT rotation flip, rolled DEMAND_TELL_LEAD
## seconds early so the Heart can telegraph it (see _tick_escalation and
## VNode.tell_res) instead of the flip rerolling silently at the last
## instant. -1 means nothing rolled yet for the upcoming flip.
var _next_rotate_demand := -1

## True from the instant the Heart has EVER received a delivery — any kind,
## even a wrong-shape one, since it only exists to prove the player has
## actually engaged. Gates the DEMAND_TIERS schedule below: playtest reported
## dying of pure opening neglect (nothing ever connected) right as the demand
## flip to REFINED happened to land, which reads as "the triangle killed me"
## when neglect already had. The schedule simply doesn't run until this is
## true, so an idle board never sees a demand change to blame.
var _heart_fed_ever := false
## Seconds since the FIRST feed, not since run start — this is what
## DEMAND_TIERS is actually measured against (see _tick_escalation). Frozen at
## 0 until _heart_fed_ever flips true.
var _demand_clock := 0.0
## run_time the moment PRISM was first unlocked (see _tick_escalation). INF
## until then — read by _hardcore_ramp() below.
var _prism_unlocked_at := INF

## Seconds this run has been alive. The escalation clock — see APPETITE_RATE.
var run_time := 0.0
var _next_well_time := FIRST_WELL_TIME
var _next_forge_time := FIRST_FORGE_TIME
var _next_loom_time := FIRST_LOOM_TIME
var _next_kiln_time := FIRST_KILN_TIME
var _next_crucible_time := FIRST_CRUCIBLE_TIME
var _well_gap := WELL_GAP_START
var _next_budget_time := FIRST_BUDGET_TIME
var _budget_gap := BUDGET_GAP_START

var _appetite_clock := 0.0

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

## The tithe overlay (created in _ready — see TitheScene/tithe.gd) plus the
## hold state that drives it. `_press_tithe` is "this press is a tithe grab
## until proven otherwise": set on press when the offer is up and the thumb
## landed on the Heart or the score-circle, cleared the moment the gesture
## becomes a drag (drawing a vein from the Heart must keep working) — and it
## suppresses dilation while held, so the two hold-verbs can't fire at once.
## `_press_tithe_score` marks a grab that started on the score-circle or the
## ghost vein (not on any node): moving that thumb must not slice veins,
## since the player is clearly holding the offer, not swiping the board.
var tithe: Node2D
var _press_tithe := false
var _press_tithe_score := false
## Beats this hold has lasted. Beat 1 is the windup — the circle inhales,
## nothing is spent — so an accidental hold released within a beat costs
## nothing and *teaches* ("what was that about to do?") instead of taxing.
var _tithe_hold_beats := 0
## Dots spent this run — drives the rising interest (see
## TITHE_INTEREST_GROWTH). Never resets mid-run.
var _tithe_dots_spent := 0
## Total score given back this run — the death screen's second line.
var _tithe_given := 0
## _tithe_dots_spent as of the current offer's bloom — the difference at
## retract time is what THIS episode cost, which sizes the scar it leaves on
## the Heart (see _tick_tithe_beat and vnode.gd's add_scar).
var _tithe_dots_at_bloom := 0
## Armed the beat misses reach MISSES_DYING, spent when they claw back to 0:
## surviving actual dying leaves its own mark even without a tithe — see
## _on_beat.
var _dying_scar_pending := false

var _rescue := 0.0
var _drain_amt := 0.0
## Ramps 0->1 once the run ends — the blood-red wash layered on top of the
## grayscale drain, see drain.gdshader's `death` uniform.
var _death_amt := 0.0
## The death-screen wreckage field, tracked so start_run() can tear it down
## on Replay (see there) — this game.gd instance and its scene persist
## across a run, there is no reload to do that for us.
var _shatter: Node2D = null
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
	# No cap existed anywhere in the project (grepped project.godot and every
	# script — nothing sets Engine.max_fps). VSync alone still lets a 90/120Hz
	# phone render at its full native refresh rate, and every VNode/Vein on
	# the board redraws unconditionally every single frame (their own
	# _process() calls queue_redraw() with no "did anything actually change"
	# guard — continuous pulse/glitch/flow animation is core to this game's
	# whole diegetic-UI identity, not incidental). That is real, sustained,
	# always-on CPU (per-node trig for jitter/glitch) and GPU (draw calls)
	# work that scales with BOTH board size and refresh rate, running the
	# entire time a run is alive, not just during any one mechanic. Reported:
	# "why did my phone get hot... I've been facing this before as well." 60
	# is a deliberately ordinary choice, not tuned against this specific
	# report — VEIN's own rhythm mechanic already reads off Beat.phase
	# (interpolated time), not raw frame count, so nothing about hit windows
	# or animation smoothness depends on running faster than this.
	Engine.max_fps = 60
	_fit_desktop_window()
	drag_layer.draw.connect(_draw_drag)
	death_ui.hide()
	headline_label.hide()
	# Death-screen buttons. A real Button consumes its own tap before
	# _unhandled_input sees it, so each does its own thing while a tap anywhere
	# ELSE on the death screen still does the default retry. The primary
	# Replay button was previously never connected — tapping it ate the tap
	# and did nothing, which read as "the replay button is broken".
	replay_btn.pressed.connect(func() -> void: start_run(0))
	tutorial_btn.pressed.connect(_on_replay_tutorial)
	share_btn.pressed.connect(_on_open_leaderboard)
	menu_btn.pressed.connect(_on_open_main_menu)
	# Created here rather than in the .tscn so its layering is explicit in
	# code next to everything else that draws (tithe.gd sets z 5, under
	# score_hud's 6 — the ring frames the numerals, never covers them). Must
	# exist before the harness branch below can start_run().
	tithe = TitheScene.new()
	add_child(tithe)
	Beat.beat.connect(_on_beat)
	Beat.stopped.connect(_on_stopped)
	_load_save()
	# Under any dev harness (probe/shot/chainstress/...) skip straight into a
	# run, same as always — those are identified by the mere presence of
	# cmdline args, which a real launch (Telegram, a browser tab, a bare
	# double-click) never has, and none of them can tap through a menu or a
	# keyboard.
	if not OS.get_cmdline_user_args().is_empty():
		start_run(0)
		_maybe_attach_harness()
		return
	# First launch ever (or a save from before names existed): claim a random
	# funny name automatically instead of making the player type one before
	# they've even seen the game — "let's remove the initial username
	# taking, and give users' random unique funny names" (they can still
	# change it later from the main menu — see _on_open_rename). Every
	# launch after this one has player_name already saved and goes straight
	# to the main menu instead — no more auto-starting a run for returning
	# players now that there's a menu to land on.
	if player_name.is_empty():
		_start_random_name_claim()
	else:
		# A returning player whose save predates recovery_code (every account
		# that existed before this feature shipped) has an already-claimed
		# name but no code saved locally yet — even after the one-time
		# server-side backfill, THIS device never fetched it. Silent,
		# fire-and-forget: re-claiming the name a player already has is a
		# no-op server-side (see submit.js's handleName), just a vehicle to
		# read back whatever recovery_code already exists for them. No UI
		# watches this; main_menu.gd's own live-read of game.recovery_code
		# (same pattern as its name label) picks it up the moment it lands.
		if recovery_code.is_empty():
			_fetching_recovery_code = true
			_claim_name(player_name)
		_on_open_main_menu()


## Kicks off the first-launch identity claim — see _tick_random_name_claim
## (polled from _process()) for how it resolves. Reuses _claim_name, the
## exact same server round trip name_prompt.gd's typed-name flow already
## used, so a random name is just as uniquely reserved as a typed one ever
## was.
func _start_random_name_claim() -> void:
	_claiming_random_name = true
	_random_name_used_suggestion = false
	_random_name_attempt = _generate_random_name()
	_claim_name(_random_name_attempt)


func _generate_random_name() -> String:
	var a: String = NAME_ADJECTIVES[randi() % NAME_ADJECTIVES.size()]
	var n: String = NAME_NOUNS[randi() % NAME_NOUNS.size()]
	return "%s_%s%d" % [a, n, randi() % 100]


## Polled every frame from _process() while _claiming_random_name is true.
## "taken" is vanishingly rare (a two-word-plus-number space this size
## colliding on the very first roll) but not impossible, and the server
## already hands back a guaranteed-free variation on a 409 (see submit.js's
## handleName) — reuse that rather than re-rolling blind. "error" (no
## network, or NAME_URL unset for local dev) falls back to the name locally,
## unconfirmed: server/leaderboard/README.md's "Arcade-style, on purpose"
## section already treats name uniqueness as best-effort, only ever enforced
## at the moment a /name call actually lands, so this is consistent with the
## existing posture rather than a new gap — and blocking a first launch
## entirely on network being up would be a far worse failure mode than an
## occasional unconfirmed name.
func _tick_random_name_claim() -> void:
	match name_state:
		"checking":
			pass
		"ok":
			_claiming_random_name = false
			player_name = _random_name_attempt
			_store_save()
			_on_open_main_menu()
		"taken":
			if not _random_name_used_suggestion and not name_suggestions.is_empty():
				_random_name_used_suggestion = true
				_random_name_attempt = str(name_suggestions[0])
				_claim_name(_random_name_attempt)
			else:
				_claiming_random_name = false
				player_name = _random_name_attempt
				_store_save()
				_on_open_main_menu()
		"error":
			_claiming_random_name = false
			player_name = _random_name_attempt
			_store_save()
			_on_open_main_menu()


## Polled every frame from _process() while _fetching_recovery_code is true
## — see the returning-player branch in _ready(). Mutually exclusive with
## _claiming_random_name (one requires an empty player_name, the other a
## non-empty one), so both never race the same _name_http/name_state at
## once despite sharing them. Silent either way: the main menu is already
## open by the time this resolves (or fails), so there is nothing to react
## to on screen — just persist a code if one came back, and reset name_state
## so it doesn't read as a stale leftover to whatever polls it next (e.g. a
## rename opened moments later).
func _tick_recovery_code_fetch() -> void:
	if name_state == "checking":
		return
	_fetching_recovery_code = false
	if name_state == "ok" and not recovery_code.is_empty():
		_store_save()
	name_state = "idle"


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
	# A genuinely fresh install has no user://vein.cfg yet — cfg.load fails,
	# and every value below simply keeps its declared default (best=0,
	# lifetime_beats=0, etc.), which is correct. What must NOT happen is
	# bailing out before player_id gets a chance to generate: that used to
	# return here unconditionally, so a first-time player's player_id stayed
	# "" forever (never regenerated on a later launch either, since by then
	# the file DOES exist and loads "successfully" with an empty value) —
	# every /name and /score call the server ever saw from them failed with
	# "bad player_id", and there was no way to ever recover from it client-side.
	if cfg.load(SAVE_PATH) == OK:
		lifetime_beats = int(cfg.get_value("run", "lifetime", 0))
		# THE BEST SCORE NO LONGER GETS WIPED BY A REBALANCE.
		#
		# This used to be gated on `tuning == TUNING_VERSION`, so every bump
		# silently reset best to 0. The intent was sound and is still true —
		# a best set on an easier curve is a wall, not a target — but the
		# cure was worse than the disease. TUNING_VERSION went 9 -> 15 in a
		# single afternoon of balancing, wiping every player's record six
		# times over, and the player-visible result was "the new high score
		# text is bs, it shows at the start of the game even though my high
		# score is +1000": best was 0, so the first delivery beat it.
		#
		# For a game that is supposed to be worth returning to, silently
		# deleting the player's one long-horizon achievement every time we
		# retune is corrosive in a way an out-of-reach target is not — they
		# still have their number, they just have to grow into it again. And
		# the current rebalance moved scores UP (probed ceiling 1893 ->
		# 2335), so existing bests are comfortably beatable anyway.
		#
		# The alternative worth building later, if an unreachable best ever
		# actually becomes the problem: keep a best PER tuning version as the
		# live target and an all-time best alongside it, so nothing is ever
		# destroyed and nothing is ever unfair. See FOREVER.md.
		best = int(cfg.get_value("run", "best", 0))
		seen_forge = bool(cfg.get_value("run", "seen_forge", false))
		seen_loom = bool(cfg.get_value("run", "seen_loom", false))
		seen_kiln = bool(cfg.get_value("run", "seen_kiln", false))
		seen_crucible = bool(cfg.get_value("run", "seen_crucible", false))
		tut_connect = bool(cfg.get_value("run", "tut_connect", false))
		tut_chain = bool(cfg.get_value("run", "tut_chain", false))
		tut_forge = bool(cfg.get_value("run", "tut_forge", false))
		tut_cut = bool(cfg.get_value("run", "tut_cut", false))
		tutorial_done = bool(cfg.get_value("run", "tutorial_done", false))
		player_id = str(cfg.get_value("run", "player_id", ""))
		player_name = str(cfg.get_value("run", "player_name", ""))
		recovery_code = str(cfg.get_value("run", "recovery_code", ""))
	# First launch ever, or a save from before the leaderboard existed —
	# every player needs SOME id before they can post a score, and it has
	# to be stable across runs, so it's generated once here rather than at
	# the moment they first tap "Post to leaderboard."
	if player_id.is_empty():
		player_id = Crypto.new().generate_random_bytes(16).hex_encode()
		_store_save()


func _store_save() -> void:
	if _harness_active:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("run", "best", best)
	cfg.set_value("run", "lifetime", lifetime_beats)
	# Still recorded, though nothing reads it any more (see _load_save for why
	# the wipe was removed) — it says which curve a saved best was set on,
	# which is exactly what a future per-version best would need.
	cfg.set_value("run", "tuning", TUNING_VERSION)
	cfg.set_value("run", "seen_forge", seen_forge)
	cfg.set_value("run", "seen_loom", seen_loom)
	cfg.set_value("run", "seen_kiln", seen_kiln)
	cfg.set_value("run", "seen_crucible", seen_crucible)
	cfg.set_value("run", "tut_connect", tut_connect)
	cfg.set_value("run", "tut_chain", tut_chain)
	cfg.set_value("run", "tut_forge", tut_forge)
	cfg.set_value("run", "tut_cut", tut_cut)
	cfg.set_value("run", "tutorial_done", tutorial_done)
	cfg.set_value("run", "player_id", player_id)
	cfg.set_value("run", "player_name", player_name)
	cfg.set_value("run", "recovery_code", recovery_code)
	cfg.save(SAVE_PATH)


## Dev harnesses, driven off the command line so they run inside a normal project
## launch — autoload singletons like Beat do not resolve as globals under a
## `--script` main loop, which is why these are attached rather than standalone.
##
##   --probe=N [--speed=X]        headless balance run
##   --shot=PATH [--after=S] [--speed=X]   render a frame (needs a window)
##   --rage [--speed=X] [--every=S]        watch the poison-rage flood on
##                                         loop (needs a window)
##   --tithelab [--speed=X]       headless tithe check — control run vs
##                                held-tithe run on one seed (see tests/tithe_lab.gd)
##   --neardeath[=SCORE]          playable run that opens at the tithe's
##                                doorstep (default score 300) — hand-test
##                                the score-for-life rescue (needs a window)
##   --crown                      playable run that fakes leaderboard rank 1
##                                so the Heart wears its crown (needs a window)
##
## Loaded dynamically so an exported build without tests/ still runs.
func _maybe_attach_harness() -> void:
	var probe_runs := 0
	var shot_path := ""
	var speed := 0.0
	var after := 20.0
	var cap := 0
	var every := 0.0
	var neardeath := 0

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
		elif a.begins_with("--every="):
			every = float(a.get_slice("=", 1))
		elif a.begins_with("--neardeath"):
			neardeath = int(a.get_slice("=", 1)) if a.contains("=") else 300

	if "--crown" in OS.get_cmdline_user_args():
		# Fakes holding leaderboard rank 1 without ever touching the network
		# — for eyeballing the Heart's crown ornament (see vnode.gd's
		# wears_crown) without needing an actual #1 score on the real board.
		# Applied here, ahead of the harness picker below, rather than as
		# its own branch in it, so it composes with --shot (screenshot the
		# crowned Heart) instead of being mutually exclusive with it.
		_harness_active = true
		tutorial.enabled = false
		lb_you = {"rank": 1, "score": 999999, "isBest": true}

	if probe_runs > 0:
		# The tutorial's grace window would silently change probe balance —
		# harness runs always measure the real game, never the lesson.
		_harness_active = true
		tutorial.enabled = false
		var p: Node = _load_harness("res://tests/probe.gd")
		if p == null:
			return
		p.runs = probe_runs
		p.speed = speed if speed > 0.0 else 60.0
		p.cap = cap
		add_child(p)
	elif "--audiocheck" in OS.get_cmdline_user_args():
		_harness_active = true
		tutorial.enabled = false
		var a: Node = _load_harness("res://tests/audiocheck.gd")
		if a != null:
			add_child(a)
	elif "--chainstress" in OS.get_cmdline_user_args():
		_harness_active = true
		tutorial.enabled = false
		var c: Node = _load_harness("res://tests/chain_stress.gd")
		if c != null:
			add_child(c)
	elif "--tithelab" in OS.get_cmdline_user_args():
		_harness_active = true
		tutorial.enabled = false
		var t: Node = _load_harness("res://tests/tithe_lab.gd")
		if t == null:
			return
		if speed > 0.0:
			t.speed = speed
		add_child(t)
	elif "--rage" in OS.get_cmdline_user_args():
		_harness_active = true
		tutorial.enabled = false
		var r: Node = _load_harness("res://tests/rage_lab.gd")
		if r == null:
			return
		r.speed = speed if speed > 0.0 else 1.0
		if every > 0.0:
			r.every = every
		add_child(r)
	elif neardeath > 0:
		# Playable, but still a harness: the seeded score was never earned,
		# so it must not write the save or reach the leaderboard —
		# _harness_active guards both, exactly as for the bots.
		_harness_active = true
		tutorial.enabled = false
		_neardeath_score = neardeath
		# start_run already ran (see _ready's harness branch) before this
		# parse, so the first run applies the opening position here; every
		# Replay after it re-applies inside start_run.
		_apply_neardeath()
	elif shot_path != "":
		_harness_active = true
		# `--tutorial` forces the hints on regardless of the save, so they
		# can be screenshot-verified; a plain shot shows the real game.
		if "--tutorial" in OS.get_cmdline_user_args():
			tut_connect = false
			tut_chain = false
			tut_forge = false
			tut_cut = false
			tutorial_done = false
		else:
			tutorial.enabled = false
		var s: Node = _load_harness("res://tests/shot.gd")
		if s == null:
			return
		s.out_path = shot_path
		s.after = after
		s.speed = speed if speed > 0.0 else 3.0
		s.demo_tutorial = "--tutorial" in OS.get_cmdline_user_args()
		add_child(s)


func _load_harness(path: String) -> Node:
	if not ResourceLoader.exists(path):
		push_error("harness missing: %s" % path)
		return null
	var script: Script = load(path)
	return null if script == null else script.new()


# --- Run lifecycle ----------------------------------------------------------

## Wipes the tutorial-completion flags and starts a fresh run, so the
## Cut-the-Rope lessons play again from the top — wired to the death screen's
## "Replay tutorial" button. Persisted, so the replayed tutorial also sticks
## if the player quits partway and comes back.
func _on_replay_tutorial() -> void:
	tut_connect = false
	tut_chain = false
	tut_forge = false
	tut_cut = false
	tutorial_done = false
	_store_save()
	start_run(0)


func start_run(run_seed: int) -> void:
	Audio.start()
	_start_run_ping()
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
	_score_carry = 0.0
	ruptures = 0
	dropped = 0
	withered = 0
	collapsed = 0
	spawned_wells = 0
	poisoned = 0
	corruptions = 0
	_poison_pending.clear()
	wasted = 0
	combo = 0
	_combo_callout_tier = 0
	_next_milestone_callout = MILESTONE_CALLOUT_STEP
	_best_callout_fired = false
	demand = VNode.Res.RAW
	_unlocked_res = [VNode.Res.RAW]
	_demand_tier_idx = 0
	_current_demand_deliveries = 0
	_next_rotate_time = INF
	_next_rotate_demand = -1
	_heart_fed_ever = false
	_demand_clock = 0.0
	_tier_time_idx = -1
	_prism_unlocked_at = INF
	_no_move_time = 0.0
	rescues = 0
	_rescue = 0.0
	_drain_amt = 0.0
	_death_amt = 0.0
	_sync_flash = 0.0
	_bad_tempo_flash = 0.0
	_appetite_clock = 0.0
	_appetite_growth = 0.0
	_pressure_growth = 0.0
	run_time = 0.0
	_next_well_time = FIRST_WELL_TIME
	_next_forge_time = FIRST_FORGE_TIME
	_next_loom_time = FIRST_LOOM_TIME
	_next_kiln_time = FIRST_KILN_TIME
	_next_crucible_time = FIRST_CRUCIBLE_TIME
	_well_gap = WELL_GAP_START
	_next_budget_time = FIRST_BUDGET_TIME
	_budget_gap = BUDGET_GAP_START
	_chain_stall.clear()
	chain_rescues = 0
	_throughput_stall = 0.0
	throughput_rescues = 0
	corruption_respawns = 0
	_pending_deliveries.clear()
	_deliver_flush_timer = 0.0
	_tithe_hold_beats = 0
	_tithe_dots_spent = 0
	_tithe_given = 0
	_tithe_dots_at_bloom = 0
	_dying_scar_pending = false
	_press_tithe = false
	_press_tithe_score = false
	tithe.vanish()

	# Dying (or hitting Replay) mid-drag never fires _on_release, so without
	# this a hold that was still active when the run ended leaves _drag_from
	# pointing at a VNode this same call is about to queue_free() above.
	# _draw_drag only guards on `_drag_from == null or not alive` — and alive
	# flips back to true a few lines down — so the very next frame's
	# drag_layer redraw dereferences a freed node's `.position` every frame
	# until something reassigns _drag_from, which is a hard "previously
	# freed instance" script error, repeating 60x/s. _press_node/_press_vein
	# are reset defensively too, even though _on_press already overwrites
	# them before anything reads them, for the same "dangling reference to
	# a node this call just freed" reason.
	_drag_from = null
	_press_node = null
	_press_vein = null
	_touching = false
	_dilating = false
	_moved = false

	heart = _make_node(VNode.Kind.HEART, heart_spawn_pos())

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
	# The Death screen persists across a Replay (no scene reload — see the
	# ReplayBtn wiring), so the last run's wreckage has to be torn down
	# explicitly or it just keeps accumulating, one more shattered layer per
	# death.
	if _shatter != null:
		_shatter.queue_free()
		_shatter = null
	alive = true
	if tutorial != null:
		tutorial.reset()
	Beat.reset()
	_rebuild_graph()
	if _neardeath_score > 0:
		_apply_neardeath()


## The `--neardeath` opening position: a seeded score to spend and the Heart
## already at TITHE_OFFER_MISSES on an empty tank, so the very first beat
## tips it to misses + 1 and blooms the offer (see _tick_tithe_beat). For
## hand-testing the tithe rescue — hold the score circle, watch the dots
## fall, confirm spending score actually brings the Heart back.
func _apply_neardeath() -> void:
	score = _neardeath_score
	fuel = 0.0
	misses = TITHE_OFFER_MISSES
	heart.fuel_ratio = health_ratio()


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


## Single source of truth for where the Heart lives, in design space — used
## by start_run() to place the real one and by main_menu.gd to place its
## decorative stand-in at the exact same spot (see there), so the menu's
## Heart and the run's Heart are never at risk of drifting apart.
func heart_spawn_pos() -> Vector2:
	var vp := design_size()
	return Vector2(vp.x * 0.5, vp.y * 0.44)


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
		VNode.Kind.CRUCIBLE:
			n.produces = VNode.Res.HEXAGON
		_:
			n.produces = VNode.Res.RAW
	node_layer.add_child(n)
	nodes.append(n)
	n.corruption_started.connect(_on_node_corrupted)
	return n


func _on_stopped(total: int) -> void:
	alive = false
	Audio.stop_all()
	# The run can die mid panic-pinch; never leave the world dilated. Only undo
	# our own dilation — blindly writing 1.0 here would stomp the time scale the
	# dev harnesses set, which silently dropped the probe back to real time.
	_end_dilation()
	# No retract animation over a shattering board — and dots still falling
	# were already paid for; they die with the Heart (foreclosure, no refund).
	tithe.vanish()
	_press_tithe = false
	_press_tithe_score = false

	lifetime_beats += total
	# Best/the death screen both track `score` — what the Heart actually
	# received — not survival time. `total` (beats) still feeds
	# lifetime_beats, a separate lifetime stat the harnesses read.
	beat_best_this_run = score > best
	if beat_best_this_run:
		best = score
	_store_save()

	score_label.text = "Score  %s" % _commas(maxi(0, score))
	# The tithe's epitaph. `score` is already net (spends subtracted at
	# emission), so this line adds information, not arithmetic: the whole
	# strategic story of the run — how much of its past this Heart ate to
	# get this far — in six words.
	if _tithe_given > 0:
		score_label.text += "  ·  gave %s back" % _commas(_tithe_given)
	# The target. Without something to beat, "one more run" has no hook — and
	# VEIN has no win state to offer instead.
	if beat_best_this_run:
		best_label.text = "Your best yet."
	else:
		best_label.text = "Best  %s" % _commas(best)
	death_ui.show()
	_submit_score()

	# The board itself shatters, not an abstract fountain — snapshot every
	# still-alive node's shape/colour/position before hiding it, then let
	# ShatterScene break each one into pieces of its own silhouette. Hiding
	# the real VNodes (rather than freeing them) keeps everything else that
	# reads `nodes` — the probe, a future Replay — untouched; start_run()
	# frees them for real when the next run begins.
	var snapshots: Array[Dictionary] = []
	for n in nodes:
		n.hide()
		var col: Color = Palette.VOID if n.corrupted else \
				(Palette.HEART if n.kind == VNode.Kind.HEART else Palette.of_res(n.produces))
		snapshots.append({
			"pos": n.position,
			"color": col,
			"radius": n.radius(),
			"kind": n.kind,
		})
	_shatter = ShatterScene.new()
	ui_layer.add_child(_shatter)
	_shatter.start(snapshots, rng.randi())


## Fire-and-forget "a run just began" ping to server/leaderboard's
## /run/start — called from start_run() the moment a real run starts, so the
## server has its own timestamp for when this run began before it ever sees
## a score. Purely a gameplay-lifecycle signal, NOT part of the name-claim/
## registration flow: no UI, doesn't gate starting to play, and
## _submit_score already tolerates _run_id staying empty (the server then
## just rejects that submission, same as any other network hiccup — see
## _submit_score's existing "error" handling below). Skipped under any dev
## harness, same reasoning as _submit_score's own _harness_active guard.
func _start_run_ping() -> void:
	_run_id = ""
	if _harness_active:
		return
	if RUN_START_URL.is_empty():
		return
	if _run_start_http == null:
		_run_start_http = HTTPRequest.new()
		_run_start_http.timeout = HTTP_TIMEOUT
		add_child(_run_start_http)
		_run_start_http.request_completed.connect(_on_run_start_request_completed)
	var body := JSON.stringify({"player_id": player_id})
	# No error handling on a failed request() call itself — a run that never
	# gets a run_id just fails its later /score submission the same way an
	# offline device already does today; nothing else in gameplay depends on
	# this succeeding.
	_run_start_http.request(
		RUN_START_URL, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)


func _on_run_start_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	# Arrives whenever it arrives — start_run() has already reset every other
	# per-run field synchronously; this is the one exception that fills in
	# asynchronously, which _submit_score just reads at death time.
	_run_id = String(parsed.get("run_id", ""))


## Fire-and-forget periodic delivery-batch flush — see _pending_deliveries
## and server/leaderboard/submit.js's handleRunDeliver, the actual proof of
## play behind a submitted score. Skipped, buffer left intact for the next
## attempt, if _run_id hasn't arrived yet — the rare race where the flush
## timer fires before _start_run_ping's own response has landed; nothing is
## lost, it just waits for the next cycle (or _submit_score's own final
## flush at death, whichever comes first).
func _flush_deliveries() -> void:
	if _run_id.is_empty() or DELIVER_URL.is_empty():
		return
	if _deliver_http == null:
		_deliver_http = HTTPRequest.new()
		_deliver_http.timeout = HTTP_TIMEOUT
		add_child(_deliver_http)
	var body := JSON.stringify({
		"player_id": player_id, "run_id": _run_id, "deliveries": _pending_deliveries,
	})
	# No error handling on a failed request() call itself, no response
	# handler — a dropped batch just means those deliveries don't count
	# server-side, same acceptable-loss reasoning as _start_run_ping.
	_deliver_http.request(
		DELIVER_URL, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	_pending_deliveries.clear()


## Arcade-style, works everywhere (Telegram, a plain browser tab, a local
## build), no login (see server/leaderboard/README.md) — fired automatically
## the instant the Heart stops (see _on_stopped), not from a button. Name is
## already guaranteed set by now: _ready() gets one before the first run
## ever starts (see name_prompt.gd).
##
## Skipped under any dev harness, same reasoning as _store_save()'s own
## _harness_active guard — a probe/shot/chainstress bot dying is not a real
## player's run, and without this every balance-tuning batch was quietly
## POSTing bot scores to the real production leaderboard under the dev's own
## player_id.
func _submit_score() -> void:
	if _harness_active:
		return
	lb_state = "loading"
	if LEADERBOARD_URL.is_empty():
		lb_state = "error"
		return
	if _lb_http == null:
		_lb_http = HTTPRequest.new()
		_lb_http.timeout = HTTP_TIMEOUT
		add_child(_lb_http)
		_lb_http.request_completed.connect(_on_lb_request_completed)
	# `score` rides along for display/debug purposes only — the server now
	# derives the authoritative score itself from validated_score, built
	# exclusively from /run/deliver batches plus this call's own `deliveries`
	# tail (see server/leaderboard/submit.js's handleScore). Whatever's still
	# buffered since the last periodic flush goes out here instead of one
	# more round trip.
	var body := JSON.stringify({
		"player_id": player_id, "name": player_name, "score": score, "beats": beats,
		"run_id": _run_id, "deliveries": _pending_deliveries,
	})
	_pending_deliveries.clear()
	var err := _lb_http.request(
		LEADERBOARD_URL, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		lb_state = "error"


func _on_lb_request_completed(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		lb_state = "error"
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		lb_state = "error"
		return
	lb_top = parsed.get("top", [])
	lb_nearby = parsed.get("nearby", [])
	lb_you = parsed.get("you", lb_you)
	lb_total_players = int(parsed.get("totalPlayers", 0))
	lb_total_plays = int(parsed.get("totalPlays", 0))
	lb_state = "loaded"


## "Leaderboard" — opens the full top-10 panel over whatever _submit_score
## already fetched (or is still fetching: leaderboard_panel.gd reads
## lb_state live and updates itself once it lands).
##
## lb_state stays "idle" until this SESSION has actually ended a run — opened
## from the main menu before that (a fresh launch, or straight after the
## first-ever name claim), there was nothing to show and the panel just sat
## on "Submitting..." forever, forever being the bug: nothing was ever
## submitting. _fetch_board() below covers exactly that gap with a read-only
## request; once a real run has submitted (or this has already run once)
## lb_state is no longer "idle" and this is a no-op, so a submission already
## in flight (or already loaded) is never raced or re-fetched.
func _on_open_leaderboard() -> void:
	if lb_state == "idle":
		_fetch_board()
	var panel := LeaderboardPanelScene.new()
	modal_layer.add_child(panel)
	panel.start(self, design_size())


## Landing screen: every real launch after the first-ever name claim lands
## here instead of auto-starting a run (see _ready()), and the death
## screen's Menu button returns here too without forcing a replay first.
func _on_open_main_menu() -> void:
	var menu := MainMenuScene.new()
	modal_layer.add_child(menu)
	menu.start(self, design_size())


## Rename — opens the same keyboard-driven prompt first launch uses, just
## pre-filled with the current name (see name_prompt.gd's edit mode) and
## wired to a different confirm handler: no run to start, just update and
## persist the name the player is already mid-session with.
func _on_open_rename() -> void:
	var prompt := NamePromptScene.new()
	modal_layer.add_child(prompt)
	prompt.confirmed.connect(_on_rename_confirmed)
	prompt.start(self, design_size(), player_name)


func _on_rename_confirmed(name_text: String) -> void:
	player_name = name_text
	_store_save()


## Opens the recovery-code entry prompt (see recover_prompt.gd) from the main
## menu's "Restore account" link — swaps this device's identity for
## whichever player_id the code belongs to (see _on_account_recovered).
func _on_open_recover() -> void:
	var prompt := RecoverPromptScene.new()
	modal_layer.add_child(prompt)
	prompt.confirmed.connect(_on_account_recovered)
	prompt.start(self, design_size())


## Claims or changes player_name against the leaderboard backend's uniqueness
## check (see server/leaderboard/submit.js's /name route) — used by
## name_prompt.gd for both the first-launch claim and rename. Same
## live-state-read pattern as _submit_score/lb_state: name_prompt.gd polls
## name_state itself rather than this returning a value directly.
func _claim_name(name_text: String) -> void:
	name_state = "checking"
	name_suggestions = []
	name_error = ""
	if NAME_URL.is_empty():
		name_state = "error"
		return
	if _name_http == null:
		_name_http = HTTPRequest.new()
		_name_http.timeout = HTTP_TIMEOUT
		add_child(_name_http)
		_name_http.request_completed.connect(_on_name_request_completed)
	var body := JSON.stringify({"player_id": player_id, "name": name_text})
	var err := _name_http.request(
		NAME_URL, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		name_state = "error"


func _on_name_request_completed(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		name_state = "error"
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		name_state = "error"
		return
	if response_code == 200:
		name_state = "ok"
		# Set on every successful claim, not just the first — handleName never
		# reissues an existing code (see its own comment), so this just keeps
		# re-saving the same value on a rename and actually sets it the one
		# time it matters, the very first claim.
		recovery_code = str(parsed.get("recovery_code", recovery_code))
	elif response_code == 409:
		name_state = "taken"
		name_suggestions = parsed.get("suggestions", [])
	else:
		# A real rejection (bad_name, bad player_id, ...) reads as what it
		# actually is instead of the generic network-failure message below —
		# see name_error's own header comment.
		name_error = str(parsed.get("error", ""))
		name_state = "error"


## Looks up an existing player_id/name/best_score by recovery code (see
## server/leaderboard/README.md's `/recover` section) — used by
## recover_prompt.gd. Read-only: never touches player_id/player_name/
## recovery_code itself, so a wrong or abandoned attempt can never clobber
## the identity already active on this device. The caller applies the
## result once it sees "ok" — see recover_prompt.gd's confirmed signal.
func _recover_account(code: String) -> void:
	recover_state = "checking"
	recovered_player_id = ""
	recovered_name = ""
	if RECOVER_URL.is_empty():
		recover_state = "error"
		return
	if _recover_http == null:
		_recover_http = HTTPRequest.new()
		_recover_http.timeout = HTTP_TIMEOUT
		add_child(_recover_http)
		_recover_http.request_completed.connect(_on_recover_request_completed)
	var body := JSON.stringify({"recovery_code": code})
	var err := _recover_http.request(
		RECOVER_URL, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		recover_state = "error"


func _on_recover_request_completed(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		recover_state = "error"
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		recover_state = "error"
		return
	if response_code == 200:
		recovered_player_id = str(parsed.get("player_id", ""))
		recovered_name = str(parsed.get("name", ""))
		# The local "best" is a device-side vanity readout (see main_menu.gd's
		# _stats_text); the server's best_score for the identity being
		# recovered is the real one. max(), not overwrite, so recovering on a
		# device that already has a higher LOCAL best (e.g. re-recovering the
		# same account after playing a few runs here first) never regresses
		# what's shown.
		best = maxi(best, int(parsed.get("best_score", 0)))
		recover_state = "ok"
	elif response_code == 404:
		recover_state = "not_found"
	else:
		recover_state = "error"


## Applies a successfully recovered identity — swaps this device's random
## player_id/player_name for the recovered ones and persists. recovery_code
## itself is untouched (it already belongs to recovered_player_id, and
## handleName never reissues it — see submit.js's own comment), so the same
## code keeps working for a THIRD device later too.
func _on_account_recovered() -> void:
	player_id = recovered_player_id
	player_name = recovered_name
	_store_save()
	# The main menu's rank readout was fetched for whatever player_id this
	# device had a moment ago — re-fetch now that it's a different identity,
	# same call the menu's own start() already makes on open.
	_fetch_rank()


## Read-only "where do I stand" lookup (see server/leaderboard/submit.js's
## /rank route) for the main menu — never writes anything, so opening the
## menu can call this freely without it counting as a run.
func _fetch_rank() -> void:
	rank_state = "loading"
	if RANK_URL.is_empty():
		rank_state = "error"
		return
	if _rank_http == null:
		_rank_http = HTTPRequest.new()
		_rank_http.timeout = HTTP_TIMEOUT
		add_child(_rank_http)
		_rank_http.request_completed.connect(_on_rank_request_completed)
	var body := JSON.stringify({"player_id": player_id})
	var err := _rank_http.request(
		RANK_URL, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		rank_state = "error"


func _on_rank_request_completed(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		rank_state = "error"
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		rank_state = "error"
		return
	rank_value = int(parsed.get("rank", 0))
	rank_total_players = int(parsed.get("totalPlayers", 0))
	rank_state = "loaded"


## Read-only "show me the board" fetch — the same RANK_URL _fetch_rank
## already hits (server/leaderboard/submit.js's /rank route now returns
## top/nearby/you/totalPlays alongside rank, the exact shape /score's
## response has), reusing _lb_http and _on_lb_request_completed so this
## slots into lb_state/lb_top/lb_nearby/lb_you exactly like a real
## submission would have. Only ever called from _on_open_leaderboard while
## lb_state is still "idle" — see there for why that gate matters.
func _fetch_board() -> void:
	lb_state = "loading"
	if RANK_URL.is_empty():
		lb_state = "error"
		return
	if _lb_http == null:
		_lb_http = HTTPRequest.new()
		_lb_http.timeout = HTTP_TIMEOUT
		add_child(_lb_http)
		_lb_http.request_completed.connect(_on_lb_request_completed)
	var body := JSON.stringify({"player_id": player_id})
	var err := _lb_http.request(
		RANK_URL, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		lb_state = "error"


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

	# Committed here, synchronously, before Beat.stop() can fire — see
	# health_ratio(). The fatal beat must land with the Heart already
	# reading exactly empty, not one frame of _process behind it.
	heart.fuel_ratio = health_ratio()

	if misses >= MISSES_FATAL:
		Beat.stop()
		return
	elif misses >= MISSES_DYING:
		Beat.set_state(Beat.State.DYING)
		# Armed here, spent on the beat misses reach 0 — see below. A tithe
		# held through the same episode already scars in _tick_tithe_beat;
		# this only fires the beats that clawed back on their own, so a
		# single recovery never marks the Heart twice.
		_dying_scar_pending = true
	elif misses >= MISSES_STRAINED:
		Beat.set_state(Beat.State.STRAINED)
	else:
		Beat.set_state(Beat.State.HEALTHY)
		if _dying_scar_pending:
			_dying_scar_pending = false
			# Compared by dots, not tithe.offered: this runs before
			# _tick_tithe_beat below, which is the call that would retract
			# the offer and scar for an actual spend — checking dots directly
			# sidesteps that ordering and only fires when nothing was spent.
			if _tithe_dots_spent == _tithe_dots_at_bloom:
				heart.add_scar(0.5)

	Beat.set_exertion(intensity())
	_tick_tithe_beat()


## The tithe's clock — everything about it is quantized to the beat, same as
## every other emission in the game: the offer blooms on a beat, the windup
## is a beat, dots leave on beats. See the TITHE_* constants for the design.
func _tick_tithe_beat() -> void:
	if not tithe.offered:
		if misses >= TITHE_OFFER_MISSES and score >= TITHE_MIN_SCORE:
			tithe.offer()
			_tithe_dots_at_bloom = _tithe_dots_spent
	elif misses == 0:
		# Danger passed: the curtain call — even mid-hold. A thumb held
		# through full recovery must not keep draining score into a capped
		# tank; the offer closing under the finger IS the "you're safe now"
		# signal. In-flight dots still land (tithe.advance keeps running),
		# and if danger returns while the thumb never lifted, the re-offer
		# starts from its own windup beat again.
		tithe.retract()
		# The wound closed; it scars (see vnode.gd's scar-tissue block).
		# Sized by what the episode cost: a one-dot flinch barely marks,
		# a long hold leaves a real seam.
		var episode := _tithe_dots_spent - _tithe_dots_at_bloom
		if episode > 0:
			heart.add_scar(clampf(float(episode) / 12.0, 0.3, 1.0))

	if not tithe.offered or not _press_tithe:
		_tithe_hold_beats = 0
		return
	_tithe_hold_beats += 1
	if _tithe_hold_beats == 1:
		# The windup: the circle inhales, the score dims, nothing is spent.
		# One beat of grace converts an accidental hold from a stealth tax
		# into the mechanic's own best teacher — the player flinches off
		# having paid nothing and now knows exactly where the lever is.
		tithe.inhale()
		return
	_tithe_emit()


## One dot leaves the score. Cost is computed at emission, not arrival — the
## point is spent the moment it becomes blood, and a dot lost to death
## mid-fall was still paid for (the loan does not refund on foreclosure).
func _tithe_emit() -> void:
	var interest := TITHE_INTEREST_START + TITHE_INTEREST_GROWTH * float(_tithe_dots_spent)
	var fuel_gain := maxf(appetite() * TITHE_DOT_BEATS, TITHE_MIN_FUEL_PER_DOT)
	# The fuel bought stays appetite-priced (the rescue math above is tuned to
	# it); the SCORE side is whichever is larger — the interest price, or a
	# flat fraction of what the player still has (see TITHE_SCORE_FRACTION).
	# Past a small score the fraction always wins, which only sharpens the
	# loan's terms: the richer the run, the more one beat of life costs it.
	var cost := maxi(1, maxi(
		int(ceil(fuel_gain * interest)),
		int(ceil(float(score) * TITHE_SCORE_FRACTION))))
	if score < cost:
		# The well is dry. Emission just stalls — the offer stays up, the
		# hold stays legal, and the empty circle over a spent score is its
		# own statement.
		return
	score -= cost
	_tithe_dots_spent += 1
	_tithe_given += cost
	# Later dots are visibly worth less — same information the pops carry,
	# told in the dot itself (see tithe.gd's `worth`).
	var worth := clampf(TITHE_INTEREST_START / interest, 0.35, 1.0)
	tithe.emit_dot(cost, fuel_gain, worth)

	# The −N pop: digits are the score's native language (score_hud is the
	# one sanctioned numeral in the game), so a minus-pop AT the score is
	# diegetic where it would be HUD anywhere else. Bruised toward
	# VEIN_STRAINED — a loss should not wear the same ink as a gain.
	var origin := _tithe_score_pos()
	var toward := (heart.position - origin).normalized()
	var pop: Node2D = FloatTextScene.new()
	vein_layer.add_child(pop)
	pop.spawn("-%d" % cost, origin + toward * (tithe.CIRCLE_R + 12.0),
		Palette.SCORE.lerp(Palette.VEIN_STRAINED, 0.5), 20, toward)

	_reverse_thump()

	# Bookkeeping for the server's validated_score — see TITHE_EVENT_KIND.
	# Same _harness_active guard as _deliver's own append: a bot's spends are
	# not a real player's run.
	if not _harness_active:
		_pending_deliveries.append({"kind": TITHE_EVENT_KIND, "cost": cost})


## The tithe's haptic signature: strong-then-weak, the exact inverse of the
## STRAINED double-beat (weak-then-strong, Beat._thump). Every other pattern
## in the game is a beat; this is a beat played backwards — you feel each
## point leave your hand, and it cannot be mistaken for the heartbeat.
func _reverse_thump() -> void:
	if not OS.has_feature("mobile"):
		return
	Input.vibrate_handheld(36)
	await get_tree().create_timer(0.08).timeout
	Input.vibrate_handheld(14)


## Where the score-circle lives: score_hud's own top-centre anchor, nudged up
## to the numerals' visual centre (draw_string draws from the baseline, so
## the glyphs sit ABOVE score_hud's origin, not around it).
func _tithe_score_pos() -> Vector2:
	return Vector2(design_size().x * 0.5, EDGE_MARGIN_Y - 10.0)


## A tithed dot reached the Heart. The mirror of _deliver's Heart branch,
## minus everything that doesn't apply: no combo (rhythm is for building),
## no demand check (this blood is always wanted), no score pop (the score
## already paid at emission — popping value twice would double-count it in
## the player's read of the exchange).
func _tithe_arrive(d: Dictionary) -> void:
	fuel = clampf(fuel + float(d.fuel), 0.0, fuel_cap())
	heart.pulse = 1.0
	Audio.swallow(VNode.Res.RAW, fuel / fuel_cap(), true)
	# A vector +, not a number — the Heart earns life, not points (see
	# float_text.gd's spawn_plus), in the rescue flash's own warm.
	var toward_score := (_tithe_score_pos() - heart.position).normalized()
	var entry := heart.position + toward_score * heart.radius()
	var mark: Node2D = FloatTextScene.new()
	vein_layer.add_child(mark)
	mark.spawn_plus(entry, Palette.WARM, 22, toward_score)
	if misses >= MISSES_DYING:
		# A near-death arrival warms the screen like any other rescue, but
		# gentler than a real delivery's full flash — dots land every beat
		# while held, and a strobing full-strength rescue would cheapen the
		# one _deliver fires for an actual routed save.
		_rescue = maxf(_rescue, 0.5)


## How far into the escalation curve this run is, UNCLAMPED — passes 1.0 at
## EXERTION_SPAN and keeps climbing forever. The clamped intensity() below
## is for everything cosmetic (audio, exertion, particle violence), which
## has a natural ceiling; the threat systems (demand rotation, corruption
## spread, airborne blight — see _tick_escalation/_tick_corruption) read
## THIS, because the run must never plateau: past EXERTION_SPAN the only
## thing still escalating used to be raw appetite, so a long run flattened
## into a grind against one number instead of a world still getting meaner.
## The loop runs forever; it just keeps getting harder until you lose.
##
## Muted while still walking the DEMAND_TIERS teaching schedule (RAW through
## PRISM has never all been unlocked yet), then eases up to full strength
## over HARDCORE_RAMP_TIME once PRISM lands. Playtest: the schedule itself
## already waits for demand to flip gently (see _demand_clock), but every
## OTHER threat — corruption spread, airborne blight, tool depletion, even
## the appetite wave below — was still climbing on the raw run clock the
## whole time, so by the time a player actually REACHED pentagon the world
## was already nearly maxed out. "Easy to reach pentagon, then it gets hard"
## needs the whole hazard mix gated on tier progress, not just the shape the
## Heart is asking for. Nothing about the tuned LATE curve changes — this
## only compresses how much of it you feel while still climbing to PRISM.
const TEACHING_PRESSURE_MULT := 0.35
## Seconds after PRISM unlocks before pressure reaches full strength.
## Was 10 — a "short breather," but paired with the old EXERTION_SPAN=110 that
## meant full hardcore intensity landed within 10s of reaching pentagon at
## all, no matter how well built the board was. Real playtest: this needs to
## be a real window to enjoy the milestone in, not a cutover with a different
## number. Raised alongside EXERTION_SPAN's own increase above so "easy to
## reach pentagon, then it gets hard" actually has a middle where it's just
## pentagon for a while.
const HARDCORE_RAMP_TIME := 60.0

## THE OTHER HALF OF THE PENTAGON SPIKE, and the one that is literally "the
## heart goes fast" — this is what sets the heartbeat's BPM, via
## intensity() -> Beat.set_exertion() -> lerpf(BPM_CALM, BPM_MAXED, ...).
##
## It used to read:
##
##     return run_time / EXERTION_SPAN * lerpf(TEACHING_PRESSURE_MULT, 1.0, _hardcore_ramp())
##
## the identical retroactive shape appetite() had: the CURRENT teaching
## multiplier applied to the TOTAL elapsed clock, so the 0.35 -> 1.0 swing
## (x2.86, even sharper than appetite's x2.5) was charged against every
## second already played the moment PRISM unlocked. Measured on the shipped
## constants, the heartbeat went 77.5 -> 118.8 BPM across the 60s ramp
## window: +41 BPM, arriving exactly at pentagon. Integrating instead makes
## that +13 BPM before EXERTION_SPAN's compensating cut above, ~+16 after.
##
## Fixing appetite() alone did not resolve the report, because the two are
## different systems — that one is fuel burned per beat, this one is how fast
## the beats come. Both had the same bug; only one had been fixed.
##
## This also silently stepped everything ELSE gated on pressure() at the same
## instant — corruption spread time, tool depletion, the live-Well cap, the
## demand-rotation gap — which is why pentagon read as a cliff rather than as
## a tempo change alone.
var _pressure_growth := 0.0

func pressure() -> float:
	return _pressure_growth


## 0 while PRISM has never been unlocked, ramping 0->1 over HARDCORE_RAMP_TIME
## once it is (see _prism_unlocked_at, set in _tick_escalation).
func _hardcore_ramp() -> float:
	if _prism_unlocked_at == INF:
		return 0.0
	return clampf((run_time - _prism_unlocked_at) / HARDCORE_RAMP_TIME, 0.0, 1.0)


## pressure() clamped to 0..1 — the cosmetic ceiling. Exertion, the mix, and
## particle violence read this; they max out and stay there.
func intensity() -> float:
	return clampf(pressure(), 0.0, 1.0)


## Fuel the Heart burns per beat, rising on the run clock.
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
## How much slower the fuel drain's RATE climbs while still teaching (see
## TEACHING_PRESSURE_MULT above — same reasoning, applied to the single
## biggest killer in the game). APPETITE_BASE/START_FUEL are untouched: those
## already carry the tuned "first ten seconds" grace on their own.
const TEACHING_APPETITE_MULT := 0.4

## THE PENTAGON SPIKE. This used to read:
##
##     var rate := APPETITE_RATE * lerpf(TEACHING_APPETITE_MULT, 1.0, _hardcore_ramp())
##     var base := APPETITE_BASE + rate * _appetite_clock
##
## which multiplies the CURRENT rate by the TOTAL elapsed clock — so the
## teaching discount was never a discount on the seconds it applied to, it
## was a loan against the whole run, called in all at once the moment
## _hardcore_ramp() started moving. And _hardcore_ramp() starts moving
## exactly when PRISM unlocks. Reported, twice, in exactly those terms: "the
## heart goes fast when we reach the pentagon."
##
## Measured on the shipped constants (0.17/0.011, PRISM at t=100, 60s ramp):
## appetite went 0.61 -> 1.93 across the ramp window, x3.16. Of that, only
## 0.011*60 = 0.66 is real elapsed time at the full rate; the rest was the
## 2.5x teaching multiplier being applied retroactively to the 100 seconds
## that had ALREADY been played at the discounted rate. TEACHING_PRESSURE_MULT
## above claims "nothing about the tuned LATE curve changes — this only
## compresses how much of it you feel while still climbing to PRISM," which
## is what the design intended and not what this arithmetic did.
##
## Integrating the rate instead makes the multiplier affect only the seconds
## it was actually in force. Same two constants, same teaching discount, same
## full-strength late slope — but no step, because nothing is recomputed
## retroactively. On the shipped constants this alone takes the ramp-window
## jump from x3.16 to x1.76; with APPETITE_RATE cut to 0.006 it is x1.52.
##
## _appetite_clock is still the wave's phase clock below — the wave is a
## function of when you are, not of how much has accumulated.
var _appetite_growth := 0.0

func appetite() -> float:
	var base := APPETITE_BASE + _appetite_growth
	var wave := sin(_appetite_clock * TAU / APPETITE_WAVE_PERIOD) * APPETITE_WAVE_AMP * intensity()
	return maxf(0.02, base + wave)


func fuel_cap() -> float:
	return FUEL_CAP


## What the Heart actually SHOWS, 0..1 — folds the miss-grace buffer into the
## same number as the fuel line so the bar never lies in either direction.
## Raw fuel/fuel_cap() alone could sit at a full, honest-looking 0.0 for up
## to MISSES_FATAL beats before death actually landed — the Heart LOOKED
## dead long before it was, which is its own kind of dishonest bar. Grace
## shrinks this multiplicatively as misses accumulate, so it keeps draining
## even through a partial fuel recovery between misses, and lands at exactly
## 0.0 on the exact beat MISSES_FATAL stops the Heart for good — never a
## separate invisible counter still running under a bar that already reads
## empty, and never a bar showing life the Heart doesn't have left.
func health_ratio() -> float:
	var grace := 1.0 - float(misses) / float(MISSES_FATAL)
	return clampf(fuel / fuel_cap(), 0.0, 1.0) * clampf(grace, 0.0, 1.0)


## Every spawn cadence used to be a flat interval — the exact same gap, every
## time, seed after seed — which reads as a metronome once you've played a
## few runs: "I know exactly when the next Boost lands." Wobbling each gap
## by up to `spread` (still drawn from the seeded `rng`, so a given seed is
## still fully reproducible) keeps the same average pace but breaks the
## predictability that made the board feel inert between events.
func _jitter(base: float, spread: float) -> float:
	return base * rng.randf_range(1.0 - spread, 1.0 + spread)


func _tut_holds_demand() -> bool:
	return tutorial != null and tutorial.holds_demand()


func _tut_gates_spawns() -> bool:
	return tutorial != null and tutorial.gates_spawns()


## Drives the spawn and budget clocks. Kept out of _on_beat so a slowing Heart
## cannot slow its own escalation.
func _tick_escalation(delta: float) -> void:
	run_time += delta
	_appetite_clock += delta
	# Accumulate the drain slope as it is actually in force, rather than
	# rescaling the whole elapsed clock by the current multiplier every frame
	# — see appetite()/_appetite_growth for why that difference IS the
	# pentagon spike. Reads _hardcore_ramp() one frame stale (PRISM can unlock
	# further down this same tick), which is irrelevant against a 60s ramp.
	_appetite_growth += APPETITE_RATE \
		* lerpf(TEACHING_APPETITE_MULT, 1.0, _hardcore_ramp()) * delta
	# Same treatment, same reason — see pressure(). This one drives the actual
	# heartbeat tempo, so its step was the audible half of the pentagon spike.
	_pressure_growth += delta / EXERTION_SPAN \
		* lerpf(TEACHING_PRESSURE_MULT, 1.0, _hardcore_ramp())
	# The demand SCHEDULE runs on time-since-first-feed, not run_time — see
	# _heart_fed_ever. Everything else (appetite, spawns, corruption) still
	# escalates on real run_time regardless of engagement; only the "what does
	# the Heart want" clock waits for proof the player has done something.
	if _heart_fed_ever:
		_demand_clock += delta

	# During the tutorial the demand schedule is suspended — the tutorial owns
	# `demand` and brings the triangle in on its own paced clock (see
	# tutorial.holds_demand), so a first-timer isn't hit with a flip before
	# they've learned to connect and chain.
	if not _tut_holds_demand():
		var want: int = demand
		# Only walks the teaching schedule while it's still running. Once
		# rotation has been armed (_next_rotate_time != INF, see below), every
		# DEMAND_TIERS entry is already unlocked and its `at` has long since
		# passed — so left unguarded, this loop always lands on the LAST
		# tier's res every single frame, overwriting `want` back to it right
		# after the rotation branch below picks something else. The bug that
		# produced: a rotation flip would show for exactly one frame, then
		# get stomped back to the final teaching tier on the very next frame
		# — "rotation" was actually a one-frame flicker, not a held demand.
		# Found chasing the Reddit "chaos, not planned management" feedback:
		# turns out rotation barely ever held long enough to plan around in
		# the first place.
		if _next_rotate_time == INF:
			# One step at a time: advancing past the CURRENT tier requires both
			# its time AND at least one confirmed feed of it (see
			# _demand_tier_idx's own header above for why).
			if _demand_tier_idx < DEMAND_TIERS.size() - 1:
				var next_tier: Dictionary = DEMAND_TIERS[_demand_tier_idx + 1]
				if _tier_time_idx != _demand_tier_idx:
					_next_tier_time = _jitter(next_tier.at, TEACHING_TIER_JITTER)
					_tier_time_idx = _demand_tier_idx
				if _demand_clock >= _next_tier_time and _current_demand_deliveries >= 1:
					_demand_tier_idx += 1
					_current_demand_deliveries = 0
			want = DEMAND_TIERS[_demand_tier_idx].res
			if not _unlocked_res.has(want):
				_unlocked_res.append(want)
				if want == VNode.Res.PRISM:
					_prism_unlocked_at = run_time

		# Teaching schedule is over once every DEMAND_TIERS entry has landed
		# AND been fed at least once — from here, demand jumps randomly among
		# everything unlocked instead of sitting at HEXAGON forever (see
		# ROTATE_GAP_START/MIN above). _next_rotate_time starts at INF (see
		# start_run) so the first crossing just arms the timer rather than
		# firing an immediate switch the instant it lands.
		if _demand_tier_idx == DEMAND_TIERS.size() - 1 and _current_demand_deliveries >= 1 \
				and _next_rotate_time == INF:
			_next_rotate_time = _demand_clock + _jitter(ROTATE_GAP_START, 0.3)
		elif _demand_clock >= _next_rotate_time:
			# Use the pre-rolled tell if one landed (the normal case — see the
			# branch below); only reroll here if the flip somehow arrived
			# without one, e.g. rotation just started this exact frame with
			# less than DEMAND_TELL_LEAD of runway.
			want = _next_rotate_demand if _next_rotate_demand != -1 else _roll_rotate_demand(want)
			_next_rotate_demand = -1
			# Keeps shrinking past pressure 1.0 (see pressure()) toward a hard
			# floor, so deep-late demand flips genuinely never stop accelerating.
			var gap := lerpf(ROTATE_GAP_START, ROTATE_GAP_MIN, intensity())
			gap = maxf(ROTATE_GAP_FLOOR, gap - maxf(pressure() - 1.0, 0.0) * 2.0)
			_next_rotate_time = _demand_clock + _jitter(gap, 0.35)
		elif _next_rotate_time != INF and _next_rotate_demand == -1 \
				and _demand_clock >= _next_rotate_time - DEMAND_TELL_LEAD:
			_next_rotate_demand = _roll_rotate_demand(want)

		# Mirror the pending tell onto the Heart every frame it's active (see
		# VNode._draw_demand) — ramps 0->1 across DEMAND_TELL_LEAD, and snaps
		# back to 0 the instant the flip above consumes it.
		if _next_rotate_demand != -1:
			heart.tell_res = _next_rotate_demand
			heart.tell_ratio = clampf(
				1.0 - (_next_rotate_time - _demand_clock) / DEMAND_TELL_LEAD, 0.0, 1.0)
		else:
			heart.tell_ratio = 0.0

		if want != demand:
			demand = want
			heart.demand = want
			# The Heart changing its mind is the loudest event in the run:
			# everything you built is now feeding it the wrong thing.
			heart.pulse = 1.0
			Audio.play("corrupt", -6.0, 1.5)
			if OS.has_feature("mobile"):
				Input.vibrate_handheld(220)

	# During the tutorial's controlled opening, spawns are suspended entirely —
	# the tutorial injects the one Well it needs and keeps the board calm until
	# chaining is taught (see tutorial.gates_spawns). Budget still grows below.
	if not _tut_gates_spawns():
		if run_time >= _next_well_time:
			_spawn_well()
			_next_well_time += _jitter(_well_gap, 0.3)
			_well_gap = maxf(WELL_GAP_MIN, _well_gap - WELL_GAP_DECAY)

		_ensure_move(delta)
		_tick_tool_chain(delta)
		_ensure_throughput(delta)

		# Tools keep arriving on their cadence but the BOARD stays capped —
		# playtest: "after a while the screen is full of triangles and squares."
		# At cap the timer still advances, so a slot freed later (a collapse)
		# refills on the next tick rather than never. Which KIND fills a given
		# slot can still lean toward the Heart's current craving — see
		# _spawn_tool_slot.
		if run_time >= _next_forge_time:
			_spawn_tool_slot(VNode.Kind.FORGE)
			_next_forge_time += _jitter(FORGE_GAP, 0.25)

		if run_time >= _next_loom_time:
			_spawn_tool_slot(VNode.Kind.LOOM)
			_next_loom_time += _jitter(LOOM_GAP, 0.2)

		if run_time >= _next_kiln_time:
			_spawn_tool_slot(VNode.Kind.KILN)
			_next_kiln_time += _jitter(KILN_GAP, 0.2)

		if run_time >= _next_crucible_time:
			_spawn_tool_slot(VNode.Kind.CRUCIBLE)
			_next_crucible_time += _jitter(CRUCIBLE_GAP, 0.2)

	if run_time >= _next_budget_time:
		budget += 1
		_next_budget_time += _jitter(_budget_gap, 0.15)
		_budget_gap = minf(BUDGET_GAP_MAX, _budget_gap + BUDGET_GAP_GROWTH)
		budget_hint.queue_redraw()


## Rolls a rotation-phase demand, excluding `current` — the pool both the
## live flip and its pre-roll tell (see _tick_escalation) draw from. Pulled
## into one function so those two call sites can't drift apart.
func _roll_rotate_demand(current: int) -> int:
	var pool := _unlocked_res.duplicate()
	pool.erase(current)
	if pool.is_empty():
		return current
	return pool[rng.randi() % pool.size()]


## The tool tier that directly produces what the Heart is CURRENTLY asking
## for — -1 if there is no such tool (RAW is eaten straight from a Well) or
## the run hasn't reached the post-teaching rotation phase yet
## (_next_rotate_time == INF). Scoped to rotation on purpose: during the
## teaching schedule every tool's own FIRST_*_TIME is already hand-tuned to
## land ahead of its matching demand flip (see the const block up top), and
## letting this override that lead-time reveal would just be a second system
## fighting the first. Rotation is where it's actually needed — that's the
## phase where demand jumps randomly among every unlocked tier and a tool's
## fixed cadence has no way to know that just happened.
func _critical_tool_kind() -> int:
	if _next_rotate_time == INF:
		return -1
	match demand:
		VNode.Res.REFINED: return VNode.Kind.FORGE
		VNode.Res.CLOTH: return VNode.Kind.LOOM
		VNode.Res.PRISM: return VNode.Kind.KILN
		VNode.Res.HEXAGON: return VNode.Kind.CRUCIBLE
	return -1


func _max_live_for(kind: int) -> int:
	var base := 0
	match kind:
		VNode.Kind.FORGE: base = MAX_LIVE_FORGES
		VNode.Kind.LOOM: base = MAX_LIVE_LOOMS
		VNode.Kind.KILN: base = MAX_LIVE_KILNS
		VNode.Kind.CRUCIBLE: base = MAX_LIVE_CRUCIBLES
		_: return 0
	var extra := floori(clampf((pressure() - CAP_RAMP_AT) / CAP_RAMP_SPAN, 0.0, 1.0) * EXTRA_LIVE_CAP)
	return base + extra


## True if `kind` is the critical tier (see _critical_tool_kind) and could use
## another live instance: fewer than two healthy already — plain existence is
## _tick_tool_chain's job (see _ensure_canonical_alive), this is about not
## being down to a single, un-backed-up instance of the one thing the Heart
## is actually asking for right now — with room left under its own cap.
func _wants_reinforcement(kind: int) -> bool:
	if kind != _critical_tool_kind():
		return false
	return _count_healthy_kind(kind) < mini(2, _max_live_for(kind))


## Fills one periodic tool-spawn slot. Ordinarily that is `kind`, the tier
## whose own timer just fired — but if some OTHER tier is critical right now
## and wants_reinforcement, this already-scheduled slot goes to that tier
## instead. Every GAP constant, and how often a slot fires at all, stays
## exactly as tuned; only WHICH kind fills a given slot can change, so a
## demand flip to a thin tier gets reinforced by the very next tool spawn
## instead of waiting out that tier's own independent cadence.
func _spawn_tool_slot(kind: int) -> void:
	var critical := _critical_tool_kind()
	var spawn_kind := kind
	if critical != -1 and critical != kind and _wants_reinforcement(critical):
		spawn_kind = critical
	if _count_healthy_kind(spawn_kind) < _max_live_for(spawn_kind):
		_spawn_node(spawn_kind)


## New Wells displace the most-neglected old one once the board is full, so the
## count stays flat and readable instead of climbing all run. Only orphans are
## ever displaced — a Well you actually wired in is safe. Returns the Well it
## placed, or null on the one path that skips spawning entirely (see below) —
## callers that need to know whether a replacement actually landed (see
## _on_node_corrupted) read this instead of assuming a spawn happened.
func _spawn_well() -> VNode:
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
			return null
		withered += 1
		_remove_node(oldest)

	return _spawn_node(VNode.Kind.WELL)


## What kind hands `kind` its raw material — a Forge eats from a Well, a Loom
## from a Forge, a Kiln from a Loom, a Crucible from a Kiln. Shared by
## _spawn_node's anchor choice and its redundancy scoring below (see there)
## so the two can never name a different feeder tier for the same tool.
func _feeder_kind_for(kind: int) -> int:
	match kind:
		VNode.Kind.FORGE: return VNode.Kind.WELL
		VNode.Kind.LOOM: return VNode.Kind.FORGE
		VNode.Kind.KILN: return VNode.Kind.LOOM
		VNode.Kind.CRUCIBLE: return VNode.Kind.KILN
	return -1


## New nodes spawn in awkward places, forcing rerouting. Bias to the lower two
## thirds so everything stays in one-thumb reach.
##
## A tool is placed by the opposite rule to a Well: it wants to sit CLOSE to the
## Heart, because its job is to stand between a cluster of Wells and the trunk
## they overload. Spawning it out at the rim like a Well would make it
## unroutable and it would never be worth the veins.
func _spawn_node(kind: int) -> VNode:
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
	# A Well's anchor must not just be CONNECTED, it must be able to USE what
	# a Well makes: a Well whose only in-reach neighbour is a Loom/Kiln (which
	# may refuse RAW) or a corrupted node "spawned reachable" but every vein
	# you could draw to it was a dead move — RAW arrived and was refused on
	# contact. Anchoring only to nodes that accept or relay RAW (the Heart,
	# healthy Wells) guarantees at least one USEFUL connection exists the
	# moment it appears, not merely a drawable one.
	#
	# The pool also includes the FRONTIER: orphan Wells that are themselves
	# within reach of the network. Playtest: "spawning seems to happen in a
	# perfect circle around the heart" — with only the connected core as
	# anchors, every new node landed on the same annulus around the same few
	# points. Growing off the frontier too lets the board wander outward in
	# organic chains instead of stacking rings.
	var connected: Array[VNode] = []
	for n in nodes:
		if n.depth < 0 or n.corrupted:
			continue
		if n.kind == VNode.Kind.HEART or n.kind == VNode.Kind.WELL \
				or (n.kind == VNode.Kind.FORGE and n.recipe.has(VNode.Res.RAW)):
			connected.append(n)
	if connected.is_empty():
		connected = [heart]
	var anchors := connected.duplicate()
	for n in nodes:
		if n.depth >= 0 or n.corrupted or n.kind != VNode.Kind.WELL:
			continue
		for m in connected:
			if in_reach(n, m):
				anchors.append(n)
				break

	var is_tool := kind == VNode.Kind.FORGE or kind == VNode.Kind.LOOM \
			or kind == VNode.Kind.KILN or kind == VNode.Kind.CRUCIBLE

	# A tool is USELESS unless BOTH its feeder and its delivery target can reach
	# it — playtest: "the triangle spawned where no circle could reach it,
	# there must never be a scenario with no move." The feeder is what hands it
	# raw material (a Forge eats from a Well, a Loom from a Forge, a Kiln from a
	# Loom); the target is always the Heart (every chain drains to it). Placing
	# the tool near the MIDPOINT of feeder<->Heart, inside a ring tight enough
	# that any candidate stays within Vein.MAX_LEN of both, makes the whole
	# link buildable by construction. The reach is then re-checked per
	# candidate below, so an off-midpoint pick can never sneak out of range.
	var anchor_point := heart.position
	var feeder: VNode = null
	var feeder_kind := _feeder_kind_for(kind)
	var min_dist := 40.0
	var max_dist := Vein.MAX_LEN * 0.9
	if is_tool:
		feeder = _nearest_node_of_kind(feeder_kind, heart.position)
		# A tool anchors to its FEEDER, not the feeder<->Heart midpoint: it
		# lives out in the field next to its supply and reaches the Heart
		# across the same single Vein.MAX_LEN every other pair gets now. That
		# is the whole scatter fix — the chain no longer collapses onto the
		# Heart. The feeder must itself be within reach of the Heart, or a
		# tool placed by it couldn't also reach the Heart; if it isn't, fall
		# back to hugging the Heart and let the rescue system drop supply
		# nearby.
		if feeder != null and heart.position.distance_to(feeder.position) > Vein.MAX_LEN - 24.0:
			feeder = null
		if feeder != null:
			anchor_point = feeder.position
			min_dist = 78.0
			max_dist = Vein.MAX_LEN * 0.82
		else:
			min_dist = MIN_HEART_CLEARANCE
			max_dist = Vein.MAX_LEN * 0.7

	for _i in 64:
		var p: Vector2
		if is_tool:
			var bearing := rng.randf() * TAU
			var dist := rng.randf_range(min_dist, max_dist)
			p = anchor_point + Vector2(cos(bearing), sin(bearing)) * dist
		else:
			var anchor: VNode = anchors[rng.randi() % anchors.size()]
			var bearing := rng.randf() * TAU
			var dist := rng.randf_range(90.0, Vein.MAX_LEN * 0.95)
			p = anchor.position + Vector2(cos(bearing), sin(bearing)) * dist
		if p.x < EDGE_MARGIN_X or p.x > vp.x - EDGE_MARGIN_X or p.y < EDGE_MARGIN_Y or p.y > vp.y - EDGE_MARGIN_Y:
			continue

		var to_heart := p.distance_to(heart.position)
		# Keep the Heart's immediate surroundings clear — nothing crowds it.
		if to_heart < MIN_HEART_CLEARANCE:
			continue

		# Hard reachability gate for tools: reject any spot the Heart or the
		# feeder cannot directly reach. This is the guarantee, not a preference.
		if is_tool:
			if to_heart > Vein.MAX_LEN:
				continue
			if feeder != null and p.distance_to(feeder.position) > Vein.MAX_LEN:
				continue

		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near < 104.0:
			continue

		var s := 0.0
		if is_tool:
			# Tools stand between supply and the Heart, but out in the reachable
			# band — not piled on the Heart. Reward elbow room and sitting near
			# the ideal ring distance, so tools scatter across the mid-field.
			s = near - absf(to_heart - TOOL_IDEAL_HEART_DIST) * 0.6
			# Reward a spot that can also reach OTHER healthy feeders, not just
			# the one it anchored to — "there should be multiple options, some
			# might get poisoned." A single-feeder tool is one corruption away
			# from being stranded; this never REQUIRES a backup (the no-move
			# guarantee above already covers that with just the one feeder),
			# it only prefers a candidate that happens to have one over one
			# that doesn't, so the board naturally grows some slack instead of
			# every tool being a lone point of failure.
			if feeder_kind != -1:
				var backups := 0
				for n in nodes:
					if n.kind == feeder_kind and not n.corrupted \
							and p.distance_to(n.position) <= Vein.MAX_LEN:
						backups += 1
				s += minf(float(backups - 1), 2.0) * 40.0
		else:
			# Prefer awkward — elbow room from neighbours — WITHOUT preferring a
			# compass direction. Distance from the Heart is deliberately not a
			# term here; that was the bias.
			s = near
		if s > best_score:
			best_score = s
			best = p

	if best_score == -INF:
		# NOTHING is allowed to silently fail to spawn. For a tool the fallback
		# must STILL be reachable — this used to sample far out along the
		# FEEDER's own ring (up to max_dist, ~0.82x MAX_LEN from it), which on
		# a crowded board could and did land a tool beyond Vein.MAX_LEN of the
		# HEART: exactly the "spawned somewhere I can never connect it" state
		# this whole function exists to prevent, and worse for a tool than a
		# Well, since a Well can still chain in through another Well but a
		# stranded tool has no such backup. The feeder<->Heart MIDPOINT sits
		# within MAX_LEN-24 of both by construction (feeder is gated to that
		# above), so nudging only a modest distance off it can never push the
		# result out of reach of either — the two limit_length calls after are
		# a second, explicit guarantee of that, not just a hope the geometry
		# works out.
		if is_tool:
			if feeder != null:
				var mid := (feeder.position + heart.position) * 0.5
				best = _least_crowded_spot(mid, Vein.MAX_LEN * 0.35)
				best = heart.position + (best - heart.position).limit_length(Vein.MAX_LEN - 4.0)
				best = feeder.position + (best - feeder.position).limit_length(Vein.MAX_LEN - 4.0)
			else:
				best = _least_crowded_spot(anchor_point, Vein.MAX_LEN * 0.6)
		else:
			var anchor: VNode = anchors[rng.randi() % anchors.size()]
			best = _least_crowded_spot(anchor.position, Vein.MAX_LEN * 0.7)
	var n := _make_node(kind, best)
	if is_tool:
		n.recipe = _roll_recipe(kind)
	if kind == VNode.Kind.FORGE and not seen_forge:
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
	elif kind == VNode.Kind.CRUCIBLE and not seen_crucible:
		seen_crucible = true
		n.teach = true
		_store_save()
	_rebuild_graph()
	return n


## What each tool kind makes never varies; what it EATS does. The plain
## recipe is two of the tier below — the classic chain. "Exotic" is COUNT
## only (see _roll_recipe's own header below for why mixed types were tried
## and reverted) — the same canonical ingredient, just 3 or sometimes 4 of
## it instead of 2.
const CANONICAL_RECIPE := {
	VNode.Kind.FORGE: [VNode.Res.RAW, VNode.Res.RAW],
	VNode.Kind.LOOM: [VNode.Res.REFINED, VNode.Res.REFINED],
	VNode.Kind.KILN: [VNode.Res.CLOTH, VNode.Res.CLOTH],
	VNode.Kind.CRUCIBLE: [VNode.Res.PRISM, VNode.Res.PRISM],
}
## Chance a tool rolls exotic, growing with run pressure — the opening stays
## the learnable classic chain, the late game asks for more.
const EXOTIC_CHANCE_BASE := 0.25
const EXOTIC_CHANCE_MAX := 0.75
## Within an exotic roll, how often it's the 4-count variant rather than
## 3-count — always the minority (caps under 0.5) so "you see 2 most often,
## then 3, then 4" holds at every point in the run, but the split itself
## still climbs with intensity like everything else: an early exotic roll is
## almost always "just one more" (3), a late one increasingly often asks for
## the full extra pair (4). Applies identically to every tool kind, same as
## EXOTIC_CHANCE_BASE/MAX above, since they all share this one function.
const EXOTIC_FOUR_CHANCE_BASE := 0.15
const EXOTIC_FOUR_CHANCE_MAX := 0.42


## THE NO-MOVE GUARANTEE APPLIES HERE TOO: the first tool of each kind on
## the board — and any tool spawned while no plain-recipe sibling of its
## kind is alive — is always canonical, so every demand tier is always
## answerable through the classic Well->Forge->Loom->Kiln chain no matter
## how heavy the extras get.
##
## Exotic used to mean MIXED types, drawn from anything unlocked so far — a
## Forge could roll "1 circle and 1 square." Real playtest: "the flow always
## wants to go from triangle to square, [mixing them] breaks" — a square is
## already PAST a Forge in the downhill chain (it flows onward to a Loom/
## Kiln/Crucible/Heart), so asking a Forge to eat one back the wrong way
## fights the game's own flow model instead of just being harder. Exotic
## variance is COUNT only now: the same canonical ingredient, just more of
## it (3, sometimes 4, instead of 2) — harder without asking for something
## the flow direction can never actually deliver.
func _roll_recipe(kind: int) -> Array[int]:
	var canonical: Array[int] = []
	canonical.assign(CANONICAL_RECIPE[kind])

	var has_canonical := false
	for n in nodes:
		if n.kind == kind and not n.corrupted and n.recipe == canonical:
			has_canonical = true
			break
	if not has_canonical:
		return canonical

	var chance := lerpf(EXOTIC_CHANCE_BASE, EXOTIC_CHANCE_MAX, intensity())
	if rng.randf() > chance:
		return canonical

	var four_chance := lerpf(EXOTIC_FOUR_CHANCE_BASE, EXOTIC_FOUR_CHANCE_MAX, intensity())
	var extra := 2 if rng.randf() < four_chance else 1
	var heavy: Array[int] = []
	for _i in canonical.size() + extra:
		heavy.append(canonical[0])
	heavy.sort()
	return heavy


func _random_node_of_kind(kind: int) -> VNode:
	var matches: Array[VNode] = []
	for n in nodes:
		if n.kind == kind:
			matches.append(n)
	return matches[rng.randi() % matches.size()] if not matches.is_empty() else null


func _count_kind(kind: int) -> int:
	var c := 0
	for n in nodes:
		if n.kind == kind:
			c += 1
	return c


## Live, non-corrupted nodes of a kind. The tool caps count this so a necrotic
## tool waiting to collapse doesn't hold its own replacement out — the board
## should always be working back toward a full spread of every shape, ready for
## whatever the Heart demands next.
func _count_healthy_kind(kind: int) -> int:
	var c := 0
	for n in nodes:
		if n.kind == kind and not n.corrupted:
			c += 1
	return c


## Guaranteed fallback placement when the normal rejection search found
## nowhere valid: whichever of a fixed ring of bearings around `center` is
## farthest from every existing node, so the node always gets SOMEWHERE on
## the board rather than silently not spawning at all. Candidates are clamped
## into the playfield margins before scoring — clamping only ever pulls a
## point INWARD toward the anchor, so it can never push one out of reach.
func _least_crowded_spot(center: Vector2, dist: float) -> Vector2:
	var vp := design_size()
	var best := center + Vector2(dist, 0.0)
	var best_near := -INF
	for i in 24:
		var a := TAU * float(i) / 24.0
		var p := center + Vector2(cos(a), sin(a)) * dist
		p.x = clampf(p.x, EDGE_MARGIN_X, vp.x - EDGE_MARGIN_X)
		p.y = clampf(p.y, EDGE_MARGIN_Y, vp.y - EDGE_MARGIN_Y)
		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near > best_near:
			best_near = near
			best = p
	return best


# --- The no-move guarantee ---------------------------------------------------
#
# The one unrecoverable state VEIN must never produce: the Heart is starving
# and there is nothing on the board the player could possibly do about it.
# Spawn anchoring (see _spawn_node) makes every new node reachable AND useful
# at the moment it appears, but reachability decays as the run chews the board
# up — Wells deplete, corrupt, wither; the network gets amputated — so the
# guarantee also needs a live check, not just careful placement.

## How long the board may sit with no claimable fresh supply before a rescue
## Well is forced in. Non-zero so a transient gap (the half-second between
## cutting a rotten limb and wiring its replacement) doesn't trigger it, but
## short enough that the rescue lands with several missed feedings still in
## hand (MISSES_FATAL) — the player should experience "supply is scarce",
## never "supply is impossible".
const RESCUE_DEBOUNCE := 1.5

var _no_move_time := 0.0
## Rescue Wells forced in this run — the probe reads it: a handful per run is
## the guarantee working; dozens means normal spawning itself is starving the
## board and needs retuning.
var rescues := 0


## True while at least one healthy Well with reserve left can still be wired
## into the live network — already on it, or within one vein of a connected
## node that would actually accept RAW (Heart, healthy Well, Forge; a Loom or
## a rotten node in reach is not a move, it just looks like one).
func _has_reachable_supply() -> bool:
	for n in nodes:
		if n.kind != VNode.Kind.WELL or n.corrupted or n.reserve <= 0.0:
			continue
		if n.depth >= 0:
			return true
		for m in nodes:
			if m.depth < 0 or m.corrupted or not in_reach(n, m):
				continue
			if m.kind == VNode.Kind.HEART or m.kind == VNode.Kind.WELL \
					or (m.kind == VNode.Kind.FORGE and m.recipe.has(VNode.Res.RAW)):
				return true
	return false


func _ensure_move(delta: float) -> void:
	if _has_reachable_supply():
		_no_move_time = 0.0
		return
	_no_move_time += delta
	if _no_move_time < RESCUE_DEBOUNCE:
		return
	_no_move_time = 0.0
	rescues += 1
	_spawn_rescue_well()


## Where a rescue Well must appear to be answerable: near the entry point of
## the chain the CURRENT demand needs. For RAW that's the Heart itself; for
## every refined tier the chain enters through a Forge (RAW is the only thing
## a Well makes), so it lands by the Forge best placed for the rest of the
## chain — nearest a Loom when the demand needs one, nearest the Heart
## otherwise. Every link downstream of that Forge is already guaranteed by
## tool anchoring (see _spawn_node).
func _rescue_anchor() -> Vector2:
	if demand == VNode.Res.RAW:
		return heart.position
	var goal := heart.position
	if demand == VNode.Res.CLOTH or demand == VNode.Res.PRISM or demand == VNode.Res.HEXAGON:
		var loom := _nearest_node_of_kind(VNode.Kind.LOOM, heart.position)
		if loom != null:
			goal = loom.position
	# Only a RAW-eating Forge is a chain entry a fresh Well can actually
	# feed — an exotic one that wants squares is no rescue at all.
	var forge: VNode = null
	var best_d := INF
	for n in nodes:
		if n.kind != VNode.Kind.FORGE or n.corrupted or not n.recipe.has(VNode.Res.RAW):
			continue
		var d := n.position.distance_to(goal)
		if d < best_d:
			best_d = d
			forge = n
	return forge.position if forge != null else heart.position


func _nearest_node_of_kind(kind: int, to: Vector2) -> VNode:
	var best: VNode = null
	var best_d := INF
	for n in nodes:
		if n.kind != kind or n.corrupted:
			continue
		var d := n.position.distance_to(to)
		if d < best_d:
			best_d = d
			best = n
	return best


## Forces a fresh Well within one vein of _rescue_anchor(). Ignores
## MAX_LIVE_WELLS — when this fires the board has zero usable supply, and
## survival outranks board hygiene. Same elbow-room sampling as _spawn_node,
## same guaranteed _least_crowded_spot fallback, so this can never itself
## fail to place.
func _spawn_rescue_well() -> void:
	var vp := design_size()
	var center := _rescue_anchor()
	var best := Vector2.ZERO
	var best_score := -INF
	for _i in 64:
		var bearing := rng.randf() * TAU
		var dist := rng.randf_range(112.0, Vein.MAX_LEN * 0.85)
		var p := center + Vector2(cos(bearing), sin(bearing)) * dist
		if p.x < EDGE_MARGIN_X or p.x > vp.x - EDGE_MARGIN_X or p.y < EDGE_MARGIN_Y or p.y > vp.y - EDGE_MARGIN_Y:
			continue
		if p.distance_to(heart.position) < MIN_HEART_CLEARANCE:
			continue
		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near < 104.0:
			continue
		if near > best_score:
			best_score = near
			best = p
	if best_score == -INF:
		best = _least_crowded_spot(center, Vein.MAX_LEN * 0.6)
	_make_node(VNode.Kind.WELL, best)
	_rebuild_graph()


# --- The chain-integrity guarantee -------------------------------------------
#
# _has_reachable_supply/_spawn_rescue_well above guarantee RAW is always
# reachable, but they predate tools being able to DIE (see VNode's per-smelt
# depletion). Once a Forge/Loom/Kiln can corrupt from use, two new
# unrecoverable states become possible that the RAW-only guarantee doesn't
# cover: every canonical instance of a tier's tool dies at once (the tier
# becomes unbuildable, full stop — no Well hookup fixes it), or one survives
# but the specific node that fed it just corrupted and nothing else has ever
# spawned close enough to replace it (the tool exists but is permanently
# stranded). Either one is exactly "the Heart wants X and there is nothing you
# can do about it" for that tier — this section closes both, for every tier
# the run has ever unlocked, not just the one currently demanded, since
# rotation can bring any of them back at any time.

## Debounce for the checks below. Tighter than RESCUE_DEBOUNCE: a broken tier
## link is a harder stop than "supply is scarce" (nothing you build reaches the
## Heart as the right shape until it resolves), so it gets caught sooner.
const CHAIN_STALL_DEBOUNCE := 2.0

var _chain_stall := {}   # String key -> accumulated stall seconds, per check.
## Rescue tools/feeders forced in by the checks below, this run. Like
## `rescues`, a handful is the guarantee working; a flood means a tier is
## structurally too fragile and needs retuning (MAX_LIVE_* caps, yield, gaps).
var chain_rescues := 0


## Live, non-corrupted instances of `kind` running the CANONICAL recipe (the
## plain "two of the tier below," not an exotic mix). The classic
## Well->Forge->Loom->Kiln chain must stay completable through at least one
## canonical instance of every unlocked tier — exotic siblings are flavour,
## never the only way through.
func _count_canonical_healthy(kind: int) -> int:
	if not CANONICAL_RECIPE.has(kind):
		return 0
	var canonical: Array[int] = []
	canonical.assign(CANONICAL_RECIPE[kind])
	var c := 0
	for n in nodes:
		if n.kind == kind and not n.corrupted and n.recipe == canonical:
			c += 1
	return c


## True if at least one live, non-corrupted `kind` node has a live,
## non-corrupted `feeder_kind` node within reach (a Well must also have
## reserve left). This is the "is the link actually USABLE" check, distinct
## from merely existing: a Loom can sit on the board forever while the one
## Forge that used to feed it is long gone and nothing new ever spawned close
## enough — it looks like progress but is dead weight.
func _any_kind_fed(kind: int, feeder_kind: int) -> bool:
	for n in nodes:
		if n.kind != kind or n.corrupted:
			continue
		for m in nodes:
			if m.kind != feeder_kind or m.corrupted:
				continue
			if feeder_kind == VNode.Kind.WELL and m.reserve <= 0.0:
				continue
			if in_reach(n, m):
				return true
	return false


## The best live, non-corrupted `kind` node to rescue-feed: nearest the Heart,
## since that is the one most likely already load-bearing in the player's build.
func _pick_stranded(kind: int) -> VNode:
	var best: VNode = null
	var best_d := INF
	for n in nodes:
		if n.kind != kind or n.corrupted:
			continue
		var d := n.position.distance_to(heart.position)
		if d < best_d:
			best_d = d
			best = n
	return best


## Ensures at least one CANONICAL `kind` stays alive once `unlock_res` has ever
## been demanded. Spawns through the normal _spawn_node path, which already
## rolls canonical automatically when none of that kind survive (see
## _roll_recipe) — this just ignores the live-count cap, because a fully dead
## tier is worse than one extra tool on the board.
func _ensure_canonical_alive(kind: int, unlock_res: int, delta: float) -> void:
	if not _unlocked_res.has(unlock_res):
		return
	var key := "canon_%d" % kind
	if _count_canonical_healthy(kind) > 0:
		_chain_stall[key] = 0.0
		return
	_chain_stall[key] = _chain_stall.get(key, 0.0) + delta
	if _chain_stall[key] < CHAIN_STALL_DEBOUNCE:
		return
	_chain_stall[key] = 0.0
	chain_rescues += 1
	_spawn_node(kind)


## Ensures a live `kind` has a USABLE `feeder_kind` in reach once `unlock_res`
## has ever been demanded — the tool existing is not enough if the one thing
## that fed it is gone (see _any_kind_fed).
func _ensure_chain_link(kind: int, feeder_kind: int, unlock_res: int, delta: float) -> void:
	if not _unlocked_res.has(unlock_res):
		return
	var key := "link_%d" % kind
	var live := _count_healthy_kind(kind) > 0
	if not live or _any_kind_fed(kind, feeder_kind):
		_chain_stall[key] = 0.0
		return
	_chain_stall[key] = _chain_stall.get(key, 0.0) + delta
	if _chain_stall[key] < CHAIN_STALL_DEBOUNCE:
		return
	_chain_stall[key] = 0.0
	chain_rescues += 1
	var target := _pick_stranded(kind)
	if target != null:
		_spawn_rescue_feeder(feeder_kind, target)


func _tick_tool_chain(delta: float) -> void:
	_ensure_canonical_alive(VNode.Kind.FORGE, VNode.Res.REFINED, delta)
	_ensure_canonical_alive(VNode.Kind.LOOM, VNode.Res.CLOTH, delta)
	_ensure_canonical_alive(VNode.Kind.KILN, VNode.Res.PRISM, delta)
	_ensure_canonical_alive(VNode.Kind.CRUCIBLE, VNode.Res.HEXAGON, delta)
	_ensure_chain_link(VNode.Kind.FORGE, VNode.Kind.WELL, VNode.Res.REFINED, delta)
	_ensure_chain_link(VNode.Kind.LOOM, VNode.Kind.FORGE, VNode.Res.CLOTH, delta)
	_ensure_chain_link(VNode.Kind.KILN, VNode.Kind.LOOM, VNode.Res.PRISM, delta)
	_ensure_chain_link(VNode.Kind.CRUCIBLE, VNode.Kind.KILN, VNode.Res.HEXAGON, delta)


## Emergency placement for a feeder a live, stranded `target` needs RIGHT NOW.
## A Well just needs to land within reach of `target`; a rescue tool (a Forge
## for a stranded Loom, a Loom for a stranded Kiln) also needs its OWN feeder
## in reach — the same dual-anchor rule _spawn_node uses, just anchored to
## `target` instead of the Heart, since here the Heart isn't the broken link.
func _spawn_rescue_feeder(feeder_kind: int, target: VNode) -> void:
	if feeder_kind == VNode.Kind.WELL:
		_spawn_rescue_well_near(target.position)
		return

	var vp := design_size()
	var sub_feeder: VNode = null
	match feeder_kind:
		VNode.Kind.FORGE:
			sub_feeder = _nearest_node_of_kind(VNode.Kind.WELL, target.position)
		VNode.Kind.LOOM:
			sub_feeder = _nearest_node_of_kind(VNode.Kind.FORGE, target.position)
		VNode.Kind.KILN:
			sub_feeder = _nearest_node_of_kind(VNode.Kind.LOOM, target.position)

	var anchor := target.position
	var min_dist := 60.0
	var max_dist := Vein.MAX_LEN * 0.85
	if sub_feeder != null and target.position.distance_to(sub_feeder.position) <= Vein.MAX_LEN * 1.9:
		anchor = (target.position + sub_feeder.position) * 0.5
		var half := target.position.distance_to(sub_feeder.position) * 0.5
		max_dist = clampf(Vein.MAX_LEN - half - 14.0, 24.0, 135.0)
		min_dist = minf(48.0, max_dist * 0.6)
	else:
		sub_feeder = null

	var best := Vector2.ZERO
	var best_score := -INF
	for _i in 64:
		var bearing := rng.randf() * TAU
		var dist := rng.randf_range(min_dist, max_dist)
		var p := anchor + Vector2(cos(bearing), sin(bearing)) * dist
		if p.x < EDGE_MARGIN_X or p.x > vp.x - EDGE_MARGIN_X or p.y < EDGE_MARGIN_Y or p.y > vp.y - EDGE_MARGIN_Y:
			continue
		if p.distance_to(target.position) > Vein.MAX_LEN:
			continue
		if sub_feeder != null and p.distance_to(sub_feeder.position) > Vein.MAX_LEN:
			continue
		if p.distance_to(heart.position) < MIN_HEART_CLEARANCE:
			continue
		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near < 104.0:
			continue
		if near > best_score:
			best_score = near
			best = p
	if best_score == -INF:
		best = _least_crowded_spot(anchor, minf(max_dist, 60.0))

	var n := _make_node(feeder_kind, best)
	var canonical: Array[int] = []
	canonical.assign(CANONICAL_RECIPE[feeder_kind])
	n.recipe = canonical
	if feeder_kind == VNode.Kind.FORGE and not seen_forge:
		seen_forge = true
		n.teach = true
		_store_save()
	elif feeder_kind == VNode.Kind.LOOM and not seen_loom:
		seen_loom = true
		n.teach = true
		_store_save()
	elif feeder_kind == VNode.Kind.KILN and not seen_kiln:
		seen_kiln = true
		n.teach = true
		_store_save()
	_rebuild_graph()


## Well-flavoured half of _spawn_rescue_feeder: lands a fresh Well within reach
## of `near`, same elbow-room sampling and guaranteed fallback as
## _spawn_rescue_well, just anchored to a specific stranded tool instead of
## _rescue_anchor()'s single current-demand guess.
func _spawn_rescue_well_near(near: Vector2) -> void:
	var vp := design_size()
	var best := Vector2.ZERO
	var best_score := -INF
	for _i in 64:
		var bearing := rng.randf() * TAU
		var dist := rng.randf_range(70.0, Vein.MAX_LEN * 0.85)
		var p := near + Vector2(cos(bearing), sin(bearing)) * dist
		if p.x < EDGE_MARGIN_X or p.x > vp.x - EDGE_MARGIN_X or p.y < EDGE_MARGIN_Y or p.y > vp.y - EDGE_MARGIN_Y:
			continue
		if p.distance_to(heart.position) < MIN_HEART_CLEARANCE:
			continue
		var nd := INF
		for n in nodes:
			nd = minf(nd, p.distance_to(n.position))
		if nd < 104.0:
			continue
		if nd > best_score:
			best_score = nd
			best = p
	if best_score == -INF:
		best = _least_crowded_spot(near, Vein.MAX_LEN * 0.6)
	_make_node(VNode.Kind.WELL, best)
	_rebuild_graph()


# --- The throughput guarantee -------------------------------------------------
#
# The two guarantees above answer "does a path exist" (_has_reachable_supply)
# and "is that path's tool actually fed" (_any_kind_fed) — both are pass/fail,
# neither asks how FAST. A Forge with exactly one starved-looking Well in
# reach is a technical yes on both, but if the Heart burns through a
# triangle's worth of fuel every few seconds and that Well can only make one
# circle every WELL_PERIOD, the "move" the other guarantees promised isn't
# actually one — the board just looks solvable. This section is the rate
# check: the CURRENT demand's best buildable lineage must be able to sustain
# at least the Heart's current burn rate, with margin, same debounce+rescue
# shape as the two guarantees above.

## Every hop's throughput ceiling, independent of length — see
## Vein.DOT_SPACING. A vein's cap doesn't care whether it's short or stretched
## to Vein.MAX_LEN; only the gap between items does.
const EDGE_RATE := Vein.SPEED / Vein.DOT_SPACING

## Fraction of bare-survival rate the achievable rate must clear before this
## check is satisfied. NOT "stay fully fed forever" — that's explicitly not
## the promise (see VEIN.md: "difficulty escalates until the topology problem
## becomes unsolvable... collapse is the content"). A probe run with every
## other guarantee healthy still dies right around EXERTION_SPAN on appetite
## alone; a margin tuned to full sustainability would have this guarantee
## fight that intended ending, forcing rescue Wells in every few seconds
## through the entire back half of every run. What it must never allow is a
## reachable, fed lineage reduced to a functional trickle — the SPECIFIC
## complaint this guarantee exists for ("circles are rare around it so flow
## can't keep the heart alive" even though a path exists and is fed). Wide
## (near-full sustain) while still walking the teaching schedule, so a first
## board never has to feel that trickle at all; falls to a low floor once the
## run is at full intensity, on the same _hardcore_ramp() lever
## TEACHING_PRESSURE_MULT/TEACHING_APPETITE_MULT already use — losing ground
## late is intended, going to literally nothing is not.
const THROUGHPUT_MARGIN_TEACHING := 1.0
## Was 0.3 — raised alongside this pass's broader generosity push (EXERTION_
## SPAN, HARDCORE_RAMP_TIME, FUEL_CAP). The late game staying genuinely
## losable is still the intent; 0.45 just means "losing ground" doesn't start
## from as thin a trickle as 0.3 allowed.
const THROUGHPUT_MARGIN_HARDCORE := 0.45

## Longer than RESCUE_DEBOUNCE/CHAIN_STALL_DEBOUNCE on purpose: appetite rides
## a sine wave (see APPETITE_WAVE_PERIOD, 17s) that alone walks needed_rate
## up and down, so a lean-but-working single-chain board can drift under
## margin for a few seconds every wave cycle without ever being in real
## trouble. A short debounce reacted to that wobble, not a genuine shortfall.
const THROUGHPUT_DEBOUNCE := 4.0
var _throughput_stall := 0.0
## Rescue Wells forced in by a THROUGHPUT shortfall specifically — a chain
## that exists and is fed, just too thinly to keep up. Distinct from
## `rescues` (nothing reachable at all) and `chain_rescues` (a tier's tool or
## link is dead): a flood here means the RATE side of the tuning (yields,
## EDGE_RATE, well density near a tier's entry point) needs work even though
## both existence guarantees read healthy.
var throughput_rescues := 0

## Same-family replacements forced in the instant a node corrupts — see
## _on_node_corrupted. Unlike the other rescue counters above (all reactive
## to something already going wrong), a healthy handful of these per run is
## just the harakiri mechanic working as intended, not a tuning smell.
var corruption_respawns := 0


## Items/sec of `demand` the Heart needs right now to hold fuel steady,
## reading combo as zero — combo only ever helps, it must never be load-
## bearing for the guarantee itself.
func _needed_rate() -> float:
	var interval := Beat.interval()
	if interval <= 0.0 or interval == INF:
		return 0.0
	var gain: float = FUEL_BY_RES.get(demand, 1.0)
	return appetite() / interval / gain


## RAW is the one tier with no tool of its own — the Heart eats it directly.
## Reachability here mirrors _has_reachable_supply's accept-list (a healthy
## Well or a RAW-eating Forge; a Loom in reach is not a move, it just looks
## like one) but walks it out through every hop instead of stopping at one —
## Vein.MAX_LEN's own doc comment is explicit that a spread-out RAW network is
## expected to chain distant Wells through nearer ones on the way to the
## Heart, so a well three relays out still counts.
func _raw_reachable_wells() -> Array[VNode]:
	var out: Array[VNode] = []
	var visited := {heart: true}
	var frontier: Array[VNode] = [heart]
	while not frontier.is_empty():
		var cur: VNode = frontier.pop_back()
		for m in nodes:
			if visited.has(m) or m.corrupted or not in_reach(cur, m):
				continue
			var relay := m.kind == VNode.Kind.WELL \
					or (m.kind == VNode.Kind.FORGE and m.recipe.has(VNode.Res.RAW))
			if not relay:
				continue
			visited[m] = true
			frontier.append(m)
			if m.kind == VNode.Kind.WELL and m.reserve > 0.0:
				out.append(m)
	return out


## Best steady-state items/sec of `demand` a BUILDABLE lineage could sustain
## right now — buildable, not built, same philosophy as
## _has_reachable_supply/_any_kind_fed above: this is "could the player make
## this work", not "have they already".
func _achievable_rate() -> float:
	if demand == VNode.Res.RAW:
		return _raw_reachable_wells().size() * (1.0 / VNode.WELL_PERIOD)
	var kind := VNode.Kind.FORGE
	match demand:
		VNode.Res.CLOTH: kind = VNode.Kind.LOOM
		VNode.Res.PRISM: kind = VNode.Kind.KILN
		VNode.Res.HEXAGON: kind = VNode.Kind.CRUCIBLE
	var best := 0.0
	for n in nodes:
		if n.kind != kind or n.corrupted or not in_reach(n, heart):
			continue
		best = maxf(best, _node_rate(n, {}))
	return best


## Recursive bottleneck: a tool's output rate is capped by the slowest of its
## own recipe needs, where each need's rate is everything live and in reach
## that makes it, summed, divided by how many of it the recipe actually wants
## (a canonical [RAW, RAW] wants 2 total, from any mix of Wells — not two
## separately-tracked slots). `seen` guards the cycle an exotic recipe can
## create once every tier is unlocked (a Loom that wants PRISM, fed by a Kiln
## that wants CLOTH, fed by that same Loom) — without it this recurses
## forever the moment such a pair rolls.
func _node_rate(n: VNode, seen: Dictionary) -> float:
	if n == null or n.corrupted or seen.has(n):
		return 0.0
	seen = seen.duplicate()
	seen[n] = true
	if n.kind == VNode.Kind.WELL:
		return 1.0 / VNode.WELL_PERIOD if n.reserve > 0.0 else 0.0
	if n.recipe.is_empty():
		return 0.0
	var needed := {}
	for r in n.recipe:
		needed[r] = needed.get(r, 0) + 1
	var worst := INF
	for res_kind in needed:
		var incoming := 0.0
		for m in nodes:
			if m == n or m.corrupted or m.produces != res_kind or not in_reach(n, m):
				continue
			incoming += minf(_node_rate(m, seen), EDGE_RATE)
		worst = minf(worst, incoming / float(needed[res_kind]))
	return minf(worst, EDGE_RATE)


func _ensure_throughput(delta: float) -> void:
	var needed := _needed_rate()
	if needed <= 0.0:
		_throughput_stall = 0.0
		return
	var margin := lerpf(THROUGHPUT_MARGIN_TEACHING, THROUGHPUT_MARGIN_HARDCORE, _hardcore_ramp())
	var have := _achievable_rate()
	if have >= needed * margin:
		_throughput_stall = 0.0
		return
	_throughput_stall += delta
	if _throughput_stall < THROUGHPUT_DEBOUNCE:
		return
	_throughput_stall = 0.0
	throughput_rescues += 1
	_spawn_rescue_well()


## Which node kind makes `res` — RAW has no tool of its own so it maps
## straight to the Well that makes it; VOID is never a demand and maps to
## nothing. The mirror of _feeder_kind_for (which names what FEEDS a kind);
## this names what MAKES a resource. Read by scripts/shape_count.gd (loose
## Node2D-parent coupling, same convention budget_hint.gd already uses for
## game.budget/veins_used()) to know which live-node count backs which
## unlocked family.
func _producer_kind_for_res(res: int) -> int:
	match res:
		VNode.Res.RAW: return VNode.Kind.WELL
		VNode.Res.REFINED: return VNode.Kind.FORGE
		VNode.Res.CLOTH: return VNode.Kind.LOOM
		VNode.Res.PRISM: return VNode.Kind.KILN
		VNode.Res.HEXAGON: return VNode.Kind.CRUCIBLE
	return -1


# --- Harakiri: on-corruption same-family respawn -----------------------------
#
# Every guarantee above reacts AFTER something already broke: no move at all,
# a tier's tool or its feeder gone, or a thin trickle below the achievable-rate
# floor. An earlier version of this (the "demand-supply guarantee") reacted to
# a Well/tool sitting on a sliver of reserve, scoped to just whatever kind the
# CURRENT demand needed — real playtest: "when a shape is getting close to
# being poisonous there should be new spawned items for users to use them
# instead." This generalizes and replaces that: instead of guessing "running
# low" from a reserve threshold on one lineage, it reacts to the actual,
# unambiguous event — a node turning — for EVERY family, not just the one the
# Heart happens to want right now. "Triangle dies, a new triangle born
# somewhere else" — not necessarily with the same needs, just the same shape.
# This is also what turns corruption into a deliberate tool rather than pure
# hazard: the smart move once a shape starts dying is to keep milking it,
# then cut it before it collapses — that was already the right move (avoids
# extra poison damage), this just adds a payoff on top of the urgency that
# was already there.
#
# See VNode.corruption_started (vnode.gd) for why this hooks a signal fired
# from inside corrupt() itself rather than checking state here: corrupt() is
# called both by this file's own spread/airborne contagion (_tick_corruption)
# and internally by VNode's own reserve-depletion path — a signal is the only
# way to catch both. Connected once per node in _make_node.


## Fired the instant any node turns — see VNode.corruption_started. Spawns a
## same-family replacement immediately; no debounce, no threshold, because
## unlike the reserve-ratio heuristic this replaces, "corrupted" is already
## an unambiguous, one-shot event (corrupt()'s own `if corrupted: return`
## guard prevents this from ever double-firing for the same node).
##
## Doesn't need round 1's cap-bypass hack: _count_healthy_kind already
## excludes corrupted nodes, so the instant `n` turns it stops counting
## toward its own family's cap, and a same-family respawn attempted right
## after naturally sees the freed slot through the ordinary cap check.
## _spawn_node is called directly (not _spawn_tool_slot, which can redirect
## a spawn to reinforce a DIFFERENT critical kind) — strict same-family
## replacement is the whole point, not "whatever's most needed."
func _on_node_corrupted(n: VNode) -> void:
	if n.kind == VNode.Kind.HEART:
		return
	var spawned: VNode = null
	if n.kind == VNode.Kind.WELL:
		spawned = _spawn_well()
	elif _count_healthy_kind(n.kind) < _max_live_for(n.kind):
		spawned = _spawn_node(n.kind)
	if spawned == null:
		return
	corruption_respawns += 1
	# Wells replace far too often (a swarm of up to 20, see MAX_LIVE_WELLS)
	# for a ghost per corruption to read as a meaningful event rather than
	# visual noise — the respawn itself still fires every time, just quietly.
	if n.kind != VNode.Kind.WELL:
		_spawn_ghost(n.position, spawned, n.kind)


## The visual bridge between a death and its replacement — see
## scripts/ghost_spawn.gd. `spawned` already exists on the board for
## gameplay purposes the instant this is called (reachable, connectable,
## "always have a move" never waits on an animation) — ghost_spawn.gd's own
## start() hides and shrinks it, only revealing it once the ghost's travel
## finishes, so its FIRST appearance always reads as this event landing,
## not a silent pop-in the player has to notice on their own. Same
## instantiate-and-forget pattern as BurstScene/ShatterScene.
func _spawn_ghost(from: Vector2, spawned: VNode, kind: int) -> void:
	var ghost: Node2D = GhostScene.new()
	vein_layer.add_child(ghost)
	ghost.start(from, spawned, kind, rng.randi())


# --- Graph: everything flows downhill toward demand -------------------------

func _rebuild_graph() -> void:
	for n in nodes:
		n.depth = -1
		n.feed_depth = -1
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

	# Secondary orientation for everything the Heart can't reach: a
	# multi-source BFS out from the Wells (and corrupted Wells, which push
	# VOID) still stranded at depth < 0. This is what makes a circle->triangle
	# with no onward path actually FLOW and pool at the triangle, instead of
	# sitting inert. A node's feed_depth is its hop-distance from the nearest
	# such Well; veins between two disconnected nodes orient low->high, i.e.
	# away from the Well toward the dead-end (see Vein.update_dir).
	var fq: Array[VNode] = []
	for n in nodes:
		if n.depth < 0 and (n.kind == VNode.Kind.WELL or n.corrupted):
			n.feed_depth = 0
			fq.append(n)
	while not fq.is_empty():
		var cur: VNode = fq.pop_front()
		for v in veins:
			var o := v.other(cur)
			if o != null and o.depth < 0 and o.feed_depth < 0:
				o.feed_depth = cur.feed_depth + 1
				fq.append(o)

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
## puzzle rests on — see Vein.MAX_LEN. One radius for every pair, no
## exceptions — a tool<->Heart pair used to reach farther (the since-removed
## TOOL_HEART_REACH); that bonus is now just baked into Vein.MAX_LEN itself,
## so every pair gets it.
func in_reach(a: VNode, b: VNode) -> bool:
	return a.position.distance_to(b.position) <= Vein.MAX_LEN


func _add_vein(a: VNode, b: VNode) -> void:
	if a == b or _find_vein(a, b) != null or not in_reach(a, b):
		return

	if not can_afford():
		return

	var synced := _tempo_action()
	var v: Vein = VeinScene.new()
	# Alternate the bend so parallel veins fan out instead of overlapping.
	v.setup(a, b, 1.0 if veins.size() % 2 == 0 else -1.0)
	v.tempo_grade = combo if synced else -1
	v.ruptured.connect(_on_ruptured)
	vein_layer.add_child(v)
	veins.append(v)
	# Flash the line inventory on every spend so a first-timer sees the budget
	# tick down — the just-spent slot is the highest lit one.
	budget_hint.flash(veins.size() - 1)
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
		_maybe_combo_callout()
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
	_combo_callout_tier = 0
	_bad_tempo_flash = 1.0
	return false


## Fires at most once per streak per tier as combo climbs through
## COMBO_CALLOUT_TIERS — _combo_callout_tier (reset everywhere combo itself
## resets to 0) tracks the highest tier already fired this streak.
func _maybe_combo_callout() -> void:
	if _harness_active:
		return
	for i in COMBO_CALLOUT_TIERS.size():
		if _combo_callout_tier <= i and combo >= COMBO_CALLOUT_TIERS[i]:
			_combo_callout_tier = i + 1
			Callout.fire("combo", vein_layer, design_size() * 0.5)
			return


func _tempo_quality() -> float:
	return minf(Beat.phase, 1.0 - Beat.phase)


## Shared teardown for a node leaving the board outside of the normal
## rupture/cut paths — withered Wells, collapsed rot. Always drops any vein
## still attached (a withered/collapsed node is by definition orphaned or
## about to be cut).
func _remove_node(n: VNode) -> void:
	for v in veins.duplicate():
		if v.a == n or v.b == n:
			_remove_vein(v)
	nodes.erase(n)
	n.queue_free()
	if heart == n:
		heart = null
	_rebuild_graph()


## A trunk carried more than it could bear. The dots in flight scatter and
## die — a real cost, whatever was in transit is gone — but the vein itself
## survives. Explicit direction: lines never die on their own, only a
## player's own cut removes one. A rupture is now a pure congestion event:
## it clears the vein back to empty and resets its strain, same jump-scare
## burst/haptic as before, just without deleting the connection you built.
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

	v.dots.clear()


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
	# Flash the line inventory on a refund too — a cut hands a slot back, and
	# seeing it light up teaches that veins are finite and reclaimable.
	budget_hint.flash(veins.size())
	# die() lets the vein shrink-and-fade in place (see vein.gd) instead of
	# blinking out — the removal itself needs to be visible even when there
	# was nothing precious in flight to burst, which is the common case for a
	# vein you'd actually choose to cut.
	v.die()
	_rebuild_graph()


# --- Sim --------------------------------------------------------------------

func _process(delta: float) -> void:
	if _claiming_random_name:
		_tick_random_name_claim()
	if _fetching_recovery_code:
		_tick_recovery_code_fetch()
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
	_death_amt = Vein._smooth(_death_amt, 1.0 if not alive else 0.0, 1.1, delta)
	# drain.gdshader samples hint_screen_texture — a full-screen post-process
	# pass, not a normal draw, so Godot has to render the scene to an
	# intermediate buffer first and run this as a second pass over every
	# pixel on screen. That ran EVERY frame for the entire life of a run
	# even at drain=warm=death=0.0 (the ordinary healthy-play case, most of
	# any run), paying for a full-screen shader pass — the single most
	# expensive thing in this file, running constantly — to draw literally
	# nothing different from the scene underneath it. Hiding the ColorRect
	# below this epsilon skips the whole pass; it re-shows itself the
	# instant any of the three actually starts moving. _drain_amt/_death_amt
	# approach their targets exponentially (see Vein._smooth) so they only
	# ever get asymptotically close to 0, never land on it exactly — the
	# epsilon is what a `> 0.0` check would miss.
	const DRAIN_VISIBLE_EPS := 0.003
	drain.visible = _drain_amt > DRAIN_VISIBLE_EPS or _rescue > DRAIN_VISIBLE_EPS \
		or _death_amt > DRAIN_VISIBLE_EPS
	if drain.visible:
		drain.material.set_shader_parameter("drain", _drain_amt)
		drain.material.set_shader_parameter("warm", _rescue)
		drain.material.set_shader_parameter("death", _death_amt)

	if _touching and not _moved and not _dilating:
		_touch_time += delta
		# `not _press_tithe`: a hold on the Heart or the score-circle while
		# the offer is up IS the tithe — the two hold-verbs must never fire
		# together, or every tithe would also slow the world (and hide the
		# very urgency the player is paying to escape). Holding anywhere
		# else still dilates as always.
		if _touch_time >= LONG_PRESS and _drag_from == null and not _press_tithe:
			_dilating = true
			_pre_dilation_scale = Engine.time_scale
			Engine.time_scale = _pre_dilation_scale * DILATION

	if not alive:
		return

	_deliver_flush_timer += delta
	if _deliver_flush_timer >= DELIVER_FLUSH_INTERVAL and not _pending_deliveries.is_empty():
		_deliver_flush_timer = 0.0
		_flush_deliveries()

	_tick_escalation(delta)
	_tick_corruption(delta)
	_tick_lifecycle(delta)
	heart.fuel_ratio = health_ratio()
	# lb_you only carries a real rank once this session has heard back from
	# a submission (see _on_lb_request_completed) — before that it's still
	# the {"rank": 0, ...} default, so the crown simply never shows until
	# you've actually earned it. It then persists across a same-session
	# Replay (lb_you isn't reset there), so the Heart keeps its crown into
	# your very next run too, not just the death screen you saw it on.
	heart.wears_crown = int(lb_you.get("rank", 0)) == 1
	# Same escalation shape as corruption spread/airborne blight/demand
	# rotation: near-zero at the open, ramping to full bite by EXERTION_SPAN,
	# and still climbing past it (see pressure()) — a tool's per-smelt reserve
	# cost is not exempt from "the enemy never stops getting worse."
	var tool_depletion := lerpf(TOOL_DEPLETION_EARLY, 1.0, intensity()) \
		+ maxf(pressure() - 1.0, 0.0) * TOOL_DEPLETION_POST_EXTRA
	for n in nodes:
		if n.kind == VNode.Kind.FORGE or n.kind == VNode.Kind.LOOM or n.kind == VNode.Kind.KILN \
				or n.kind == VNode.Kind.CRUCIBLE:
			n.depletion_rate = tool_depletion
	_push_from_nodes()
	for v in veins:
		# The line itself should show it's wrong, not just the pop once it
		# lands — see Vein.wrong_flow/_wrong_jiggle. Only a vein feeding the
		# Heart directly can BE wrong (an intermediate Well->Forge link is
		# never off-demand, it's just supply); VOID keeps its own established
		# poison language rather than being folded into this one.
		var wrong := false
		if v.sink() == heart:
			for d in v.dots:
				if d.kind != demand and d.kind != VNode.Res.VOID:
					wrong = true
					break
		v.wrong_flow = wrong
		for item in v.advance(delta):
			_deliver(item.kind, v, v.sink(), item.pot)

	# The tithe's falling dots, advanced with the same dilation-scaled delta
	# as everything else — the panic pinch slows the rescue too, which is
	# honest: time dilation reads the world, it doesn't cheat it.
	tithe.sync(_tithe_score_pos(), heart.position, heart.radius())
	for d in tithe.advance(delta):
		_tithe_arrive(d)

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
	var exert := intensity()
	var phase := Beat.phase
	var beat_r := 48.0 + phase * (44.0 + exert * 54.0)

	# The heartbeat pulse — a ring that blooms outward on every beat. This is
	# the whole on-Heart overlay now: the rhythm-target arc, the combo teeth,
	# and the off-beat flash that used to ring the Heart were removed as
	# unreadable clutter (playtest: "a half curve and dashes around the heart
	# I don't understand"). The rhythm bonus still pays out under the hood, it
	# just no longer draws a gauge nobody was reading.
	var ring := Palette.HEART
	ring.a = (1.0 - phase) * (0.22 + exert * 0.22)
	draw_arc(centre, beat_r, 0.0, TAU, 72, ring, 1.5 + exert * 2.0, true)


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
	# Past pressure 1.0 the rot keeps tightening toward a hard floor and the
	# blight jumps more often — the enemy never stops getting worse, same
	# rule as the demand rotation (see pressure()).
	var spread_time := lerpf(VNode.SPREAD_TIME, SPREAD_TIME_LATE, exert)
	spread_time = maxf(SPREAD_TIME_FLOOR, spread_time - maxf(pressure() - 1.0, 0.0) * 0.8)
	# A corrupted node still wired to the Heart is already being punished the
	# ordinary way — its own VOID buffer flows downhill and poisons the Heart
	# directly every CORRUPT_PERIOD (see VNode._emit/_push_from_nodes). Cut
	# its Heart vein and that outlet is gone: it goes into a RAGE instead,
	# turning on whatever it is still wired to — AT THE SAME CADENCE, reusing
	# VNode.CORRUPT_PERIOD rather than a separate faster number. Direct
	# feedback: "a poisonous shape connected to the Heart produces poison
	# dots toward the Heart — when it gets disconnected, [it should attack]
	# at the same rate [as] the poison dots that go to the Heart."
	# One flood per firing (see below) reaches every node still wired to
	# it, direct or indirect, so a whole limb still turns over in one go —
	# just paced to the ordinary poison cadence instead of a bespoke rage
	# clock.
	var airborne := exert >= AIRBORNE_AT
	var airborne_chance := minf(
		AIRBORNE_CHANCE_MAX, AIRBORNE_CHANCE + maxf(pressure() - 1.0, 0.0) * 0.1)

	# Airborne-jump targets only — those still corrupt instantly (see below),
	# vein-adjacency targets now go through _start_poison_dart instead (see
	# its own comment for why an instant flip was replaced with a travelling
	# dart).
	var newly: Array[VNode] = []
	for n in nodes:
		if not n.corrupted:
			continue
		# spread_accum runs in parallel with corrupt_age from the moment of
		# corruption (NOT only once the floor below clears) — an orphaned
		# node's threshold is VNode.CORRUPT_PERIOD, the same value as the
		# floor, so if this only started counting once the floor cleared it
		# would need a further full CORRUPT_PERIOD on top of it, past
		# ORPHAN_COLLAPSE_TIME (1.6s): the node would collapse from neglect
		# before ever landing a single attack. Counting from corruption
		# itself is what makes the floor and the threshold land on the same
		# frame, so a node turns on its neighbours the instant it's allowed
		# to, at the same cadence it already emits its own poison at.
		n.spread_accum += delta
		# A node is already "actually dangerous" the moment it produces its
		# first poison dot (VNode.CORRUPT_PERIOD after corrupting) — that is
		# also the earliest it makes sense for it to turn on its neighbours.
		# Playtest: "when they got poisonous it should give you a little
		# buffer to disconnect it, just like before when it first produces a
		# poisonous dot — I don't want a lot of time, but not instant
		# either."
		if n.corrupt_age < VNode.CORRUPT_PERIOD:
			continue
		var t: float = VNode.CORRUPT_PERIOD if n.depth < 0 else spread_time
		if n.spread_accum < t:
			continue
		n.spread_accum = 0.0

		# EVERY live-vein neighbour, not just one picked at random — a
		# disconnected island is a dead limb; the whole thing goes together,
		# not one victim per tick while its neighbours sit untouched.
		# Playtest: "it only kills the nearest neighbour — no, it should
		# kill all the connected neighbours, the whole disconnected island."
		# This only starts the attack on n's DIRECT neighbours — each one is
		# a relay, not a dead end: the moment its own dart lands and it
		# turns, _start_poison_dart fires fresh darts from IT to its own
		# neighbours in turn, and so on, so the poison keeps travelling
		# node-to-node until it runs out of island, all the way to the
		# leaves at the far end. Playtest, after a version that instead
		# pre-computed every downstream target from n and fired simultaneous
		# darts at all of them: "the poisonous dot don't stop at direct
		# neighbours — [it should] go through them to reach all other
		# connected shapes." A relay is what that actually looks like: the
		# dot passing through each node on the way, not several darts
		# fanning out from the same origin at once.
		#
		# ANY non-Heart neighbour, not just a Well — restricting this to
		# Kind.WELL meant a corrupted Well whose only live neighbours were
		# tools (the ordinary case: a Well feeds a Forge/Loom, not another
		# Well) had zero valid targets and could never attack at all, while a
		# corrupted TOOL almost always has a Well neighbour and attacked
		# freely. Reported: "only noncircle shapes... start shooting back at
		# neighbours... circles just don't." The Heart itself is the one
		# real exclusion — corruption has no meaning there. Also excludes
		# anything already with a dart in flight (_poison_pending) so two
		# attackers can't both target the same node.
		for v in veins:
			var o := v.other(n)
			if o != null and not o.corrupted and o.kind != VNode.Kind.HEART \
					and not _poison_pending.has(o) and o not in newly:
				_start_poison_dart(o, v, v.a == n)

		# Airborne is a slow, occasional "roaming blight" (see the file
		# comment), gated to the ORIGINAL spread_time cadence only — NOT the
		# fast orphan rage path. Letting it roll on the fast path too was a
		# real bug: every orphaned node in a rage cluster rolled
		# independently every tick, so a cluster of even a handful of nodes
		# had a near-certain chance SOME jump would land almost every tick —
		# and since a jump can land on another node that is ALSO orphaned
		# (post-rage, a big chunk of the board can be), that node immediately
		# joined the fast path too. Confirmed report: "the whole screen
		# suddenly went poisonous" and the phone got hot from the resulting
		# spawn/VFX storm — a real runaway feedback loop, not just an
		# intense-looking one.
		if n.depth >= 0 and airborne and rng.randf() < airborne_chance:
			var jumped := _nearest_orphan_well(n.position, AIRBORNE_RADIUS)
			if jumped != null and jumped not in newly and not _poison_pending.has(jumped):
				newly.append(jumped)

		if newly.size() >= MAX_CORRUPTIONS_PER_TICK:
			break

	for n in newly:
		n.corrupt()
		corruptions += 1
		Audio.play("corrupt", -4.0, 0.62)
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(140)
		# The moment of the "attack" itself, not just the aftermath — a burst
		# right on the newly-turned node, same vector language _tick_lifecycle
		# already uses for a collapse.
		var burst: Node2D = BurstScene.new()
		vein_layer.add_child(burst)
		burst.spawn([n.position], [VNode.Res.VOID], rng.randi(), Color(0, 0, 0, 0), exert)


## A raging node's attack on one direct neighbour — an open-ended stream of
## darts over the SAME vein, but the target still turns the moment
## travel_time elapses, not once the stream itself stops. Playtest, after a
## 3-hit-to-kill burst was tried once already: "don't even kill them faster,
## just poison dots — when [one] reaches a neighbour, make it poisonous."
## That verdict stands; the VISUAL went through two more tries after that. A
## fixed 3-dart burst read as one discrete event regardless of distance.
## Capping the stream to "however many darts fit in one target's
## travel_time" (5-6 for a typical hop) was closer, but still stopped the
## instant that ONE neighbour turned: "I want them flowing from the source...
## the source and closer shapes shouldn't vanish sooner, when the last one
## got poisonous all shapes and lines vanish together." The pulse below
## keeps going for as long as the vein and the far node still exist, which —
## since a raging node no longer collapses on its own (see
## _island_ready_to_collapse) — is the WHOLE island's remaining lifetime,
## not one hop's travel time. travel_time itself (and therefore when the
## target turns) is still computed once, off the vein alone, same as before
## — only the visual keeps running past that point.
##
## `vein` is the live connection between them — the darts ride its actual
## curve (see poison_dart.gd), not a straight line cutting across the board,
## and take vein.length/Vein.SPEED to arrive — the same speed every ordinary
## resource dot rides. A real Vein.inject() dot was tried here instead and
## reverted: it only travels a vein's fixed flow direction, and only
## resolves anything once it arrives through the ordinary delivery pipeline,
## which just treats VOID as harmless pass-through for a non-Heart
## destination — so the visible dot and the actual kill ended up decoupled
## and unreliable, which is exactly what broke. poison_dart.gd is purely
## cosmetic and drawn to match vein.gd's own _draw_poison_dot; this function
## alone decides who actually turns and when, so the two can never disagree.
## `target` is marked _poison_pending for the whole flight so no second
## attacker can also target it in the meantime (see the candidate loop in
## _tick_corruption above), and the resolve step re-checks is_instance_valid
## + not already corrupted, since a corrupted node can still be cut,
## collapse, or get caught by the OTHER spread path (airborne) before its
## own dart lands.
##
## THE RELAY: the moment `target` turns, it does not just sit there — it
## immediately fires its own darts at its own remaining live neighbours,
## the same way it was just reached through one of ITS neighbours. That is
## what makes the poison travel node-to-node through the whole disconnected
## island instead of stopping at whichever node happened to trigger it.
## Playtest, after a version that instead pre-computed every downstream
## target from the ORIGINAL raging node and fired simultaneous darts at all
## of them: "the poisonous dot don't stop at direct neighbours — [it should]
## go through them to reach all other connected shapes." Several darts
## converging on different destinations from the same single origin, all at
## once, did not read as that; a relay — each hop only ever knowing about
## its own immediate neighbours — does, and it is also simpler: no
## precomputed path, no BFS, just "arrive, turn, attack whoever is still
## next to you."
func _start_poison_dart(target: VNode, vein: Vein, forward: bool) -> void:
	_poison_pending[target] = true
	var travel_time := maxf(vein.length / Vein.SPEED, MIN_RAGE_DART_TRAVEL_TIME)

	# The continuous visual — self-reschedules every RAGE_DART_INTERVAL for
	# as long as both ends are still around, with no upper bound baked in.
	# It keeps running past the kill below (a raging node stays red and
	# connected long after it first turns, until its whole island collapses
	# together), which is what makes the vein read as an ongoing flow
	# instead of a burst that happens to stop once. `pulse_ref` — a
	# one-element Array rather than a plain Callable var — is the only way
	# to actually make this self-referencing: a GDScript closure captures a
	# local var's VALUE at the moment the lambda is defined, so a bare
	# `var pulse: Callable; pulse = func(): ... .connect(pulse)` bakes in
	# whatever `pulse` was (null, since the assignment isn't finished yet)
	# and every dart after the first silently failed to reschedule. An
	# Array is captured BY REFERENCE, so `pulse_ref[0]` inside the lambda
	# reads whatever was stored there at CALL time, not definition time.
	var pulse_ref: Array = [Callable()]
	pulse_ref[0] = func() -> void:
		# target.corrupted matters here, not just validity — without it, a
		# vein whose target had ALREADY turned kept firing a new dart every
		# RAGE_DART_INTERVAL regardless, since the only thing that ever
		# stopped it was the vein itself finally getting freed — which,
		# since a raging node no longer collapses alone (see
		# _island_ready_to_collapse), can now be many seconds after this
		# particular target died, for however long the REST of a large
		# island takes to finish. A big disconnected cut could leave dozens
		# of already-spent veins each still spawning darts every 0.1s for
		# seconds on end — real, sustained, unbounded draw work. Reported:
		# "why did my phone get hot, isn't vein supposed to be a low[-power]
		# game?" The attack succeeded the moment the target turned; nothing
		# past that point should still be firing at it.
		if not is_instance_valid(vein) or not is_instance_valid(target) or target.corrupted:
			return
		var dart: Node2D = PoisonDartScene.new()
		vein_layer.add_child(dart)
		dart.spawn(vein, forward)
		get_tree().create_timer(RAGE_DART_INTERVAL).timeout.connect(pulse_ref[0])
	pulse_ref[0].call()

	get_tree().create_timer(travel_time).timeout.connect(func() -> void:
		_poison_pending.erase(target)
		# is_instance_valid(vein) matters here, not just target — this used
		# to only check the target, so cutting the vein mid-attack made the
		# dart visually vanish (poison_dart.gd's own _process already checks
		# vein validity) while the kill fired anyway on schedule regardless.
		# Playtest: "when a neighbour is not attacked yet and we disconnect
		# it, it should get disconnected safely... sometimes even though you
		# disconnect [it], a neighbour got poisoned." Cutting the connection
		# is exactly what should call off an attack still in flight.
		if not is_instance_valid(vein) or not is_instance_valid(target) or target.corrupted:
			return
		target.corrupt()
		corruptions += 1
		Audio.play("corrupt", -4.0, 0.62)
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(140)
		var burst: Node2D = BurstScene.new()
		vein_layer.add_child(burst)
		# Explicitly typed rather than inline array literals — inside a
		# lambda (unlike a plain function body) GDScript does not always
		# infer Array[Vector2]/Array[int] from a bare `[x]` literal at the
		# call site, and passing the untyped Array through errors at runtime.
		var pts: Array[Vector2] = [target.position]
		var kinds: Array[int] = [VNode.Res.VOID]
		burst.spawn(pts, kinds, rng.randi(), Color(0, 0, 0, 0), intensity())
		for v2 in veins:
			var o2 := v2.other(target)
			if o2 != null and not o2.corrupted and o2.kind != VNode.Kind.HEART \
					and not _poison_pending.has(o2):
				_start_poison_dart(o2, v2, v2.a == target)
	)


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


## True once EVERY node still reachable from `n` over live veins (the same
## disconnected island the rage relay walks — see _start_poison_dart) has
## BOTH corrupted AND individually passed its own collapse_ratio — i.e. the
## whole island is not just fully turned but fully past its own
## ORPHAN_COLLAPSE_TIME. Checking collapse_ratio here too, not just
## `corrupted`, matters: without it, the LAST node to turn would still make
## everyone else wait for exactly IT to reach 1.0, but only once THAT one
## timer expires — the freshest member, not the whole island, would be
## setting the pace, and it would still lag noticeably behind the rest. This
## way the whole island's collapse is paced by whichever member is closest
## to done, which is what makes it land on one shared tick. Used to hold a
## raging node's own collapse back until the whole island is spent — see
## _tick_lifecycle below.
##
## `cache` is a per-_tick_lifecycle-call memo (node -> ready), populated for
## EVERY member of the island in one pass, not just `n` — without it, a large
## island sitting in this wait state had every one of its members redo the
## same full BFS over `veins`, from scratch, every single frame, for however
## many seconds the wait lasted (whichever member finishes last paces the
## whole island — see above), since _tick_lifecycle calls this once per
## waiting node. One BFS per island per tick, not one per waiting member per
## tick, is what this cache buys back.
func _island_ready_to_collapse(n: VNode, cache: Dictionary) -> bool:
	if cache.has(n):
		return cache[n]
	var visited := {n: true}
	var island: Array[VNode] = [n]
	var ready := true
	var qi := 0
	while qi < island.size():
		var cur: VNode = island[qi]
		qi += 1
		if not cur.corrupted or cur.collapse_ratio() < 1.0:
			ready = false
		for v in veins:
			if v.a != cur and v.b != cur:
				continue
			var o := v.other(cur)
			if o == null or visited.has(o) or o.kind == VNode.Kind.HEART:
				continue
			visited[o] = true
			island.append(o)
	for m in island:
		cache[m] = ready
	return ready


## Wells nobody ever wired in wither away; rot nobody ever cut collapses
## outright. Both remove the node itself (see _remove_node), which is what
## keeps the board turning over instead of only ever accumulating — every
## object that appears either gets used, gets cut, or eventually leaves.
##
## A RAGING node (depth < 0 — orphaned) is the one exception to "collapses
## on its own the moment ITS collapse_ratio hits 1.0": it waits for
## _island_ready_to_collapse too. Nodes only turn on their own local
## schedule (the rage relay reaches the ones nearest the trigger first — see
## _start_poison_dart), so without this, the ones closest to where the rage
## started were hitting ORPHAN_COLLAPSE_TIME and vanishing — vein and all —
## while the far end of the same island was still mid-attack. Playtest: "the
## lines between them only die when all are poisonous... right now the
## closer lines die faster... when all are poisonous all die together
## shapes and lines." A node whose island isn't done yet just sits at its
## already-passed collapse_ratio (harmlessly clamped at 1.0, still drawn
## raging-red) until every member has, then the whole island collapses on
## the same tick.
func _tick_lifecycle(_delta: float) -> void:
	var island_ready_cache := {}
	for n in nodes.duplicate():
		if not is_instance_valid(n) or n not in nodes:
			continue
		if n.wither_ratio() >= 1.0:
			withered += 1
			_remove_node(n)
		elif n.collapse_ratio() >= 1.0:
			if n.depth < 0 and not _island_ready_to_collapse(n, island_ready_cache):
				continue
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
		var was_full := n.buffer.size() >= n.buffer_cap()

		# Round-robin so a node with two downhill veins splits between them, but
		# fall through to the others rather than stalling on a full one.
		var placed := false
		var start := n.next_out(outs.size())
		var pot: float = n.poison_pot if n.corrupted else 1.0
		var item: int = n.buffer[0]
		for i in outs.size():
			var v: Vein = outs[(start + i) % outs.size()]
			var sink := v.sink()
			# A sink that would just refuse this item on arrival is treated as
			# blocked, same as one with no physical room left — sending it
			# anyway only burns THIS node's reserve to watch it get discarded
			# as `dropped` at the far end. Holding it here instead lets the
			# backlog build and correctly back-pressure all the way up to
			# whatever is producing it (see VNode.can_accept).
			if sink != null and not sink.can_accept(item):
				v.note_blocked()
				continue
			if v.inject(item, pot):
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


func _deliver(kind: int, v: Vein, to: VNode, pot := 1.0) -> void:
	if to == null:
		return
	if to.kind == VNode.Kind.HEART:
		# The very first delivery of the run, of any kind — this is what starts
		# the demand SCHEDULE's own clock (see _demand_clock / _tick_escalation).
		_heart_fed_ever = true
		# Near-miss engineering: a save when the heart is nearly gone must feel
		# enormous.
		if misses >= MISSES_DYING:
			_rescue = 1.0
			if OS.has_feature("mobile"):
				Input.vibrate_handheld(120)
			if not _harness_active:
				Callout.fire("rescue", vein_layer, design_size() * 0.5, true)
		var gain := float(FUEL_BY_RES.get(kind, 1.0))
		# A spent tool's poison bites harder than a spent circle's (pot > 1).
		if kind == VNode.Res.VOID:
			gain *= pot
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
			_combo_callout_tier = 0
			_bad_tempo_flash = 1.0
		elif kind == demand and kind != VNode.Res.VOID:
			gain *= (1.0 + minf(float(combo), float(COMBO_CAP)) * COMBO_GAIN)
			# Feeds the demand-tier advance gate (see _demand_tier_idx/
			# _tick_escalation) — a correct delivery is what actually earns
			# the schedule the right to move on to the next craving.
			_current_demand_deliveries += 1
		if not off_demand and not _harness_active:
			# Leaderboard anti-cheat round 2: proof of play, not a trusted
			# score number — see server/leaderboard/submit.js's
			# handleRunDeliver. Only demand-matching/VOID deliveries actually
			# move score (see above), so only those get reported; an
			# off-demand one is already worth ~0 and would just bloat the
			# batch for nothing. _harness_active skipped same as everywhere
			# else leaderboard-related — a bot's deliveries are not a real
			# player's run.
			_pending_deliveries.append({"kind": kind, "combo": combo, "pot": pot})
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
		# Reads as WRONG now, not just off-key: closer to the bruised
		# VEIN_STRAINED red than the rescue-flash WARM amber it used to lean
		# toward (that blend read too close to "good news"), a wider scatter
		# radius so the burst is an actual particle event instead of a
		# 5px ring nobody's eye catches, and a real intensity so the bits
		# fly instead of just sitting there fading.
		var warn := Palette.VEIN_STRAINED.lerp(Palette.WARM, 0.15)
		var ring: Array[Vector2] = []
		var kinds: Array[int] = []
		for i in 12:
			var a := TAU * float(i) / 12.0
			ring.append(at + Vector2(cos(a), sin(a)) * 14.0)
			kinds.append(0)
		var burst: Node2D = BurstScene.new()
		vein_layer.add_child(burst)
		burst.spawn(ring, kinds, rng.randi(), warn, 0.55)

		# "!" read as a caution note, then "X" read as a rejection mark, not
		# what actually happened — a vector cross now, drawn (not a font
		# glyph) so it can't come out as a missing-character box. Sized up
		# alongside the stronger burst so the whole event competes on equal
		# footing with a real score pop. Playtest: the muted `warn` tint that
		# fits the burst particles all but disappeared as a mark on its own —
		# drawn in Palette.SCORE instead, the same bright, legible colour the
		# "+N" pop already earns its visibility from, so the cross reads at a
		# glance instead of blending into the board.
		var mark: Node2D = FloatTextScene.new()
		vein_layer.add_child(mark)
		mark.spawn_cross(at + jitter, Palette.SCORE, 28, out_dir)
		return
	if absf(gain) < 0.5:
		return
	# Carried through _score_carry (see its own comment) rather than rounded
	# per-delivery, so the combo bonus's fractional score is never silently
	# discarded on every delivery.
	_score_carry += gain
	var rounded := int(_score_carry)
	_score_carry -= float(rounded)
	if rounded == 0:
		return
	# Deliberately NOT maxi(0, ...)'d here — a VOID/poison hit early in a run
	# can push the running total below zero, and clamping it back to 0 on the
	# spot silently forgives that debt instead of making later gains pay it
	# off, same as the server's own validated_score accumulator does (see
	# submit.js's handleRunDeliver/handleScore — it only floors once, at
	# final submission). Clamping every delivery here used to make the
	# HUD/death-screen number diverge from what the leaderboard actually
	# recorded. Display sites (score_hud.gd, score_label below) clamp for
	# show instead.
	score += rounded
	if not _harness_active:
		if score >= _next_milestone_callout:
			_next_milestone_callout += MILESTONE_CALLOUT_STEP
			Callout.fire("milestone", vein_layer, design_size() * 0.5)
		# `best > 0` matters: without it this fires on the FIRST DELIVERY of
		# any run where best is 0, because 1 > 0. Reported as "the new high
		# score text is bs, it shows at the start of the game even though my
		# high score is +1000" — best had been wiped to 0 (see _load_save),
		# so the game congratulated the player on beating a record it had
		# just deleted, five seconds into the run. It would also have hit
		# every genuinely new player on their first-ever delivery, where
		# "NEW HIGH SCORE" is technically true and completely meaningless.
		if not _best_callout_fired and best > 0 and score > best:
			_best_callout_fired = true
			Callout.fire("best", vein_layer, design_size() * 0.5, true)
	var col: Color
	var text: String
	if kind == VNode.Res.VOID:
		# Playtest: Palette.VOID's muted cold tint read as harder to spot than
		# the "+N" pop right next to it, even though it's the more important
		# number to notice. Drawn in Palette.SCORE instead — same legible
		# colour as a gain, so a poison hit competes for the eye on equal
		# footing; the leading "-" and the burst below still carry "this is
		# bad", the tint no longer has to.
		col = Palette.SCORE
		text = "%d" % rounded
		# A poison landing has to be FELT, not just read as a negative number
		# sitting next to every positive one — the same small violent burst a
		# rupture gets (see burst.gd), the one cold colour in the palette, so
		# the impact reads as wrong by shape and motion, not the tint alone.
		var ring: Array[Vector2] = []
		var kinds: Array[int] = []
		for i in 8:
			var a := TAU * float(i) / 8.0
			ring.append(at + Vector2(cos(a), sin(a)) * 10.0)
			kinds.append(0)
		var hit: Node2D = BurstScene.new()
		vein_layer.add_child(hit)
		hit.spawn(ring, kinds, rng.randi(), Palette.VOID, 0.75)
	else:
		col = Palette.SCORE
		text = "+%d" % rounded
	var pop: Node2D = FloatTextScene.new()
	vein_layer.add_child(pop)
	pop.spawn(text, at + jitter, col, 26, out_dir)


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


## Cuts every vein the swipe segment `from`->`to` actually crosses, tested
## against the vein's own sampled Bézier points (v.pts) — same shape
## distance_to_point already reads for the stationary-tap cut — not the
## straight a->b chord, since a bent vein's visible line is not that chord.
## Duplicated so cutting mid-loop (which mutates `veins`) can't skip or
## double-visit an entry.
func _slice_check(from: Vector2, to: Vector2) -> void:
	if from == to:
		return
	var cut_any := false
	for v in veins.duplicate():
		for i in v.pts.size() - 1:
			if Geometry2D.segment_intersects_segment(from, to, v.pts[i], v.pts[i + 1]) != null:
				_remove_vein(v, true)
				cut_any = true
				break
	# The knife-slash read (see slash.gd) — one per swipe segment that
	# actually connected, not per vein, so criss-crossing two veins in the
	# same frame draws a single clean streak instead of overlapping copies.
	if cut_any:
		var slash: Node2D = SlashScene.new()
		vein_layer.add_child(slash)
		slash.spawn(from, to)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_on_press(event.position)
		else:
			_on_release(event.position)
	elif event is InputEventScreenDrag:
		_on_move(event.position)


func _on_press(p: Vector2) -> void:
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
	# A tithe grab, until proven otherwise: the offer is up and the thumb
	# landed on the Heart (SNAP-radius, same as any node press), on the
	# score-circle, or anywhere along the ghost vein between them. All three
	# grab points on purpose — desperate players clutch the dying thing, their
	# number, or the lifeline itself, and every instinct must work. If the
	# gesture turns into a drag, the drag wins (see _on_move) — drawing a
	# rescue vein from the Heart is exactly what the tithe must never block.
	var tithe_grab: bool = tithe.hit(p) or tithe.hit_path(p)
	_press_tithe = tithe.offered and (_press_node == heart or tithe_grab)
	_press_tithe_score = tithe.offered and _press_node == null and tithe_grab


func _on_move(p: Vector2) -> void:
	var prev := _drag_pos
	_drag_pos = p
	if not _moved and p.distance_to(_touch_start) > DRAG_SLOP:
		_moved = true
		# The gesture just became a real drag: commit to "new connection from
		# the pressed node" even if a vein also happened to be under the
		# initial touch point — near the Heart that's the common case, not
		# an edge case, since veins fan out from point-blank range.
		_drag_from = _press_node
		prev = _touch_start
		# ...and a drag is never a tithe. A Heart-press that moves is the
		# player routing (the more important verb — it keeps working exactly
		# as before the tithe existed); emission stops, in-flight dots land.
		_press_tithe = false
	# A drag that did NOT start on a node is never a connection — nothing
	# else used that gesture, so it's free to mean "slice," Fruit-Ninja
	# style: any vein the swipe path actually crosses gets cut, on top of
	# (not instead of) the existing stationary-tap cut in _on_release.
	# EXCEPT a wobble off the score-circle: that thumb was holding the
	# offer, not swiping the board, and turning its slip into cut veins
	# would punish the exact panic the tithe exists to answer.
	if _moved and _drag_from == null and not _press_tithe_score:
		_slice_check(prev, p)


func _on_release(p: Vector2) -> void:
	_touching = false
	# Release ends emission on the next beat tick; whatever is already
	# falling still lands (see tithe.advance) — the same commitment rule as
	# everything else in flight.
	_press_tithe = false
	_press_tithe_score = false
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
	# One ring for every node kind now — no separate outer ring, since there
	# is no longer a second, longer reach for a tool/Heart pair to show.
	var reach := Palette.HEART
	reach.a = 0.10
	drag_layer.draw_arc(_drag_from.position, Vein.MAX_LEN, 0.0, TAU, 64, reach, 1.5, true)

	var to := _node_at(_drag_pos)
	var end := _drag_pos if to == null else to.position
	var stretched := _drag_from.position.distance_to(end) > Vein.MAX_LEN

	var col := Palette.VEIN_STRAINED if stretched else Palette.VEIN_LIVE
	col.a = 0.75
	drag_layer.draw_line(_drag_from.position, end, col, 3.0, true)

	if to == null:
		return
	var ok := to != _drag_from and can_afford() and _find_vein(_drag_from, to) == null \
		and in_reach(_drag_from, to)
	var ring := Palette.WARM if ok else Palette.VEIN_STRAINED
	ring.a = 0.85
	drag_layer.draw_arc(to.position, to.radius() + 8.0, 0.0, TAU, 28, ring, 2.0, true)
