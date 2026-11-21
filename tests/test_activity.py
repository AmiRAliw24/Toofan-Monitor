"""Request counting per address (defender/activity.py) and the connections view over a period (conns.view win=1h/24h).

Event lines are the ones `conntrack -E -o extended` prints; nothing runs conntrack here.
"""
import json
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "defender"))
import activity  # noqa: E402
import conns  # noqa: E402
import ipdb  # noqa: E402

HOST = "91.0.0.1"
LOCAL = frozenset({HOST, "172.17.0.1", "127.0.0.1", "::1"})


def new(src, dport, proto="tcp", dst=HOST, sport=40000):
    return (f"    [NEW] ipv4     2 {proto}      6 120 SYN_SENT src={src} dst={dst} sport={sport} dport={dport} [UNREPLIED] "
            f"src={dst} dst={src} sport={dport} dport={sport}")


def destroy(src, dport, sent=0, got=0, assured=True, dst=HOST, sport=40000):
    return (f"[DESTROY] ipv4     2 tcp      6 src={src} dst={dst} sport={sport} dport={dport} packets=3 bytes={sent} "
            f"src={dst} dst={src} sport={dport} dport={sport} packets=4 bytes={got} {'[ASSURED] ' if assured else ''}mark=0 use=1")


class Reset(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        activity._data = self.tmp
        activity._fine.clear()
        activity._coarse.clear()
        activity._state.update(since=int(time.time()) - 7200, running=True, error="", lost=0, events=0)

    def feed(self, lines, now=None):
        for line in lines:
            ev = activity.parse(line, LOCAL)
            if ev:
                activity.record(ev, now)


class Parse(Reset):
    def test_incoming(self):
        self.assertEqual(activity.parse(new("1.2.3.4", 443), LOCAL), ("in", "1.2.3.4", "443/tcp", 1, 0, 0, 0))

    def test_closed_with_bytes(self):
        # the remote sent 500 bytes and received 9000; the handshake completed
        self.assertEqual(activity.parse(destroy("1.2.3.4", 443, 500, 9000), LOCAL), ("in", "1.2.3.4", "443/tcp", 0, 500, 9000, 0))

    def test_never_completed(self):
        self.assertEqual(activity.parse(destroy("5.5.5.5", 22, assured=False), LOCAL)[6], 1)

    def test_outgoing(self):
        line = f"    [NEW] ipv4     2 tcp      6 120 SYN_SENT src={HOST} dst=9.9.9.9 sport=40000 dport=443 [UNREPLIED] src=9.9.9.9 dst={HOST} sport=443 dport=40000"
        self.assertEqual(activity.parse(line, LOCAL)[:3], ("out", "9.9.9.9", "443/tcp"))
        # a container masqueraded by the host: the reply goes back to the host's address
        line = f"    [NEW] ipv4     2 tcp      6 120 SYN_SENT src=172.18.0.5 dst=1.1.1.1 sport=5555 dport=443 [UNREPLIED] src=1.1.1.1 dst={HOST} sport=443 dport=5555"
        self.assertEqual(activity.parse(line, LOCAL)[:2], ("out", "1.1.1.1"))

    def test_ignored(self):
        self.assertIsNone(activity.parse("conntrack v1.4.9 (conntrack-tools): 5 flow events have been shown.", LOCAL))
        self.assertIsNone(activity.parse("garbage", LOCAL))
        self.assertIsNone(activity.parse(new("172.17.0.1", 80), LOCAL))         # between two of the server's own addresses
        self.assertIsNone(activity.parse(new("8.8.8.8", 53, dst="9.9.9.9"), LOCAL))   # neither side is this server
        icmp = f"    [NEW] ipv4     2 icmp     1 30 src=3.3.3.3 dst={HOST} type=8 code=0 id=1 [UNREPLIED] src={HOST} dst=3.3.3.3 type=0 code=0 id=1"
        self.assertEqual(activity.parse(icmp, LOCAL)[:3], ("in", "3.3.3.3", "icmp"))


class Counting(Reset):
    def test_counts_and_ports(self):
        self.feed([new("1.2.3.4", 443)] * 5 + [new("1.2.3.4", 80)] * 2 + [destroy("1.2.3.4", 443, 100, 2000)] * 3)
        e = activity.total(activity.buckets(3600, "in"))["1.2.3.4"]
        self.assertEqual(e[:4], [7, 300, 6000, 0])
        self.assertEqual(e[4], {"443/tcp": 5, "80/tcp": 2})
        self.assertEqual(activity.total(activity.buckets(86400, "in"))["1.2.3.4"][0], 7)    # the hourly buckets agree
        self.assertEqual(activity.total(activity.buckets(3600, "out")), {})

    def test_window(self):
        now = time.time()
        self.feed([new("1.2.3.4", 443)], now - 2 * 3600)        # two hours ago: in the day, not in the hour
        self.feed([new("1.2.3.4", 443)] * 2, now)
        self.assertEqual(activity.total(activity.buckets(3600, "in"))["1.2.3.4"][0], 2)
        self.assertEqual(activity.total(activity.buckets(86400, "in"))["1.2.3.4"][0], 3)

    def test_span_starts_with_counting(self):
        now = time.time()
        activity._state["since"] = int(now) - 30
        self.feed([new("1.2.3.4", 443)], now)
        (_s, length, _b), = activity.buckets(86400, "in")
        self.assertLessEqual(length, 31)        # not the whole hour: counting began 30 s ago

    def test_cap(self):
        old = activity.CAP
        activity.CAP = 3
        try:
            self.feed([new(f"10.9.0.{i}", 443).replace("src=10.9.0", "src=44.9.0") for i in range(10)])
        finally:
            activity.CAP = old
        t = activity.total(activity.buckets(3600, "in"))
        self.assertEqual(len(t), 4)
        self.assertEqual(t[activity.OTHER][0], 7)       # the rest is added up, nothing is lost

    def test_both_directions(self):
        out = f"    [NEW] ipv4     2 tcp      6 120 SYN_SENT src={HOST} dst=1.2.3.4 sport=40000 dport=443 [UNREPLIED] src=1.2.3.4 dst={HOST} sport=443 dport=40000"
        self.feed([new("1.2.3.4", 22), out])
        self.assertEqual(activity.total(activity.buckets(3600, "all"))["1.2.3.4"][0], 2)

    def test_save_load(self):
        self.feed([new("1.2.3.4", 443)] * 4)
        activity.save()
        activity._fine.clear()
        activity._coarse.clear()
        activity._load()
        self.assertEqual(activity.total(activity.buckets(3600, "in"))["1.2.3.4"][0], 4)
        with open(os.path.join(self.tmp, "conn_activity.json")) as f:
            json.load(f)

    def test_turn_off_forgets(self):
        self.feed([new("1.2.3.4", 443)])
        activity.save()
        activity.set_on(False)
        self.assertFalse(activity.on())
        self.assertEqual(activity.buckets(3600, "in"), [])
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "conn_activity.json")))
        activity.set_on(True)
        self.assertTrue(activity.on())

    def test_ip_detail(self):
        self.feed([new("1.2.3.4", 443)] * 3 + [destroy("1.2.3.4", 22, assured=False)])
        d = activity.ip_detail("1.2.3.4")
        self.assertEqual(d["h1"]["req"], 3)
        self.assertEqual(d["h24"]["failed"], 1)
        self.assertEqual(d["h24"]["ports"], [["443/tcp", 3]])
        self.assertEqual(sum(h[1] for h in d["hours"]), 3)
        self.assertIsNone(activity.ip_detail("9.9.9.9")["h1"])


GEO = {"1.2.3.4": "DE", "5.5.5.5": "US", "6.6.6.6": "IR"}


class View(Reset):
    """conns.view over a period: requests per address next to the connections open now."""
    def setUp(self):
        super().setUp()
        conns._data = self.tmp
        for x in (conns._history, conns._timeline, conns._first_seen, conns._geo_cache, conns._subnets):
            x.clear()
        self.orig = (conns.geo, conns.snapshot, ipdb.status, ipdb.ensure)
        conns.geo = lambda ip: (GEO.get(ip), 64500 if ip in GEO else None, "TEST-AS Example" if ip in GEO else None)
        ipdb.status = lambda data: {"ready": True, "state": "done"}
        ipdb.ensure = lambda data, force=False: None
        table = f"ipv4     2 tcp      6 300 ESTABLISHED src=6.6.6.6 dst={HOST} sport=1 dport=443 src={HOST} dst=6.6.6.6 sport=443 dport=1 [ASSURED] mark=0 use=1"
        groups, n, lb = conns._parse(table, LOCAL, {})
        snap = {"at": time.time(), "took": 0.01, "interval": 4.0, "groups": groups, "entries": n, "loopback": lb, "max": 1000, "truncated": False}
        conns.snapshot = lambda force=False: snap
        # 1.2.3.4: 60 requests to 443 and 20 to 22; 5.5.5.5: 30 attempts that never completed; 6.6.6.6: open now, 1 request
        self.feed([new("1.2.3.4", 443)] * 60 + [new("1.2.3.4", 22)] * 20 + [new("5.5.5.5", 22)] * 30
                  + [destroy("5.5.5.5", 22, assured=False)] * 30 + [new("6.6.6.6", 443)])

    def tearDown(self):
        conns.geo, conns.snapshot, ipdb.status, ipdb.ensure = self.orig

    def v(self, **q):
        out = conns.view(q)
        json.dumps(out)
        return out

    def test_window_rows(self):
        v = self.v(dir="in", win="1h")
        self.assertEqual(v["win"], "1h")
        rows = {r["ip"]: r for r in v["ips"]}
        self.assertEqual([r["ip"] for r in v["ips"]], ["1.2.3.4", "5.5.5.5", "6.6.6.6"])     # by requests
        self.assertEqual((rows["1.2.3.4"]["req"], rows["1.2.3.4"]["conns"]), (80, 0))
        self.assertEqual(rows["1.2.3.4"]["ports"], ["443/tcp", "22/tcp"])
        self.assertEqual((rows["5.5.5.5"]["req"], rows["5.5.5.5"]["failed"]), (30, 30))
        self.assertEqual((rows["6.6.6.6"]["req"], rows["6.6.6.6"]["conns"]), (1, 1))          # open now and counted
        self.assertEqual((v["act"]["req"], v["act"]["failed"], v["act"]["ips"]), (111, 30, 3))
        self.assertEqual(v["countries"][0], {"cc": "DE", "conns": 80, "half": 0, "ips": 1})
        self.assertEqual(sum(p["in"] for p in v["act"]["series"]), 111)
        self.assertEqual(v["summary"]["conns"], 1)                  # open connections stay what they are

    def test_now_keeps_open_order_with_last_hour(self):
        v = self.v(dir="in")
        self.assertEqual(v["win"], "now")
        self.assertEqual([r["ip"] for r in v["ips"]], ["6.6.6.6"])
        self.assertEqual(v["ips"][0]["req"], 1)
        self.assertEqual(v["countries"][0]["cc"], "IR")

    def test_window_filters(self):
        v = self.v(dir="in", win="24h", port="22")
        rows = {r["ip"]: r["req"] for r in v["ips"]}
        self.assertEqual(rows, {"1.2.3.4": 20, "5.5.5.5": 30})      # only the requests to that port
        self.assertEqual([p["port"] for p in v["ports"]], ["22"])
        self.assertEqual({r["ip"] for r in self.v(dir="in", win="1h", cc="US")["ips"]}, {"5.5.5.5"})
        self.assertEqual({r["ip"] for r in self.v(dir="in", win="1h", state="HALF")["ips"]}, {"5.5.5.5"})
        self.assertEqual({r["ip"] for r in self.v(dir="in", win="1h", q="iran", qcc="IR")["ips"]}, {"6.6.6.6"})

    def test_window_insights(self):
        # findings need some volume (100+): 1.2.3.4 makes 180 of 311 requests, 130 never completed
        self.feed([new("1.2.3.4", 443)] * 100 + [new("5.5.5.5", 22)] * 100 + [destroy("5.5.5.5", 22, assured=False)] * 100)
        kinds = {i["kind"] for i in self.v(dir="in", win="1h")["insights"]}
        self.assertIn("ip", kinds)              # 1.2.3.4 makes 72% of the requests
        self.assertIn("half", kinds)            # 27% never completed

    def test_counting_off(self):
        activity.set_on(False)
        v = self.v(dir="in", win="1h")
        self.assertEqual(v["win"], "now")
        self.assertFalse(v["act"]["counting"])
        self.assertEqual(v["ips"][0]["req"], 0)

    def test_bad_window(self):
        self.assertEqual(self.v(dir="in", win="7d")["win"], "now")

    def test_detail(self):
        conns._ptr_cache["1.2.3.4"] = None
        d = conns.detail({"ip": "1.2.3.4"})
        json.dumps(d)
        self.assertEqual(d["activity"]["h1"]["req"], 80)


if __name__ == "__main__":
    unittest.main()
