"""Builds the nftables ruleset of the Defender from its configuration.

Everything lives in one table, `inet defender`, with one base chain on the prerouting hook at
priority -150: after conntrack (-200), before Docker's DNAT (-100). So it sees the original
destination port of traffic for the host *and* for published container ports, and it can only ever
drop packets: other tables (Docker, fail2ban, ufw) keep working exactly as before.

Order of the chain (first match wins):
  loopback / Docker bridges / trusted interfaces  -> accept   (never touched)
  allowlist                                        -> accept
  blocklist, temporary bans                        -> drop
  established / related                            -> accept   (only NEW traffic is limited below)
  invalid state, impossible TCP flag combinations  -> drop
  SSH: too many new connections per source         -> ban
  strict mode: TCP/UDP to a port that is not open  -> drop
  per source: SYN rate, new connection rate, concurrent connections, new UDP flows, ping rate
                                                   -> drop (and ban at 3x the limit)
"""
import ipaddress

PROFILES = {
    # per source IP. syn/conn/udp/icmp: packets or new flows per second (burst = 2x). conc: open TCP connections.
    "normal": {"syn": 60, "conn": 100, "conc": 400, "udp": 300, "icmp": 20, "ban": 15},
    "strict": {"syn": 25, "conn": 40, "conc": 150, "udp": 120, "icmp": 6, "ban": 30},
    "attack": {"syn": 10, "conn": 15, "conc": 60, "udp": 40, "icmp": 2, "ban": 60},
}
LIMIT_KEYS = {"syn": (1, 100000), "conn": (1, 100000), "conc": (5, 1000000), "udp": (1, 1000000),
              "icmp": (1, 10000), "ban": (1, 10080)}
AUTOBAN_FACTOR = 3        # a source going this many times over a limit is banned, not just slowed down
SSH_NEW_PER_MIN = 12      # new SSH connections per source and minute before the source is banned
COUNTERS = ("allow", "block", "ban", "geo", "invalid", "badflags", "ssh", "policy", "syn", "conn", "conc",
            "udp", "icmp", "autoban", "new", "all")
ALWAYS_TRUSTED = ("lo", "docker*", "br-*", "veth*")
# Cloudflare's edge (https://www.cloudflare.com/ips/). A site or proxy behind Cloudflare receives all of its
# visitors from these addresses, so per-source limits would hit thousands of users at once.
CDN4 = ("173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18", "108.162.192.0/18",
        "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
        "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22")
CDN6 = ("2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32")


def ports_expr(items):
    """['22', '8000-8100'] -> '{ 22, 8000-8100 }' (nft set syntax)."""
    return "{ " + ", ".join(items) + " }"


def iface_rules(ifaces):
    out = []
    for name in list(ALWAYS_TRUSTED) + [i for i in ifaces if i not in ALWAYS_TRUSTED]:
        out.append(f'        iifname "{name}" accept')
    return out


def split_ips(items):
    v4, v6 = [], []
    for it in items:
        net = ipaddress.ip_network(it, strict=False)
        (v4 if net.version == 4 else v6).append(str(net) if net.num_addresses > 1 else str(net.network_address))
    return v4, v6


def set_block(name, family, items, extra=""):
    elements = f" elements = {{ {', '.join(items)} }};" if items else ""
    return f"    set {name} {{ type {family}_addr; flags interval;{extra}{elements} }}"


def build(cfg, limits, ban_elements=None, ssh_ports=(), panel_ports=(), geo4=(), geo6=()):
    """The complete ruleset as text, ready for `nft -f` (an atomic replace of the table)."""
    fw = cfg["firewall"]
    allow4, allow6 = split_ips(a["ip"] for a in cfg["allow"])
    block4, block6 = split_ips(b["ip"] for b in cfg["block"] if not b.get("until"))
    ban_elements = ban_elements or {"ban4": [], "ban6": []}
    ban_t = f"{int(limits['ban'])}m"
    lines = ["table inet defender", "delete table inet defender", "table inet defender {"]
    lines += [f"    counter c_{c} {{ }}" for c in COUNTERS]
    lines += [set_block("allow4", "ipv4", allow4), set_block("allow6", "ipv6", allow6),
              set_block("block4", "ipv4", block4), set_block("block6", "ipv6", block6),
              set_block("cdn4", "ipv4", list(CDN4) if cfg.get("trust_cdn", True) else []),
              set_block("cdn6", "ipv6", list(CDN6) if cfg.get("trust_cdn", True) else []),
              set_block("geo4", "ipv4", list(geo4), " auto-merge;"), set_block("geo6", "ipv6", list(geo6), " auto-merge;")]
    for fam, name in (("ipv4", "ban4"), ("ipv6", "ban6")):
        els = ban_elements.get(name) or []
        body = f" elements = {{ {', '.join(f'{ip} timeout {int(secs)}s' for ip, secs in els)} }};" if els else ""
        lines.append(f"    set {name} {{ type {fam}_addr; flags timeout; timeout {ban_t}; size 262144;{body} }}")
    for meter in ("syn", "synb", "conn", "connb", "udp", "udpb", "icmp", "icmpb", "ssh"):
        for fam, suffix in (("ipv4", "4"), ("ipv6", "6")):
            lines.append(f"    set m_{meter}{suffix} {{ type {fam}_addr; flags dynamic, timeout; timeout 2m; size 262144; }}")
    for fam, suffix in (("ipv4", "4"), ("ipv6", "6")):
        lines.append(f"    set m_conc{suffix} {{ type {fam}_addr; flags dynamic; size 262144; }}")

    ssh = sorted({str(p) for p in ssh_ports}) or ["22"]
    open_tcp = sorted({str(p) for p in ssh} | {str(p) for p in panel_ports} |
                      {p["port"] for p in fw["ports"] if p["proto"] in ("tcp", "both") and not p.get("from")}, key=_port_key)
    open_udp = sorted({p["port"] for p in fw["ports"] if p["proto"] in ("udp", "both") and not p.get("from")}, key=_port_key)

    r = ["", "    chain pre {", "        type filter hook prerouting priority -150; policy accept;"]
    r += iface_rules(fw.get("trusted_ifaces", []))
    r += ["        ip saddr @allow4 counter name c_allow accept",
          "        ip6 saddr @allow6 counter name c_allow accept",
          "        ip saddr @block4 counter name c_block drop",
          "        ip6 saddr @block6 counter name c_block drop",
          "        ip saddr @ban4 counter name c_ban drop",
          "        ip6 saddr @ban6 counter name c_ban drop",
          "        ip saddr @cdn4 accept",   # blocklist and bans above still apply to the CDN
          "        ip6 saddr @cdn6 accept",
          "        ip saddr @geo4 counter name c_geo drop",    # blocked countries (allowlist, admins, CDN pass above)
          "        ip6 saddr @geo6 counter name c_geo drop",
          "        counter name c_all",
          "        ct state established,related accept"]
    if cfg["ddos"].get("drop_invalid", True):
        r.append("        ct state invalid counter name c_invalid drop")
    if cfg["ddos"].get("bad_flags", True):
        for flags in ("& (fin|syn|rst|psh|ack|urg) == 0x0", "& (fin|syn) == fin|syn", "& (syn|rst) == syn|rst",
                      "& (fin|rst) == fin|rst", "& (fin|psh|urg) == fin|psh|urg", "& (fin|ack) == fin"):
            r.append(f"        tcp flags {flags} counter name c_badflags drop")
    r.append("        counter name c_new")
    if cfg["ssh_guard"].get("l4", True):
        for fam, suffix in (("ip", "4"), ("ip6", "6")):
            r.append(f"        tcp dport {ports_expr(ssh)} tcp flags syn update @m_ssh{suffix} {{ {fam} saddr limit rate over {SSH_NEW_PER_MIN}/minute burst {SSH_NEW_PER_MIN} packets }} "
                     f"add @ban{suffix} {{ {fam} saddr timeout 60m }} counter name c_ssh drop")
    # Ports with a source restriction ("only from 1.2.3.0/24") are accepted for that source only.
    for p in fw["ports"]:
        if p.get("from"):
            fam = "ip6" if ":" in p["from"] else "ip"
            for proto in (("tcp", "udp") if p["proto"] == "both" else (p["proto"],)):
                r.append(f"        {fam} saddr {p['from']} {proto} dport {p['port']} accept")
    if fw.get("mode") == "strict":
        r.append(f"        tcp dport != {ports_expr(open_tcp)} counter name c_policy drop")
        r.append(f"        meta l4proto udp udp dport != {ports_expr(open_udp)} counter name c_policy drop" if open_udp
                 else "        meta l4proto udp counter name c_policy drop")
    L = limits
    for fam, suffix, icmp in (("ip", "4", "icmp type echo-request"), ("ip6", "6", "icmpv6 type echo-request")):
        r += [
            f"        tcp flags & (syn|ack) == syn update @m_synb{suffix} {{ {fam} saddr limit rate over {L['syn'] * AUTOBAN_FACTOR}/second burst {L['syn'] * AUTOBAN_FACTOR * 2} packets }} add @ban{suffix} {{ {fam} saddr }} counter name c_autoban drop",
            f"        tcp flags & (syn|ack) == syn update @m_syn{suffix} {{ {fam} saddr limit rate over {L['syn']}/second burst {L['syn'] * 2} packets }} counter name c_syn drop",
            f"        meta nfproto {'ipv4' if suffix == '4' else 'ipv6'} ct state new update @m_connb{suffix} {{ {fam} saddr limit rate over {L['conn'] * AUTOBAN_FACTOR}/second burst {L['conn'] * AUTOBAN_FACTOR * 2} packets }} add @ban{suffix} {{ {fam} saddr }} counter name c_autoban drop",
            f"        meta nfproto {'ipv4' if suffix == '4' else 'ipv6'} ct state new update @m_conn{suffix} {{ {fam} saddr limit rate over {L['conn']}/second burst {L['conn'] * 2} packets }} counter name c_conn drop",
            f"        meta l4proto tcp add @m_conc{suffix} {{ {fam} saddr ct count over {L['conc']} }} counter name c_conc drop",
            f"        meta l4proto udp update @m_udp{suffix} {{ {fam} saddr limit rate over {L['udp']}/second burst {L['udp'] * 2} packets }} counter name c_udp drop",
            f"        {icmp} update @m_icmp{suffix} {{ {fam} saddr limit rate over {L['icmp']}/second burst {L['icmp'] * 2} packets }} counter name c_icmp drop",
        ]
    r.append("    }")
    lines += r
    lines.append("}")
    return "\n".join(lines) + "\n"


def _port_key(p):
    return int(str(p).split("-")[0])
