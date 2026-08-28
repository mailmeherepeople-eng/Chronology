# Decisions

Why things are the way they are. Each entry records the decision, what forced
it, and what it costs, so a future change does not quietly undo the reasoning.

Newest first.

---

## 2026-08-28

### Start screen v2: the button ladder and the category strip

**Decision.** The start screen is rebuilt around one hierarchy: Settings gear and Quit pill in the top corners, title block with the full description, a three-card fan (Indus Valley, Taj Mahal, ChatGPT, real cards, category art), a "Play a category" strip, then the button ladder: Start Game as a green hero with a "solo run, 3 lives" sublabel, 2 Player Mode in the same green, How to Play and Museum/Stats in the full gold. Green means "play", gold means "info", red exists only on Quit. No light shades; hierarchy is carried by the hero's size and sublabel alone (iterated through five shade mockups before landing here).

**Category Run.** A solo run drawn from one OR MORE categories (user call 2026-08-28: tapping a tile must never start a game instantly). Every strip tile opens the picker modal with that category pre-checked; tiles toggle with a check badge and a Play button starts the combined run ("Play (2 categories)" when several are checked, disabled at zero). `_categoryRun` holds the selected category names as an array and filters the pool in `startGame` (guarded: a combined pool under 8 cards falls back to a full run), the meta-card injection is skipped during category runs, and everything else rides the normal solo pipeline: museum unlocks, stats, sessions. `startSolo()` clears the filter; the end-bar Play Again now calls `playAgain()`, which keeps it, so replaying a category run replays the same selection.

**The start button grew a label span.** `_setStartBtnState` used to write `btn.textContent`, which would have wiped the hero's sublabel. All three writers (state sync, retry, boot IIFE) now go through `_setStartLabel(text, showSub)`, which targets `#btn-start-label` and hides the sublabel for non-idle states like "Loading..." and the retry message.

**The picker is the Vault (2026-08-28, same day).** The modal wears the Rare Finds premium treatment (dark-gold vault, hairline frame, gold title with flanking rules, the 7s gold sheen on the existing `rareSheen` keyframes, reduced-motion respected) and selection is the "lit exhibit": no check badges (user: tacky); once anything is selected the unpicked tiles fall into shadow and picked tiles get a bright gold ring plus a warm top-light. Inherently dark, so light and dark themes share one look; the dark-mode `body.dark .modal-box` override is out-specified deliberately. The sheen layer forces `overflow:hidden` on the box (its host must clip, as in #stats-rare), so the GRID is the scroll container on short screens.

**category_runs analytics (live DB, same day).** New table `category_runs(player_id FK, event open|play, cats text[], created_at)`: one row per picker open (cats = the preselected tile) and per run started (cats = the selection). Insert+select-own only for authenticated, all other grants stripped, cats CHECK-bounded to the nine real names, cap 9. Two lessons paid for: (1) **`players.id` is NOT `auth.uid()`** in this schema; RLS policies must use the `current_player_id()` helper like every other player table, an `auth.uid()` policy silently 403s every legitimate insert. (2) **`_sbRun` logged "synced" on rejected writes** because supabase-js resolves with `{error}` instead of rejecting; it now inspects the result. Verified from the client: own rows insert and read back, UPDATE/DELETE/forged-player inserts all 403 and the data is confirmed unchanged afterwards (asserting on data, not status, per the 204 rule).

**The notification dot trap.** `.col-notif-dot` is `position:absolute` top-right, designed for the old chip which was `position:relative`. The new gold Museum button was not, so the dot escaped to the screen edge and dragged a horizontal scrollbar with it. Fix: `#btn-collection { position:relative; }`. When moving a badge, move its anchor.

**Removed from the screen**: the "Can you unlock all 398 cards?" line, the "398 events / 9 categories / 3 lives" note (the sublabel and description carry both), and the old chip row. All ids the JS reaches for (btn-start, btn-resume-online, btn-collection, col-notif-dot, btn-quit-app, btn-2p, btn-howto, btn-stats) survive in the new markup.

---

## 2026-08-13

### Background music streams through `<audio>`, it does not join the SFX buffer system

**Decision.** Two `<audio loop>` elements (`calm`, `game`) in a self-contained BACKGROUND MUSIC block, crossfaded by a timer. The `AudioContext` + `decodeAudioData` path above it is untouched and still owns every SFX.

**Why.** `initAudio()` decodes each sound into a `AudioBuffer`, which holds raw PCM: fine for a 45 KB blip, ruinous for a two-minute bed. Stereo 44.1 kHz float32 is ~21 MB per decoded minute, so two music tracks through that path would cost ~80 MB of RAM on phones the game is meant to run on. Streaming costs a timer-driven fade instead of a scheduled `GainNode` ramp, which is the right trade.

**Cost.** `HTMLMediaElement.volume` is read-only on iOS Safari, so the bed there cuts instead of fading. Cosmetic, and the toggles and pause/resume still work. If iOS ever matters, route the elements through `createMediaElementSource` into the existing `AudioContext` and fade a `GainNode`.

### The screen → track map hangs off `_showScreenInternal`, not off the callers

**Decision.** One `setMusicFor(id)` call near the top of `_showScreenInternal`, wrapped in `try/catch`. Everything is `calm` except `game`; `gameover` is special-cased.

**Why there.** It is the single choke point every navigation already funnels through, including the hardware-back path, which bypasses `showScreen()` entirely. Hooking the call sites instead would have missed back-button navigation and every future screen. It sits *before* the per-screen branches so a throw in `runGoPlateAnimations()` cannot leave the game bed playing over the score plate, and the `try/catch` makes the converse impossible too.

**Why `gameover` is special.** The end-of-run specials (`new_high`, `near_miss`, `zero`, `suspicious`) are the emotional payload of the screen and they lose to a music bed underneath them. The game track is cut on entry and `calm` fades back in 1.3 s later. Re-entering `game` (Play Again) clears that timer first, so a fast retap never gets a stray calm start.

### Music has its own volume and toggle rather than riding the existing slider

**Decision.** New `chronology-music-vol` (default 35) and `chronology-music-on` (default true), surfaced in both the settings screen and the in-game modal. Master Mute still silences everything.

**Why.** Wanting the answer sounds but not the bed is the single most common reaction to background music in a game, and one shared slider makes that impossible. Default 35 against the SFX default of 70 keeps the bed under the sounds that carry information.

**Cost.** The in-game settings modal gained a fourth section, so `#settings-modal .modal-box` is now capped at `92vh` with `overflow-y: auto`. Nothing locks orientation, and at 812x375 the modal was already taller than the viewport before music existed — this fixes that case rather than creating it. The cap is scoped to that one modal so no other modal's `::before` inset border can start scrolling with content.

**Missing files are a supported state.** A 404 or an undecodable track is marked dead on first failure and never retried, so the game behaves exactly as it did before until `sounds/music/calm.mp3` and `game.mp3` exist. Autoplay is allowed in the Capacitor shell (`Bridge.java` clears the gesture requirement) but blocked on the web build, where a rejected `play()` with `NotAllowedError` arms a one-shot listener and starts on the first tap.

---

## 2026-08-11 / 2026-08-12

### Hide the feedback banner in solo instead of removing it

**Decision.** `#quip-banner` is hidden in solo play via `body.mode-solo .quip-banner { display: none; }`. The element, its CSS and every function that writes to it stay exactly as they were.

**Why not just delete it.** The name is misleading. `#quip-banner` is the game's only in-play status strip, and quips are the least important thing it renders:

| Consumer | Mode | What it shows |
|---|---|---|
| `showQuip()` | solo only | flavor text after an answer |
| `showTurnBanner()` | local2p + online | whose turn it is, per-player color, lives |
| `showTimeUp()` | local2p + online | "Time's up, X loses a life" |
| `clearQuip()` | all | resets to idle |

`clearQuip()`, `showTurnBanner()` and `showTimeUp()` all call `getElementById('quip-banner')` and immediately assign `.className` with no null guard. Deleting the element makes `clearQuip()` throw inside `startGame()` one line before `showScreen('game')`, so **no mode would start at all**. Doing it properly means touching ~20 call sites, several of which sit between a state mutation and its commit: one aborts before `_onlineSubmitMove()` so the move never reaches the server, another runs after `confirmQuit()` has already resigned the match server-side.

Solo is safe to hide because `showTurnBanner` and `showTimeUp` are provably unreachable there: the turn timer is gated to local2p, and `_onApplyRemote` returns unless the mode is online. Solo has no timer at all.

**Cost.** Solo loses the quip text. The reclaimed 55px becomes blank space *below* the timeline rather than bigger cards, because `.timeline-track` is `align-items: flex-start`. If a larger playfield is wanted, that needs a separate change to `--tl-card-h` / `--tl-card-w` or centering the track.

**Companion fix that is not optional.** `.tut-pill` is `position: fixed` with the banner's 55px baked into its `top` constant (`118px` = 52 header + 55 banner + 11 gap), and JS never positions it. Without moving it to `63px` the tutorial instruction pill sits 55px too low and covers the card's top third, including the year, during the phase that says "look at the year of the card below". `.tut-tap-overlay` shares the slot and moves `112px` to `57px`. Both are solo-only by construction (the tutorial only launches under `gameMode === 'solo'`), so they change unconditionally with no 2P risk.

**A new `body.mode-solo` class rather than reusing `.game-header.two-player`.** The header flag is accurate today and a sibling selector would need zero JS, but it is semantically a *header layout* flag: the finished-online-match branch in `startOnlineGame` never sets it. Reusing it would leave a trip-wire for whoever fixes that branch later.

### Keep the quip arrays and `showQuip()` even though they are now vestigial

**Decision.** `CORRECT_QUIPS`, `WRONG_QUIPS` and `showQuip()` stay, writing into a hidden element.

**Why.** Removing them requires removing their call sites too, because the arrays are evaluated as *arguments* before the call, so `showQuip`'s `gameMode !== 'solo'` early return does not protect anything. One of those call sites is on the online path, inside `_onApplyRemote`, between a timeline mutation and the turn flip. A leftover reference throws `ReferenceError` mid-match, freezing the game with the card placed and the turn never advancing, and the primary invocation is an unhandled realtime callback so it fails silently. A couple of KB of dead strings is a far better trade than a new failure mode in the one server-authoritative mode.

### Filter in-app browser noise out of Sentry, scoped by platform

**Decision.** `ignoreErrors` and `denyUrls` added to `Sentry.init`. `'Java object is gone'` is applied **on web only**, via `window.Capacitor`.

**Why the scoping.** Instagram and similar in-app browsers inject `iabjs://` / `fbjs://` scripts that throw against our release when someone opens the Pages link inside the app. But `'Java object is gone'` is the Android WebView error for a collected `@JavascriptInterface` object, and that is exactly what Capacitor's `androidBridge` is. Sentry matches `ignoreErrors` by substring, so an unscoped entry would have swallowed real bridge crashes in the shipped app the moment the Android assets were synced. In an in-app browser it is their bridge dying (noise); in our shell it is ours (a real crash).

**Cost.** None on web. Android keeps full crash visibility.

### Own the attribution instead of reading it off the crash dashboard

**Decision.** New `public.visits` table (`visited_at`, `referrer_host`, `source`), written fire-and-forget on boot. Settles the open question of whether to leave the in-app-browser noise unfiltered as a proxy for link clicks: filter the noise, measure traffic properly.

**Design constraints, each deliberate:**

- **Host only, never the full URL.** Cross-origin referrers are origin-only by default anyway, so a path adds nothing while risking capture of the referring site's query string.
- **A `source` column from `?utm_source=` / `?s=`.** This is the part that works. In-app browsers routinely strip the referrer, which is precisely the traffic worth measuring. Posts should use tagged links or the column records mostly nulls.
- **No player id, no auth uid.** Rows are anonymous and unlinkable, so nothing enters the deletion flow and no deletion request needs to reach them.
- **Web only, via `IS_NATIVE_APP`.** A `capacitor://` origin has no referrer, and staying inert on Android keeps the submitted Play Data Safety declaration accurate. Enabling it app-wide would mean amending that form mid closed-test.
- **The session guard is released on failure.** It is set before the write so a reload cannot double count, but a failed insert clears it so the next load retries. Otherwise one failure would silently lose that visit for the whole session, and since the table is unreadable with the anon key, "nobody came" and "the write is broken" would look identical.

**Known gap.** On Android Chrome an app-originated visit gives `document.referrer = android-app://com.linkedin.android`, so `referrer_host` records **app packages**. This is confirmed happening on real traffic. `privacy.html` still claims "No tracking across other apps or websites" and needs updating.

### Retire `claim_legacy_player()`

**Decision.** `EXECUTE` revoked from all public roles, and `anon_id` cleared on the remaining claimable rows. The client call was deleted from boot.

**Why.** It re-parented any player row matching an `anon_id` where `auth_uid IS NULL`, guarded only by "be authenticated" (anonymous sign-in is free and unlimited) and "don't already have a player row" (true of any fresh identity). That made `anon_id` a bearer credential with no expiry and no rate limit: anyone who learned one could take over that account and read its entire history, since every `player_*` policy keys off `current_player_id()`. Proven exploitable against a decoy row.

**Cost.** Two dormant installs lose auto-recovery of old history. Any still-live install would already have auto-claimed on its next visit, so the practical loss is near zero. The one-time migration finished 2026-08-03.

### Strip the default table grants on new tables, not just RLS

**Decision.** `visits` grants only `INSERT` to `anon` / `authenticated`. `SELECT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`, `TRIGGER` are revoked.

**Why.** Supabase grants public roles full table privileges by default, so **only RLS** stood between the anon key shipped in our HTML and the whole log. Toggling RLS off in the dashboard would have made it world-readable.

**Second, less obvious reason.** With the grants in place, a blocked `UPDATE`/`DELETE` returns **HTTP 204 with no error**, identical to a successful one, because PostgREST returns 204 for "affected zero rows". Verifying by status code alone reports a wide-open table as secure. After revoking, the same probes fail with a loud `403 permission denied`. Always assert against the row, not the response.

### Do not regress the column-level grants on `players`

**Not a new decision, but the audit surfaced it as the schema's strongest control and it is easy to break.** `authenticated` may `UPDATE` only `auth_uid`, `dark_mode`, `native_user_id`, `tutorial_done`. That is the only thing preventing a client writing its own `high_score`; scores must go through the `submit_session` RPC. A blanket `GRANT UPDATE ON players` would silently reopen score forgery.

---

## Standing notes

- `index.html` is bundled into the Capacitor shell. Any change here needs `npm run sync` plus a versionCode bump before it reaches Android. `www/` is gitignored build output and is routinely stale.
- Verify RLS from the client with the anon key, never with a service-role SQL console, which bypasses RLS entirely and always passes.
