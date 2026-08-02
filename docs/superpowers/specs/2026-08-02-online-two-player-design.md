# Online Two-Player Mode (Stage 1: Friend Rooms) — Design

**Date:** 2026-08-02
**Status:** Draft (pending owner review)
**Depends on:** Two-player pass-and-play mode (shipped), anonymous sign-ins enabled on Supabase project.

## Summary

Friend-link online play: one player creates a room and shares a 6-character code (or link); the other joins from the existing "Play Online" panel on the 2 Player Mode chooser. Same rules as pass-and-play: alternating turns on one shared timeline, 3 lives each, sudden death. All game authority lives on the server; clients render and animate.

## Locked decisions

| Decision | Choice |
|---|---|
| Matchmaking | Room codes / invite links only. No random matchmaking in Stage 1. |
| Shuffle | True random (server-generated Fisher-Yates), stored in the match row. No history weighting. |
| Turn timer | 30 seconds per placement. Expiry = lose a life, card revealed and discarded, turn passes. |
| Abandonment | 60 seconds without a move/heartbeat → opponent may claim victory; abandoner recorded as loser. |
| Authority | Server-validated moves via RPC (same philosophy as existing `submit_session` replay validation). Clients never report outcomes. |
| Auth | Anonymous Supabase sign-in (must be enabled in dashboard — currently 422s). |
| Persistence | Full match state in DB; refresh/reopen restores an active match. |

## Schema

New table `matches` (RLS on):

```
id           uuid pk default gen_random_uuid()
code         text unique          -- 6-char A-Z0-9, generated server-side
host_id      uuid not null        -- auth.uid of creator
guest_id     uuid                 -- null until joined
players      jsonb not null       -- {"0":{name,lives,score,streak,maxStreak},"1":{...}}
deck         int[] not null       -- card ids in play order (server shuffle)
deck_pos     int default 0        -- next card index
timeline     jsonb not null       -- [{card_id, wrong}] in placement order
turn         int default 0        -- 0 = host, 1 = guest
turn_started timestamptz          -- for 30s enforcement
last_seen_0  timestamptz          -- heartbeats for abandonment
last_seen_1  timestamptz
status       text default 'waiting'  -- waiting|active|finished|abandoned
winner       int                  -- 0|1|null(tie)
end_reason   text                 -- lives|timeout_claim|deck_tie|resign
created_at   timestamptz default now()
```

RLS: `select` only where `auth.uid() in (host_id, guest_id)`. All writes go through security-definer RPCs; no direct `insert/update/delete` for clients. Room-code lookup for joining happens inside `join_match`, so codes are not enumerable via select.

## RPCs (security definer)

- `create_match(p_name)` → `{match_id, code}` — validates auth, generates code + shuffled deck (from the server-side cards table already used by replay validation), seeds timeline with card 1, status `waiting`.
- `join_match(p_code, p_name)` → match row — first joiner wins the guest slot (row lock), status → `active`, `turn_started = now()`.
- `submit_move(p_match_id, p_drop_index)` → updated match — checks: caller is a player, status active, caller's turn, within 30s + 5s network grace (late = treated as timeout expiry, not the submitted move). Validates placement against server card years, updates score/streak/lives/timeline/deck_pos, flips turn, resets `turn_started`. Ends match on 0 lives (sudden death) or deck exhaustion (score compare, tie allowed).
- `expire_turn(p_match_id)` → updated match — either player may call when `now() - turn_started > 30s`: active player loses a life, current card revealed+discarded (recorded in timeline as `{card_id, wrong:true, expired:true}`), turn flips. Idempotent (checks turn_started unchanged).
- `claim_timeout(p_match_id)` → finished match — callable when opponent's `last_seen_*` is > 60s old; status → `abandoned`, caller wins, `end_reason = timeout_claim`.
- `heartbeat(p_match_id)` — updates caller's `last_seen_*`; called every ~15s and on visibility change.
- `resign_match(p_match_id)` — quit button online: opponent wins, `end_reason = resign`.

Server-side timer enforcement means a cheater cannot pause their clock by suspending their client; the timestamps decide.

## Realtime sync

Each client subscribes to `postgres_changes` on its `matches` row. Every RPC write triggers one push. On receiving a change where the last move was the opponent's, the client replays it as an animation (card slides to its slot, correct/wrong flash) before unlocking the local turn. Realtime is transport only — a missed event self-heals because the client re-fetches the row on reconnect/visibility change.

## Client flow (states)

1. **Create room** — "Play Online" panel gains a "Create Room" button beside the join field. Shows code large + share button (reuses Challenge a Friend link with `?room=CODE`); URL param auto-fills the join field on the friend's device.
2. **Waiting** — host sees "Waiting for a friend… CODE". Cancel deletes the match.
3. **Playing** — existing 2P game screen. TurnManager's `endTurnAndNext()` is replaced in online mode by: submit move → wait for Realtime push → replay opponent move → unlock. A countdown ring (30s) shows on the active player's chip; at 0 the client calls `expire_turn`.
4. **Opponent's turn** — board locked (drag disabled), subtle "Arjun is thinking…" state, opponent moves replay as animations.
5. **Interrupted** — on refresh/reopen: if an `active` match exists for my uid, prompt "Resume your online game". On opponent silence > 60s: "Arjun seems to have left — claim victory?" button (calls `claim_timeout`).
6. **End** — existing 2P end bar, plus reason line for timeout/resign endings. Rematch creates a fresh match with the same pair (new code auto-joined via a `rematch_of` handshake — loser hosts).

## Edge handling

- Double-submit / stale client: server rejects out-of-turn moves; client re-syncs from row.
- Both clients calling `expire_turn`: idempotency check on `turn_started`.
- Card data version: match row stores `data_version`; client refuses to join/resume on mismatch and prompts reload.
- Backgrounded phone: heartbeat stops → after 60s opponent may claim; on return the player sees the loss (fair per abandonment rule).
- Local pass-and-play is completely untouched by this stage; the 30s timer is online-only (owner may extend to local later).

## Out of scope (Stage 1)

Random matchmaking, spectators, chat, push notifications for async play, ELO/leaderboards, >2 players, timer in local mode.

## Testing

- Two browser contexts (Playwright) playing a full match: create/join, alternation, server rejection of out-of-turn moves, timer expiry path, claim-timeout path, resign, rematch, resume-after-refresh.
- RLS probe: third client cannot select or mutate a match it isn't in; join with wrong code fails.
- Solo + local 2P regression after client changes.
