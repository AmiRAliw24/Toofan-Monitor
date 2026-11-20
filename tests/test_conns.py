"""The connections view (defender/conns.py): reading the conntrack table, filters, findings, history, reports.

A hand-made table covers every kind of entry the kernel produces; Prometheus, Docker and the IP
database are replaced by fixed answers, so the test runs anywhere (python -m unittest discover tests).
"""
import json
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "defender"))
import conns  # noqa: E402
import ipdb  # noqa: E402

HOST, HOST6 = "91.0.0.1", "2a01::1"
LOCAL = frozenset({HOST, HOST6, "172.17.0.1", "127.0.0.1", "::1"})
TABLE = "\n".join([
    # incoming SSH, established
    f"ipv4     2 tcp      6 431999 ESTABLISHED src=1.2.3.4 dst={HOST} sport=50000 dport=22 src={HOST} dst=1.2.3.4 sport=22 dport=50000 [ASSURED] mark=0 use=1",
    # a SYN flood leaves half-open entries (three source ports, one address)
    *[f"ipv4     2 tcp      6 59 SYN_RECV src=5.5.5.5 dst={HOST} sport={40000 + i} dport=443 src={HOST} dst=5.5.5.5 sport=443 dport={40000 + i} mark=0 use=1" for i in range(3)],
    # a published Docker port: the reply comes from the container
    f"ipv4     2 tcp      6 300 ESTABLISHED src=8.8.4.4 dst={HOST} sport=1234 dport=3000 src=172.19.0.8 dst=8.8.4.4 sport=8080 dport=1234 [ASSURED] mark=0 use=1",
    # this server's own program connecting out
    f"ipv4     2 tcp      6 300 ESTABLISHED src={HOST} dst=9.9.9.9 sport=45678 dport=443 src=9.9.9.9 dst={HOST} sport=443 dport=45678 [ASSURED] mark=0 use=1",
    # a container connecting out (masqueraded)
    f"ipv4     2 tcp      6 300 ESTABLISHED src=172.18.0.5 dst=1.1.1.1 sport=5555 dport=443 src=1.1.1.1 dst={HOST} sport=443 dport=5555 [ASSURED] mark=0 use=1",
    # the server talking to itself: never parsed
    "ipv4     2 tcp      6 10 TIME_WAIT src=127.0.0.1 dst=127.0.0.1 sport=1 dport=2 src=127.0.0.1 dst=127.0.0.1 sport=2 dport=1 [ASSURED] mark=0 use=1",
    # a ping nobody answered: not "half-open"
    f"ipv4     2 icmp     1 29 src=3.3.3.3 dst={HOST} type=8 code=0 id=1 [UNREPLIED] src={HOST} dst=3.3.3.3 type=0 code=0 id=1 mark=0 use=1",
    # IPv6
    f"ipv6     10 tcp      6 300 ESTABLISHED src=2001:db8::5 dst={HOST6} sport=5000 dport=443 src={HOST6} dst=2001:db8::5 sport=443 dport=5000 [ASSURED] mark=0 use=1",
    # UDP without a reply: not half-open either (only TCP handshakes are)
    f"ipv4     2 udp      17 29 src=4.4.4.4 dst={HOST} sport=53000 dport=51820 [UNREPLIED] src={HOST} dst=4.4.4.4 sport=51820 dport=53000 mark=0 use=1",
    # with byte accounting on
    f"ipv4     2 tcp      6 300 ESTABLISHED src=6.6.6.6 dst={HOST} sport=1 dport=80 packets=10 bytes=1000 src={HOST} dst=6.6.6.6 sport=80 dport=1 packets=20 bytes=50000 [ASSURED] mark=0 use=1",
    "garbage line",
    "",
])
GEO = {"1.2.3.4": "DE", "5.5.5.5": "DE", "8.8.4.4": "US", "9.9.9.9": "CH", "1.1.1.1": "AU", "3.3.3.3": "FR",
       "2001:db8::5": "NL", "4.4.4.4": "US", "6.6.6.6": "IR"}
SERVICES = {("tcp", 22): "sshd", ("tcp", 3000): "docker-proxy", ("tcp", 443): "nginx"}


def fake_geo(ip):
    return (GEO.get(ip, "LAN" if ip.startswith(("172.", "10.", "192.168.")) else None), 64500 if ip in GEO else None, "TEST-AS Example" if ip in GEO else None)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        conns._data = self.tmp
        conns._history.clear()
        conns._timeline.clear()
        conns._first_seen.clear()
        conns._geo_cache.clear()
        conns._subnets.clear()
        self.orig = (conns.geo, conns.snapshot, ipdb.status, ipdb.ensure)
        conns.geo = fake_geo
        ipdb.status = lambda data: {"ready": True, "state": "done"}
        ipdb.ensure = lambda data, force=False: None
        groups, n, loopback = conns._parse(TABLE, LOCAL, SERVICES, {("tcp", 45678): "xray"})
        self.snap = {"at": time.time(), "took": 0.01, "interval": 4.0, "groups": groups, "entries": n, "loopback": loopback,
                     "max": 262144, "truncated": False}
        conns.snapshot = lambda force=False: self.snap

    def tearDown(self):
        conns.geo, conns.snapshot, ipdb.status, ipdb.ensure = self.orig


class Parse(Base):
    def test_classification(self):
        g = self.snap["groups"]
        self.assertEqual(self.snap["loopback"], 1)
        self.assertIn(("in", "tcp", "1.2.3.4", "22", "ESTABLISHED", "sshd", ""), g)
        half = g[("in", "tcp", "5.5.5.5", "443", "SYN_RECV", "nginx", "")]
        self.assertEqual(half[:2], [3, 3])                         # three entries, all half-open, merged into one row
        self.assertIn(("in", "tcp", "8.8.4.4", "3000", "ESTABLISHED", "docker-proxy", "172.19.0.8:8080"), g)
        self.assertIn(("out", "tcp", "9.9.9.9", "443", "ESTABLISHED", "xray", ""), g)       # the program that connects
        self.assertIn(("out", "tcp", "1.1.1.1", "443", "ESTABLISHED", "", "172.18.0.5"), g)  # the container that connects
        icmp = g[("in", "icmp", "3.3.3.3", "", "UNREPLIED", "", "")]
        self.assertEqual(icmp[1], 0)                               # an unanswered ping is not half-open
        udp = g[("in", "udp", "4.4.4.4", "51820", "UNREPLIED", "wireguard", "")]
        self.assertEqual(udp[1], 0)
        self.assertIn(("in", "tcp", "2001:db8::5", "443", "ESTABLISHED", "nginx", ""), g)
        acct = g[("in", "tcp", "6.6.6.6", "80", "ESTABLISHED", "http", "")]
        self.assertEqual((acct[2], acct[3]), (1000, 50000))        # bytes in = what the remote sent

    def test_limit(self):
        old = conns.MAX_ENTRIES
        conns.MAX_ENTRIES = 3
        try:
            _g, n, _l = conns._parse(TABLE, LOCAL, SERVICES)
        finally:
            conns.MAX_ENTRIES = old
        self.assertEqual(n, 4)       # stops right after the limit


class View(Base):
    def v(self, **q):
        out = conns.view(q)
        json.dumps(out)                 # every answer must be valid JSON (the agent sends it as JSON)
        return out

    def test_incoming_summary(self):
        v = self.v(dir="in")
        self.assertEqual(v["summary"]["conns"], 9)
        self.assertEqual(v["summary"]["half"], 3)
        self.assertEqual(v["dirs"], {"in": 9, "out": 2, "int": 1})
        self.assertEqual(v["countries"][0]["cc"], "DE")
        self.assertEqual(v["countries"][0]["conns"], 4)
        self.assertEqual(v["ports"][0]["port"], "443")
        self.assertEqual([p for p in v["ports"] if p["port"] == "3000"][0]["targets"], ["172.19.0.8:8080"])
        self.assertEqual(v["ips"][0]["ip"], "5.5.5.5")
        self.assertEqual(v["ips"][0]["half"], 3)

    def test_filters(self):
        self.assertEqual(self.v(dir="in", cc="DE")["summary"]["conns"], 4)
        self.assertEqual(self.v(dir="in", state="HALF")["summary"]["conns"], 3)
        self.assertEqual(self.v(dir="all", port="443")["summary"]["conns"], 6)
        self.assertEqual(self.v(dir="in", ip="5.5.5.0/24")["summary"]["conns"], 3)
        self.assertEqual(self.v(dir="in", ip="1.2.3.4")["summary"]["conns"], 1)
        self.assertEqual(self.v(dir="out", q="xray")["summary"]["conns"], 1)
        self.assertEqual(self.v(dir="in", proto="icmp")["summary"]["conns"], 1)
        self.assertEqual(self.v(dir="in", q="germany", qcc="DE")["summary"]["conns"], 4)   # a country name typed in the search box
        self.assertEqual(self.v(dir="in", q="nothing-like-this")["summary"]["conns"], 0)
        self.assertEqual(self.v(dir="in", asn="64500")["summary"]["conns"], 9)

    def test_bad_params_are_safe(self):
        v = self.v(dir="bogus", limit="999999", state="x" * 500)
        self.assertEqual(v["query"]["dir"], "in")
        self.assertEqual(v["query"]["limit"], 2000)
        self.assertEqual(self.v(limit="nope")["query"]["limit"], 300)

    def test_rows_limit_and_order(self):
        v = self.v(dir="all", limit="20")
        self.assertEqual(v["rows_total"], 9)          # 11 entries: loopback skipped, the three half-open ones merged
        self.assertEqual(v["rows"][0]["ip"], "5.5.5.5")            # the busiest address first

    def test_insights(self):
        g = {}
        for i in range(10):                     # 300 connections from Germany, 120 of them half-open, from one /24
            g[("in", "tcp", f"7.7.7.{i}", "443", "SYN_RECV", "nginx", "")] = [12, 12, 0, 0, 60]
            g[("in", "tcp", f"7.7.7.{i}", "443", "ESTABLISHED", "nginx", "")] = [18, 0, 0, 0, 300]
        for i in range(5):
            g[("in", "tcp", f"8.8.{i}.1", "443", "ESTABLISHED", "nginx", "")] = [10, 0, 0, 0, 300]
        self.snap["groups"] = g
        geo = dict(GEO, **{f"7.7.7.{i}": "DE" for i in range(10)}, **{f"8.8.{i}.1": "US" for i in range(5)})
        conns.geo = lambda ip: (geo.get(ip), 64500, "TEST")
        kinds = {i["kind"]: i for i in self.v(dir="in")["insights"]}
        self.assertEqual(kinds["country"]["cc"], "DE")
        self.assertAlmostEqual(kinds["country"]["share"], 300 / 350, places=3)
        self.assertIn("half", kinds)
        self.assertEqual(kinds["subnet"]["net"], "7.7.7.0/24")
        self.assertEqual(self.v(dir="out")["insights"], [])          # findings are about incoming connections

    def test_no_insights_when_quiet(self):
        self.assertEqual(self.v(dir="in")["insights"], [])          # 9 connections: nothing to point at


class History(Base):
    def test_point_and_persistence(self):
        p = conns._point(1000, self.snap["groups"])
        self.assertEqual((p["in"], p["out"], p["half"], p["ips"]), (9, 2, 3, 7))
        self.assertEqual(p["cc"]["DE"], 4)
        conns._add_history(dict(p, t=int(time.time())))
        conns._history.clear()
        conns._load_history()
        self.assertEqual(len(conns._history), 1)
        conns.set_history(False)
        self.assertFalse(conns.history_on())
        self.assertFalse(os.path.exists(conns._hist_path()))
        conns.set_history(True)
        self.assertTrue(conns.history_on())

    def test_old_points_dropped(self):
        old = {"t": int(time.time()) - conns.HISTORY - 10, "in": 1, "out": 0, "half": 0, "ips": 1, "cc": {}}
        with open(conns._hist_path(), "w") as f:
            json.dump([old], f)
        conns._load_history()
        self.assertEqual(len(conns._history), 0)

    def test_view_returns_history_only_when_asked(self):
        self.assertIsNone(conns.view({"dir": "in"})["history"])
        self.assertEqual(conns.view({"dir": "in", "hist": "1"})["history"], [])


class Reports(Base):
    def test_record_attack(self):
        got = []
        conns._on_report = got.append
        state = {"n": 0}

        def active():
            state["n"] += 1
            return False                       # the attack has ended by the first check
        t0 = time.time()
        conns.record_attack(active, t0, "pps")
        for _ in range(50):
            if conns.reports():
                break
            time.sleep(0.1)
        r = conns.report(int(t0))
        self.assertEqual((r["top_cc"], r["top_port"], r["conns"], r["half"]), ("DE", "443/tcp", 9, 3))
        self.assertTrue(r["ended"])
        self.assertEqual(got[0]["id"], int(t0))
        self.assertEqual([x["id"] for x in conns.view({"dir": "in"})["reports"]], [int(t0)])
        with self.assertRaises(ValueError):
            conns.report(12345)


class Detail(Base):
    def test_detail_and_ptr_timeout(self):
        real = conns.socket.gethostbyaddr

        def slow(ip):
            time.sleep(5)
            return ("never.example", [], [ip])
        conns.socket.gethostbyaddr = slow
        conns._ptr_cache.clear()
        try:
            t0 = time.time()
            d = conns.detail({"ip": "5.5.5.5"})
            self.assertLess(time.time() - t0, 3)       # a slow DNS server never blocks the page
        finally:
            conns.socket.gethostbyaddr = real
        self.assertEqual((d["cc"], d["summary"]["conns"], d["summary"]["half"]), ("DE", 3, 3))
        json.dumps(d)
        self.assertIsNone(d["ptr"])
        with self.assertRaises(ValueError):
            conns.detail({"ip": "1.2.3.4; rm -rf /"})


if __name__ == "__main__":
    unittest.main()
