# Claude + Codex Touch Bar Design

## Goal

Extend the existing native macOS Touch Bar app so that it displays the active
Claude Code subscription window and the active Codex subscription window side
by side, without placing either OAuth token in the GUI process, command line,
environment, log, or persistent cache.

## Scope

This feature reports the Claude Code and Codex agentic allowances available to
their locally authenticated CLIs. It does not attempt to report general
ChatGPT web-chat message caps, model-specific ChatGPT caps, or API billing.

## Architecture

The app will retain a single Objective-C Touch Bar process and one shell
reader. The reader will call two small provider functions: Claude keeps its
existing Keychain-backed request; Codex reads only the access token from the
locally authenticated Codex credential file and requests the Codex usage
endpoint. Each provider writes a cache containing percentages, reset time,
timestamp, and state only; neither cache contains a token.

The script returns a versioned, fixed-width provider record for Claude and
Codex. The GUI parser turns each record into a provider model. Rendering uses
four equal cells, labelled `C 5h`, `C 7d`, `G 5h`, and `G 7d` (`G` is the
compact glyph for GPT/Codex), with the Claude reset countdown under its first
cell and the Codex reset countdown under its first cell. If a provider has no
valid reading, its pair is visibly unavailable rather than fabricated from the
other provider's data.

## Credential and Network Rules

- Claude remains read from `Claude Code-credentials` in the login Keychain.
- Codex reads the current local CLI credential file read-only; a missing,
  malformed, or expired credential is reported as `none` or `expired`.
- Tokens are supplied to `curl` through stdin headers and immediately unset.
- The GUI process continues to open no sockets and access no credential store.
- Caches are mode `0600`, in `/tmp`, and include only derived usage values and
  timestamps.
- A failed refresh surfaces the last known value as `stale`; an expired token
  is shown as expired and is never disguised as current data.

## UI and Error Handling

The existing mascot continues to react to Claude's five-hour value. The
readout reserves the existing 300-point panel for four compact usage cells.
Each cell has a short provider/window label, percentage, fill bar, and the
existing 50%/90% ticks and warning colours. Provider state is rendered next to
that provider's pair: `expired` tells the user which CLI must be signed in
again; `stale` shows age; `none` shows an em dash.

## Testing

Parser tests use captured/synthetic JSON payloads for each provider and cover
valid limits, missing fields, reset parsing, malformed JSON, expired and stale
state propagation. Headless render states cover four-provider normal, one
provider unavailable, stale, and expired layouts. `make test` remains network-
and credential-free.

## Constraints

- macOS 12+ and a physical Touch Bar MacBook Pro.
- Keep the dependency-free Objective-C/Cocoa app and shell/Python runtime.
- The undocumented provider usage endpoints and private Touch Bar API may
  change; document that limitation accurately.
- Do not send credentials to a third-party service.
