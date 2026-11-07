#!/bin/bash
# Exercises the JSON parser inside claude-touchbar.sh against fixed payloads.
#
# The parser is the part most likely to break silently: a wrong scale or a
# swallowed field still prints something that looks like a reading. These cases
# are the ones that actually went wrong, or nearly did.
#
# No network, no keychain, no Claude.app — safe to run anywhere, including CI.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PY=/usr/bin/python3
[ -x "$PY" ] || PY=$(command -v python3) || { echo "no python3"; exit 1; }

# Pull the parser out of the script itself so the test exercises the shipped
# code rather than a copy that can drift. Anchored on `parsed=$(` because the
# script has more than one Python invocation.
SRC=$(awk '/parsed=\$\(/{f=1;next} f{ if(/^print\(f/){sub(/\x27\)$/,"");print;exit} print }' claude-touchbar.sh)
[ -n "$SRC" ] || { echo "FAIL: could not extract the Claude parser from claude-touchbar.sh"; exit 1; }
SRC_CODEX=$(awk '/# CODEX_PARSER_BEGIN/{f=1;next} /# CODEX_PARSER_END/{exit} f{print}' claude-touchbar.sh)

pass=0 fail=0
check() { # name, payload, expected ("*" matches any single field)
  local got; got=$(printf '%s' "$2" | "$PY" -c "$SRC" 2>/dev/null)
  local ok=1 i
  read -ra g <<< "$got"; read -ra w <<< "$3"
  [ "${#g[@]}" = "${#w[@]}" ] || ok=0
  for i in "${!w[@]}"; do
    [ "${w[$i]}" = "*" ] && continue
    [ "${g[$i]:-}" = "${w[$i]}" ] || ok=0
  done
  if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         got      [%s]\n         expected [%s]\n' "$1" "$got" "$3"; fi
}

check_codex() { # name, payload, expected ("*" matches any single field)
  local got; got=$(printf '%s' "$2" | "$PY" -c "$SRC_CODEX" 2>/dev/null)
  local ok=1 i
  read -ra g <<< "$got"; read -ra w <<< "$3"
  [ "${#g[@]}" = "${#w[@]}" ] || ok=0
  for i in "${!w[@]}"; do
    [ "${w[$i]}" = "*" ] && continue
    [ "${g[$i]:-}" = "${w[$i]}" ] || ok=0
  done
  if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         got      [%s]\n         expected [%s]\n' "$1" "$got" "$3"; fi
}

echo "parser:"

# The API reports whole percentages. A previous version guessed the scale with
# `v > 1 ? v : v*100`, turning a real 1% into a displayed 100%.
check "reads utilization as-is" \
  '{"five_hour":{"utilization":37},"seven_day":{"utilization":8}}' \
  "37 8 -1 -1 -1 -"
check "1% stays 1%" \
  '{"five_hour":{"utilization":1},"seven_day":{"utilization":1}}' \
  "1 1 -1 -1 -1 -"

# limits[] is authoritative when present and must win over the top-level windows.
check "limits[] overrides" \
  '{"five_hour":{"utilization":10},"limits":[{"kind":"session","percent":91},{"kind":"weekly_all","percent":44}]}' \
  "91 44 -1 -1 -1 -"
check "weekly_scoped + model name" \
  '{"limits":[{"kind":"weekly_scoped","percent":12,"scope":{"model":{"display_name":"Claude Fable 5"}}}]}' \
  "-1 -1 -1 -1 12 ClaudeFable5"
check "scoped without a name" \
  '{"limits":[{"kind":"weekly_scoped","percent":12}]}' \
  "-1 -1 -1 -1 12 -"

# Anything non-numeric must fall back to -1 rather than reaching the widget as
# text: the caller does integer arithmetic on these fields.
check "percent as string is ignored" \
  '{"limits":[{"kind":"session","percent":"91"}]}' \
  "-1 -1 -1 -1 -1 -"
check "null utilization" \
  '{"five_hour":{"utilization":null},"seven_day":{}}' \
  "-1 -1 -1 -1 -1 -"
check "empty object" '{}' "-1 -1 -1 -1 -1 -"

# resets_at feeds $((RESET/60)) in the caller. The old node parser emitted NaN
# here, which made that arithmetic fail.
check "unparseable resets_at -> -1" \
  '{"five_hour":{"utilization":5,"resets_at":"garbage"}}' \
  "5 -1 -1 -1 -1 -"
check "valid resets_at -> a number" \
  '{"five_hour":{"utilization":5,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"resets_at":"2030-01-05T00:00:00Z"}}' \
  "5 -1 * * -1 -"

# Codex may put either allowance in primary_window, so duration—not position—
# is the contract. Reversing that classification would show a weekly burn in
# the five-hour gauge, which is misleading even though both values are valid.
check_codex "classifies windows by duration" \
  '{"rate_limit":{"primary_window":{"used_percent":17,"reset_at":1893456000,"limit_window_seconds":18000},"secondary_window":{"used_percent":42,"reset_at":1894060800,"limit_window_seconds":604800}}}' \
  "17 42 * * 7 -"
check_codex "weekly-only primary window" \
  '{"rate_limit":{"primary_window":{"used_percent":42,"reset_at":1894060800,"limit_window_seconds":604800},"secondary_window":null}}' \
  "-1 42 -1 * 7 -"
check_codex "rejects string percentages" \
  '{"rate_limit":{"primary_window":{"used_percent":"17","reset_at":1893456000,"limit_window_seconds":18000}}}' \
  "-1 -1 -1 -1 7 -"

# A free ChatGPT plan has one 30-day window and no 5h or weekly one. Its length
# must reach the widget, which would otherwise label it "7d".
check_codex "free plan: single 30-day window" \
  '{"rate_limit":{"primary_window":{"used_percent":12,"reset_at":1893456000,"limit_window_seconds":2592000},"secondary_window":null}}' \
  "-1 12 -1 * 30 -"
check_codex "unknown duration on the secondary window defaults to 7 days" \
  '{"rate_limit":{"primary_window":{"used_percent":5,"reset_at":1893456000,"limit_window_seconds":18000},"secondary_window":{"used_percent":9,"reset_at":1894060800}}}' \
  "5 9 * * 7 -"
check_codex "implausible duration is clamped" \
  '{"rate_limit":{"primary_window":{"used_percent":3,"reset_at":1893456000,"limit_window_seconds":999999999999}}}' \
  "-1 3 -1 * 3650 -"
check_codex "malformed rate_limit reports no windows" \
  '{"rate_limit":null}' \
  "-1 -1 -1 -1 7 -"

# The subscription level comes from plan_type. It is a label shown on the bar,
# so anything outside a safe charset is stripped and non-strings are unknown.
check_codex "plan_type is carried through" \
  '{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":5,"reset_at":1893456000,"limit_window_seconds":18000}}}' \
  "5 -1 * -1 7 plus"
check_codex "plan_type is lower-cased and sanitised" \
  '{"plan_type":"Pro Lite; rm -rf /","rate_limit":{"primary_window":{"used_percent":5,"reset_at":1893456000,"limit_window_seconds":18000}}}' \
  "5 -1 * -1 7 proliterm-rf"
check_codex "non-string plan_type is unknown" \
  '{"plan_type":["pro"],"rate_limit":{"primary_window":{"used_percent":5,"reset_at":1893456000,"limit_window_seconds":18000}}}' \
  "5 -1 * -1 7 -"
check_codex "overlong plan_type is truncated to 24" \
  '{"plan_type":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rate_limit":{"primary_window":{"used_percent":5,"reset_at":1893456000,"limit_window_seconds":18000}}}' \
  "5 -1 * -1 7 aaaaaaaaaaaaaaaaaaaaaaaa"

# Malformed input must produce nothing at all, which the caller treats as stale
# — printing a partial line would be read as a live measurement.
got=$(printf 'not json' | "$PY" -c "$SRC" 2>/dev/null)
if [ -z "$got" ]; then pass=$((pass+1)); echo "  ok    malformed JSON prints nothing"
else fail=$((fail+1)); echo "  FAIL  malformed JSON printed [$got]"; fi

# Each parser lives inside a bash '...' string, so a stray single quote ends it
# early and the parser silently prints nothing (the provider then reads as
# "none"). bash -n cannot see this, so check it explicitly.
for block in "$SRC" "$SRC_CODEX"; do
  if printf '%s' "$block" | grep -q "'"; then
    fail=$((fail+1)); echo "  FAIL  a parser block contains a single quote"
  else pass=$((pass+1)); echo "  ok    parser block is free of single quotes"; fi
done

echo
echo "shell:"
if command -v shellcheck >/dev/null; then
  if shellcheck -S warning claude-touchbar.sh tools/test.sh; then
    pass=$((pass+1)); echo "  ok    shellcheck"
  else fail=$((fail+1)); echo "  FAIL  shellcheck"; fi
else
  echo "  --    shellcheck not installed, skipped"
fi

if "$PY" -m py_compile tools/extract-assets.py 2>/dev/null; then
  pass=$((pass+1)); echo "  ok    extract-assets.py compiles"
else fail=$((fail+1)); echo "  FAIL  extract-assets.py does not compile"; fi

if clang -fobjc-arc -framework Foundation -o /tmp/claude-touchbar-usage-model-test \
    tools/usage-model-test.m usage_model.m 2>/dev/null && /tmp/claude-touchbar-usage-model-test; then
  pass=$((pass+1)); echo "  ok    usage record model"
else fail=$((fail+1)); echo "  FAIL  usage record model"; fi

if clang -fobjc-arc -framework Foundation -o /tmp/claude-touchbar-mascot-physics-test \
    tools/mascot-physics-test.m mascot_physics.m 2>/dev/null && /tmp/claude-touchbar-mascot-physics-test; then
  pass=$((pass+1)); echo "  ok    mascot collision physics"
else fail=$((fail+1)); echo "  FAIL  mascot collision physics"; fi

if clang -fobjc-arc -framework Foundation -o /tmp/claude-touchbar-effects-test \
    tools/effects-test.m effects.m 2>/dev/null && /tmp/claude-touchbar-effects-test; then
  pass=$((pass+1)); echo "  ok    effects: particles, hops and tweens"
else fail=$((fail+1)); echo "  FAIL  effects: particles, hops and tweens"; fi

if clang -fobjc-arc -framework Foundation -o /tmp/claude-touchbar-sky-test \
    tools/night-sky-test.m night_sky.m 2>/dev/null && /tmp/claude-touchbar-sky-test; then
  pass=$((pass+1)); echo "  ok    night sky: parallax, twinkle, meteors"
else fail=$((fail+1)); echo "  FAIL  night sky: parallax, twinkle, meteors"; fi

if clang -fobjc-arc -framework Foundation -o /tmp/claude-touchbar-gpt-test \
    tools/gpt-sprite-test.m gpt_sprite.m 2>/dev/null && /tmp/claude-touchbar-gpt-test; then
  pass=$((pass+1)); echo "  ok    GPT sprite: faces and gait"
else fail=$((fail+1)); echo "  FAIL  GPT sprite: faces and gait"; fi

if ! rg -q 'escapeKeyReplacementItemIdentifier|sendEscape:|local\\.claude-touchbar\\.esc' main.m; then
  pass=$((pass+1)); echo "  ok    no replacement Escape key"
else fail=$((fail+1)); echo "  FAIL  replacement Escape key is still present"; fi

echo
echo "$pass passed, $fail failed"
if ! clang -fobjc-arc -framework Foundation -o /tmp/claude-touchbar-lens-test tools/lens-motion-test.m lens_motion.m || ! /tmp/claude-touchbar-lens-test; then
  exit 1
fi
[ "$fail" = 0 ]
