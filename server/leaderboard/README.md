# VEIN leaderboard backend

An AWS Lambda behind an API Gateway HTTP API, fronting two DynamoDB tables —
plain aws-cli provisioning (see [deploy.sh](deploy.sh)), no CDK/Terraform/SAM,
matching how the rest of this project ships infra (see `../../deploy_web.sh`).

- `vein-leaderboard-players` — one item per player: `player_id`, `name`,
  `best_score`, `best_score_at`, `total_runs`, `has_played` (false only for a
  row created by a `/name` claim that hasn't finished a run yet — see below),
  `last_rank` (this player's rank as of their own last `/score` submission,
  used to compute `rankChange` — see below).
- `vein-leaderboard-meta` — a single `totals` item: `total_players`,
  `total_plays`, both plain counters incremented atomically per submission.

## Arcade-style, on purpose

There's no login and no proof of identity — a player is whatever
`player_id` their client sends (a random ID generated once and saved
locally, see `_load_save`/`_generate_player_id` in `scripts/game.gd`),
under whatever name they've claimed via `/name` (see `scripts/name_prompt.gd`
and its in-game custom keyboard). Anyone who found this URL could POST an
arbitrary score under any name that isn't already claimed — that's the
accepted trade for a leaderboard that works everywhere (Telegram, a plain
browser tab, a local build) with no sign-in step. `submit.js` still bounds
score/name/ID to sane sizes and enforces one name per player, but it's not
trying to stop a determined cheater; VEIN is a casual mobile game, not a
competitive ranking with anything real riding on it. An earlier version
required a signed Telegram session instead — see git history if that trade
ever needs revisiting.

Names are unique going forward (case-insensitive), enforced only at the
moment one is claimed or changed via `/name` — `/score` never re-checks it,
so the death-flow round trip stays exactly as cheap as before. Names that
were already duplicated in the table before this existed are grandfathered,
not retroactively fixed.

## Endpoints

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
{ "player_id": "<random ID, generated once and saved locally>", "name": "your name", "score": 1234, "beats": 5678 }
```

`beats` is accepted but not currently stored; the board ranks by `score`,
same number the death screen shows.

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

Creates or updates, in order: the two DynamoDB tables, an IAM role scoped to
just those tables, the Lambda function, and an HTTP API with `POST /score`,
`POST /name`, and `POST /rank` routes and open CORS. Safe to re-run; every
step checks before creating. Prints the endpoint URL at the end — paste it
into `scripts/game.gd`'s `LEADERBOARD_URL`/`NAME_URL`/`RANK_URL` constants.

## Scale note

`submit.js` answers a rank by scanning the whole `players` table and sorting
in memory. VEIN.md's own scope is a single-screen, run-based mobile game,
not a leaderboard built to survive tens of thousands of concurrent
players — a scan is the simplest correct thing at the size this is likely
to ever be. If the player count ever makes that slow, the fix is a GSI on a
bucketed `best_score`, not before.
