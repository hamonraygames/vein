# VEIN — the forever game

How VEIN stops being a game people play hard for three days and then forget.
Companion to VEIN.md, which covers what the game *is*; this covers what makes
someone open it again in six weeks.

Written against the code as it stands, not in the abstract — every proposal
below names the system it lands on.

## The diagnosis

VEIN is currently a game of **execution**, not of **decisions**.

Every run poses the same problem. The board is one shape, the demand ladder
walks the same order, and the vein budget arrives on a timer — `budget += 1`
at `game.gd:2182`, silently, identically, in every run anyone has ever played.
Nothing about a run is *chosen*. You are only ever executing the one correct
response to whatever the clock just did, faster or slower than last time.

Execution games get mastered and then abandoned, because once your hands know
the answer there is nothing left to think about. Decision games get
theorycrafted, argued about, and replayed, because the interesting part
happens before your hands move. Mini Metro is a decision game wearing an
execution game's clothes.

Four concrete gaps, in the order they cost us:

1. **No reason to open it *today*.** Nothing is time-bound. Any run is
   available at any moment, so no moment is special.
2. **No decisions outside the instant.** Budget is granted, never chosen.
   There is no build path, so no two runs diverge and there is nothing to
   theorycraft.
3. **No long-horizon goal.** `lifetime_beats` is counted and persisted
   (`game.gd:685`, `1126`) and **read by nothing**. It buys the player
   nothing, so accumulating it means nothing.
4. **No variety.** One board shape, forever. Seeds shuffle the noise, not the
   problem.

There is also an active retention leak — see "The best-score wipe" below.

## What's already built (and this is a lot)

The expensive infrastructure exists. What's missing is mostly design surface
on top of it.

| Asset | State |
|---|---|
| Deterministic sim, seeded | Built, and deliberately protected — `game.gd:8`: *"Daily, replays and offline balancing for free. Keep it that way."* |
| Server-validated scores | Built. `submit.js` derives score from delivery events and burns `run_id` against replay. |
| Backend | Built. 3 DynamoDB tables (PLAYERS/RUNS/META), 6 routes: `/score`, `/name`, `/rank`, `/run/start`, `/run/deliver`, `/recover`. |
| Stable player identity | Built — `player_id`, `player_name`, cross-device `recovery_code`. |
| Local persistence | Built — ConfigFile `run` section. |
| Leaderboard + rank UI | Built — `leaderboard_panel.gd`, `ranks_strip.gd`. |
| Daily Vein | **Not built.** No date-seed anywhere; `start_run(0)` always `randi()`. |
| Mutators | **Not built.** |
| Multiple boards | **Not built.** |

The single most important line in the codebase for this document is
`game.gd:8`. Because the sim is deterministic and someone protected that
property on purpose, **the Daily is mostly UI.** The hard half is done.

## 1. Daily Vein — the reason to open it today

*Borrowed from: Mini Metro's daily, Wordle's structure.*

One shared seed per UTC day. One attempt. A global percentile shown as a
position on a vertical vein — *"you reached deeper than 91% of players
today"* — exactly as VEIN.md already specifies.

Single-attempt dailies are the highest-retention mechanic per unit of effort
in this genre, and the reason is not novelty: it manufactures **scarcity** and
**a shared conversation**. Everyone plays the same board, so the score is
comparable in a way a free-seed score never is, and when it's gone it's gone
until tomorrow. That is what converts "I could play this" into "I haven't done
today's yet."

**How it lands on existing code**

- Seed: hash of the UTC date string. No server round trip needed to *start* —
  the client can derive it offline, which keeps the Daily playable on a
  flaky connection.
- Attempt lock: two new save keys, `daily_date` and `daily_score`. The lock is
  client-side and therefore soft; that is fine and is what Mini Metro does.
  The *leaderboard* is protected by the existing server validation, which is
  the part that actually matters.
- Backend: reuse `/run/start` + `/run/deliver` unchanged, with a `daily` flag
  so rows key under `daily#YYYY-MM-DD`. The anti-cheat problem is already
  solved and does not need revisiting.
- UI: a second button on the main menu, and a result screen showing the
  percentile vein.

**Risks.** A bad seed with one attempt is genuinely frustrating. Wordle and
Mini Metro both accept this, and the fix is not seed-vetting (which we cannot
do cheaply) but making the Daily *additional* to free play, never a
replacement.

**Effort: low.** Days, not weeks. This is the first thing to build.

## 2. The vein choice — giving the game a spine

*Borrowed from: Mini Metro's weekly asset choice.*

This is the fix for "we are not strategic like Mini Metro," and it is a
smaller change than it sounds.

Mini Metro's strategic core is one repeated decision: every week, pick one of
two upgrades. That is the entire reason two runs on the same map play
differently and the reason players argue about strategy at all. VEIN currently
grants the equivalent silently.

Replace the timed `budget += 1` with an **offer of two**, from a pool:

- **+1 vein** — the current behaviour; breadth.
- **+1 tool slot** for one tier — raises `MAX_LIVE_*` for Forge/Loom/Kiln;
  depth. (Note the measured hazard: more tools also means more rot, since
  spent tools go necrotic. That tension is a *feature* here — it makes the
  choice real rather than a strict upgrade.)
- **Reserve refill** — restore a spent Well or tool instead of re-plumbing.
- **Reach** — a longer maximum vein span, once.

Now a run has a shape: wide-and-shallow versus tall-and-fragile. Two players
with the same seed end up with different boards. That is theorycraft, and
theorycraft is what keeps a game alive in conversation between sessions.

**The hard constraint.** VEIN.md's first pillar is *"no HUD numbers, no menus
mid-run"* and *"the entire game is playable one-handed."* A modal upgrade
menu would violate the brand outright. The choice must be **diegetic**: two
ghost shapes bloom near the Heart, you take one with the same drag you already
use, the other fades. No pause, no menu, no text. If it cannot be expressed
that way it should not ship — that constraint is the reason the game looks
like it does.

**Effort: medium**, and it changes game feel substantially, so it wants both
probe runs and real playtest before it's locked.

## 3. Mutators — the long-horizon goal

*Borrowed from: roguelike meta-progression; VEIN.md already specifies these.*

VEIN.md already names them: **Twin Hearts** (feed two), **Sclerosis** (veins
harden and must be replaced), **Night** (nodes visible only when pulsing).
Unlocked at lifetime beat milestones, and they **multiply score** rather than
grant power — depth without power creep.

`lifetime_beats` is already counted and already persisted. It currently buys
nothing. Wiring unlocks to it converts a dead counter into a reason to keep
playing past today's best.

Each mutator is independent and can ship alone, which makes this a good
drip-feed of updates rather than one big release.

**Effort: medium per mutator**, low coupling.

## 4. Boards — variety

*Borrowed from: Mini Metro's cities.*

Distinct layouts that pose different topology problems, not just different
noise: a scar across the board that veins cannot cross (Mini Metro's river,
which is what makes its maps actually differ), a dense half and a sparse half,
an off-centre Heart.

Lands on `heart_spawn_pos()`, `_spawn_node` placement, and `in_reach`.

**Effort: high** — placement logic, plus per-board balancing, plus art
direction. Highest variety payoff, worst effort ratio. Last.

## The best-score wipe — fix this regardless

`game.gd:1127`:

```gdscript
if int(cfg.get_value("run", "tuning", 0)) == TUNING_VERSION:
    best = int(cfg.get_value("run", "best", 0))
```

**A player's best score is destroyed every time `TUNING_VERSION` changes.**
In this session alone it went 9 → 15, so every existing player's best has been
wiped six times over.

The intent is sound and documented — a best set on an easier curve is a wall,
not a target. But for a game meant to retain, silently deleting the player's
one long-horizon achievement every time we rebalance is corrosive, and it
directly undercuts everything above. `lifetime_beats` survives (it is read
unconditionally); `best` does not.

Options, cheapest first:

1. **Keep bests per tuning version.** Show the current-version best as the
   target, and an all-time best alongside it. Nothing is ever destroyed,
   nothing is ever unfair.
2. **Tie unlocks to `lifetime_beats` only**, never to `best`, so progression
   is immune to rebalancing by construction.
3. Keep the wipe, but *tell the player* it happened and why.

Recommendation: 1 and 2 together. This is small, and it should land before or
alongside the Daily — there is no point building retention on top of a system
that periodically deletes the player's reason to care.

## Sequencing

1. **Best-score survival** (tiny) — stop the leak first.
2. **Daily Vein** (low effort, highest retention) — the reason to return.
3. **Vein choice** (medium) — the reason it stays interesting once you do.
4. **Mutators** (medium, drip-feed) — the reason to play past your best.
5. **Boards** (high) — variety, when the rest has proven out.

Retention before depth, depth before variety. A deeper game nobody opens is
worth nothing; and adding variety to a game with no decision spine just makes
the same shallow run look different.

## What we still don't do

Unchanged from VEIN.md, and worth restating because every mechanic above is
the kind that usually arrives wearing a dark pattern: no energy, no timers
gating play, no currencies, no gacha, no nagging notifications. The Daily is
one attempt because scarcity makes the score *mean* something, not to create
an appointment the player resents. The restraint is the brand.

## Open questions

- **Which tower game?** The second reference from the original conversation is
  unidentified. If it is a wave-based tower defence, its borrowable idea is a
  **prep/defend rhythm** — discrete build phases between escalations, which
  would convert VEIN's demand flips from something you react to into something
  you plan for. That is potentially bigger than anything in section 2 and is
  worth pinning down before committing to the sequence above.
- **Is one Daily attempt right for a 3–6 minute run?** Wordle's single attempt
  works partly because a game is short. A lost Daily 20 seconds in feels very
  different from a lost one at beat 400.
- **Does the vein choice survive the no-menus pillar in practice?** The
  diegetic version is described above but has not been prototyped. If it
  cannot be made readable without text, the whole idea needs rethinking rather
  than compromising the pillar.
