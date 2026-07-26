# VEIN leaderboard backend

An AWS Lambda behind an API Gateway HTTP API, fronting two DynamoDB tables —
plain aws-cli provisioning (see [deploy.sh](deploy.sh)), no CDK/Terraform/SAM,
matching how the rest of this project ships infra (see `../../deploy_web.sh`).

- `vein-leaderboard-players` — one item per Telegram user: `player_id`,
  `name`, `best_score`, `best_score_at`, `total_runs`.
- `vein-leaderboard-meta` — a single `totals` item: `total_players`,
  `total_plays`, both plain counters incremented atomically per submission.

## Why this replaced the Telegram Serverless bot

The first pass ran on [Telegram Serverless](https://core.telegram.org/bots/serverless)
and worked by chat reply: "Post to leaderboard" called
`Telegram.WebApp.sendData()`, which sends the score and **closes the Mini
App** in the same call, and a bot handler replied with the board back into
the chat. That was a workaround for a real constraint — Serverless only
reacts to Bot API updates, there's no public HTTP endpoint the Mini App's
own canvas could call while still open — but the actual ask was an in-game
panel, not a chat message. This backend exists so the death screen can call
a real endpoint and render the result itself without closing the app (see
`_on_share_score` in `scripts/game.gd`).

## Endpoint

`POST /score` — submit-and-fetch in one call, so the panel never needs a
second round trip after posting.

Request body:
```json
{ "initData": "<Telegram.WebApp.initData, verbatim>", "score": 1234, "beats": 5678 }
```

`initData` is verified server-side against the bot token (see
[lib/verify_telegram.js](lib/verify_telegram.js)) — without that check,
anyone who found the URL could POST an arbitrary score for an arbitrary
player. `beats` is accepted but not currently stored; the board ranks by
`score`, same number the death screen shows.

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

Needs `TELEGRAM_BOT_TOKEN` in the repo root's `.env` (gitignored — same
token the bot already uses for its API calls) and AWS credentials for the
same account/region `deploy_web.sh` already deploys the game to.

```bash
./deploy.sh
```

Creates or updates, in order: the two DynamoDB tables, an IAM role scoped to
just those tables, the Lambda function, and an HTTP API with a `POST /score`
route and CORS open to any origin (there's no cookie-based auth to protect —
`initData` verification is what actually gates writes). Safe to re-run;
every step checks before creating. Prints the endpoint URL at the end —
paste it into `scripts/game.gd`'s `LEADERBOARD_URL` constant.

## Scale note

`submit.js` answers a rank by scanning the whole `players` table and sorting
in memory. VEIN.md's own scope is a single-screen, run-based mobile game,
not a leaderboard built to survive tens of thousands of concurrent
players — a scan is the simplest correct thing at the size this is likely
to ever be. If the player count ever makes that slow, the fix is a GSI on a
bucketed `best_score`, not before.
