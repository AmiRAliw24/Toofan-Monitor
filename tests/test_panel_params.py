"""The panel passes only known, well-formed query parameters on to the firewall agent (panel/defender.py)."""
import os
import sys
import unittest
from urllib.parse import parse_qs

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "panel"))
os.environ.setdefault("DATA_DIR", os.path.join(os.path.dirname(__file__), "_tmp"))
import defender  # noqa: E402


def q(params):
    return {k: v[0] for k, v in parse_qs(defender._query(params)).items()}


class Params(unittest.TestCase):
    def test_connection_filters_pass(self):
        got = q({"dir": "in", "cc": "DE", "port": "443", "ip": "5.5.5.0/24", "asn": "24940", "state": "HALF", "proto": "tcp",
                 "limit": "300", "q": "آلمان hetzner", "qcc": "DE,AT", "hist": "1", "id": "1795100000"})
        self.assertEqual(got["cc"], "DE")
        self.assertEqual(got["ip"], "5.5.5.0/24")
        self.assertEqual(got["q"], "آلمان hetzner")
        self.assertEqual(got["qcc"], "DE,AT")
        self.assertEqual(len(got), 12)

    def test_bad_values_dropped(self):
        got = q({"dir": "everything", "cc": "germany", "port": "443;", "ip": "1.2.3.4&x=1", "asn": "AS1", "state": "half",
                 "limit": "-1", "q": "a\x00b", "qcc": "DE,ATT", "hist": "yes", "other": "1", "since": "12.5"})
        self.assertEqual(got, {"since": "12.5"})

    def test_values_are_encoded(self):
        raw = defender._query({"q": "a&b=c d"})
        self.assertEqual(raw, "q=a%26b%3Dc%20d")


if __name__ == "__main__":
    unittest.main()
