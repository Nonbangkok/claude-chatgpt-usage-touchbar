#!/usr/bin/env python3
"""Offline integration tests; security and curl are always local stubs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "claude-touchbar.sh"
CLAUDE_NONE = "claude 0 0 -1 -1 -1 none 7 -"
CLAUDE_EXPIRED = "claude 0 0 -1 -1 -1 expired 7 -"
CODEX_NONE = "codex 0 0 -1 -1 -1 none 7 -"


class CacheSecurityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.log = self.home / "calls"
        # The stub answers per host, so Claude and Codex can be exercised
        # independently without ever reaching a real service.
        for name, body in {
            "security": "printf 'security\\n' >> \"$MOCK_LOG\"\nprintf '%s' \"$MOCK_CREDENTIAL\"\n",
            "curl": ("cat >/dev/null\n"
                     "case \"$*\" in\n"
                     "  *chatgpt.com*) printf 'curl-codex\\n' >> \"$MOCK_LOG\"; printf '%s\\n200\\n' \"$MOCK_CODEX_RESPONSE\" ;;\n"
                     "  *) printf 'curl-claude\\n' >> \"$MOCK_LOG\"; printf '%s\\n200\\n' \"$MOCK_RESPONSE\" ;;\n"
                     "esac\n"),
        }.items():
            path = self.bin / name
            path.write_text("#!/bin/bash\n" + body)
            path.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), USER="test-user",
                        PATH=str(self.bin) + ":/usr/bin:/bin", MOCK_LOG=str(self.log),
                        MOCK_CREDENTIAL="{}",
                        MOCK_RESPONSE='{"five_hour":{"utilization":37},"seven_day":{"utilization":8}}',
                        MOCK_CODEX_RESPONSE=json.dumps({"plan_type": "plus", "rate_limit": {
                            "primary_window": {"used_percent": 17, "reset_at": time.time() + 3600,
                                               "limit_window_seconds": 18000},
                            "secondary_window": {"used_percent": 42, "reset_at": time.time() + 86400,
                                                 "limit_window_seconds": 604800}}}))
        self.env.pop("CODEX_HOME", None)
        self.directory = self.home / ".claude-usage-touchbar"
        self.directory.mkdir(mode=0o700)
        self.cache = self.directory / "usage"
        self.codex_cache = self.directory / "codex-usage"
        self.marker = self.home / "INJECTED"

    def put(self, text, path=None):
        path = path or self.cache
        path.write_text(text + "\n")
        path.chmod(0o600)

    def valid(self):
        return "37 8 20 100 -1 - max_20x " + str(int(time.time()))

    def codex_valid(self):
        return "18 42 44 5000 7 plus " + str(int(time.time()))

    def run_all(self):
        result = subprocess.run(["/bin/bash", str(SCRIPT), "--raw"], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.marker.exists(), "untrusted input executed")
        lines = result.stdout.strip().splitlines()
        self.assertEqual(len(lines), 2, result.stdout)
        return lines

    def run_script(self):
        return self.run_all()[0]

    def run_codex(self):
        return self.run_all()[1]

    def enable_api(self):
        self.env["MOCK_CREDENTIAL"] = json.dumps({"claudeAiOauth": {
            "expiresAt": (time.time() + 3600) * 1000, "accessToken": "test-token-only",
            "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}})

    def enable_codex(self):
        codex = self.home / ".codex"
        codex.mkdir(exist_ok=True)
        auth = codex / "auth.json"
        auth.write_text(json.dumps({"tokens": {"access_token": "codex-token-only",
                                               "account_id": "acct"}}))
        auth.chmod(0o600)

    # --- shared / Claude ---------------------------------------------------

    def test_legacy_shared_cache_paths_are_not_referenced(self):
        # Do not create or disturb another process's real /tmp cache in a test.
        source = "\n".join(line for line in SCRIPT.read_text().splitlines()
                           if not line.lstrip().startswith("#"))
        self.assertNotIn("/tmp/.claude-usage-", source)
        self.assertNotIn("/tmp/.codex-usage-", source)

    def test_fresh_cache_avoids_credentials_and_network(self):
        self.put(self.valid())
        self.put(self.codex_valid(), self.codex_cache)
        lines = self.run_all()
        self.assertRegex(lines[0], r"^claude 37 8 20 100 [0-9]+ ok 7 max_20x$")
        self.assertRegex(lines[1], r"^codex 18 42 44 5000 [0-9]+ ok 7 plus$")
        self.assertFalse(self.log.exists())

    def test_arithmetic_payloads_rejected_in_each_numeric_field(self):
        payload = 'a[$(touch${IFS}' + str(self.marker) + ')]'
        for index in range(8):
            with self.subTest(index=index):
                values = self.valid().split()
                values[index] = payload
                self.put(" ".join(values))
                self.assertEqual(self.run_script(), CLAUDE_EXPIRED)

    def test_malformed_records_rejected(self):
        now = str(int(time.time()))
        for value in ("", "1 2", self.valid() + " extra", "101 8 20 100 -1 - pro 1",
                      "1 2 999999999999999999999 100 -1 - pro 1", "1 2 20 100 -1 - pro 9999999999",
                      "1 2 20 100 -1 bad/name pro 1", "1 2 20 100 -1 - bad/plan 1",
                      "1 2 20 100 -1 - " + "x" * 25 + " 1",             # plan too long
                      "1 2 20 100 -1 - pro 0",
                      "1 2 20 100 -1 - " + now,                         # old seven-field shape
                      "1 2 20 -1 - " + now,                             # older six-field shape
                      "1 2 20 525601 -1 - pro " + now):
            with self.subTest(value=value):
                self.put(value)
                self.assertEqual(self.run_script(), CLAUDE_EXPIRED)

    def test_leading_zeroes_normalized(self):
        self.put("008 009 020 030 -1 - pro " + str(int(time.time())))
        self.assertRegex(self.run_script(), r"^claude 8 9 20 30 [0-9]+ ok 7 pro$")

    def test_unsafe_file_permissions_rejected(self):
        self.put(self.valid())
        self.cache.chmod(0o644)
        self.assertEqual(self.run_script(), CLAUDE_EXPIRED)

    def test_symlink_cache_not_read_or_followed_on_write(self):
        victim = self.home / "victim"
        victim.write_text(self.valid())
        victim.chmod(0o600)
        original = victim.read_text()
        self.cache.symlink_to(victim)
        self.assertEqual(self.run_script(), CLAUDE_EXPIRED)
        self.enable_api()
        self.assertEqual(self.run_script(), "claude 37 8 -1 -1 0 ok 7 max_20x")
        self.assertFalse(self.cache.is_symlink())
        self.assertEqual(victim.read_text(), original)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o600)

    def test_symlink_directory_rejected(self):
        self.directory.rmdir()
        target = self.home / "target"
        target.mkdir(mode=0o700)
        self.directory.symlink_to(target, target_is_directory=True)
        self.enable_api()
        self.enable_codex()
        self.assertEqual(self.run_all(), [CLAUDE_NONE, CODEX_NONE])
        self.assertEqual(list(target.iterdir()), [])

    def test_fifo_rejected_without_blocking(self):
        os.mkfifo(self.cache, 0o600)
        os.mkfifo(self.codex_cache, 0o600)
        lines = self.run_all()
        self.assertEqual(lines, [CLAUDE_EXPIRED, CODEX_NONE])

    def test_unsafe_directory_rejected(self):
        self.directory.chmod(0o755)
        self.enable_api()
        self.assertEqual(self.run_script(), CLAUDE_NONE)
        self.assertFalse(self.cache.exists())

    def test_hardlink_cache_rejected(self):
        victim = self.home / "victim"
        victim.write_text(self.valid())
        victim.chmod(0o600)
        os.link(victim, self.cache)
        self.assertEqual(self.run_script(), CLAUDE_EXPIRED)

    def test_oversized_cache_rejected(self):
        self.put(self.valid() + " " * 1024)
        self.assertEqual(self.run_script(), CLAUDE_EXPIRED)

    def test_api_write_creates_private_complete_cache(self):
        self.directory.rmdir()
        self.enable_api()
        self.assertEqual(self.run_script(), "claude 37 8 -1 -1 0 ok 7 max_20x")
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(self.cache.read_text().split()), 8)
        self.assertEqual([p.name for p in self.directory.iterdir()], ["usage"])

    # --- Codex -------------------------------------------------------------

    def test_codex_malformed_records_rejected(self):
        now = str(int(time.time()))
        for value in ("", "1 2", self.codex_valid() + " extra", "101 8 20 100 7 plus " + now,
                      "1 2 999999999999999999999 100 7 plus " + now, "1 2 20 100 7 plus 9999999999",
                      "1 2 20 100 7 plus 0", "1 2 20 525601 7 plus " + now,
                      "1 2 20 100 0 plus " + now, "1 2 20 100 3651 plus " + now,   # days out of range
                      "1 2 20 100 7 pl/us " + now, "1 2 20 100 7 " + "x" * 25 + " " + now,
                      "1 2 20 100 7 " + now,                            # old six-field shape
                      "1 2 20 100 " + now,                              # older five-field shape
                      self.valid()):                                    # Claude's shape
            with self.subTest(value=value):
                self.put(value, self.codex_cache)
                self.assertEqual(self.run_codex(), CODEX_NONE)

    def test_codex_arithmetic_payloads_rejected_in_each_field(self):
        payload = 'a[$(touch${IFS}' + str(self.marker) + ')]'
        for index in range(7):
            with self.subTest(index=index):
                values = self.codex_valid().split()
                values[index] = payload
                self.put(" ".join(values), self.codex_cache)
                self.assertEqual(self.run_codex(), CODEX_NONE)

    def test_codex_symlink_cache_not_read_or_followed_on_write(self):
        victim = self.home / "victim"
        victim.write_text(self.codex_valid())
        victim.chmod(0o600)
        original = victim.read_text()
        self.codex_cache.symlink_to(victim)
        self.assertEqual(self.run_codex(), CODEX_NONE)
        self.enable_codex()
        self.assertRegex(self.run_codex(), r"^codex 17 42 [0-9]+ [0-9]+ 0 ok 7 plus$")
        self.assertFalse(self.codex_cache.is_symlink())
        self.assertEqual(victim.read_text(), original)
        self.assertEqual(self.codex_cache.stat().st_mode & 0o777, 0o600)

    def test_codex_unsafe_file_permissions_and_hardlink_rejected(self):
        self.put(self.codex_valid(), self.codex_cache)
        self.codex_cache.chmod(0o644)
        self.assertEqual(self.run_codex(), CODEX_NONE)
        self.codex_cache.unlink()
        victim = self.home / "victim"
        victim.write_text(self.codex_valid())
        victim.chmod(0o600)
        os.link(victim, self.codex_cache)
        self.assertEqual(self.run_codex(), CODEX_NONE)

    def test_providers_do_not_share_cache_files(self):
        # A valid Codex file must never satisfy Claude, and vice versa.
        self.put(self.codex_valid())
        self.assertEqual(self.run_script(), CLAUDE_EXPIRED)
        self.cache.unlink()
        self.put(self.valid(), self.codex_cache)
        self.assertEqual(self.run_codex(), CODEX_NONE)

    def test_codex_thirty_day_window_reaches_the_widget(self):
        # A free ChatGPT plan: one 30-day window, no 5h and no weekly one.
        self.enable_codex()
        self.env["MOCK_CODEX_RESPONSE"] = json.dumps({"plan_type": "free", "rate_limit": {
            "primary_window": {"used_percent": 12, "reset_at": time.time() + 86400 * 29,
                               "limit_window_seconds": 2592000},
            "secondary_window": None}})
        self.assertRegex(self.run_codex(), r"^codex -1 12 -1 [0-9]+ 0 ok 30 free$")
        self.assertEqual(self.codex_cache.read_text().split()[4], "30")
        # And it is served from the cache, with the length preserved.
        self.assertRegex(self.run_codex(), r"^codex -1 12 -1 [0-9]+ [0-9]+ ok 30 free$")

    def test_claude_plan_levels_are_read_from_the_credential(self):
        for sub, tier, expected in (("max", "default_claude_max_20x", "max_20x"),
                                    ("max", "default_claude_max_5x", "max_5x"),
                                    ("pro", "default_claude_pro", "pro"),
                                    ("team", "", "team"),
                                    ("", "", "-")):
            with self.subTest(sub=sub, tier=tier):
                if self.cache.exists():
                    self.cache.unlink()
                self.env["MOCK_CREDENTIAL"] = json.dumps({"claudeAiOauth": {
                    "expiresAt": (time.time() + 3600) * 1000, "accessToken": "t",
                    "subscriptionType": sub, "rateLimitTier": tier}})
                self.assertRegex(self.run_script(), r"^claude 37 8 -1 -1 0 ok 7 %s$" % expected)

    def test_hostile_plan_names_are_neutralised(self):
        payload = "max$(touch${IFS}" + str(self.marker) + ");`id`|x y/z"
        self.env["MOCK_CREDENTIAL"] = json.dumps({"claudeAiOauth": {
            "expiresAt": (time.time() + 3600) * 1000, "accessToken": "t",
            "subscriptionType": payload, "rateLimitTier": "default_claude_max_20x"}})
        line = self.run_script()               # also asserts nothing was executed
        self.assertRegex(line, r"^claude 37 8 -1 -1 0 ok 7 [A-Za-z0-9_.-]{1,24}$")
        self.enable_codex()
        self.env["MOCK_CODEX_RESPONSE"] = json.dumps({"plan_type": payload, "rate_limit": {
            "primary_window": {"used_percent": 1, "reset_at": time.time() + 60,
                               "limit_window_seconds": 18000}}})
        self.assertRegex(self.run_codex(), r"^codex 1 -1 [0-9]+ -1 0 ok 7 [A-Za-z0-9_.-]{1,24}$")

    def test_missing_or_non_string_codex_plan_is_unknown(self):
        self.enable_codex()
        for plan in (None, 5, ["pro"], {"a": 1}, ""):
            with self.subTest(plan=plan):
                if self.codex_cache.exists():
                    self.codex_cache.unlink()
                self.env["MOCK_CODEX_RESPONSE"] = json.dumps({"plan_type": plan, "rate_limit": {
                    "primary_window": {"used_percent": 1, "reset_at": time.time() + 60,
                                       "limit_window_seconds": 18000}}})
                self.assertRegex(self.run_codex(), r"^codex 1 -1 [0-9]+ -1 0 ok 7 -$")

    # --- both --------------------------------------------------------------

    def test_concurrent_writes_leave_complete_private_records(self):
        self.enable_api()
        self.enable_codex()
        children = [subprocess.Popen(["/bin/bash", str(SCRIPT), "--raw"],
                                    env=self.env, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE) for _ in range(4)]
        for child in children:
            out, err = child.communicate(timeout=10)
            self.assertEqual(child.returncode, 0, err)
            lines = out.strip().splitlines()
            self.assertRegex(lines[0], r"^claude 37 8 -1 -1 [0-9]+ ok 7 max_20x$")
            self.assertRegex(lines[1], r"^codex 17 42 [0-9]+ [0-9]+ [0-9]+ ok 7 plus$")
        self.assertEqual(len(self.cache.read_text().split()), 8)
        self.assertEqual(len(self.codex_cache.read_text().split()), 7)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.codex_cache.stat().st_mode & 0o777, 0o600)
        self.assertEqual(sorted(p.name for p in self.directory.iterdir()),
                         ["codex-usage", "usage"])


if __name__ == "__main__":
    unittest.main()
