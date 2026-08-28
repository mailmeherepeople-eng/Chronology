# Background music

Six files, exact names, this folder:

| File                 | Plays on                                   |
|----------------------|--------------------------------------------|
| `mainmenumusic1.mp3` | start screen, settings, 2P chooser, tutorial |
| `museummusic1.mp3`   | the Museum                                 |
| `statsmusic1.mp3`    | the stats screen                           |
| `ingamemusic1.mp3`   | during a run (random pool)                 |
| `ingamemusic2.mp3`   | during a run (random pool)                 |
| `ingamemusic3.mp3`   | during a run (random pool)                 |

The named beds loop themselves. The in-game pool does not loop: each new
game opens on a random track, and when one ends another (different, still
alive) track takes over.

Until both exist the game runs exactly as before — a missing file is marked
dead on its first failure and the bed stays silent.

## Specs

- **Format** MP3, 96 kbps, stereo, 44.1 kHz (mono at 64 kbps is fine too and
  halves the size — phone speakers are mono anyway).
- **Length** 90–120 s. Longer files delay the first play on a cold start.
- **Size** aim for under 1.5 MB each.
- **Loudness** master these ~10-12 dB quieter than the SFX. The in-game
  default is 35% volume against 70% for effects; if the bed still fights the
  correct/wrong sounds, fix it in the file, not the slider.
- **Loop point** MP3 encoders pad the start and end, so `<audio loop>` can
  tick audibly at the seam. Pick tracks that loop on a soft sustain rather
  than a hard downbeat. If a tick is still audible on a phone, the fix is a
  manual crossfade loop in `setMusicFor`'s neighbours (see BACKGROUND MUSIC
  in index.html).

## After dropping files in

1. Bump `_MUS_V` in `index.html` (BACKGROUND MUSIC section) when *replacing*
   an existing file, so cached copies on GitHub Pages get busted.
2. `npm run sync` to rebuild `www/` before any Android build.
