"""Traffic accounting (panel/traffic.py): exact, kept across reboots, per day in the viewer's time zone.

Three days of readings every 30 s at a known rate, with a reboot (and 10 minutes down), two hours
without readings, a tunnel whose counter starts again, the node-exporter container's own eth0 that
must never be mixed in, and node-net coming up after node-exporter. The counted bytes must equal the
truth exactly.
"""
import calendar
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "panel"))
os.environ.setdefault("DATA_DIR", tempfile.mkdtemp())
import traffic  # noqa: E402

RX, TX, WG = 1000, 500, 7
T0 = calendar.timegm((2026, 10, 30, 20, 0, 0))
END = T0 + 3 * 86400
SHUTDOWN = T0 + int(1.5 * 86400) + 20          # 20 s after a reading: those 20 s cannot be known
BOOT2 = SHUTDOWN + 600
GAP = (T0 + int(2.2 * 86400), T0 + int(2.2 * 86400) + 7200)
WG_RESET = T0 + int(2.6 * 86400)
BOOT1 = T0 - 3600
NODE_NET_LATE = BOOT2 + 20
LOST = 20


def samples():
    s = {k: [] for k in [("node-net", "eth0", 0), ("node-net", "eth0", 1), ("node-net", "wg0", 0), ("node-net", "wg0", 1),
                         ("node", "", "boot"), ("node", "eth0", 0), ("node", "eth0", 1)]}
    for t in range(T0, END + 1, 30):
        if SHUTDOWN < t < BOOT2 or GAP[0] < t < GAP[1]:
            continue
        up = t - (BOOT1 if t <= SHUTDOWN else BOOT2)
        s[("node", "eth0", 0)].append((t, up * 3))            # the container's own interface
        s[("node", "eth0", 1)].append((t, up * 2))
        s[("node", "", "boot")].append((t + 45 if t > BOOT2 else t, BOOT1 if t <= SHUTDOWN else BOOT2))   # scraped later
        if BOOT2 <= t < NODE_NET_LATE:
            continue
        s[("node-net", "eth0", 0)].append((t, up * RX))
        s[("node-net", "eth0", 1)].append((t, up * TX))
        wg = (t - WG_RESET) * WG if t >= WG_RESET else up * WG
        s[("node-net", "wg0", 0)].append((t, wg))
        s[("node-net", "wg0", 1)].append((t, wg))
    return s


class Traffic(unittest.TestCase):
    def setUp(self):
        self.s = samples()
        self.real = (traffic._matrix, traffic._instant, traffic._devices_info, traffic.node_instances, traffic.time.time)
        traffic._ledger = {"version": 4, "tz": 0, "servers": {}}
        traffic.FILE = traffic.Path(tempfile.mkdtemp()) / "traffic.json"

        def matrix(expr, span, at):
            k = 0 if "receive" in expr else 1 if "transmit" in expr else "boot"
            out = {}
            for (job, dev, kk), pts in self.s.items():
                if kk == k:
                    sel = [(t, v) for t, v in pts if at - span < t <= at]
                    if sel:
                        out[(job, dev)] = sel
            return out
        traffic._matrix = matrix
        traffic._instant = lambda expr, at=None: float(T0) if expr.startswith("min(min_over_time(timestamp(") else None
        traffic._devices_info = lambda inst: {"eth0": {"physical": True}, "wg0": {"physical": False}}
        traffic.node_instances = lambda: ["srv"]
        traffic.time.time = lambda: END + 5

    def tearDown(self):
        traffic._matrix, traffic._instant, traffic._devices_info, traffic.node_instances, traffic.time.time = self.real

    def total(self, dev, k):
        return sum(v[k] for v in traffic._ledger["servers"]["srv"]["b"].get(dev, {}).values())

    def test_exact_totals(self):
        traffic.sync("srv", END + 5)
        first = self.s[("node-net", "eth0", 0)][0][0]
        want = ((SHUTDOWN - first) + (END - BOOT2) - LOST) * RX
        self.assertEqual(self.total("eth0", 0), want)
        self.assertEqual(self.total("eth0", 1), want // 2)
        self.assertTrue(all(not k.startswith("node|") for k in traffic._ledger["servers"]["srv"]["last"]))

    def test_days_in_tehran(self):
        traffic.sync("srv", END + 5)
        tz = -210
        first = self.s[("node-net", "eth0", 0)][0][0]
        truth = {}
        for t in range(first + 1, END + 1):
            if SHUTDOWN - LOST < t <= BOOT2:
                continue
            k = traffic._day_key(t - 1, tz)
            truth[k] = truth.get(k, 0) + RX
        r = traffic.api_traffic({"instance": "srv", "tz": str(tz)})
        got = {f"{r['prev']['key']}-{d['day']:02d}": d["rx"] for d in r["prev"]["daily"] if d["rx"]}
        got.update({f"{r['month']['key']}-{d['day']:02d}": d["rx"] for d in r["month"]["daily"] if d["rx"]})
        for k, v in truth.items():
            self.assertLessEqual(abs(got.get(k, 0) - v), 30 * RX, k)
        self.assertEqual([d["name"] for d in r["devices"] if d["counted"]], ["eth0"])     # the tunnel is not counted
        self.assertEqual(r["boot"]["rx"], (END - BOOT2) * RX)
        self.assertEqual(r["alltime"]["rx"], self.total("eth0", 0))

    def test_reload_does_not_double_count(self):
        traffic.sync("srv", END + 5)
        before = self.total("eth0", 0)
        traffic._save(force=True)
        traffic._ledger = traffic._load()
        traffic.sync("srv", END + 5)
        self.assertEqual(self.total("eth0", 0), before)

    def test_choose_cards(self):
        traffic.sync("srv", END + 5)
        traffic.post_devices({"instance": "srv", "devices": ["eth0", "wg0"]})
        r = traffic.api_traffic({"instance": "srv", "tz": "0"})
        self.assertFalse(r["auto"])
        self.assertEqual(r["alltime"]["rx"], self.total("eth0", 0) + self.total("wg0", 0))
        with self.assertRaises(ValueError):
            traffic.post_devices({"instance": "srv", "devices": ["eth0; rm"]})
        traffic.post_devices({"instance": "srv", "devices": None})
        self.assertTrue(traffic.api_traffic({"instance": "srv", "tz": "0"})["auto"])


if __name__ == "__main__":
    unittest.main()
