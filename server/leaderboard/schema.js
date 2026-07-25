import { table, integer, text, index, sql } from 'sdk/db';

// One row per Telegram player. bestScore/bestBeats/bestAt track their single
// best run (score is what's shown — see game.gd's score vs beats distinction
// in VEIN itself); runs is every death, best or not, which is what "total
// times VEIN has been played" sums across every player.
export const players = table('players', {
  tgId:      integer('tg_id').primaryKey(),
  name:      text('name').notNull(),
  bestScore: integer('best_score').notNull().default(0),
  bestBeats: integer('best_beats').notNull().default(0),
  bestAt:    integer('best_at', { mode: 'timestamp' }),
  runs:      integer('runs').notNull().default(0),
  createdAt: integer('created_at', { mode: 'timestamp' }).default(sql`(unixepoch())`),
}, (t) => ({
  scoreIdx: index('idx_players_score').on(t.bestScore),
}));
