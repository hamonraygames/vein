# VEIN leaderboard bot

Runs on [Telegram Serverless](https://core.telegram.org/bots/serverless) — no
server of our own, the code and the SQLite database both live on Telegram's
infrastructure. See [schema.js](schema.js) (one `players` table: best score,
when it was set, total runs) and [handlers/message.js](handlers/message.js)
(receives a score, replies with the top 10 + your rank + totals).

## Why a chat reply, not an in-game panel

Serverless only reacts to Bot API updates — there's no public HTTP endpoint
the Mini App's own canvas can call while it's still open. The death screen's
"Post to leaderboard" button calls `Telegram.WebApp.sendData()`, which sends
the score and **closes the Mini App** in the same call (see
`_on_share_score` in `scripts/game.gd`); the bot receives that as a
`message.web_app_data` update and posts the leaderboard back into the chat.
That's a hard platform constraint, not a choice — see the conversation that
built this for the alternatives that were considered.

## Going live (not done yet — needs your BotFather access)

This was scaffolded and written against the public SDK docs, but never
pushed to a real bot — that needs a credential only you can generate:

1. In **@BotFather**: your bot → **Serverless** → turn it on → **CLI Access**
   → grab the **access token** (`app<id>:<secret>` — separate from the
   bot's API token already in `.env`).
2. `cd server/leaderboard && npx tgcloud login` — paste that token.
3. `npx tgcloud push` — deploys `schema.js`, `handlers/message.js`.
4. `npx tgcloud migrate` — creates the `players` table (interactive; review
   before confirming).
5. Sanity-check without a real Telegram round trip:
   `npx tgcloud run handlers/message '{ chat: { id: 1 }, from: { id: 1, first_name: "Test" }, web_app_data: { data: "{\"score\":42,\"beats\":100}" } }'`

Commands to know afterward: `npx tgcloud status` (local vs. deployed),
`npx tgcloud pull` (bring local in line with the cloud), `npx tgcloud webhook`
(check the bot's webhook matches the deployed handlers).

## Player-facing commands

- Death screen → **Post to leaderboard**: submits the run, closes the Mini
  App, bot replies with the board.
- `/top` or `/leaderboard` in the chat: same reply, on demand.
- `/name <text>`: sets the display name (defaults to your Telegram username
  or first name on first submission).
