# Security

This project reads the locally authenticated Claude Code and Codex credentials.
That deserves a precise account rather than a reassuring one, so this document
describes what the code actually does. If any claim here does not match the
source, that is a bug — please open an issue.

## What is read, and by what

`~/bin/claude-touchbar.sh` runs:

```sh
security find-generic-password -s 'Claude Code-credentials' -a "$USER" -w
```

That is Apple's `/usr/bin/security` reading the keychain item **Claude Code
created when you signed in**. This project creates no keychain item of its own
and asks for no new access. On most machines `/usr/bin/security` is already a
trusted application on that item, so no dialog appears; if one does, it will
name `security`.

From the returned JSON only `claudeAiOauth.accessToken`,
`claudeAiOauth.expiresAt`, and the plan labels `subscriptionType` and
`rateLimitTier` (reduced to a token such as `max_20x`) are used.
`refreshToken` is never read.

For Codex, the script reads `${CODEX_HOME:-~/.codex}/auth.json` read-only. From
that JSON it uses only `tokens.access_token` and optional `tokens.account_id`.
It does not update the credential file or run a token refresh command. From
the usage response it keeps the percentages, reset times, the window length
and the `plan_type` label.

## Where the token goes

Claude's token goes to the `Authorization` header of this GET request:

```
GET https://api.anthropic.com/api/oauth/usage
```

Handling, in order:

1. The token lives in a shell variable for the duration of one request.
2. It reaches `curl` through **stdin** (`-H @-`), never as an argument — so it
   does not appear in `ps`, in your shell history, or in any process listing.
3. `unset tok` immediately after the request.
4. It is never written to a file, never logged, never printed, never copied to
   the clipboard, and never passed to a child process's environment.

Codex's token and optional account ID go only to stdin-supplied request headers
for this GET request:

```
GET https://chatgpt.com/backend-api/wham/usage
```

There is no telemetry, analytics, crash reporting, or third-party backend.
The only runtime hosts are `api.anthropic.com` and `chatgpt.com`. You can
confirm that yourself:

```sh
grep -oE 'https?://[^ "]+' ~/bin/claude-touchbar.sh
```

## What the GUI process can do

Nothing, with respect to your credentials. `ClaudeTouchBar.app`:

- never links `Security.framework` and never calls any keychain API
- opens no sockets — it has no networking code at all
- spawns exactly one subprocess: `/bin/bash -lc ~/bin/claude-touchbar.sh --raw`
- parses two provider records from that output with a strict C parser

The split exists so that the component with credential and network access is a
small shell script you can audit in a sitting, rather than a compiled binary
you have to take on trust.

## The disk-cache hazard, and why it is not present here

A prior tool that inspired this one used `NSURLSession.sharedSession` for the
same request. macOS caches responses for the shared session on disk, and the
cache retains request headers — so the full bearer token was written in plain
text to `~/Library/Caches/<bundle-id>/Cache.db-wal` with mode `0644`, readable
by any process running as that user, no prompt required. The application code
itself never wrote a file; the framework did it.

This project uses `curl` from a shell script, which has no such cache. The GUI
process performs no requests at all, so the failure mode cannot occur. If you
ever port the request into the app, use `ephemeralSessionConfiguration` and set
`URLCache` to `nil`.

That earlier tool's own SECURITY.md stated the token was "kept in memory only".
It was not. Verify claims like this against the code — including the ones on
this page.

## What is cached

Two files, both mode `0600`, in a private `0700` directory
`~/.claude-usage-touchbar/`, containing only derived whitespace-separated
values:

```
usage        <5h%> <7d%> <5hResetMin> <7dResetMin> <scoped%> <model> <plan> <unixTimestamp>   (Claude)
codex-usage  <5h%> <7d%> <5hResetMin> <7dResetMin> <longWindowDays> <plan> <unixTimestamp>  (Codex)
```

Percentages, reset times, the long window's length in days (1–3650), a sanitized model name
and subscription level such as `max_20x` or `free` (`[A-Za-z0-9_.-]`, at most 64 and 24
characters respectively) and a timestamp. The subscription level is read from
`subscriptionType`/`rateLimitTier` in the Claude credential already being used and from
`plan_type` in the Codex usage response; it is a label, not an identifier, and is
stripped to that charset before it can reach the cache or the widget. No token, account ID, or other identifier is
cached. Delete either file whenever you like; it is rebuilt within a minute.

The old shared `/tmp/.claude-usage-$UID` and `/tmp/.codex-usage-$UID` files are
never read or migrated.
Cache paths are opened relative to verified directory descriptors, without
following symlinks. The home and cache directories must belong to the current
user and must not be writable by other users. Cache records are size-limited,
validated and normalized before any value reaches shell arithmetic. Writes
use a new private file and an atomic rename, not truncation of an existing path.

## Build-time assets

Pose downloads are untrusted input, not executable code. The asset extractor
checks SHA-256 pins and parses only a restricted data-expression grammar with
locally implemented grid operations; it never evaluates JavaScript. It fails
closed on unsupported source syntax or invalid data, requires the
complete ordered set of 13 clips, and replaces the generated header only after
all validation succeeds. The native build also rejects partial clip tables.
These checks do not grant a licence to redistribute the artwork.

The activity assertion keeps animation responsive without disabling macOS
idle sleep. Frame updates pause while the screen is locked or the display is
asleep; display wake alone does not clear the separate lock state. Clip
selection also checks runtime bounds in addition to the compile-time guard.

## Usage-reader output

The GUI uses the same portable C parser exercised by the offline tests. It
looks backwards through stdout for the newest valid record of each provider,
ignoring login banners and trailing diagnostics. A record is 7-9
whitespace-separated fields (spaces or tabs): the provider name (`claude` or
`codex`), five integers checked for syntax and range before conversion, a
known state, an optional window length (1-3650 days) and an optional plan
label (at most 24 ASCII letters/digits or `_.-`, starting with a letter).
Malformed output cannot partially update a reading: a provider with no valid
record keeps its previous reading. Inputs over 64 KiB and embedded NUL bytes
are rejected; individual protocol lines are limited to 512 bytes.

This is validation, not authentication: arbitrary output that exactly matches
the protocol cannot be distinguished from the reader's own line. The script
and the user's login files remain trusted local code. The line-oriented fix
was prompted by @xmihal03's report and PR #1.

## Private API

The app calls `+[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:]`
and `DFRSystemModalShowsCloseBoxWhenFrontMost` from `DFRFoundation.framework`.
These are undocumented, and no public alternative exists — a Control Strip item
is a fixed narrow slot with no sizing API in either the public headers or the
private method table.

The call is guarded with `respondsToSelector:`; if a future macOS removes it,
the app logs and exits instead of crashing. This is also why the app can never
be distributed through the App Store.

No entitlements are requested and ad-hoc signing is sufficient. Nothing here
needs Full Disk Access, Screen Recording, Accessibility, or any other TCC
permission.

## No synthetic events

An earlier version drew a replacement Escape key and pressed it by posting a
synthetic keyboard event, which is what the Accessibility permission governs.
That button is gone (`tools/test.sh` fails if it comes back): the app posts no
events of any kind, so no permission dialog can be caused by it. Touches on the
bar are handled inside the app's own view.

An earlier version of this file claimed no permission could ever be requested
while that code path still existed. That claim was written from intent rather
than from reading the code, and it was the kind of unverified reassurance a
security document should never contain. If you find any other statement here
that the source does not support, please open an issue.

## Reporting

Open a GitHub issue. This is a personal project maintained on a best-effort
basis — if you need a guaranteed response window, this is not the right
dependency for you.

