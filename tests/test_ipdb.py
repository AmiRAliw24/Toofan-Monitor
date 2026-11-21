"""The offline country / network database (defender/ipdb.py): building it and looking addresses up.

The downloads are replaced by small files with the same format as the real ones.
"""
import gzip
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "defender"))
import ipdb  # noqa: E402
import sources  # noqa: E402

COUNTRY = "1.0.0.0,1.0.0.255,AU\n1.0.1.0,1.0.3.255,CN\n5.160.0.0,5.160.255.255,IR\n91.107.0.0,91.107.255.255,DE\n"
ASN = ("1.0.0.0\t1.0.0.255\t13335\tUS\tCLOUDFLARENET - Cloudflare, Inc.\n"
       "1.0.1.0\t1.0.3.255\t0\tNone\tNot routed\n"
       "5.160.0.0\t5.160.255.255\t42337\tIR\tRESPINA-AS Respina Networks & Beyond PJSC\n"
       "91.107.0.0\t91.107.255.255\t24940\tDE\tHETZNER-AS Hetzner Online GmbH\n"
       "2a01:4f8::\t2a01:4f8:ffff:ffff:ffff:ffff:ffff:ffff\t24940\tDE\tHETZNER-AS Hetzner Online GmbH\n"
       "2a02:1::\t2a02:1:ffff:ffff:ffff:ffff:ffff:ffff\t3320\t\tDTAG Deutsche Telekom AG\n")
COUNTRY6 = ("2a01:4f8::,2a01:4f8:ffff:ffff:ffff:ffff:ffff:ffff,DE\n"
            "2a02:1::,2a02:1:ffff:ffff:ffff:ffff:ffff:ffff,DE\n"
            "2a03:ef40::,2a03:ef47:ffff:ffff:ffff:ffff:ffff:ffff,IR\n"
            "bad line\n")
ASN_CSV4 = '1.0.0.0,1.0.0.255,13335,"Cloudflare, Inc."\n91.107.0.0,91.107.255.255,24940,Hetzner Online GmbH\n'


def _write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


class Build(unittest.TestCase):
    def setUp(self):
        self.data = tempfile.mkdtemp()
        self.real = sources.fetch_file
        ipdb._db = None
        self.fail_asn = False
        self.blocked = ()                   # sources that "cannot be reached"
        self.urls = {}

        def fake(urls, dest, check=None, **kw):
            urls = [u for u in urls if not any(b in u for b in self.blocked)]
            if not urls:
                raise ValueError("all blocked")
            u = urls[0]
            self.urls[os.path.basename(dest)] = u
            if "country-ipv4" in u:
                _write(dest, COUNTRY)
            elif "country-ipv6" in u:
                _write(dest, COUNTRY6)
            elif "iptoasn.com" in u:
                if self.fail_asn:
                    raise ValueError("blocked")
                with gzip.open(dest, "wt") as f:
                    f.write(ASN)
            elif "asn-ipv4" in u:
                _write(dest, ASN_CSV4)
            else:
                raise ValueError("no such source")
            return u
        sources.fetch_file = fake

    def tearDown(self):
        sources.fetch_file = self.real
        ipdb._db = None
        shutil.rmtree(self.data, ignore_errors=True)

    def test_lookups(self):
        ipdb._build(self.data)
        m = ipdb.meta(self.data)
        self.assertEqual(m["rows"], {"country4": 4, "country6": 3, "asn4": 3, "asn6": 2, "networks": 4})
        self.assertEqual(m["v"], ipdb.VERSION)   # "Not routed" (AS0) is left out
        L = lambda ip: ipdb.lookup(self.data, ip)   # noqa: E731
        self.assertEqual(L("1.0.0.0"), {"cc": "AU", "asn": 13335, "org": "CLOUDFLARENET - Cloudflare, Inc."})
        self.assertEqual(L("1.0.0.255")["cc"], "AU")                       # last address of a range
        self.assertEqual(L("1.0.1.0"), {"cc": "CN", "asn": None, "org": None})
        self.assertEqual(L("5.160.10.20")["asn"], 42337)
        self.assertEqual(L("91.107.168.176"), {"cc": "DE", "asn": 24940, "org": "HETZNER-AS Hetzner Online GmbH"})
        self.assertEqual(L("9.9.9.9"), {"cc": None, "asn": None, "org": None})   # in a gap
        self.assertEqual(L("2a01:4f8:c010:5303::1")["cc"], "DE")
        self.assertEqual(L("2a01:4f9::1")["asn"], None)                    # just after the range
        self.assertEqual(L("2a02:1::5"), {"cc": "DE", "asn": 3320, "org": "DTAG Deutsche Telekom AG"})   # from the IPv6 country table
        self.assertEqual(L("2a03:ef42:1:2::9"), {"cc": "IR", "asn": None, "org": None})       # a country, no network
        self.assertEqual(L("::ffff:5.160.10.20")["cc"], "IR")                                # IPv4-mapped
        self.assertEqual(L("2002:5b6b:a8b0::1"), L("91.107.168.176"))                         # 6to4 of 91.107.168.176
        self.assertEqual(L("not an address"), {"cc": None, "asn": None, "org": None})
        self.assertTrue(ipdb.status(self.data)["ready"])

    def test_fallback_source(self):
        self.fail_asn = True                     # iptoasn.com blocked: the jsDelivr CSV is used for networks
        ipdb._build(self.data)
        self.assertEqual(ipdb.lookup(self.data, "1.0.0.7")["org"], "Cloudflare, Inc.")
        self.assertEqual(ipdb.lookup(self.data, "1.0.0.7")["cc"], "AU")
        self.assertEqual(ipdb.meta(self.data)["rows"]["asn6"], 0)

    def test_blocked_sources(self):
        # DB-IP and the geo-whois IPv6 file blocked: the next alternative of the same format is used
        self.blocked = ("dbip-country", "geo-whois-asn-country", "iptoasn.com")
        ipdb._build(self.data)
        self.assertIn("iptoasn-country-ipv4", self.urls["country4.csv"])
        self.assertIn("iptoasn-country-ipv6", self.urls["country6.csv"])
        self.assertEqual(ipdb.lookup(self.data, "2a03:ef40::1")["cc"], "IR")
        self.assertEqual(ipdb.lookup(self.data, "91.107.1.1")["cc"], "DE")

    def test_no_ipv6_countries(self):
        self.blocked = ("country-ipv6",)        # still built: IPv6 gets the network's country
        ipdb._build(self.data)
        self.assertEqual(ipdb.meta(self.data)["rows"]["country6"], 0)
        self.assertEqual(ipdb.lookup(self.data, "2a01:4f8::1")["cc"], "DE")
        self.assertEqual(ipdb.lookup(self.data, "2a02:1::5")["cc"], None)

    def test_no_ipv4_countries(self):
        self.blocked = ("country-ipv4",)
        with self.assertRaises(ValueError):
            ipdb._build(self.data)

    def test_old_tables(self):
        # tables of version 1 (no IPv6 countries): still used, and rebuilt in the background
        ipdb._build(self.data)
        d = os.path.join(self.data, "ipdb")
        for n in ("c6s", "c6e", "c6c"):
            os.unlink(os.path.join(d, n))
        m = ipdb.meta(self.data)
        del m["v"]
        with open(os.path.join(d, "meta.json"), "w") as f:
            json.dump(m, f)
        ipdb._db = None
        self.assertEqual(ipdb.lookup(self.data, "2a01:4f8::1")["cc"], "DE")
        started = []
        real = ipdb.threading.Thread
        ipdb.threading.Thread = lambda target, daemon: type("T", (), {"start": lambda self: started.append(1)})()
        try:
            ipdb.ensure(self.data)
        finally:
            ipdb.threading.Thread = real
        self.assertEqual(started, [1])

    def test_not_ready(self):
        self.assertEqual(ipdb.lookup(self.data, "1.0.0.1"), {"cc": None, "asn": None, "org": None})
        self.assertFalse(ipdb.status(self.data)["ready"])

    def test_unload(self):
        ipdb._build(self.data)
        ipdb.lookup(self.data, "1.0.0.1")
        self.assertIsNotNone(ipdb._db)
        ipdb._used -= ipdb.IDLE_UNLOAD + 1
        ipdb.unload_if_idle()
        self.assertIsNone(ipdb._db)
        self.assertEqual(ipdb.lookup(self.data, "1.0.0.1")["cc"], "AU")    # loads again on the next lookup


if __name__ == "__main__":
    unittest.main()
