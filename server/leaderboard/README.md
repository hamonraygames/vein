# VEIN leaderboard backend

An AWS Lambda behind an API Gateway HTTP API, fronting two DynamoDB tables —
plain aws-cli provisioning (see [deploy.sh](deploy.sh)), no CDK/Terraform/SAM,
matching how the rest of this project ships infra (see `../../deploy_web.sh`).

- `vein-leaderboard-players` — one item per player: `player_id`, `name`,
  `best_score`, `best_score_at`, `total_runs`.
- `vein-leaderboard-meta` — a single `totals` item: `total_players`,
  `total_plays`, both plain counters incremented atomically per submission.

## Arcade-style, on purpose

There's no login and no proof of identity — a player is whatever
`player_id` their client sends (a random ID generated once and saved
locally, see `_load_save`/`_generate_player_id` in `scripts/game.gd`),
under whatever name they typed once (see `scripts/leaderboard_panel.gd`'s
name prompt). Anyone who found this URL could POST an arbitrary score under
an arbitrary name — that's the accepted trade for a leaderboard that works
everywhere (Telegram, a plain browser tab, a local build) with no sign-in
step. `submit.js` still bounds score/name/ID to sane sizes so the data
stays tidy, but it's not trying to stop a determined cheater; VEIN is a
casual mobile game, not a competitive ranking with anything real riding on
it. An earlier version required a signed Telegram session instead — see git
history if that trade ever needs revisiting.

## Endpoint

`POST /score` — submit-and-fetch in one call, so the panel never needs a
second round trip after posting.

Request body:
```json
{ "player_id": "<random ID, generated once and saved locally>", "name": "your name", "score": 1234, "beats": 5678 }
```

`beats` is accepted but not currently stored; the board ranks by `score`,
same number the death screen shows.

Response body:
```json
{
  "top": [{ "name": "...", "score": 1234, "at": "2026-07-25T12:00:00.000Z" }, "...up to 10"],
  "you": { "rank": 3, "score": 1234, "isBest": true },
  "totalPlayers": 512,
  "totalPlays": 2871
}
```

## Deploying

Needs AWS credentials for the same account/region `deploy_web.sh` already
deploys the game to — nothing else.

```bash
./deploy.sh
```

Creates or updates, in order: the two DynamoDB tables, an IAM role scoped to
just those tables, the Lambda function, and an HTTP API with a `POST /score`
route and open CORS. Safe to re-run; every step checks before creating.
Prints the endpoint URL at the end — paste it into `scripts/game.gd`'s
`LEADERBOARD_URL` constant.

## Scale note

`submit.js` answers a rank by scanning the whole `players` table and sorting
in memory. VEIN.md's own scope is a single-screen, run-based mobile game,
not a leaderboard built to survive tens of thousands of concurrent
players — a scan is the simplest correct thing at the size this is likely
to ever be. If the player count ever makes that slow, the fix is a GSI on a
bucketed `best_score`, not before.
