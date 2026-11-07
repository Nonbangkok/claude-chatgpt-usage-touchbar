# Claude + ChatGPT Usage Touch Bar

Your live Claude Code and Codex usage on the MacBook Pro Touch Bar, with two
small pixel creatures pacing under a night sky beside it.

![Claude and Codex usage with two pixel mascots on the Touch Bar](docs/demo.gif)

*Recorded with `make film` — the widget's own animation loop, rendered
headless. No screen was filmed. The animation uses illustrative sample data.*

## What it shows

One bar per usage window the account actually has. Claude Code has a 5-hour
and a 7-day window on most plans; Max 20x has no 5-hour limit, so it shows
only the weekly bar. Codex (ChatGPT) has a 5-hour and a weekly window on paid
plans and a single 30-day window on the free plan. Each bar is labelled with
the provider, its subscription level when there is room (`Claude Ultra · 7d`,
`GPT Plus · 5h`; Max 20x is shown as Ultra) and the window, and reads
**remaining** allowance: the fill shrinks as you use it, the figure counts
down, and ticks at 50% and 90% turn it into a scale. Claude is orange, ChatGPT
is blue; both turn amber at half and red at a tenth left, and a nearly
exhausted bar breathes a red halo. `login`, `—` and `stale` on a label mean
the provider needs signing in, has no window to report, or is showing its last
good reading.

This reports **Claude Code and Codex agentic allowances**, not general ChatGPT
web-chat message caps or API billing usage.

**Touch a bar** and the readout becomes a detail panel for that window: a ring
gauge of what is left, when it resets as both a countdown and a clock, and a
timeline of the whole window showing how much of it has passed, with a marker
at *now*. Drag along the timeline to read the clock at any point of the window
(`in 2h 03m · 15:38`). A tap keeps the panel up for three seconds; a drag
lingers where you left it, then springs away.

## The creatures

Clawd (Anthropic's mascot, drawn from the official pose library) and a GPT
companion drawn by hand on the same 20×20 pixel grid and flat palette, so the
two read as one cast. Their behaviour is the gauge too: they stroll while the
5-hour window is under 30%, pick up the pace past that, tire past 60% and panic
past 85%. GPT walks with the same four-beat gait, blinks on its own clock,
glances over when you touch a bar, grins when tapped, startles when grabbed or
flung, and dozes off after a long rest.

Everything answers a fingertip. Tap a mascot and it crouches, hops and throws
pixel confetti in its own colour with a ground ring and a heart. Tap again
quickly to chain a combo (`×2`, `×3`…) that flips it like a coin; `×5` throws a
party in every colour and gets Clawd dancing; `×8` leaves it dizzy for a
moment, stars circling its head, until it has had a breather. Drag and release
a mascot to toss it along the runway: throws kick up dust and bounce off the
wall with stars, and the two bump with a twinkle when they collide. Readings
count up when they arrive and glide when they change, and a highlight sweeps
along the bars every few seconds.

Behind the runway is a night sky: three depths of pixel stars that breathe
slowly and occasionally glint, a thin crescent moon, and a meteor every ten to
twenty seconds. The sky drifts against Clawd's travel, nearer stars faster, so
his pacing reads as a journey. It ends where the readout begins, which stays
on the dark panel the numbers were designed for.

---

## Before you install: what this asks of your Mac

**It reads your Claude Code OAuth token from the login keychain**, and your
Codex token from `~/.codex/auth.json`. That is the only way to ask the usage
endpoints who you are. Specifically:

- `~/bin/claude-touchbar.sh` calls `/usr/bin/security find-generic-password`
  on the item `Claude Code-credentials`, which Claude Code itself created.
- **On most machines this does not prompt**, because `/usr/bin/security` is
  already a trusted application on that keychain item. If yours does prompt,
  it will name `security` — not this project.
- The app binary never touches the keychain or the Codex file. It runs the
  script and draws whatever text comes back.

**It uses private AppKit/DFRFoundation API.** A Control Strip item is a fixed,
narrow slot; there is no public or private way to widen it. Anything that
wants real estate on the Touch Bar has to call
`+[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:]`.
Every Touch Bar utility does this — MTMR, Pock, BetterTouchTool. The practical
consequences: it can never ship on the App Store, and a future macOS could
break it (the app exits cleanly if the API disappears rather than crashing).

**It asks for no permissions** — no Full Disk Access, no Screen Recording, no
Accessibility, nothing. It posts no events and reads nothing but the two
credentials above.

See [SECURITY.md](SECURITY.md) for exactly where the tokens go and what is
cached.

---

## Requirements

- MacBook Pro with a physical Touch Bar (2016–2023; the 13" M2 was the last)
- macOS 12+ — developed and tested on macOS 26.4
- Xcode Command Line Tools: `xcode-select --install`
- Claude Code, signed in (`claude` in a terminal)
- Codex CLI, signed in with the ChatGPT account whose Codex allowance you want
  to show (`codex` in a terminal)
- Python 3 (included with the Command Line Tools). No Node dependency.

Either provider alone works; the other shows `—` until it is signed in.

## Install

```bash
git clone https://github.com/Nonbangkok/claude-chatgpt-usage-touchbar
cd claude-chatgpt-usage-touchbar

make install-script    # puts the usage reader in ~/bin
make assets            # fetches Clawd's poses onto this machine
make run
```

Then set **System Settings → Keyboard → Touch Bar Settings → Touch Bar shows**
to *App Controls* if it is not already.

Check the script works on its own first:

```bash
~/bin/claude-touchbar.sh
# Claude [max_20x]: 5h -1%  7d 41% (ok)
# Codex  [free]: 5h -1%  30d 0% (ok)
```

A `-1` is a window the plan does not have. If Claude says `expired`, run
`claude -p hi` once. If Codex says `expired` or `none`, sign in again with
`codex`.

### Why the poses are not in this repository

Clawd is Anthropic's mascot; the name and the character are theirs. The pose
library at [claudepix.vercel.app](https://claudepix.vercel.app) publishes no
licence, which means all rights reserved.

So the pose data is not redistributed here. `make assets` fetches the pose
grids at build time and writes them to `clawd_presets.h` on your machine. Each
source is checked against `tools/assets-sha256.json`, then a restricted Python
parser reads its data declarations. **No downloaded JavaScript is executed.**
All 13 clips, frame dimensions, durations and palette indices must validate
before the complete header atomically replaces the previous one. A changed
upstream page fails closed; the previous header stays untouched.

Maintainers updating the hash manifest must download the changed source as
text, review its data and helper semantics against `tools/extract-assets.py`,
adapt the parser if needed, and run `python3 tools/test_assets.py` plus a local
`make assets` and build. Do not automatically accept new hashes or add an eval
fallback. The current pins were obtained from the 14 source files on
2026-11-02; only hashes, not the unlicensed artwork, are checked in.

Nothing you can build a pose library from is in this repository — the demo
recording at the top is a rendering of the running widget, the same as any
project showing its own UI. The GPT companion is original pixel art in
`gpt_sprite.m`.

## Run it at login

```bash
make install-agent      # start at login, restart on crash
make uninstall-agent    # remove it again
```

The agent points at the bundle where you built it rather than copying it —
an ad-hoc signature does not survive a copy. Keep the checkout where it is, or
re-run `make install-agent` after moving it.

It restarts on a crash but not when you quit it yourself, and it does not load
outside a GUI session. Removing it leaves nothing behind: no daemon, no
preferences, no keychain entry of its own.

## How it fits together

```
Claude Keychain ─┐
                ├─ ~/bin/claude-touchbar.sh ──> two provider records ──> Touch Bar UI
Codex auth.json ─┘
                     ↑ NSTask every 30s
```

The split is deliberate: the GUI process holds no credentials and opens no
sockets, so the part with network and keychain access stays small enough to
audit in one sitting.

`claude-touchbar.sh --raw` prints one record per provider:

```
claude <5h%> <7d%> <5hResetMin> <7dResetMin> <ageSec> <state> <longDays> <plan>
codex  <5h%> <7d%> <5hResetMin> <7dResetMin> <ageSec> <state> <longDays> <plan>
```

Each provider reports one of four states — `ok`, `stale`, `expired`, `none` —
and the widget renders it independently. `longDays` is the length of the long
window (7, or 30 on a free ChatGPT plan) and `plan` the subscription level,
both restricted to a safe character set before they reach the cache or the
screen. The app parses these lines with a strict C parser (`usage_parser.h`)
that keeps the last good reading when anything is malformed.

Both providers use authenticated, undocumented usage endpoints which may change
without notice. The widget treats malformed or unavailable responses as stale
or unavailable rather than inventing a percentage.

## Building

```bash
make            # build the .app
make assets     # re-fetch Clawd's poses
make test       # every check below — no network, no keychain, no poses needed
make run        # build, restart, launch
make stop
make clean
```

The Touch Bar cannot be screenshotted by the app, so several targets exist to
look at work that would otherwise be invisible:

```bash
make shots      # the readout across a spread of data states -> PNGs
make poses      # all thirteen animation clips, mid-frame -> PNGs
make palette    # candidate colours side by side, on the bar itself
make ruler      # fixed ticks, to read the usable width off the bar
make sweat      # the drag reaction, held on screen
make film       # 20s of the real animation loop -> PNGs (+ gif if ffmpeg)
make film-lens  # 60 fps tour of the touch panel: tap, scrub, release
make film-fx    # 60 fps tour of every effect, combos and all
make film-drag  # scripted grab, drag and throw -> PNGs (+ gif)
make social     # docs/social.png from two stills of the film
```

To capture the real thing, macOS has it built in: **⌘⇧6** saves a picture of
the Touch Bar to the Desktop.

`palette` and `ruler` matter more than they sound. Colours picked from a PNG
were rejected three times running before the same choice made on the panel
landed in one; and the bar's usable width came out as three different numbers
depending on how it was measured, with only the ruler telling the truth.

Objective-C with no dependencies and no package manager. `main.m` draws; the
motion and data live in small Foundation-only modules so they can be tested
without a Touch Bar: `effects` (particles, hops, tweens), `night_sky`,
`gpt_sprite`, `lens_motion`, `mascot_physics`, `usage_model`, and the C
`usage_parser.h`. The script needs only `/usr/bin/python3`, which ships with
the Command Line Tools the build already requires.

`make test` runs the script's JSON parsers against fixed payloads (a wrong
scale or a dropped field would otherwise print something that reads like a
valid measurement), the cache-security tests (symlinks, FIFOs, permissions,
injected arithmetic, concurrent writes), the native parser under
AddressSanitizer with 30,000 fuzzed inputs, the asset extractor, and a unit
suite for every module above. CI runs it on every push, along with a check
that no machine-specific path has crept into a tracked file.

## Credits

- **Clawd**, the mascot, and all its artwork — [Anthropic](https://anthropic.com)
- **Pose library** — [claudepix.vercel.app](https://claudepix.vercel.app)
- Forked from [tpklo/claude-usage-touchbar](https://github.com/tpklo/claude-usage-touchbar),
  which carries the Clawd widget, the security hardening and the asset pipeline
- Touch Bar private API usage follows the pattern established by
  [MTMR](https://github.com/Toxblh/MTMR) and [Pock](https://github.com/pock/pock)

Not affiliated with or endorsed by Anthropic or OpenAI.

## Licence

MIT, covering the code in this repository only. It does not extend to Clawd,
to Anthropic's artwork, or to the pose data — none of which is included here.
