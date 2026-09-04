# Claude + Codex Touch Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display the logged-in Claude Code and Codex subscription usage windows together on the existing native Touch Bar widget.

**Architecture:** Extend the existing shell reader into two provider readers that emit one fixed-width record each. The Objective-C app parses both records, retains independent provider state, and draws a compact pair of cells per provider; all credential and network access remains in the script.

**Tech Stack:** Bash, Python 3 standard library, curl, Objective-C ARC, Cocoa/AppKit, private NSTouchBar/DFRFoundation APIs.

**Spec:** `docs/superpowers/specs/2026-09-04-claude-codex-touchbar-design.md`

## Global Constraints

- Support macOS 12+ on physical Touch Bar MacBook Pro models.
- Preserve the dependency-free Cocoa app and Bash/Python runtime.
- Read credentials locally and read-only; never write OAuth tokens to a file, log, environment, or command argument.
- Pass bearer headers to curl through stdin and unset tokens after the request.
- Cache only derived values under `/tmp` with mode `0600`.
- `make test` must require neither network access nor real credentials.

### Task 1: Define and test the dual-provider shell protocol

**Files:**

- Modify: `claude-touchbar.sh`
- Modify: `tools/test.sh`

**Interfaces:**

- Produces: `claude-touchbar.sh --raw` prints two newline-delimited records: `<provider> <5hPct> <7dPct> <resetMin> <ageSec> <state>`.
- Consumes: no live credential in tests; tests invoke embedded JSON parsers with fixed payloads.

- [ ] **Step 1: Write failing parser tests for Codex windows**

Add a `check_codex` helper that extracts the Codex parser from `claude-touchbar.sh`. Add tests for a five-hour primary window plus weekly secondary window, a weekly-only primary window, invalid string percentages, malformed JSON, and invalid reset timestamp. Expected parser output is `<p5> <p7> <resetMinutes>`, where unavailable values are `-1`.

- [ ] **Step 2: Run the parser test to verify it fails**

Run: `./tools/test.sh`

Expected: FAIL because the script has no Codex parser or record.

- [ ] **Step 3: Add provider records and a Codex JSON parser**

Refactor the existing Claude read into `read_claude_usage`. Add `read_codex_usage` that reads only `tokens.access_token` and optional `tokens.account_id` from `${CODEX_HOME:-$HOME/.codex}/auth.json`. It requests `https://chatgpt.com/backend-api/wham/usage`, passes `Authorization` and optional `ChatGPT-Account-Id` headers through curl stdin, and unsets the token after the request. Parse `rate_limit.primary_window` and `secondary_window`; classify a window with `limit_window_seconds >= 86400` as weekly and a shorter one as five-hour. Maintain a separate mode-0600 `/tmp/.codex-usage-$UID` cache and emit `none`, `expired`, `stale`, or `ok` independently for each provider.

Example raw output:

```text
claude 26 91 125 0 ok
codex 18 42 44 0 ok
```

- [ ] **Step 4: Run parser tests to verify they pass**

Run: `./tools/test.sh`

Expected: all Claude and Codex parser cases pass without network or keychain access.

- [ ] **Step 5: Commit the protocol change**

Run: `git add claude-touchbar.sh tools/test.sh && git commit -m "feat: add Codex usage reader"`

### Task 2: Render independent Claude and Codex usage pairs

**Files:**

- Modify: `main.m`

**Interfaces:**

- Consumes: two `<provider> <5hPct> <7dPct> <resetMin> <ageSec> <state>` records from `claude-touchbar.sh --raw`.
- Produces: four compact usage cells labelled `C 5h`, `C 7d`, `G 5h`, and `G 7d`; mascot mood continues to use Claude five-hour usage.

- [ ] **Step 1: Add a failing headless render state**

Extend `RenderStates` with a Claude-and-Codex state, then run `make assets && make` followed by `./ClaudeTouchBar.app/Contents/MacOS/ClaudeTouchBar --render /tmp/claude-codex-shots`. The old single-provider test tuple must not be accepted as a dual-provider state.

- [ ] **Step 2: Add a provider value model and dual-record parser**

Add a small provider value type containing `p5`, `p7`, `resetMin`, `ageSec`, `state`, and `available`. Replace the current single space-split parse in `-poll` with newline splitting; validate exactly six fields per record and assign only records whose first field is `claude` or `codex`. A malformed Codex record must not replace healthy Claude state.

- [ ] **Step 3: Update the readout layout**

Keep the mascot and its collision wall. Replace the Claude-only cell list with the ordered pair list `C 5h`, `C 7d`, `G 5h`, `G 7d`. An unavailable provider gets two dimmed cells with an em dash; a stale provider shows age beside its first cell; an expired provider uses `C login` or `G login` instead of a percentage. Preserve 50/90 ticks and warning colours.

- [ ] **Step 4: Verify rendered layouts**

Run `make`, render `/tmp/claude-codex-shots`, and inspect normal, Codex-stale, Codex-expired, and Claude-unavailable PNG states. Each of four cells must be legible and must not overlap the mascot.

- [ ] **Step 5: Commit the UI change**

Run: `git add main.m && git commit -m "feat: render Codex usage on Touch Bar"`

### Task 3: Update installation and security documentation

**Files:**

- Modify: `README.md`
- Modify: `SECURITY.md`

**Interfaces:**

- Consumes: final dual-provider protocol and credential paths.
- Produces: accurate setup, endpoint, cache, limitation, and failure-state documentation.

- [ ] **Step 1: Update README**

Describe the display as Claude Code and Codex allowances, not general ChatGPT web-chat message limits. Add Codex CLI sign-in as a requirement, add the dual-provider flow, explain the provider-specific state labels, and state that the endpoint is undocumented and may change.

- [ ] **Step 2: Update SECURITY.md**

Document that Codex reads `tokens.access_token` and optional `account_id` from `${CODEX_HOME:-~/.codex}/auth.json`, transmits them only to `chatgpt.com/backend-api/wham/usage` in stdin-supplied headers, and writes only derived values to its mode-0600 temporary cache. Add `codex` reauthentication to troubleshooting.

- [ ] **Step 3: Run complete verification**

Run: `make test && git diff --check && git status --short`

Expected: parser tests pass, there are no whitespace errors, and only intended files have changed.

- [ ] **Step 4: Commit documentation**

Run: `git add README.md SECURITY.md && git commit -m "docs: explain Codex Touch Bar usage"`
