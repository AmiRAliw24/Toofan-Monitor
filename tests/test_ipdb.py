"""The offline country / network database (defender/ipdb.py): building it and looking addresses up.

The downloads are replaced by small files with the same format as the real ones.
"""
import gzip
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
ASN_CSV4 = '1.0.0.0,1.0.0.255,13335,"Cloudflare, Inc."\n91.107.0.0,91.107.255.255,24940,Hetzner Online GmbH\n'


class Build(unittest.TestCase):
    def setUp(self):
        self.data = tempfile.mkdtemp()
        self.real = sources.fetch_file
        ipdb._db = None
        self.fail_asn = False

        def fake(urls, dest, check=None, **kw):
            u = urls[0]
            if "dbip-country" in u:
                open(dest, "w").write(COUNTRY)
            elif "iptoasn" in u:
                if self.fail_asn:
                    raise ValueError("blocked")
                with gzip.open(dest, "wt") as f:
                    f.write(ASN)
            elif "asn-ipv4" in u:
                open(dest, "w").write(ASN_CSV4)
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
        self.assertEqual(m["rows"], {"country4": 4, "asn4": 3, "asn6": 2, "networks": 4})   # "Not routed" (AS0) is left out
        L = lambda ip: ipdb.lookup(self.data, ip)   # noqa: E731
        self.assertEqual(L("1.0.0.0"), {"cc": "AU", "asn": 13335, "org": "CLOUDFLARENET - Cloudflare, Inc."})
        self.assertEqual(L("1.0.0.255")["cc"], "AU")                       # last address of a range
        self.assertEqual(L("1.0.1.0"), {"cc": "CN", "asn": None, "org": None})
        self.assertEqual(L("5.160.10.20")["asn"], 42337)
        self.assertEqual(L("91.107.168.176"), {"cc": "DE", "asn": 24940, "org": "HETZNER-AS Hetzner Online GmbH"})
        self.assertEqual(L("9.9.9.9"), {"cc": None, "asn": None, "org": None})   # in a gap
        self.assertEqual(L("2a01:4f8:c010:5303::1")["cc"], "DE")
        self.assertEqual(L("2a01:4f9::1")["asn"], None)                    # just after the range
        self.assertEqual(L("2a02:1::5"), {"cc": None, "asn": 3320, "org": "DTAG Deutsche Telekom AG"})
        self.assertEqual(L("not an address"), {"cc": None, "asn": None, "org": None})
        self.assertTrue(ipdb.status(self.data)["ready"])

    def test_fallback_source(self):
        self.fail_asn = True                     # iptoasn.com blocked: the jsDelivr CSV is used for networks
        ipdb._build(self.data)
        self.assertEqual(ipdb.lookup(self.data, "1.0.0.7")["org"], "Cloudflare, Inc.")
        self.assertEqual(ipdb.lookup(self.data, "1.0.0.7")["cc"], "AU")
        self.assertEqual(ipdb.meta(self.data)["rows"]["asn6"], 0)

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
