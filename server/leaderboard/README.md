# VEIN leaderboard backend

An AWS Lambda behind an API Gateway HTTP API, fronting three DynamoDB tables —
plain aws-cli provisioning (see [deploy.sh](deploy.sh)), no CDK/Terraform/SAM,
matching how the rest of this project ships infra (see `../../deploy_web.sh`).

- `vein-leaderboard-players` — one item per player: `player_id`, `name`,
  `best_score`, `best_score_at`, `total_runs`, `has_played` (false only for a
  row created by a `/name` claim that hasn't finished a run yet — see below),
  `last_rank` (this player's rank as of their own last `/score` submission,
  used to compute `rankChange` — see below).
- `vein-leaderboard-meta` — a single `totals` item: `total_players`,
  `total_plays`, both plain counters incremented atomically per submission.
- `vein-leaderboard-runs` — one item per started run: `run_id`, `player_id`,
  `started_at` (server timestamp, ms since epoch), `consumed` (bool), `ttl`
  (DynamoDB-native TTL, auto-expires stale rows), `validated_score`,
  `total_raw_count`/`total_refined_count`, `last_batch_at`. Written by
  `/run/start`, accumulated by `/run/deliver`, read and marked consumed by
  `/score` — see "Arcade-style, on purpose" below.

## Arcade-style, on purpose

There's no login and no account — a player is whatever `player_id` their
client sends (a random ID generated once and saved locally, see
`_load_save`/`_generate_player_id` in `scripts/game.gd`), under whatever name
they've claimed via `/name` (see `scripts/name_prompt.gd` and its in-game
custom keyboard). Anyone who found this URL could POST under any name that
isn't already claimed — but they can no longer fabricate a score, in two
layers:

1. `/score` requires a `run_id` minted server-side by `/run/start` at the
   moment a real run began — closes the zero-effort case, an instant fake #1
   from a single crafted POST with no run behind it at all.
2. `/score` no longer trusts the `score` it's sent, either. Real-world
   red-teaming of layer 1 alone found that "plausible for elapsed time" isn't
   the same as "earned" — `/run/start`, `sleep 2`, `score: 2000` sailed
   straight through and took #1. So the authoritative score is now
   `validated_score` on the run row, built exclusively from `/run/deliver`
   batches: the client reports every actual scoring delivery
   (`kind`/`combo`/`pot`) as it happens, and `handleRunDeliver`/`handleScore`
   recompute each one's gain themselves from the same formula game.gd uses,
   rate-limiting both the point total AND the raw/refined delivery *counts*
   against real server-clocked elapsed time.

Neither layer is proof of identity, and neither is trying to stop a
determined cheater who reads the open-source client and scripts a
properly-paced, properly-shaped bot for the full duration of the run they
want to claim — that would take genuinely unforgeable proof of play (full
server-side replay validation), disproportionate for VEIN's actual stakes
(bragging rights on a casual mobile game, not a competitive ranking with
anything real riding on it). What this closes is casual/opportunistic
abuse — the actual incidents that prompted both layers. An earlier version
required a signed Telegram session instead of any of this — see git history
if that trade ever needs revisiting.

Names are unique going forward (case-insensitive), enforced only at the
moment one is claimed or changed via `/name` — `/score` never re-checks it,
so the death-flow round trip stays exactly as cheap as before. Names that
were already duplicated in the table before this existed are grandfathered,
not retroactively fixed.

## Endpoints

### `POST /run/start` — mark the moment a real run began

Fire-and-forget, called from `scripts/game.gd`'s `start_run()` the instant a
run starts — not part of the name-claim/registration flow, carries no name,
no uniqueness semantics, nothing `/name` does. `/score` below requires the
`run_id` this returns.

Request body:
```json
{ "player_id": "<random ID, generated once and saved locally>" }
```

Response body:
```json
{ "run_id": "<32-character hex string>" }
```

### `POST /run/deliver` — report scoring deliveries as they happen

Fire-and-forget, called periodically by `scripts/game.gd`'s
`_flush_deliveries()` (every `DELIVER_FLUSH_INTERVAL` of real time) with
whatever scoring deliveries happened since the last flush — the actual proof
of play behind a submitted score, not part of the name-claim/registration
flow.

Request body:
```json
{ "player_id": "<random ID>", "run_id": "<from a prior /run/start>", "deliveries": [{ "kind": 5, "combo": 7, "pot": 1.0 }] }
```

`kind` is the resource enum int (`scripts/vnode.gd`'s `Res`: `0`=RAW,
`1`=REFINED, `2`=CLOTH, `3`=PRISM, `4`=VOID, `5`=HEXAGON), `combo` the
vein-edit rhythm combo at that delivery (clamped server-side to
`0..COMBO_CAP`), `pot` the poison potency for a `VOID` delivery (clamped to
`0..MAX_POT`, ignored otherwise). Each event's gain is recomputed
server-side from these three fields, never trusted as a number — see
`submit.js`'s `_validateDeliveries`.

Both the gain-sum and the raw/refined event *counts* (two different rate
tiers — a tool-tier delivery is far more rate-constrained in real play than
a Well's) are checked against real server-clocked elapsed time, per-batch
and cumulative since the run began. A missing/unknown/mismatched/consumed
`run_id`, a malformed `deliveries` array, or an implausible batch all reject
with `400` and write nothing.

Success (`200`):
```json
{ "ok": true }
```

### `POST /name` — claim or change a display name

Request body:
```json
{ "player_id": "<random ID, generated once and saved locally>", "name": "wanted-name" }
```

The name is cleaned server-side to lowercase letters, digits, and `_ - .`
only (matching exactly what the in-game keyboard can type) before the
uniqueness check.

Success (`200`):
```json
{ "ok": true, "name": "wanted-name" }
```

Taken (`409`), with a few guaranteed-free variations to offer instead of
making the player guess:
```json
{ "error": "name_taken", "suggestions": ["wanted-name2", "wanted-name3", "wanted-name7"] }
```

### `POST /score` — submit-and-fetch in one call

So the panel never needs a second round trip after posting.

Request body:
```json
{ "player_id": "<random ID, generated once and saved locally>", "name": "your name", "score": 1234, "beats": 5678, "run_id": "<from a prior /run/start>", "deliveries": [] }
```

`beats` is accepted but not currently stored. **`score` is advisory only and
never trusted** — the board ranks by the run's own server-derived
`validated_score` instead (built from `/run/deliver` batches, see above).
`deliveries` here is optional: whatever the client still had buffered since
its last periodic flush, validated and rate-checked exactly the same way
`/run/deliver` does, folded in atomically with marking the run consumed.

`run_id` must come from a prior `/run/start` call for this same `player_id`
and not yet used by an earlier `/score` submission. A missing, unknown,
mismatched, reused, or malformed-`deliveries` request all reject with `400`
and write nothing — see `submit.js`'s `handleScore`.

Response body:
```json
{
  "top": [{ "name": "...", "score": 1234, "at": "2026-07-25T12:00:00.000Z", "plays": 12, "rankChange": 2 }, "...up to 10"],
  "nearby": [{ "rank": 8, "name": "...", "score": 900, "at": "...", "plays": 4, "rankChange": -1 }, "...2 above, you, 2 below"],
  "you": { "rank": 3, "score": 1234, "isBest": true, "plays": 12, "rankChange": 2 },
  "totalPlayers": 512,
  "totalPlays": 2871
}
```

`plays` is that player's total run count (`total_runs`). `nearby` is only
meaningful when `you.rank` falls outside the `top` array — see
`scripts/leaderboard_panel.gd`'s ellipsis + nearby-block rendering and
`scripts/ranks_strip.gd`'s death-screen strip, both of which read it.

`rankChange` is how many places THAT ROW's player moved since their own
last `/score` submission (positive = climbed, negative = fell, `0` = no
prior run to compare against) — every row carries its own, not just `you`,
so a peer's chevron in the top 10 reflects their last run, not yours.

### `POST /rank` — read-only "where do I stand"

For the main menu (`scripts/main_menu.gd`), shown next to the locally-saved
best score. Never writes anything — a menu visit is not a run, so this must
never bump `total_runs`/`totalPlayers` the way `/score` does.

Request body:
```json
{ "player_id": "<random ID, generated once and saved locally>" }
```

Response body:
```json
{ "rank": 3, "score": 1234, "plays": 12, "rankChange": 2, "totalPlayers": 512 }
```

`rank` is `0` if this player has never posted a score.

## Deploying

Needs AWS credentials for the same account/region `deploy_web.sh` already
deploys the game to — nothing else.

```bash
./deploy.sh
```

Creates or updates, in order: the three DynamoDB tables (including TTL on
`vein-leaderboard-runs`), an IAM role scoped to just those tables, the Lambda
function, and an HTTP API with `POST /score`, `POST /name`, `POST /rank`,
`POST /run/start`, and `POST /run/deliver` routes and open CORS. Safe to
re-run; every step checks before creating. Prints the endpoint URL at the
end — paste it into `scripts/game.gd`'s
`LEADERBOARD_URL`/`NAME_URL`/`RANK_URL`/`RUN_START_URL`/`DELIVER_URL`
constants.

The score-plausibility thresholds — `MAX_SCORE_RATE`/`MAX_RUN_SECONDS`/
`MIN_RUN_SECONDS`/`SCORE_GRACE` (the backstop on `handleScore`'s derived
`validated_score`) and `RAW_DELIVERY_RATE`/`REFINED_DELIVERY_RATE`/
`DELIVERY_COUNT_GRACE`/`MAX_BATCH_WINDOW_SECONDS` (the primary gate, in
`handleRunDeliver`) — are all Lambda env vars, defaulted in `deploy.sh`'s
`ENV_VARS` line. Retune them there (or with a direct
`aws lambda update-function-configuration`) without touching `submit.js` or
redeploying code.

If deploying through the CI workflow rather than running this script
locally, the CI role's IAM policy (`ci-iam-policy.json` in this directory) is
hand-maintained documentation of what the live `vein-github-actions-deploy`
role's policy should contain — nothing in this repo applies it automatically.
After editing it, apply it once by hand (e.g.
`aws iam put-role-policy --role-name vein-github-actions-deploy --policy-name <existing-name> --policy-document file://ci-iam-policy.json`)
before merging, or the next CI-triggered deploy fails with `AccessDenied` on
whatever changed.

## Scale note

`submit.js` answers a rank by scanning the whole `players` table and sorting
in memory. VEIN.md's own scope is a single-screen, run-based mobile game,
not a leaderboard built to survive tens of thousands of concurrent
players — a scan is the simplest correct thing at the size this is likely
to ever be. If the player count ever makes that slow, the fix is a GSI on a
bucketed `best_score`, not before.
