# VEIN

A minimalist resource-flow game with a heartbeat.
Mobile-first design document — v0.1

## The name

VEIN carries three layers, and all three are the game:

1. **Mineral vein** — the resource-extraction fantasy. You are mining, refining, channeling raw material.
2. **Blood vein** — the economy is a living organism. Resources flow through veins you draw. The whole game pulses to a heartbeat, and your phone pulses with it.
3. **In vain** — every run ends. Collapse is inevitable. The game is about how long you can keep something alive, knowing you can't forever.

The player discovers layers 2 and 3 through play, not through text. Nobody explains it.

## One-sentence pitch

Mini Metro's elegance meets an economy that is literally alive: draw veins between shapes to feed a Heart whose beat you feel in your hand — keep it beating as long as you can.

## Design pillars

**Everything is diegetic.** No HUD numbers, no menus mid-run, no icons with labels. Shape is resource type, motion is throughput, pulse is health, color is state. If a mechanic can't be communicated through shape/motion/sound/haptics, it doesn't ship.

**One thumb, portrait, dead time.** The entire game is playable one-handed on a bus. Every interaction is a single drag or tap. A run fits in a coffee break.

**The phone has a pulse.** Haptics are not feedback garnish — they're a core channel. The device physically beats with the Heart. A healthy economy feels like a calm animal in your hand; a starving one develops arrhythmia you feel before you see. No other mobile game does this. It's the hook people describe to friends.

**Collapse is the content.** This is a tense, run-based game ("one more run"), not a zen sandbox. Difficulty escalates until the topology problem becomes unsolvable. Score is measured in heartbeats survived.

## Core loop

A run begins with the Heart — a slowly pulsing hexagon at screen center — and two or three Wells (circles) near the edges that emit raw resource dots.

The player's only verb: drag a vein from one node to another. Resources flow along veins automatically, always downhill toward demand. Tap a vein to delete it and refund it to your budget.

The Heart consumes resources to beat. Each beat is a haptic tick and a score increment. As beats accumulate:

- The Heart's appetite grows — it starts demanding refined shapes, not raw ones.
- Forges (triangles) and Looms (squares) spawn at the screen edges. A Forge eats two circles and emits a triangle. A Loom eats two triangles and emits a square. The refinement chain deepens over the run: circle → triangle → square → and eventually the Heart demands hexagons, which only a rare Crucible can make.
- New Wells spawn in awkward places, forcing rerouting.

**The scarcity that creates the puzzle:** the player has a small vein budget (start with 5, earn more at milestones). Veins are free to redraw but scarce to hold. Mid-game is a constant topology negotiation — every new node makes you question your whole network. This is Mini Metro's proven tension transplanted onto a production chain.

**Congestion is visible, never numeric.** When a vein carries more than it can bear, dots physically pile up, the vein bulges and darkens, its haptic texture turns grainy under your thumb when you touch it. A blocked vein can rupture — a small burst, dots scatter and die, the vein is destroyed and returns to your budget. Ruptures are the game's jump-scare.

## Death

When the Heart misses feedings, its beat slows. The screen desaturates from the edges inward. Haptics stutter — long gaps, double-beats. The player feels the dying before any visual reads it. When the beat stops, everything drains to grayscale, one final long vibration, and a single line appears:

> Your heart beat 4,812 times.

That number is the score. It's poetic, it's shareable, and it converts "session length" into an emotional metric. Below it, one button: a fresh Heart, already pulsing faintly. The restart is the retry prompt.

## Why it's addictive (the honest mechanics of it)

**Fast loop, visible cause.** Runs are 3–8 minutes. Death is always attributable to a specific routing decision made 40 seconds earlier — the player replays it mentally and immediately knows what to try next. "I know exactly what I did wrong" is the strongest one-more-run trigger that exists.

**Escalation math.** Appetite grows on a smooth exponential; node spawns are semi-random. Every run has a distinct topology story, but skill expression is real — the leaderboard gap between a new and expert player should be 10x.

**The pulse itself.** A steady heartbeat in the hand is physiologically calming; its disruption is physiologically alarming. The game borrows the player's own nervous system as a feedback channel. Players will describe the endgame arrhythmia as genuinely stressful — that stress is the flavor.

**Near-miss engineering.** When the Heart is one missed feeding from death and a triangle arrives just in time, everything flashes warm, the beat surges, a strong haptic thump. Rescues must feel enormous. Tune spawn logic so rescues are common in the first minute of danger and rarer later — the game teaches players that saves are possible, then makes them earn it.

**Daily Vein.** One shared daily seed, one attempt, global percentile shown as a simple position on a vertical vein ("you reached deeper than 91% of players today"). Single-attempt dailies are the highest-retention mechanic per gram of dev effort in this genre (Dorfromantik, Wordle logic).

**Milestone unlocks are mutators, not power.** At beat milestones across your lifetime total (a persistent counter: "your hearts have beaten 214,006 times"), unlock run-mutators: Twin Hearts (feed two), Sclerosis (veins slowly harden and must be replaced), Night (nodes only visible when pulsing). Mutators multiply score. Depth without power creep.

## What we deliberately do NOT have

No energy systems, no timers gating play, no currencies, no gacha, no notifications begging for return. The game is premium ($3.99, no ads, no IAP except cosmetic palettes if ever). The restraint is the brand — a minimalist game with maximalist monetization would be self-parody. Addictiveness comes from the loop, not from retention dark patterns. This also keeps the store page clean: "No ads. No timers. Just a heart to keep beating."

## Visual & audio direction

**Canvas:** near-black (`#0D0D10`) background. Nodes and resources in a strict 5-color palette per theme; the default theme is warm-on-dark (amber circles, coral triangles, bone squares, white Heart). Shape always encodes meaning; color is a redundant channel — the game is fully colorblind-safe by construction.

**Motion is the art.** Nodes pulse when they emit or consume. Dots ease along veins with slight acceleration into nodes (they're being swallowed). Veins are not straight lines — they're slightly curved, slightly organic Béziers that thicken with flow. At full health the screen looks like a living circulatory diagram; screenshots should be beautiful enough to be the marketing.

**Audio:** the heartbeat is the metronome; every emission and consumption is a note quantized to it. A healthy economy literally plays generative music in time. Starvation detunes it. Headphone players get the best version of the game; haptics carry the rhythm for everyone else.

## Mobile-first interaction spec

- Portrait only. All spawn logic keeps nodes within one-thumb reach bias (lower two-thirds weighted).
- Drag from node → node draws a vein; a magnetic snap radius of ~48pt makes imprecise thumbs feel precise.
- Tap a vein: delete (with a short undo window — a ghost vein you can tap to restore within 2 seconds).
- Long-press anywhere: time dilates to 30% while held. This is the "panic pinch" — reading time under pressure, not a pause. Costs nothing; the pressure is that flow continues.
- No pinch-zoom, no pan. One screen is the whole world. The constraint keeps runs legible and keeps the design honest.

## Godot implementation notes

This is close to the ideal Godot 4 project — zero asset pipeline.

- **Rendering:** custom `_draw()` on a single canvas layer for veins (curved `draw_polyline` with width by flow) and pooled `Node2D`/MultiMesh instances for resource dots. Target 60fps on a 5-year-old mid-range Android; dot counts stay in the low hundreds, trivially achievable.
- **Pulse system:** one global `Beat` autoload emitting a signal; every node, tween, audio note, and haptic tick subscribes. The entire game synchronizes to one timer — this is also what makes the audio quantization free.
- **Haptics:** `Input.vibrate_handheld()` with duration/amplitude patterns per beat state; on iOS, Core Haptics via a small plugin for the arrhythmia textures (worth it — it's the pillar).
- **Flow sim:** resources as lightweight structs on paths (progress ∈ [0,1] along a Curve2D), not physics bodies. Congestion = per-vein capacity counter. The whole sim is deterministic given a seed — which gives you the Daily, replays, and easy balancing for free.
- **Data:** node types and escalation curves in Resource files (`.tres`) so tuning never touches code.

## MVP scope (grey-box in ~2 weekends)

1. **Weekend 1:** Wells, Heart, vein drawing, dots flowing, appetite escalation, death. No Forges yet. If this isn't already a little compelling, the concept fails cheap.
2. **Weekend 2:** Forges (one refinement tier), vein budget, congestion/rupture, heartbeat haptics + audio metronome.
3. **Then:** playtest for the one metric that matters — do testers immediately restart without being asked? Target: 70%+ unprompted restart rate before building anything else.

Everything else (Daily, mutators, Crucible tier, palettes, leaderboards) is post-validation.

## The bet

Mini Metro proved minimalist topology puzzles retain for years. VEIN's bet is that adding a body — a heartbeat you feel, an organism you fail — turns the same elegance from contemplative into visceral. The player isn't managing a supply chain. They're keeping something alive, in vain, one more time.
