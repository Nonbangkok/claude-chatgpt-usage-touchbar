#!/bin/bash
# Claude usage for the Touch Bar widget.
#
# --raw prints one record per provider:
#   "claude|codex <5h%> <7d%> <5hResetMin> <7dResetMin> <ageSec> <state>"
#   state: ok      — fresh reading from the API
#          stale   — API unreachable, showing the last good numbers
#          expired — the OAuth token has expired; run `claude -p hi` to refresh
#          none    — never had a reading
#
# The caller MUST distinguish these: an expired token used to look identical to
# a healthy one, because the cache kept serving its last value forever.
#
# The token is read via /usr/bin/security (already on the keychain item's ACL,
# so nothing prompts), goes into a curl header over stdin — never argv, a file,
# or a log — and is unset immediately after.
set -uo pipefail

umask 077
# Never read the legacy shared /tmp caches. Keep usage data in a private
# directory directly under the current user's home: `usage` (Claude) and
# `codex-usage` (Codex).
TTL=60

# /usr/bin/python3 ships with the Command Line Tools, which this project already
# requires to build — so there is no runtime dependency to install. An earlier
# version pointed at a hard-coded nvm path, which worked on exactly one machine.
PY=/usr/bin/python3
[ -x "$PY" ] || PY=$(command -v python3) || {
  printf 'claude 0 0 -1 -1 -1 none\ncodex 0 0 -1 -1 -1 none\n'; exit 0; }

# Open paths relative to verified directory descriptors. O_NOFOLLOW rejects
# symlinks; O_NONBLOCK prevents a planted FIFO from hanging the poller. This
# helper also normalizes *every* number before Bash can use it in arithmetic.
# Usage: cache_io read|write <usage|codex-usage> [record]
cache_io() {
  "$PY" - "$1" "$2" "${3:-}" <<'PY_CACHE'
import os, re, stat, sys, time, uuid

# name -> (field count, (low, high) per numeric field, index of the model name
# or None, index of the timestamp). Only these two files can ever be touched.
SCHEMAS = {
    "usage": (7, [(-1, 100), (-1, 100), (-1, 525600), (-1, 525600), (-1, 100)], 5, 6),
    "codex-usage": (5, [(-1, 100), (-1, 100), (-1, 525600), (-1, 525600)], None, 4),
}

def record(schema, text):
    count, ranges, name_index, stamp_index = schema
    fields = text.split()
    if len(fields) != count:
        raise ValueError("invalid field count")
    values = []
    for value, (low, high) in zip(fields, ranges):
        if not re.fullmatch(r"-?[0-9]{1,10}", value):
            raise ValueError("invalid number")
        value = int(value, 10)
        if not low <= value <= high:
            raise ValueError("number out of range")
        values.append(str(value))
    if name_index is not None:
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", fields[name_index]):
            raise ValueError("invalid model name")
        values.append(fields[name_index])
    if not re.fullmatch(r"[0-9]{1,10}", fields[stamp_index]):
        raise ValueError("invalid timestamp")
    stamp = int(fields[stamp_index], 10)
    if not 0 < stamp <= int(time.time()) + 5:
        raise ValueError("timestamp out of range")
    return " ".join(values + [str(stamp)])

try:
    schema = SCHEMAS[sys.argv[2]]
    file_name = sys.argv[2]
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    home = os.open(os.path.expanduser("~"), flags)
    info = os.fstat(home)
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("unsafe home directory")
    try:
        os.mkdir(".claude-usage-touchbar", 0o700, dir_fd=home)
    except FileExistsError:
        pass
    directory = os.open(".claude-usage-touchbar", flags, dir_fd=home)
    info = os.fstat(directory)
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("unsafe cache directory")
    if sys.argv[1] == "read":
        fd = os.open(file_name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1
                or info.st_size > 1024):
            raise ValueError("unsafe cache file")
        with os.fdopen(fd) as stream:
            result = record(schema, stream.read(1025))
    else:
        result = record(schema, sys.argv[3])
        name = "." + file_name + "-" + uuid.uuid4().hex
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory)
        try:
            with os.fdopen(fd, "w") as stream:
                stream.write(result + "\n")
            os.replace(name, file_name, src_dir_fd=directory, dst_dir_fd=directory)
        finally:
            try:
                os.unlink(name, dir_fd=directory)
            except FileNotFoundError:
                pass
    print(result)
except (KeyError, OSError, ValueError, UnicodeError):
    sys.exit(1)
PY_CACHE
}

read_cache() {                          # -> P5 P7 RESET RESET7 SP SN STAMP
  local validated
  validated=$(cache_io read usage) || return 1
  read -r P5 P7 RESET RESET7 SP SN STAMP <<< "$validated"
}

P5=; P7=; RESET=-1; RESET7=-1; SP=-1; SN=-; STAMP=0
read_cache || :
AGE=$(( $(date +%s) - ${STAMP:-0} ))

state=ok
if [ "${STAMP:-0}" -eq 0 ] || [ "$AGE" -ge "$TTL" ]; then
  cred=$(security find-generic-password -s 'Claude Code-credentials' -a "$USER" -w 2>/dev/null)

  # Check expiry locally first: it tells us *why* we failed instead of guessing
  # from an HTTP code, and saves a round trip on a token that cannot work.
  expired=$(printf '%s' "$cred" | "$PY" -c 'import json,sys,time
try: print("1" if json.load(sys.stdin)["claudeAiOauth"]["expiresAt"] < time.time()*1000 else "0")
except Exception: print("1")')

  if [ "$expired" = "1" ]; then
    state=expired
  else
    tok=$(printf '%s' "$cred" | "$PY" -c 'import json,sys
try: sys.stdout.write(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])
except Exception: pass')
    unset cred

    # -w '%{http_code}' so a 401 is never silently parsed as "no data".
    resp=$(printf 'Authorization: Bearer %s' "$tok" | curl -sS --max-time 6 -H @- \
      -H 'Accept: application/json' -H 'anthropic-beta: oauth-2025-04-20' \
      -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage 2>/dev/null)
    unset tok

    code=$(printf '%s' "$resp" | tail -1)
    if [ "$code" = "401" ] || [ "$code" = "403" ]; then
      state=expired
    elif [ "$code" = "200" ]; then
      # SCALE: the API reports whole percentages (0-100) directly, and
      # limits[].percent confirms it. A previous version guessed the scale with
      # `v > 1 ? v : v*100`, which turned a real 1% into 100%. Never infer a
      # scale — read the field as the payload actually reports it.
      parsed=$(printf '%s' "$resp" | sed '$d' | "$PY" -c '
import json, sys, re, datetime
try: j = json.load(sys.stdin)
except Exception: sys.exit(0)

def pct(w):
    v = (w or {}).get("utilization")
    return round(v) if isinstance(v, (int, float)) else -1

p5, p7, sp, sn = pct(j.get("five_hour")), pct(j.get("seven_day")), -1, "-"

for l in j.get("limits") or []:
    v = l.get("percent")
    if not isinstance(v, (int, float)):
        continue
    k = l.get("kind")
    if k == "session":       p5 = round(v)
    elif k == "weekly_all":  p7 = round(v)
    elif k == "weekly_scoped":
        sp = round(v)
        nm = ((l.get("scope") or {}).get("model") or {}).get("display_name")
        if isinstance(nm, str): sn = re.sub(r"[^A-Za-z0-9_.-]", "", nm)[:64] or "-"

def reset_min(window):
    t = (window or {}).get("resets_at")
    if not t: return -1
    try:
        # fromisoformat only learned to accept a trailing Z in 3.11.
        d = datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
        return max(0, round((d - datetime.datetime.now(d.tzinfo)).total_seconds() / 60))
    except Exception:
        return -1

r5 = reset_min(j.get("five_hour"))
r7 = reset_min(j.get("seven_day"))
print(f"{p5} {p7} {r5} {r7} {sp} {sn}")')
      case "$parsed" in
        ''|-1\ -1\ *) state=stale ;;
        *) if validated=$(cache_io write usage "$parsed $(date +%s)"); then
             read -r P5 P7 RESET RESET7 SP SN STAMP <<< "$validated"
             AGE=0; state=ok
           else
             state=stale
           fi ;;
      esac
    else
      state=stale                       # network/5xx — keep the last good numbers
    fi
  fi
fi

# Keep Claude's state independent: no Claude credential must prevent Codex from
# being read. `none` is more useful than a fabricated zero when this is a first
# run; `expired` still wins because it gives the user an actionable cause.
if [ -z "${P5:-}" ]; then
  P5=0; P7=0; RESET=-1; RESET7=-1; AGE=-1
  [ "$state" = expired ] || state=none
elif [ "$state" != ok ]; then
  AGE=$(( $(date +%s) - ${STAMP:-0} ))
fi

# Codex uses the ChatGPT plan token created by the Codex CLI. The usage endpoint
# is undocumented, so everything below is deliberately defensive: a schema
# change leaves this provider stale/none rather than inventing a percentage.
# Cache record (`codex-usage`): "5h 7d 5hReset 7dReset epoch"
CTTL=60
CP5=; CP7=; CRESET=-1; CRESET7=-1; CSTAMP=0; CAGE=-1; cstate=ok
if cvalidated=$(cache_io read codex-usage); then
  read -r CP5 CP7 CRESET CRESET7 CSTAMP <<< "$cvalidated"
fi
CAGE=$(( $(date +%s) - ${CSTAMP:-0} ))

if [ "${CSTAMP:-0}" -eq 0 ] || [ "$CAGE" -ge "$CTTL" ]; then
  CAUTH="${CODEX_HOME:-$HOME/.codex}/auth.json"
  cparts=$("$PY" -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f: data = json.load(f)
    tokens = data.get("tokens") or {}
    token = tokens.get("access_token")
    if isinstance(token, str) and token:
        print(token)
        account = tokens.get("account_id")
        if isinstance(account, str): print(account)
except Exception:
    pass
' "$CAUTH")
  # macOS still ships Bash 3.2, which has no `mapfile`. Split the two-line
  # result in-process so the bearer token never becomes a child argv/env value.
  ctok=${cparts%%$'\n'*}
  caccount=
  [ "$cparts" != "$ctok" ] && caccount=${cparts#*$'\n'}
  unset cparts

  if [ -z "$ctok" ]; then
    cstate=none
  else
    # Command substitution trims the trailing newline, so explicitly restore it
    # before appending the optional account header. Otherwise both headers merge
    # and ChatGPT rejects the bearer token as malformed.
    cheaders=$(printf 'Authorization: Bearer %s' "$ctok")
    [ -n "$caccount" ] && cheaders="${cheaders}"$'\n'"ChatGPT-Account-Id: ${caccount}"
    cresp=$(printf '%s\n' "$cheaders" | curl -sS --max-time 6 -H @- \
      -H 'Accept: application/json' -H 'User-Agent: codex-cli' \
      -w '\n%{http_code}' https://chatgpt.com/backend-api/wham/usage 2>/dev/null)
    unset ctok caccount cheaders

    ccode=$(printf '%s' "$cresp" | tail -1)
    if [ "$ccode" = 401 ] || [ "$ccode" = 403 ]; then
      cstate=expired
    elif [ "$ccode" = 200 ]; then
      cparsed=$(printf '%s' "$cresp" | sed '$d' | "$PY" -c '
# CODEX_PARSER_BEGIN
import json, sys, time
try: j = json.load(sys.stdin)
except Exception: sys.exit(0)

rate_limit = j.get("rate_limit")
if not isinstance(rate_limit, dict):
    print("-1 -1 -1 -1"); sys.exit(0)

p5 = p7 = reset5 = reset7 = -1
for index, key in enumerate(("primary_window", "secondary_window")):
    window = rate_limit.get(key)
    if not isinstance(window, dict):
        continue
    percent = window.get("used_percent")
    reset_at = window.get("reset_at")
    duration = window.get("limit_window_seconds")
    if isinstance(percent, bool) or not isinstance(percent, (int, float)):
        continue
    if isinstance(duration, bool) or not isinstance(duration, (int, float)):
        is_weekly = index == 1
    else:
        is_weekly = duration >= 86400
    if is_weekly:
        p7 = round(percent)
        if isinstance(reset_at, (int, float)) and not isinstance(reset_at, bool):
            reset7 = max(0, round((reset_at - time.time()) / 60))
    else:
        p5 = round(percent)
        if isinstance(reset_at, (int, float)) and not isinstance(reset_at, bool):
            reset5 = max(0, round((reset_at - time.time()) / 60))

print(f"{p5} {p7} {reset5} {reset7}")
# CODEX_PARSER_END
')
      case "$cparsed" in
        ''|-1\ -1\ *) cstate=stale ;;
        *) if cvalidated=$(cache_io write codex-usage "$cparsed $(date +%s)"); then
             read -r CP5 CP7 CRESET CRESET7 CSTAMP <<< "$cvalidated"
             CAGE=0; cstate=ok
           else
             cstate=stale
           fi ;;
      esac
    else
      cstate=stale
    fi
  fi
fi

if [ -z "${CP5:-}" ]; then
  CP5=0; CP7=0; CRESET=-1; CRESET7=-1; CAGE=-1
  [ "$cstate" = expired ] || cstate=none
elif [ "$cstate" != ok ]; then
  CAGE=$(( $(date +%s) - ${CSTAMP:-0} ))
fi

case "${1:-}" in
  --raw)
    printf 'claude %s %s %s %s %s %s\n' "$P5" "$P7" "$RESET" "$RESET7" "$AGE" "$state"
    printf 'codex %s %s %s %s %s %s\n' "$CP5" "$CP7" "$CRESET" "$CRESET7" "$CAGE" "$cstate"
    ;;
  *)
    printf 'Claude: 5h %s%%  7d %s%% (%s)\n' "$P5" "$P7" "$state"
    printf 'Codex:  5h %s%%  7d %s%% (%s)\n' "$CP5" "$CP7" "$cstate"
    ;;
esac

