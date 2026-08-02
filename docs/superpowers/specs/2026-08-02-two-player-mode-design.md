# Two-Player Mode (Pass-and-Play) — Design

**Date:** 2026-08-02
**Status:** Approved by owner (pending spec review)
**Scope:** Local pass-and-play on one phone. Architecture leaves a seam for online play later; online itself is out of scope.

## Summary

Add a hot-seat two-player mode to Chronology. Players alternate placing cards on one shared timeline. Each player has 3 lives, their own score, and their own streak/multiplier. Sudden death: the first player to lose all 3 lives loses immediately; the survivor wins. Scores are shown for bragging rights and rematch motivation.

## Decisions (locked)

| Decision | Choice |
|---|---|
| Mode | Pass-and-play, one device; designed online-ready |
| End condition | Sudden death — first to 0 lives loses, other player wins instantly |
| Timeline / deck | Shared; timeline grows across both players' turns |
| Streak / multiplier | Per player, identical rules to solo |
| Turn hand-over | Instant switch with a turn banner; no privacy screen (no hidden info) |
| Player identity | Optional names, defaults "Player 1" / "Player 2" |
| Persistence | 2P runs are NOT recorded to Supabase (sessions/mistakes/category stats). Collection unlocks still apply on the device. |
| Start screen entry | "2 Players" button placed BELOW the Start Game button, stacked, same styling family |

## Architecture — Turn-Manager Layer

The engine keeps its existing globals (`lives`, `score`, `streak`, `maxStreak`, `deck`, `timeline`, `currentCard` — index.html ~line 4073) as **the active player's working state**. Solo mode is untouched: one player, no turn flips, no behavior change.

New module-level state (same script, near existing globals):

```js
let gameMode = 'solo';            // 'solo' | 'local2p'
let players  = [];                // [{name, lives, score, streak, maxStreak}]
let activeIdx = 0;
```

TurnManager responsibilities (plain functions, no framework):

- `initTwoPlayer(names)` — build `players`, set `gameMode`, load player 0 into globals, then run the existing `startGame()` flow.
- `syncActive()` — copy globals back into `players[activeIdx]`. Called once, at the single point where a placement fully resolves (after the correct/wrong animation completes, same place the solo code currently decides whether to draw the next card).
- `endTurn()` — after `syncActive()`: if `players[activeIdx].lives === 0` → `endTwoPlayerGame(winnerIdx = 1 - activeIdx)`. Otherwise flip `activeIdx`, load the new active player's state into the globals, update the HUD, show the turn banner, then let the existing `nextCard()` run.

Online seam: `endTurn()` is the only place that decides "whose move is next." A future online mode replaces the local flip with "wait for remote move" and serializes `players` + `timeline`; nothing in the engine changes.

## UI

1. **Start screen** — "2 Players" button directly below "Start Game" (stacked, secondary styling). Tapping it shows a small modal (reusing the existing modal pattern) with two name inputs, both optional with placeholder defaults, and a "Start" button.
2. **In-game HUD (2P only)** — the header's solo Streak/Score cluster is replaced by two compact player chips: `name · mini-hearts · score`. The active player's chip is highlighted with the accent color/border. The existing multiplier badge attaches to the active chip. Solo HUD is unchanged.
3. **Turn banner** — on every turn flip, a slide-in banner ("Priya's turn") using the existing quip-banner pattern and timing. Suppressed for the very first turn (the highlighted chip is enough) to keep the game start snappy.
4. **Game over (2P)** — winner headline ("Priya wins!"), both players' final score and best streak side by side, then: Rematch (same names, fresh shuffled deck, loser goes first) and Back to Start. The solo game-over screen (share/challenge, collection CTA) is not shown for 2P in v1.

## Error handling / edge cases

- Quit mid-game: existing quit confirmation applies; 2P state is discarded (same as solo).
- Deck exhaustion before anyone dies (both players survive all 349 cards): winner = higher score; tie = shared victory screen. Extremely unlikely but must not crash.
- Refresh mid-game: 2P state is in-memory only, same as solo runs today — the run is lost. Acceptable for v1.
- Back-button guard: existing popstate guard applies unchanged.

## Testing

- Solo regression first: full solo run (start → place correct/wrong → game over → play again) must behave identically — this is the highest-priority check.
- 2P happy path: alternation, per-player lives/score/streak isolation, sudden death ends the game the moment a player hits 0 lives (winner is the other player regardless of scores).
- Edge: wrong placement on player's last life during their turn; rematch resets both players and reshuffles; deck-exhaustion tie path renders.
- Mobile viewport (375px): dual-chip HUD fits without wrapping; turn banner doesn't overlap the card stage.

## Out of scope (explicitly)

- Online multiplayer, rooms, invite links (future; the TurnManager is the seam).
- Recording 2P results to Supabase.
- More than 2 players.
- Per-player collection ownership.
