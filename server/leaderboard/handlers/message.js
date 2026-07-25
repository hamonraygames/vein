// handlers/message.js — runs on each `message` update, which is also how a
// score arrives: VEIN calls Telegram.WebApp.sendData() from the death
// screen, which Telegram delivers here as message.web_app_data rather than
// as its own update type. There's no way for the Mini App to keep the
// canvas open and ask this bot "what's the top 10" (Serverless only reacts
// to Bot API updates, no public HTTP in), so the leaderboard is delivered
// as a chat reply instead, right after sendData() closes the Mini App.

import { api, db } from 'sdk';
import { players } from 'schema';
import { eq, gt, desc, sum, sql } from 'sdk/db';

const MAX_NAME_LEN = 24;

export default async function (message) {
  if (message.web_app_data) {
    await recordScore(message);
    return;
  }
  if (typeof message.text !== 'string') {
    return;
  }
  if (message.text.startsWith('/name')) {
    await rename(message);
    return;
  }
  if (message.text.startsWith('/leaderboard') || message.text.startsWith('/top')) {
    await replyLeaderboard(message.chat.id, message.from.id);
    return;
  }
  if (message.text.startsWith('/start')) {
    await api.sendMessage({
      chat_id: message.chat.id,
      text: 'Open VEIN, keep a heart beating. Your best run lands here automatically.'
        + ' /name sets what shows on the leaderboard, /top shows it.',
    });
  }
}

async function recordScore(message) {
  const tgId = message.from.id;
  let data;
  try {
    data = JSON.parse(message.web_app_data.data);
  } catch {
    return;
  }
  const score = Math.max(0, Math.floor(Number(data.score) || 0));
  const beats = Math.max(0, Math.floor(Number(data.beats) || 0));
  const defaultName = (message.from.username || message.from.first_name || 'Player')
    .slice(0, MAX_NAME_LEN);

  await db.insert(players)
    .values({
      tgId,
      name: defaultName,
      bestScore: score,
      bestBeats: beats,
      bestAt: new Date(),
      runs: 1,
    })
    .onConflictDoUpdate({
      target: players.tgId,
      set: {
        runs: sql`${players.runs} + 1`,
        bestScore: sql`MAX(${players.bestScore}, ${score})`,
        bestBeats: sql`CASE WHEN ${score} > ${players.bestScore} THEN ${beats} ELSE ${players.bestBeats} END`,
        bestAt: sql`CASE WHEN ${score} > ${players.bestScore} THEN unixepoch() ELSE ${players.bestAt} END`,
      },
    })
    .run();

  const row = await db.select().from(players).where(eq(players.tgId, tgId)).get();
  const isBest = row != null && row.bestScore === score && row.bestBeats === beats;
  await replyLeaderboard(message.chat.id, tgId, { justScored: score, isBest });
}

async function rename(message) {
  const newName = message.text.replace(/^\/name(@\w+)?/, '').trim().slice(0, MAX_NAME_LEN);
  if (!newName) {
    await api.sendMessage({
      chat_id: message.chat.id,
      text: `Send /name followed by what you want on the leaderboard, e.g. /name Comet (max ${MAX_NAME_LEN} chars).`,
    });
    return;
  }
  const [row] = await db.update(players).set({ name: newName })
    .where(eq(players.tgId, message.from.id)).returning().run();
  await api.sendMessage({
    chat_id: message.chat.id,
    text: row ? `Done — you'll show up as "${newName}".` : 'Play a run in VEIN first, then rename yourself.',
  });
}

async function replyLeaderboard(chatId, tgId, ctx) {
  const top = await db.select().from(players).orderBy(desc(players.bestScore)).limit(10).all();
  const totalPlayers = await db.$count(players);
  const totalsRow = await db.select({ n: sum(players.runs) }).from(players).get();
  const totalRuns = totalsRow && totalsRow.n != null ? totalsRow.n : 0;
  const me = await db.select().from(players).where(eq(players.tgId, tgId)).get();

  const lines = top.map((p, i) => {
    const when = p.bestAt ? new Date(p.bestAt).toISOString().slice(0, 16).replace('T', ' ') : '?';
    return `${i + 1}. ${p.name} — ${p.bestScore} (${when} UTC)`;
  });

  const parts = [];
  if (ctx) {
    parts.push(ctx.isBest ? `New best: ${ctx.justScored}.` : `Score: ${ctx.justScored}.`);
  }
  parts.push('VEIN — Top 10');
  parts.push(lines.length ? lines.join('\n') : 'Nobody has fed a Heart yet.');

  if (me) {
    const ahead = await db.$count(players, gt(players.bestScore, me.bestScore));
    parts.push(`You: #${ahead + 1} of ${totalPlayers}, best ${me.bestScore}.`);
  } else {
    parts.push('Play a run to get on the board.');
  }
  parts.push(`${totalPlayers} players · ${totalRuns} hearts fed so far.`);

  await api.sendMessage({ chat_id: chatId, text: parts.join('\n\n') });
}
