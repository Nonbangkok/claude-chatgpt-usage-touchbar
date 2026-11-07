# Claude + Codex Usage Touch Bar

Your live Claude Code and Codex usage on the MacBook Pro Touch Bar, with a
small pixel creature pacing alongside it.

![Claude and Codex usage with a transparent-background GPT mascot on the Touch Bar](docs/demo.gif)

*Recorded with `make film` — the widget's own animation loop, rendered
headless. No screen was filmed. The animation uses illustrative sample data.*

The bars show Claude Code and Codex 5-hour and 7-day utilisation. A window
appears only if the account has one: Claude Max 20x has no 5-hour limit, so it
shows just the weekly bar, and the remaining bars grow to fill the space.
Each provider's subscription level (`Claude Ultra · 7d`, `GPT Free · 30d`; Max 20x is shown as Ultra) is
printed beside its name when the cell is wide enough to hold it; with four
narrow cells it is left off the bars and shown in the lens instead. When
both are visible, their labels read `Claude 5h`, `Claude 7d`, `GPT 5h`, and
`GPT 7d`; a single provider uses its full name. Tick marks sit at
50% and 90%; colour and a `!` glyph both flag trouble, so the warning survives
a red/green colour deficiency. `login`, `—`, and an age in minutes distinguish
expired, unavailable, and stale provider data.

This reports **Claude Code and Codex agentic allowances**, not general ChatGPT
web-chat message caps or API billing usage.

Everything answers a fingertip. Tap a mascot and it crouches, hops and throws
pixel confetti in its own colour with a ground shock-ring and a heart; tap
again quickly to chain a combo (`×2`, `×3`…) that flips it like a coin. Throws
kick up dust and bounce off the wall with stars, and the two bump with a
twinkle when they collide. Touching a bar makes both mascots glance over at
what you are reading. Readings count up when they arrive and glide when they
change, a highlight sweeps along the bars every few seconds, and a bar that is
nearly exhausted breathes a red halo. Preview it
all with `./ClaudeTouchBar.app/Contents/MacOS/ClaudeTouchBar --film-fx /tmp/fx`.

Behind the runway is a night sky: three depths of pixel stars that breathe
slowly and occasionally glint, a thin crescent moon, and a meteor every ten
to twenty seconds. The sky drifts against Clawd's travel, nearer stars faster,
so his pacing reads as a journey. It ends where the readout begins, which
stays on the dark panel the numbers were designed for.

The creatures' behaviour is the gauge too: they stroll when you are under 30%,
pick up the pace past that, tire past 60%, and panic past 85%. GPT alternates
between walking and short idle rests; tap either mascot for a small sparkle,
or drag and release it to toss it along the runway.

Touch a usage bar and the readout becomes a detail panel for that window: a
ring gauge of what is left, when it resets as both a countdown and a clock, and
a timeline of the whole window showing how much of it has passed, with a
marker at *now*. Drag along the timeline to read the clock at any point of
the window (`in 2h 03m · 15:38`). A tap keeps the panel up for three seconds;
a drag lingers where you left it, then springs away. Preview the gestures with
`./ClaudeTouchBar.app/Contents/MacOS/ClaudeTouchBar --film-lens /tmp/lens-frames 10.5`
(60 fps PNG sequence).

---

## Before you install: what this asks of your Mac

**It reads your Claude Code OAuth token from the login keychain.** That is the
only way to ask the usage endpoint who you are. Specifically:

- `~/bin/claude-touchbar.sh` calls `/usr/bin/security find-generic-password`
  on the item `Claude Code-credentials`, which Claude Code itself created.
- **On most machines this does not prompt**, because `/usr/bin/security` is
  already a trusted application on that keychain item. If yours does prompt,
  it will name `security` — not this project.
- The app binary never touches the keychain. It runs the script and draws
  whatever text comes back.

**It uses private AppKit/DFRFoundation API.** A Control Strip item is a fixed,
narrow slot; there is no public or private way to widen it. Anything that
wants real estate on the Touch Bar has to call
`+[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:]`.
Every Touch Bar utility does this — MTMR, Pock, BetterTouchTool. The practical
consequences: it can never ship on the App Store, and a future macOS could
break it (the app exits cleanly if the API disappears rather than crashing).

**It asks for no permissions to show you your usage** — no Full Disk Access, no
Screen Recording, nothing. One exception: the replacement Escape key posts a
synthetic key event through `CGEventPost`, which is what the Accessibility
permission governs. It has not prompted on the machine this was built on, but
if a dialog does appear it will be Accessibility, it will be the Escape button
that caused it, and declining costs you only that button.

See [SECURITY.md](SECURITY.md) for exactly where the token goes.

---

## Requirements

- MacBook Pro with a physical Touch Bar (2016–2023; the 13" M2 was the last)
- macOS 12+ — developed and tested on macOS 26.4
- Xcode Command Line Tools: `xcode-select --install`
- Claude Code, signed in (`claude` in a terminal)
- Codex CLI, signed in with the ChatGPT account whose Codex allowance you want
  to show (`codex` in a terminal)
- Python 3 (included with the Command Line Tools). No Node dependency.


## Install

```bash
git clone https://github.com/tpklo/claude-usage-touchbar
cd claude-usage-touchbar

make install-script    # puts the usage reader in ~/bin
make assets            # fetches Clawd's poses onto this machine
make run
```

Then set **System Settings → Keyboard → Touch Bar Settings → Touch Bar shows**
to *App Controls* if it is not already.

Check the script works on its own first:

```bash
~/bin/claude-touchbar.sh
# Claude: 5h 26%  7d 91% (ok)
# Codex:  5h 18%  7d 42% (ok)
```

If Claude says `expired`, run `claude -p hi` once. If Codex says `expired` or
`none`, sign in again with `codex`.

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
recording at the top is a screenshot of the running widget, the same as any
project showing its own UI.

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

Each provider reports one of four states — `ok`, `stale`, `expired`, `none` —
and the widget renders it independently. If Codex says `login` or `—`, sign in
again with `codex`; if Claude says `login`, refresh with `claude -p hi`.

Both providers use authenticated, undocumented usage endpoints which may change
without notice. The widget treats malformed or unavailable responses as stale
or unavailable rather than inventing a percentage.

## Building

```bash
make            # build the .app
make assets     # re-fetch Clawd's poses
make test       # parser checks — no network, no keychain, no poses needed
make run        # build, restart, launch
make stop
make clean
```

The Touch Bar cannot be screenshotted, so several targets exist to look at work
that would otherwise be invisible:

```bash
make shots      # readout across eight data states -> PNGs
make poses      # all thirteen animation clips, mid-frame -> PNGs
make palette    # candidate colours side by side, on the bar itself
make ruler      # fixed ticks, to read the usable width off the bar
make sweat      # the drag reaction, held on screen
make film       # 20s of the real animation loop -> PNGs (+ gif if ffmpeg)
make film-drag  # scripted grab, drag and throw -> PNGs (+ gif)
```

`palette` and `ruler` matter more than they sound. Colours picked from a PNG
were rejected three times running before the same choice made on the panel
landed in one; and the bar's usable width came out as three different numbers
depending on how it was measured, with only the ruler telling the truth.

Single Objective-C file, no dependencies, no package manager. The script needs
only `/usr/bin/python3`, which ships with the Command Line Tools the build
already requires.

`make test` covers the JSON parser, which is where a silent failure would hide:
a wrong scale or a dropped field still prints something that reads like a valid
measurement. CI runs it on every push, along with a check that no
machine-specific path has crept into a tracked file — a hard-coded nvm path
shipped once and broke every clone but the author's.

## Credits

- **Clawd**, the mascot, and all its artwork — [Anthropic](https://anthropic.com)
- **Pose library** — [claudepix.vercel.app](https://claudepix.vercel.app)
- Touch Bar private API usage follows the pattern established by
  [MTMR](https://github.com/Toxblh/MTMR) and [Pock](https://github.com/pock/pock)

Not affiliated with or endorsed by Anthropic.

## Licence

MIT, covering the code in this repository only. It does not extend to Clawd,
to Anthropic's artwork, or to the pose data — none of which is included here.

