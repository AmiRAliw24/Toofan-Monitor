// Firewall > Connections: who is connected to this server, from which country and network, to which port
// and service, live. Data comes from the defender agent (/api/defender/conns); this file only draws it.
(() => {
  "use strict";
  const P = window.Panel;
  if (!P) return;
  const { t, esc, nf, num, fmtBytes, ago, icon, api, post, act, toast, openDialog, confirmBox, pill } = P;

  P.addIcons({
    pause: '<rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/>',
    "arrow-in": '<path d="M4 12h12M11 7l5 5-5 5"/><path d="M20 4v16"/>',
    "arrow-out": '<path d="M8 12h12M15 7l5 5-5 5"/><path d="M4 4v16"/>',
    "arrow-both": '<path d="M7 7 3 11l4 4M17 9l4 4-4 4M3 11h12M9 13h12"/>',
    filter: '<path d="M3 5h18l-7 8v6l-4 2v-8z"/>',
    pin: '<path d="M12 22s7-6.2 7-12a7 7 0 1 0-14 0c0 5.8 7 12 7 12z"/><circle cx="12" cy="10" r="2.5"/>',
    link: '<path d="M10 14a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1"/><path d="M14 10a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1"/>',
    report: '<path d="M6 3h9l4 4v14H6z"/><path d="M14 3v5h5M9 13h7M9 17h5"/>',
  });

  // ---------------------------------------------------------------- strings
  const EN = {
    df_t_conns: "Connections", cx_n_ips: "{n} IPs",
    df_e_attack_sources: "Attack sources: {cc} sent {pct}% of {conns} incoming connections, most to {port}",
    df_e_bulk_ban: "{n} addresses banned from the connections page", df_e_conn_acct: "Per-connection traffic counting: {state}", df_on: "on", df_off: "off",
    cx_live30: "Live (30 min)", cx_h48: "48 hours", cx_hist_empty: "The history fills up by itself: a point every 5 minutes, also when this page is closed.",
    cx_hist_off: "Background history is off.", cx_hist: "Keep a 48-hour history", cx_hist_sub: "Every 5 minutes, also when this page is closed, notes where incoming connections come from (about 0.3% of one core).",
    cx_sel: "{n} selected", cx_sel_all: "Select all on this page", cx_sel_clear: "Clear selection", cx_ban_sel: "Ban {d}", cx_block_sel: "Block permanently",
    cx_bulk_q: "Ban {n} addresses for {d}?", cx_bulk_perm_q: "Add {n} addresses to the permanent blocklist?", cx_bulk_done: "{n} banned", cx_bulk_skip: "{n} skipped (yours, allowlisted or invalid)",
    cx_csv: "CSV", cx_csv_t: "Download as CSV (opens in Excel)", cx_sort: "Sort", cx_ptr: "Host name", cx_threat_lists: "Threat lists", cx_kbd: "Press / to search",
    cx_program: "program", cx_c_prog: "Program / service",
    cx_title: "Live connections", cx_sub: "Every connection to and from this server right now: who (address, country, network), to what (port, service, container) and in which state. Click anything to filter by it.",
    cx_in: "Incoming", cx_out: "Outgoing", cx_all: "All", cx_int: "Internal",
    cx_live: "Live · every {s}", cx_paused: "Paused", cx_pause: "Pause", cx_resume: "Resume", cx_read: "table read in {s}",
    cx_search: "Search address, country, network, port, service...", cx_proto: "Protocol", cx_state: "State", cx_any: "Any",
    cx_half_state: "Half-open (SYN flood sign)", cx_clear: "Clear filters",
    cx_f_cc: "Country", cx_f_port: "Port", cx_f_ip: "Address", cx_f_asn: "Network",
    cx_k_conns: "Connections", cx_k_ips: "Addresses", cx_k_cc: "Countries", cx_k_asn: "Networks", cx_k_half: "Half-open", cx_k_bytes: "Traffic (these connections)",
    cx_k_table: "Kernel table: {n} of {max} entries", cx_bytes_off: "Per-connection traffic is off", cx_bytes_on: "Turn on",
    cx_world: "Where they come from", cx_world_out: "Where this server connects to", cx_countries: "Countries",
    cx_ports: "Ports and services", cx_ports_out: "Remote ports", cx_asns: "Networks (providers)", cx_subnets: "Subnets", cx_ips: "Addresses",
    cx_rows: "All connections", cx_rows_sub: "Identical connections (same address, port and state) are shown once with their count.",
    cx_more: "Show more", cx_less: "Show less", cx_none: "No connections match.", cx_none_in: "Nobody is connected to this server right now.",
    cx_c_ip: "Address", cx_c_where: "Location", cx_c_net: "Network", cx_c_conns: "Connections", cx_c_ports: "Ports", cx_c_state: "State", cx_c_first: "Seen since",
    cx_c_dir: "", cx_c_proto: "Protocol", cx_c_to: "To", cx_c_from: "From", cx_c_n: "Count", cx_c_bytes: "Traffic", cx_c_ttl: "Expires in", cx_c_port: "Port", cx_c_svc: "Service",
    cx_c_cc: "Countries", cx_c_target: "Forwarded to", cx_c_net2: "Network", cx_c_ips: "Addresses",
    cx_trend: "Incoming connections over time", cx_trend_sub: "Since this page was opened. The busiest countries are drawn separately.", cx_trend_total: "All incoming", cx_trend_half: "Half-open",
    cx_lan: "Local network", cx_unknown: "Unknown",
    cx_ins_country: "{share} of incoming connections come from {cc} ({ips} addresses).",
    cx_ins_half: "{share} of incoming connections are half-open ({n}): a typical sign of a SYN flood.",
    cx_ins_subnet: "{share} of incoming connections come from one subnet, {net} ({ips} addresses).",
    cx_ins_ip: "One address holds {share} of incoming connections: {ip} ({n}).",
    cx_ins_asn: "{share} of incoming connections come from one network: {org}.",
    cx_attack: "An attack is in progress. The busiest sources are shown below; a report is being recorded.",
    cx_show_only: "Show only these", cx_block_cc: "Block {cc}", cx_block_net: "Block this subnet", cx_ban: "Ban 1 hour", cx_details: "Details",
    cx_banned: "banned", cx_blocked: "blocklisted", cx_allowed: "allowlisted", cx_threat: "on a threat list",
    cx_block_cc_q: "Block all incoming traffic from {cc}? About {n} connections from {ips} addresses are open now. You (logged-in and allowlisted addresses) are never blocked, and the change is tested for 60 seconds first.",
    cx_block_cc_btn: "Block country", cx_block_cc_done: "{cc} is blocked", cx_rule_name: "Blocked countries", cx_off_note: "Protection is off: the rule is saved and works once protection is turned on.",
    cx_block_net_q: "Add {net} to the blocklist? Every address in it is blocked until you remove it.", cx_block_net_done: "{net} is blocked",
    cx_ban_done: "{ip} is banned", cx_allow_done: "{ip} is allowlisted", cx_copied: "Copied",
    cx_ip_title: "Address {ip}", cx_ip_conns: "Its connections", cx_ip_ban: "Ban for", cx_ip_block: "Block permanently", cx_ip_allow: "Allowlist", cx_ip_copy: "Copy address",
    cx_ip_ext: "Look it up", cx_ip_first: "First seen {ago}", cx_ip_subnet: "Subnet",
    cx_m10: "10 minutes", cx_h1: "1 hour", cx_h24: "1 day", cx_d7: "7 days",
    cx_reports: "Attack reports", cx_reports_sub: "When an attack is detected, the busiest moment of its incoming connections is saved here: where it came from and what it hit.",
    cx_reports_none: "No attacks recorded yet.", cx_report_title: "Attack of {date}", cx_report_ongoing: "ongoing", cx_report_lasted: "lasted {d}",
    cx_report_peak: "At its peak: {n} incoming connections, {half} half-open, from {ips} addresses.",
    cx_db_loading: "Downloading the country and network database (about 22 MB, once a month). Addresses show without their country until it is ready.",
    cx_db_error: "The country and network database could not be downloaded: {e}", cx_db_retry: "Try again",
    cx_db_ok: "Locations: DB-IP Lite (CC BY 4.0) and iptoasn.com, updated {date}. Map: svg-maps (CC BY 4.0).",
    cx_acct: "Count traffic per connection", cx_acct_sub: "Uses the kernel's connection accounting (a little CPU). Counts connections that start after it is turned on.",
    cx_truncated: "The connection table is very large; only the first {n} entries were read.",
    cx_loading: "Reading the connection table...",
    cx_st: { ESTABLISHED: "Established", SYN_RECV: "Half-open (in)", SYN_SENT: "Connecting", TIME_WAIT: "Closing (wait)", CLOSE_WAIT: "Closing", FIN_WAIT: "Closing", LAST_ACK: "Closing", CLOSE: "Closed", UNREPLIED: "No reply", ACTIVE: "Active" },
  };
  const FA = {
    df_t_conns: "اتصال‌ها", cx_n_ips: "{n} آی‌پی",
    df_e_attack_sources: "منشأ حمله: {cc} با {pct}٪ از {conns} اتصال ورودی، بیشتر به {port}",
    df_e_bulk_ban: "{n} آی‌پی از صفحه‌ی اتصال‌ها مسدود شد", df_e_conn_acct: "شمارش حجم هر اتصال: {state}", df_on: "روشن", df_off: "خاموش",
    cx_live30: "زنده (۳۰ دقیقه)", cx_h48: "۴۸ ساعت", cx_hist_empty: "تاریخچه خودش پر می‌شود: هر ۵ دقیقه یک نقطه، حتی وقتی این صفحه بسته است.",
    cx_hist_off: "ثبت تاریخچه در پس‌زمینه خاموش است.", cx_hist: "نگه‌داشتن تاریخچه‌ی ۴۸ ساعته", cx_hist_sub: "هر ۵ دقیقه، حتی وقتی این صفحه بسته است، ثبت می‌کند اتصال‌های ورودی از کجا آمده‌اند (حدود ۰٫۳٪ یک هسته).",
    cx_sel: "{n} انتخاب شد", cx_sel_all: "انتخاب همه‌ی این صفحه", cx_sel_clear: "لغو انتخاب", cx_ban_sel: "مسدود {d}", cx_block_sel: "مسدود دائمی",
    cx_bulk_q: "{n} آی‌پی برای {d} مسدود شود؟", cx_bulk_perm_q: "{n} آی‌پی به لیست سیاه دائمی اضافه شود؟", cx_bulk_done: "{n} آی‌پی مسدود شد", cx_bulk_skip: "{n} مورد رد شد (خودتان، مجاز یا نامعتبر)",
    cx_csv: "CSV", cx_csv_t: "دانلود به‌صورت CSV (در اکسل باز می‌شود)", cx_sort: "مرتب‌سازی", cx_ptr: "نام میزبان", cx_threat_lists: "لیست‌های تهدید", cx_kbd: "برای جستجو / را بزنید",
    cx_program: "برنامه", cx_c_prog: "برنامه / سرویس",
    cx_title: "اتصال‌های زنده", cx_sub: "همه‌ی اتصال‌های این سرور همین الان: چه کسی (آی‌پی، کشور، شبکه)، به کجا (پورت، سرویس، کانتینر) و در چه وضعیتی. روی هر چیزی کلیک کنید تا بر اساس آن فیلتر شود.",
    cx_in: "ورودی", cx_out: "خروجی", cx_all: "همه", cx_int: "داخلی",
    cx_live: "زنده · هر {s}", cx_paused: "متوقف", cx_pause: "توقف", cx_resume: "ادامه", cx_read: "خواندن جدول {s}",
    cx_search: "جستجوی آی‌پی، کشور، شبکه، پورت، سرویس...", cx_proto: "پروتکل", cx_state: "وضعیت", cx_any: "همه",
    cx_half_state: "نیمه‌باز (نشانه‌ی SYN flood)", cx_clear: "پاک کردن فیلترها",
    cx_f_cc: "کشور", cx_f_port: "پورت", cx_f_ip: "آدرس", cx_f_asn: "شبکه",
    cx_k_conns: "اتصال", cx_k_ips: "آی‌پی", cx_k_cc: "کشور", cx_k_asn: "شبکه", cx_k_half: "نیمه‌باز", cx_k_bytes: "حجم (همین اتصال‌ها)",
    cx_k_table: "جدول کرنل: {n} از {max}", cx_bytes_off: "شمارش حجم هر اتصال خاموش است", cx_bytes_on: "روشن کردن",
    cx_world: "از کجا وصل شده‌اند", cx_world_out: "این سرور به کجا وصل شده", cx_countries: "کشورها",
    cx_ports: "پورت‌ها و سرویس‌ها", cx_ports_out: "پورت‌های مقصد", cx_asns: "شبکه‌ها (ارائه‌دهنده)", cx_subnets: "زیرشبکه‌ها", cx_ips: "آی‌پی‌ها",
    cx_rows: "همه‌ی اتصال‌ها", cx_rows_sub: "اتصال‌های یکسان (همان آی‌پی، پورت و وضعیت) یک بار با تعدادشان نشان داده می‌شوند.",
    cx_more: "نمایش بیشتر", cx_less: "نمایش کمتر", cx_none: "اتصالی با این فیلترها نیست.", cx_none_in: "الان کسی به این سرور وصل نیست.",
    cx_c_ip: "آی‌پی", cx_c_where: "موقعیت", cx_c_net: "شبکه", cx_c_conns: "اتصال", cx_c_ports: "پورت‌ها", cx_c_state: "وضعیت", cx_c_first: "دیده‌شده از",
    cx_c_dir: "", cx_c_proto: "پروتکل", cx_c_to: "به", cx_c_from: "از", cx_c_n: "تعداد", cx_c_bytes: "حجم", cx_c_ttl: "انقضا", cx_c_port: "پورت", cx_c_svc: "سرویس",
    cx_c_cc: "کشورها", cx_c_target: "هدایت به", cx_c_net2: "شبکه", cx_c_ips: "آی‌پی",
    cx_trend: "اتصال‌های ورودی در طول زمان", cx_trend_sub: "از وقتی این صفحه باز شده. پرتعدادترین کشورها جدا رسم شده‌اند.", cx_trend_total: "کل ورودی", cx_trend_half: "نیمه‌باز",
    cx_lan: "شبکه‌ی محلی", cx_unknown: "نامشخص",
    cx_ins_country: "{share} اتصال‌های ورودی از {cc} است ({ips} آی‌پی).",
    cx_ins_half: "{share} اتصال‌های ورودی نیمه‌باز است ({n})؛ نشانه‌ی معمول حمله‌ی SYN flood.",
    cx_ins_subnet: "{share} اتصال‌های ورودی از یک زیرشبکه است: {net} ({ips} آی‌پی).",
    cx_ins_ip: "یک آی‌پی {share} اتصال‌های ورودی را گرفته: {ip} ({n}).",
    cx_ins_asn: "{share} اتصال‌های ورودی از یک شبکه است: {org}.",
    cx_attack: "حمله در جریان است. پرتعدادترین منبع‌ها پایین آمده‌اند و گزارش آن ذخیره می‌شود.",
    cx_show_only: "فقط همین‌ها", cx_block_cc: "مسدود کردن {cc}", cx_block_net: "مسدود کردن زیرشبکه", cx_ban: "مسدود ۱ ساعت", cx_details: "جزئیات",
    cx_banned: "مسدود موقت", cx_blocked: "در لیست سیاه", cx_allowed: "مجاز", cx_threat: "در لیست تهدید",
    cx_block_cc_q: "همه‌ی ترافیک ورودی از {cc} مسدود شود؟ الان حدود {n} اتصال از {ips} آی‌پی باز است. خود شما (آدرس‌های واردشده و مجاز) هیچ‌وقت مسدود نمی‌شوید و تغییر اول ۶۰ ثانیه آزمایش می‌شود.",
    cx_block_cc_btn: "مسدود کردن کشور", cx_block_cc_done: "{cc} مسدود شد", cx_rule_name: "کشورهای مسدود", cx_off_note: "حفاظت خاموش است: قانون ذخیره شد و با روشن کردن حفاظت اعمال می‌شود.",
    cx_block_net_q: "{net} به لیست سیاه اضافه شود؟ همه‌ی آدرس‌های آن تا وقتی حذفش کنید مسدود می‌مانند.", cx_block_net_done: "{net} مسدود شد",
    cx_ban_done: "{ip} مسدود شد", cx_allow_done: "{ip} مجاز شد", cx_copied: "کپی شد",
    cx_ip_title: "آی‌پی {ip}", cx_ip_conns: "اتصال‌هایش", cx_ip_ban: "مسدود برای", cx_ip_block: "مسدود دائمی", cx_ip_allow: "مجاز کردن", cx_ip_copy: "کپی آی‌پی",
    cx_ip_ext: "جستجو در", cx_ip_first: "اولین بار {ago}", cx_ip_subnet: "زیرشبکه",
    cx_m10: "۱۰ دقیقه", cx_h1: "۱ ساعت", cx_h24: "۱ روز", cx_d7: "۷ روز",
    cx_reports: "گزارش حمله‌ها", cx_reports_sub: "وقتی حمله‌ای تشخیص داده شود، شلوغ‌ترین لحظه‌ی اتصال‌های ورودی‌اش اینجا ذخیره می‌شود: از کجا آمده و به چه چیزی زده.",
    cx_reports_none: "هنوز حمله‌ای ثبت نشده.", cx_report_title: "حمله‌ی {date}", cx_report_ongoing: "در جریان", cx_report_lasted: "{d} طول کشید",
    cx_report_peak: "در اوج: {n} اتصال ورودی، {half} نیمه‌باز، از {ips} آی‌پی.",
    cx_db_loading: "در حال دریافت پایگاه‌داده‌ی کشور و شبکه‌ی آی‌پی‌ها (حدود ۲۲ مگابایت، ماهی یک بار). تا آماده شود آی‌پی‌ها بدون کشور نشان داده می‌شوند.",
    cx_db_error: "پایگاه‌داده‌ی کشور و شبکه دریافت نشد: {e}", cx_db_retry: "تلاش دوباره",
    cx_db_ok: "موقعیت‌ها: DB-IP Lite (CC BY 4.0) و iptoasn.com، به‌روزرسانی {date}. نقشه: svg-maps (CC BY 4.0).",
    cx_acct: "شمارش حجم هر اتصال", cx_acct_sub: "از شمارش اتصال کرنل استفاده می‌کند (کمی CPU). اتصال‌هایی شمرده می‌شوند که بعد از روشن کردن شروع شوند.",
    cx_truncated: "جدول اتصال‌ها خیلی بزرگ است؛ فقط {n} مورد اول خوانده شد.",
    cx_loading: "در حال خواندن جدول اتصال‌ها...",
    cx_st: { ESTABLISHED: "برقرار", SYN_RECV: "نیمه‌باز (ورودی)", SYN_SENT: "در حال اتصال", TIME_WAIT: "در حال بستن", CLOSE_WAIT: "در حال بستن", FIN_WAIT: "در حال بستن", LAST_ACK: "در حال بستن", CLOSE: "بسته", UNREPLIED: "بی‌پاسخ", ACTIVE: "فعال" },
  };
  P.addStrings(EN, FA);
  const tv = (k, vars) => Object.entries(vars || {}).reduce((s, [x, y]) => s.split(`{${x}}`).join(y), t(k));
  const stName = (s) => { const m = t("cx_st"); return (m && typeof m === "object" && m[s]) || s; };
  const pct = (x) => `${nf(x * 100, x < 0.1 ? 1 : 0)}%`;

  // ---------------------------------------------------------------- countries and flags
  let names = null;
  const ccName = (cc) => {
    if (!cc || cc === "?") return t("cx_unknown");
    if (cc === "LAN") return t("cx_lan");
    try {
      if (!names || names.lang !== P.state.lang) names = { lang: P.state.lang, dn: new Intl.DisplayNames([P.state.lang === "fa" ? "fa" : "en"], { type: "region" }) };
      return names.dn.of(cc) || cc;
    } catch (e) { return cc; }
  };
  // Windows has no colour flag emoji (it shows two letters): draw a code badge there instead
  const flagEmoji = (() => {
    try {
      const c = document.createElement("canvas"); c.width = c.height = 20;
      const x = c.getContext("2d"); x.font = "16px sans-serif"; x.textBaseline = "top"; x.fillText("\u{1F1E9}\u{1F1EA}", 0, 0);
      const d = x.getImageData(0, 0, 20, 20).data;
      for (let i = 0; i < d.length; i += 4) if (d[i + 3] > 100 && (Math.abs(d[i] - d[i + 1]) > 50 || Math.abs(d[i + 1] - d[i + 2]) > 50)) return true;
    } catch (e) { /* no canvas */ }
    return false;
  })();
  const flag = (cc) => {
    if (cc === "LAN") return `<span class="cx-flag cx-code lan" aria-hidden="true">${icon("server")}</span>`;
    if (!cc || cc === "?" || !/^[A-Z]{2}$/.test(cc)) return `<span class="cx-flag cx-code" aria-hidden="true">?</span>`;
    if (flagEmoji) return `<span class="cx-flag" aria-hidden="true">${String.fromCodePoint(...[...cc].map((ch) => 0x1f1a5 + ch.charCodeAt(0)))}</span>`;
    return `<span class="cx-flag cx-code" aria-hidden="true">${cc}</span>`;
  };
  const place = (cc) => `<span class="cx-place">${flag(cc)}<span>${esc(ccName(cc))}</span></span>`;
  const orgShort = (org) => String(org || "").replace(/^[A-Z0-9_.-]+(?: - |\s)(?=\S)/, "").trim() || org || "";
  const orgHTML = (org, asn) => `<bdi>${esc(orgShort(org) || (asn ? `AS${asn}` : "–"))}</bdi>`;

  // ---------------------------------------------------------------- state
  const C = {
    dir: "in", f: { cc: "", port: "", ip: "", asn: "", proto: "", state: "", q: "" }, limit: 300, data: null, paused: false, busy: false,
    last: 0, root: null, ctx: null, map: null, more: {}, err: "",
    trend: "live", hist: null, histAt: 0, sel: new Set(), sort: { k: "conns", desc: true }, html: {},
  };

  function params() {
    const p = { dir: C.dir, limit: C.limit };
    for (const [k, v] of Object.entries(C.f)) if (v) p[k] = v;
    if (C.f.q) {     // countries whose name (in this language or English) contains the search text
      const q = C.f.q.toLowerCase(), codes = new Set();
      const all = (C.map && Object.keys(C.map.paths)) || ((C.data && C.data.countries.map((c) => c.cc)) || []);
      for (const cc of all) {
        if (!/^[A-Z]{2}$/.test(cc)) continue;
        if (ccName(cc).toLowerCase().includes(q) || enName(cc).toLowerCase().includes(q)) codes.add(cc);
      }
      if (codes.size) p.qcc = [...codes].slice(0, 250).join(",");
    }
    return p;
  }
  let enNames = null;
  const enName = (cc) => { try { enNames = enNames || new Intl.DisplayNames(["en"], { type: "region" }); return enNames.of(cc) || cc; } catch (e) { return cc; } };

  async function load(force = false) {
    if (C.busy || (!force && C.paused)) return;
    C.busy = true;
    try {
      C.data = await api("/api/defender/conns", params());
      C.err = "";
      C.last = Date.now();
    } catch (e) {
      C.err = e.message;
    } finally { C.busy = false; }
    paint();
  }

  // called by the firewall page every 2 s; fetches at the pace the agent can afford
  function tick() {
    if (!C.root || !document.body.contains(C.root) || C.paused || document.hidden) return;
    const every = Math.max(3, (C.data && C.data.interval) || 3) * 1000;
    if (Date.now() - C.last >= every - 300) load();
    if (C.trend === "h48" && Date.now() - C.histAt > 60000) loadHistory();
  }

  async function loadHistory() {
    C.histAt = Date.now();
    try {
      const d = await api("/api/defender/conns", { dir: "in", limit: 20, hist: 1 });
      C.hist = d.history || [];
    } catch (e) { /* the live view still works */ }
    if (C.data) paintTrend(C.data);
  }

  // ---------------------------------------------------------------- layout
  function render(ctx) {
    C.ctx = ctx;
    return `<section class="sec cx" id="cx">
      <div class="sec-head"><h3>${icon("network")}${esc(t("cx_title"))}</h3><p class="muted">${esc(t("cx_sub"))}</p></div>
      <div class="cx-bar">
        <div class="seg" role="group" aria-label="${esc(t("cx_title"))}" id="cx-dir">${dirSeg()}</div>
        <label class="cx-search" title="${esc(t("cx_kbd"))}">${icon("search")}<input type="search" id="cx-q" placeholder="${esc(t("cx_search"))}" value="${esc(C.f.q)}" autocomplete="off" spellcheck="false"><kbd class="cx-kbd" aria-hidden="true">/</kbd></label>
        <select id="cx-proto" aria-label="${esc(t("cx_proto"))}">${opts([["", `${t("cx_proto")}: ${t("cx_any")}`], ["tcp", "TCP"], ["udp", "UDP"], ["icmp", "ICMP"], ["ipv6-icmp", "ICMPv6"]], C.f.proto)}</select>
        <select id="cx-state" aria-label="${esc(t("cx_state"))}">${opts([["", `${t("cx_state")}: ${t("cx_any")}`], ["HALF", t("cx_half_state")], ...["ESTABLISHED", "SYN_RECV", "SYN_SENT", "TIME_WAIT", "CLOSE_WAIT", "UNREPLIED", "ACTIVE"].map((s) => [s, stName(s)])], C.f.state)}</select>
        <div class="cx-live" id="cx-live"></div>
      </div>
      <div class="cx-chips" id="cx-chips"></div>
      <div id="cx-alerts"></div>
      <div class="cx-kpis" id="cx-kpis"><div class="skeleton"></div></div>
      <div class="cx-geo">
        <div class="chart cx-map-card"><header><h3 id="cx-world-h">${icon("globe")}${esc(t(C.dir === "out" ? "cx_world_out" : "cx_world"))}</h3></header><div class="cx-map" id="cx-map"></div><div class="cx-tip" id="cx-tip" hidden></div></div>
        <div class="chart cx-cc-card"><header><h3>${icon("pin")}${esc(t("cx_countries"))}</h3></header><div id="cx-cc"></div></div>
      </div>
      <div class="chart cx-trend-card" id="cx-trend-card" hidden><header><h3>${icon("activity")}${esc(t("cx_trend"))}</h3>
        <div class="seg" role="group" aria-label="${esc(t("cx_trend"))}">${[["live", "cx_live30"], ["h48", "cx_h48"]].map(([k, l]) => `<button type="button" data-c="trend" data-v="${k}" aria-pressed="${C.trend === k}">${esc(t(l))}</button>`).join("")}</div>
        <p class="muted small" id="cx-trend-sub">${esc(t("cx_trend_sub"))}</p></header><div class="legend" id="cx-trend-legend"></div><div class="plot" id="cx-trend"></div></div>
      <div class="cx-grid">
        <div class="chart"><header><h3 id="cx-ports-h">${icon("server")}${esc(t("cx_ports"))}</h3></header><div id="cx-ports"></div></div>
        <div class="chart"><header><h3>${icon("network")}${esc(t("cx_asns"))}</h3></header><div id="cx-asns"></div></div>
        <div class="chart"><header><h3>${icon("grid")}${esc(t("cx_subnets"))}</h3></header><div id="cx-subnets"></div></div>
      </div>
      <div class="chart"><header><h3>${icon("globe")}${esc(t("cx_ips"))}</h3><span class="cx-count" id="cx-ips-n"></span>
        <button type="button" class="btn small ghost cx-csv" data-c="csv" data-k="ips" title="${esc(t("cx_csv_t"))}">${icon("file")}${esc(t("cx_csv"))}</button></header>
        <div id="cx-bulk"></div><div id="cx-ips"></div></div>
      <div class="chart"><header><h3>${icon("list")}${esc(t("cx_rows"))}</h3>
        <button type="button" class="btn small ghost cx-csv" data-c="csv" data-k="rows" title="${esc(t("cx_csv_t"))}">${icon("file")}${esc(t("cx_csv"))}</button>
        <span class="muted small">${esc(t("cx_rows_sub"))}</span></header><div id="cx-rows"></div></div>
      <div class="chart"><header><h3>${icon("report")}${esc(t("cx_reports"))}</h3><span class="muted small">${esc(t("cx_reports_sub"))}</span></header><div id="cx-reports"></div></div>
      <div class="cx-foot" id="cx-foot"></div>
    </section>`;
  }
  const opts = (list, cur) => list.map(([v, l]) => `<option value="${esc(v)}" ${v === cur ? "selected" : ""}>${esc(l)}</option>`).join("");
  const dirSeg = () => [["in", "arrow-in", "cx_in"], ["out", "arrow-out", "cx_out"], ["all", "arrow-both", "cx_all"]]
    .map(([d, ic, k]) => `<button type="button" data-c="dir" data-v="${d}" aria-pressed="${C.dir === d}">${icon(ic)}${esc(t(k))}</button>`).join("");

  async function mount(body) {
    C.root = body.querySelector("#cx");
    if (!C.root) return;
    C.root.addEventListener("click", onClick);
    C.root.addEventListener("change", onChange);
    const q = C.root.querySelector("#cx-q");
    let deb = 0;
    q.addEventListener("input", () => { clearTimeout(deb); deb = setTimeout(() => { C.f.q = q.value.trim(); C.limit = 300; load(true); }, 350); });
    if (!C.keyBound) {
      C.keyBound = true;
      document.addEventListener("keydown", (e) => {
        if (e.key !== "/" || !C.root || !document.body.contains(C.root) || e.ctrlKey || e.metaKey || e.altKey) return;
        const tag = (document.activeElement && document.activeElement.tagName) || "";
        if (/^(INPUT|TEXTAREA|SELECT)$/.test(tag) || document.querySelector("dialog[open]")) return;
        e.preventDefault();
        const box = $("cx-q");
        if (box) box.focus();
      });
    }
    C.html = {};
    paintLive();
    loadMap();
    await load(true);
  }

  // ---------------------------------------------------------------- painting
  const $ = (id) => C.root && C.root.querySelector(`#${id}`);
  const put = (id, html) => {
    const el = $(id);
    if (!el || C.html[id] === html) return;      // unchanged: keep the DOM (hover, focus, scroll) as it is
    C.html[id] = html;
    el.innerHTML = html;
  };

  function paint() {
    if (!C.root || !document.body.contains(C.root)) return;
    paintLive();
    const d = C.data;
    if (!d) {
      put("cx-kpis", C.err ? `<div class="notice bad">${icon("alert")}<span>${esc(C.err)}</span></div>` : `<div class="notice">${icon("refresh")}<span>${esc(t("cx_loading"))}</span></div>`);
      return;
    }
    put("cx-chips", chipsHTML());
    put("cx-alerts", alertsHTML(d));
    put("cx-kpis", kpisHTML(d));
    put("cx-cc", countriesHTML(d));
    paintMap(d);
    paintTrend(d);
    put("cx-ports-h", `${icon("server")}${esc(t(C.dir === "out" ? "cx_ports_out" : "cx_ports"))}`);
    put("cx-world-h", `${icon("globe")}${esc(t(C.dir === "out" ? "cx_world_out" : "cx_world"))}`);
    put("cx-ports", portsHTML(d));
    put("cx-asns", asnsHTML(d));
    put("cx-subnets", subnetsHTML(d));
    put("cx-ips-n", d.ips.length ? esc(`${nf(d.summary.ips, 0)}`) : "");
    put("cx-ips", ipsHTML(d));
    put("cx-bulk", bulkHTML());
    put("cx-rows", rowsHTML(d));
    put("cx-reports", reportsHTML(d));
    put("cx-foot", footHTML(d));
  }

  function paintLive() {
    const d = C.data;
    const every = d ? `${nf(Math.round(d.interval), 0)}s` : "…";
    put("cx-live", `${C.paused ? `<span class="cx-dot off"></span><span>${esc(t("cx_paused"))}</span>` : `<span class="cx-dot"></span><span>${esc(tv("cx_live", { s: every }))}</span>`}
      ${d ? `<span class="muted small">${esc(tv("cx_read", { s: `${nf(d.took, 2)}s` }))}</span>` : ""}
      <button type="button" class="btn small ghost icon" data-c="pause" title="${esc(t(C.paused ? "cx_resume" : "cx_pause"))}" aria-label="${esc(t(C.paused ? "cx_resume" : "cx_pause"))}">${icon(C.paused ? "play" : "pause")}</button>`);
  }

  function chipsHTML() {
    const lab = { cc: (v) => `${flag(v)}${esc(ccName(v))}`, port: (v) => num(esc(v)), ip: (v) => num(esc(v)), asn: (v) => esc(`AS${v} ${orgShort((C.data && C.data.orgs && C.data.orgs[v]) || "")}`) };
    const chips = ["cc", "port", "ip", "asn"].filter((k) => C.f[k]).map((k) => `<button type="button" class="chip cx-chip" data-c="unfilter" data-k="${k}" aria-label="${esc(t("cx_clear"))}">
      <span class="muted">${esc(t(`cx_f_${k}`))}:</span>${lab[k](C.f[k])}${icon("x")}</button>`);
    if (!chips.length) return "";
    return `${chips.join("")}<button type="button" class="btn small ghost" data-c="clear">${esc(t("cx_clear"))}</button>`;
  }

  function alertsHTML(d) {
    const out = [];
    const st = C.ctx && C.ctx.D && C.ctx.D.st;
    if (st && st.attack && st.attack.active) out.push(`<div class="notice bad cx-alert">${icon("flame")}<span>${esc(t("cx_attack"))}</span></div>`);
    for (const i of d.insights || []) {
      let text = "", acts = "";
      if (i.kind === "country") {
        text = tv("cx_ins_country", { share: `<b>${num(pct(i.share))}</b>`, cc: `${flag(i.cc)}<b>${esc(ccName(i.cc))}</b>`, ips: num(nf(i.ips, 0)) });
        acts = `<button type="button" class="btn small" data-c="filter" data-k="cc" data-v="${esc(i.cc)}">${icon("filter")}${esc(t("cx_show_only"))}</button>
          <button type="button" class="btn small danger" data-c="block-cc" data-cc="${esc(i.cc)}">${icon("ban")}${esc(tv("cx_block_cc", { cc: ccName(i.cc) }))}</button>`;
      } else if (i.kind === "half") {
        text = tv("cx_ins_half", { share: `<b>${num(pct(i.share))}</b>`, n: num(nf(i.conns, 0)) });
        acts = `<button type="button" class="btn small" data-c="filter" data-k="state" data-v="HALF">${icon("filter")}${esc(t("cx_show_only"))}</button>`;
      } else if (i.kind === "subnet") {
        text = tv("cx_ins_subnet", { share: `<b>${num(pct(i.share))}</b>`, net: `${flag(i.cc)}<b>${num(esc(i.net))}</b>`, ips: num(nf(i.ips, 0)) });
        acts = `<button type="button" class="btn small" data-c="filter" data-k="ip" data-v="${esc(i.net)}">${icon("filter")}${esc(t("cx_show_only"))}</button>
          <button type="button" class="btn small danger" data-c="block-net" data-net="${esc(i.net)}">${icon("ban")}${esc(t("cx_block_net"))}</button>`;
      } else if (i.kind === "ip") {
        text = tv("cx_ins_ip", { share: `<b>${num(pct(i.share))}</b>`, ip: `${flag(i.cc)}<b>${num(esc(i.ip))}</b>`, n: num(nf(i.conns, 0)) });
        acts = `<button type="button" class="btn small" data-c="ip" data-ip="${esc(i.ip)}">${icon("eye")}${esc(t("cx_details"))}</button>
          <button type="button" class="btn small danger" data-c="ban" data-ip="${esc(i.ip)}" data-min="60">${icon("ban")}${esc(t("cx_ban"))}</button>`;
      } else if (i.kind === "asn") {
        text = tv("cx_ins_asn", { share: `<b>${num(pct(i.share))}</b>`, org: `<b>${orgHTML(d.orgs[i.asn], i.asn)}</b>` });
        acts = `<button type="button" class="btn small" data-c="filter" data-k="asn" data-v="${esc(i.asn)}">${icon("filter")}${esc(t("cx_show_only"))}</button>`;
      }
      if (text) out.push(`<div class="notice warn cx-alert">${icon("alert")}<span class="cx-alert-t">${text}</span><span class="cx-alert-a">${acts}</span></div>`);
    }
    return out.join("");
  }

  function kpisHTML(d) {
    const s = d.summary, halfShare = s.conns ? s.half / s.conns : 0;
    const tile = (label, value, sub = "", cls = "") => `<div class="cx-kpi ${cls}"><span class="cx-kpi-l">${esc(label)}</span><b class="cx-kpi-v">${value}</b>${sub ? `<span class="cx-kpi-s">${sub}</span>` : ""}</div>`;
    const spark = sparkTrend(d.timeline, "in");
    const bytes = d.acct
      ? tile(t("cx_k_bytes"), `${num(esc(fmtBytes(s.bytes_in + s.bytes_out)))}`, `${icon("down")}${num(esc(fmtBytes(s.bytes_in)))} · ${icon("up")}${num(esc(fmtBytes(s.bytes_out)))}`)
      : `<div class="cx-kpi muted-kpi"><span class="cx-kpi-l">${esc(t("cx_k_bytes"))}</span><span class="cx-kpi-s">${esc(t("cx_bytes_off"))}</span><button type="button" class="btn small" data-c="acct" data-on="1">${esc(t("cx_bytes_on"))}</button></div>`;
    return [
      tile(t("cx_k_conns"), num(nf(s.conns, 0)), spark),
      tile(t("cx_k_ips"), num(nf(s.ips, 0))),
      tile(t("cx_k_cc"), num(nf(s.countries, 0))),
      tile(t("cx_k_asn"), num(nf(s.asns, 0))),
      tile(t("cx_k_half"), num(nf(s.half, 0)), s.conns ? num(pct(halfShare)) : "", halfShare >= 0.25 && s.half >= 50 ? "bad" : halfShare >= 0.1 && s.half >= 20 ? "warn" : ""),
      bytes,
    ].join("") + `<div class="cx-table-use muted small">${esc(tv("cx_k_table", { n: nf(d.entries, 0), max: d.max ? nf(d.max, 0) : "?" }))}${d.truncated ? ` · ${esc(tv("cx_truncated", { n: nf(d.entries, 0) }))}` : ""}</div>`;
  }

  function sparkTrend(tl, key) {
    if (!tl || tl.length < 2) return "";
    const v = tl.map((p) => p[key] || 0), max = Math.max(1, ...v), W = 120, H = 26;
    const pts = v.map((y, i) => `${((i / (v.length - 1)) * W).toFixed(1)},${(H - 2 - (y / max) * (H - 4)).toFixed(1)}`).join(" ");
    return `<svg class="cx-spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-hidden="true"><polyline points="${pts}" fill="none" stroke="var(--accent)" stroke-width="1.6" vector-effect="non-scaling-stroke"/></svg>`;
  }

  const bar = (n, max, cls = "") => `<span class="cx-bar-in ${cls}" style="--w:${max ? Math.max(2, (n / max) * 100).toFixed(1) : 0}%"></span>`;
  const moreBtn = (key, total, shown) => (total > shown || C.more[key])
    ? `<button type="button" class="btn small ghost cx-more" data-c="more" data-k="${key}">${esc(t(C.more[key] ? "cx_less" : "cx_more"))}${C.more[key] ? "" : ` (${num(nf(total - shown, 0))})`}</button>` : "";
  const take = (key, list, n) => (C.more[key] ? list : list.slice(0, n));
  const empty = (d) => `<div class="empty">${esc(t(d.summary.conns || C.dir !== "in" || Object.values(C.f).some(Boolean) ? "cx_none" : "cx_none_in"))}</div>`;

  function countriesHTML(d) {
    if (!d.countries.length) return empty(d);
    const max = d.countries[0].conns, list = take("cc", d.countries, 12);
    const rows = list.map((c) => {
      const on = C.f.cc === c.cc;
      return `<div class="cx-rank${on ? " on" : ""}">
        <button type="button" class="cx-rank-main" data-c="filter" data-k="cc" data-v="${esc(c.cc)}" aria-pressed="${on}">
          ${place(c.cc)}<span class="cx-rank-bar">${bar(c.conns, max, c.half > c.conns / 3 ? "bad" : "")}</span>
          <span class="cx-rank-n">${num(nf(c.conns, 0))}</span><span class="cx-rank-s muted">${esc(tv("cx_n_ips", { n: nf(c.ips, 0) }))}</span></button>
        ${C.dir !== "out" && /^[A-Z]{2}$/.test(c.cc) ? `<button type="button" class="btn small icon ghost danger" data-c="block-cc" data-cc="${esc(c.cc)}" title="${esc(tv("cx_block_cc", { cc: ccName(c.cc) }))}" aria-label="${esc(tv("cx_block_cc", { cc: ccName(c.cc) }))}">${icon("ban")}</button>` : ""}
      </div>`;
    }).join("");
    return `<div class="cx-ranks">${rows}</div>${moreBtn("cc", d.countries.length, 12)}`;
  }

  function portsHTML(d) {
    if (!d.ports.length) return empty(d);
    const max = d.ports[0].conns;
    const rows = take("ports", d.ports, 8).map((p) => `<tr>
      <td><button type="button" class="cx-link" data-c="filter" data-k="port" data-v="${esc(p.port)}">${num(esc(p.port ? `${p.port}/${p.proto}` : p.proto))}</button>
        ${p.svc ? `<span class="cx-svc">${esc(p.svc)}</span>` : ""}${p.targets.length ? `<span class="cx-target muted small">→ ${num(esc(p.targets.join(", ")))}</span>` : ""}</td>
      <td class="cx-num" data-label="${esc(t("cx_c_conns"))}"><span class="cx-cell-bar">${bar(p.conns, max, p.half > p.conns / 3 ? "bad" : "")}${num(nf(p.conns, 0))}</span></td>
      <td class="cx-num" data-label="${esc(t("cx_c_ips"))}">${num(nf(p.ips, 0))}</td>
      <td class="cx-hide-sm" data-label="${esc(t("cx_c_cc"))}"><span class="cx-flags">${p.ccs.map((c) => `<span title="${esc(ccName(c))}">${flag(c)}</span>`).join("")}</span></td></tr>`).join("");
    return `<div class="table-wrap cx-table cx-compact"><table><thead><tr><th>${esc(t("cx_c_port"))}</th><th>${esc(t("cx_c_conns"))}</th><th>${esc(t("cx_c_ips"))}</th><th class="cx-hide-sm">${esc(t("cx_c_cc"))}</th></tr></thead><tbody>${rows}</tbody></table></div>${moreBtn("ports", d.ports.length, 8)}`;
  }

  function asnsHTML(d) {
    if (!d.asns.length) return empty(d);
    const max = d.asns[0].conns;
    const rows = take("asns", d.asns, 8).map((a) => `<tr>
      <td><button type="button" class="cx-link cx-org" data-c="filter" data-k="asn" data-v="${esc(a.asn)}">${flag(a.cc)}<span>${orgHTML(a.org, a.asn)}</span></button><span class="muted small cx-asn">${num(`AS${a.asn}`)}</span></td>
      <td class="cx-num" data-label="${esc(t("cx_c_conns"))}"><span class="cx-cell-bar">${bar(a.conns, max)}${num(nf(a.conns, 0))}</span></td>
      <td class="cx-num" data-label="${esc(t("cx_c_ips"))}">${num(nf(a.ips, 0))}</td></tr>`).join("");
    return `<div class="table-wrap cx-table cx-compact"><table><thead><tr><th>${esc(t("cx_c_net2"))}</th><th>${esc(t("cx_c_conns"))}</th><th>${esc(t("cx_c_ips"))}</th></tr></thead><tbody>${rows}</tbody></table></div>${moreBtn("asns", d.asns.length, 8)}`;
  }

  function subnetsHTML(d) {
    if (!d.subnets.length) return empty(d);
    const max = d.subnets[0].conns;
    const rows = take("subnets", d.subnets, 8).map((s) => `<tr>
      <td><button type="button" class="cx-link" data-c="filter" data-k="ip" data-v="${esc(s.net)}">${flag(s.cc)}${num(esc(s.net))}</button></td>
      <td class="cx-num" data-label="${esc(t("cx_c_conns"))}"><span class="cx-cell-bar">${bar(s.conns, max)}${num(nf(s.conns, 0))}</span></td>
      <td class="cx-num" data-label="${esc(t("cx_c_ips"))}">${num(nf(s.ips, 0))}</td>
      <td class="act">${C.dir !== "out" && s.cc !== "LAN" ? `<button type="button" class="btn small icon ghost danger" data-c="block-net" data-net="${esc(s.net)}" title="${esc(t("cx_block_net"))}" aria-label="${esc(t("cx_block_net"))} ${esc(s.net)}">${icon("ban")}</button>` : ""}</td></tr>`).join("");
    return `<div class="table-wrap cx-table cx-compact"><table><thead><tr><th>${esc(t("cx_subnets"))}</th><th>${esc(t("cx_c_conns"))}</th><th>${esc(t("cx_c_ips"))}</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>${moreBtn("subnets", d.subnets.length, 8)}`;
  }

  const statusPills = (r) => [r.banned ? pill("bad", t("cx_banned")) : "", r.blocked ? pill("bad", t("cx_blocked")) : "", r.allowed ? pill("ok", t("cx_allowed")) : "", r.threat ? pill("warn", t("cx_threat")) : ""].join("");
  const statePill = (s) => {
    const kind = s === "ESTABLISHED" || s === "ACTIVE" ? "ok" : s === "SYN_RECV" || s === "UNREPLIED" ? "bad" : s === "SYN_SENT" ? "warn" : "";
    return `<span class="pill ${kind} cx-st">${esc(stName(s))}</span>`;
  };

  const SORTS = { conns: (r) => r.conns, half: (r) => r.half, nports: (r) => r.nports, first: (r) => -(r.first || 0), bytes: (r) => r.bytes_in + r.bytes_out };
  const selectable = (r) => C.dir !== "out" && r.cc !== "LAN" && !r.allowed && !r.banned && !r.blocked;
  const sortTh = (k, label) => `<th><button type="button" class="cx-th${C.sort.k === k ? " on" : ""}" data-c="sort" data-k="${k}" title="${esc(t("cx_sort"))}">${esc(t(label))}${C.sort.k === k ? `<span aria-hidden="true">${C.sort.desc ? "▾" : "▴"}</span>` : ""}</button></th>`;

  function ipsHTML(d) {
    if (!d.ips.length) return empty(d);
    const max = Math.max(...d.ips.map((r) => r.conns)), out = C.dir === "out";
    const f = SORTS[C.sort.k] || SORTS.conns, sorted = d.ips.slice().sort((a, b) => (C.sort.desc ? f(b) - f(a) : f(a) - f(b)) || b.conns - a.conns);
    const shown = take("ips", sorted, 25), canSel = shown.filter(selectable);
    const allOn = canSel.length && canSel.every((r) => C.sel.has(r.ip));
    const rows = shown.map((r) => `<tr class="${r.banned || r.blocked ? "cx-dim" : ""}${C.sel.has(r.ip) ? " cx-picked" : ""}">
      <td class="cx-c-ip">${selectable(r) ? `<input type="checkbox" class="cx-pick" data-c="pick" data-ip="${esc(r.ip)}" ${C.sel.has(r.ip) ? "checked" : ""} aria-label="${esc(r.ip)}">` : `<span class="cx-pick-gap"></span>`}<button type="button" class="cx-link cx-ip" data-c="ip" data-ip="${esc(r.ip)}">${num(esc(r.ip))}</button>${statusPills(r)}</td>
      <td class="cx-c-where" data-label="${esc(t("cx_c_where"))}"><button type="button" class="cx-link" data-c="filter" data-k="cc" data-v="${esc(r.cc || "?")}">${place(r.cc || "?")}</button></td>
      <td data-label="${esc(t("cx_c_net"))}" class="cx-net cx-c-net">${r.asn ? `<button type="button" class="cx-link" data-c="filter" data-k="asn" data-v="${esc(r.asn)}">${orgHTML(d.orgs[r.asn], r.asn)}</button>` : "–"}</td>
      <td class="cx-num cx-c-conns" data-label="${esc(t("cx_c_conns"))}"><span class="cx-cell-bar">${bar(r.conns, max, r.half > r.conns / 3 ? "bad" : "")}${num(nf(r.conns, 0))}</span>${r.half ? `<span class="cx-half" title="${esc(t("cx_k_half"))}">${num(nf(r.half, 0))}</span>` : ""}</td>
      <td class="cx-c-ports" data-label="${esc(t(out ? "cx_c_port" : "cx_c_ports"))}"><span class="cx-ports">${r.ports.map((p) => `<span class="chip">${num(esc(p))}</span>`).join("")}${r.nports > r.ports.length ? `<span class="muted small">+${num(r.nports - r.ports.length)}</span>` : ""}</span></td>
      ${d.acct ? `<td class="cx-num cx-c-bytes" data-label="${esc(t("cx_c_bytes"))}">${num(esc(fmtBytes(r.bytes_in + r.bytes_out)))}</td>` : ""}
      <td data-label="${esc(t("cx_c_first"))}" class="muted small cx-c-first">${r.first ? esc(ago(r.first)) : "–"}</td>
      <td class="act cx-c-act"><div class="row-actions">
        <button type="button" class="btn small icon ghost" data-c="ip" data-ip="${esc(r.ip)}" title="${esc(t("cx_details"))}" aria-label="${esc(t("cx_details"))} ${esc(r.ip)}">${icon("eye")}</button>
        ${out || r.cc === "LAN" || r.allowed ? "" : `<button type="button" class="btn small icon ghost danger" data-c="ban" data-ip="${esc(r.ip)}" data-min="60" title="${esc(t("cx_ban"))}" aria-label="${esc(t("cx_ban"))} ${esc(r.ip)}">${icon("ban")}</button>`}
      </div></td></tr>`).join("");
    const head = `<th>${canSel.length ? `<input type="checkbox" class="cx-pick" data-c="pick-all" ${allOn ? "checked" : ""} aria-label="${esc(t("cx_sel_all"))}" title="${esc(t("cx_sel_all"))}">` : ""}${esc(t("cx_c_ip"))}</th><th>${esc(t("cx_c_where"))}</th><th>${esc(t("cx_c_net"))}</th>${sortTh("conns", "cx_c_conns")}${sortTh("nports", out ? "cx_c_port" : "cx_c_ports")}${d.acct ? sortTh("bytes", "cx_c_bytes") : ""}${sortTh("first", "cx_c_first")}<th></th>`;
    return `<div class="table-wrap cx-table cx-ipt"><table><thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table></div>${moreBtn("ips", d.ips.length, 25)}`;
  }

  const dirIcon = (dr) => `<span class="cx-dir ${dr}" title="${esc(t(dr === "in" ? "cx_in" : dr === "out" ? "cx_out" : "cx_int"))}">${icon(dr === "in" ? "arrow-in" : dr === "out" ? "arrow-out" : "arrow-both")}</span>`;

  function rowsHTML(d) {
    if (!d.rows.length) return empty(d);
    const rows = d.rows.map((r) => `<tr>
      <td class="cx-r-ip">${dirIcon(r.dir)}<button type="button" class="cx-link cx-ip" data-c="ip" data-ip="${esc(r.ip)}">${flag(r.cc)}${num(esc(r.ip))}</button></td>
      <td class="cx-r-port" data-label="${esc(t(r.dir === "out" ? "cx_c_to" : "cx_c_port"))}"><button type="button" class="cx-link" data-c="filter" data-k="port" data-v="${esc(r.port)}">${num(esc(r.port ? `${r.port}/${r.proto}` : r.proto))}</button>${r.svc ? ` <span class="cx-svc">${esc(r.svc)}</span>` : ""}${r.target ? `<span class="cx-target muted small">${r.dir === "out" ? "←" : "→"} ${num(esc(r.target))}</span>` : ""}</td>
      <td class="cx-r-state" data-label="${esc(t("cx_c_state"))}">${statePill(r.state)}</td>
      <td class="cx-num cx-r-n" data-label="${esc(t("cx_c_n"))}">${r.n > 1 ? `<b>×${num(nf(r.n, 0))}</b>` : num("1")}</td>
      ${d.acct ? `<td class="cx-num cx-r-bytes" data-label="${esc(t("cx_c_bytes"))}">${r.bytes_in + r.bytes_out ? `${icon("down")}${num(esc(fmtBytes(r.bytes_in)))} ${icon("up")}${num(esc(fmtBytes(r.bytes_out)))}` : "–"}</td>` : ""}
      <td class="cx-num muted small cx-r-ttl" data-label="${esc(t("cx_c_ttl"))}">${num(esc(fmtTtl(r.ttl)))}</td></tr>`).join("");
    const more = d.rows_total > d.rows.length ? `<button type="button" class="btn small ghost cx-more" data-c="rows-more">${esc(t("cx_more"))} (${num(nf(d.rows_total - d.rows.length, 0))})</button>` : "";
    return `<div class="table-wrap cx-table cx-rows"><table><thead><tr><th>${esc(t("cx_c_ip"))}</th><th>${esc(t("cx_c_port"))}</th><th>${esc(t("cx_c_state"))}</th><th>${esc(t("cx_c_n"))}</th>${d.acct ? `<th>${esc(t("cx_c_bytes"))}</th>` : ""}<th>${esc(t("cx_c_ttl"))}</th></tr></thead><tbody>${rows}</tbody></table></div>${more}`;
  }
  const fmtTtl = (s) => (s >= 86400 ? `${Math.floor(s / 86400)}d` : s >= 3600 ? `${Math.floor(s / 3600)}h` : s >= 60 ? `${Math.floor(s / 60)}m` : `${s}s`);

  const when = (ts) => { try { return new Intl.DateTimeFormat(P.state.lang === "fa" ? "fa-IR-u-ca-gregory-nu-latn" : "en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(ts * 1000)); } catch (e) { return new Date(ts * 1000).toLocaleString(); } };
  const dur = (s) => (s >= 3600 ? `${Math.floor(s / 3600)}h ${Math.round((s % 3600) / 60)}m` : s >= 60 ? `${Math.round(s / 60)}m` : `${s}s`);

  function reportsHTML(d) {
    if (!d.reports || !d.reports.length) return `<div class="empty">${esc(t("cx_reports_none"))}</div>`;
    return `<div class="cx-reports">${d.reports.map((r) => `<button type="button" class="cx-report" data-c="report" data-id="${r.id}">
      <span class="cx-report-t">${icon("flame")}<b>${esc(when(r.since))}</b><span class="muted small">${esc(r.ended ? tv("cx_report_lasted", { d: dur(r.ended - r.since) }) : t("cx_report_ongoing"))}</span></span>
      <span class="cx-report-m">${r.top_cc ? place(r.top_cc) : ""}${r.top_port ? `<span class="chip">${num(esc(r.top_port))}</span>` : ""}<span class="muted small">${num(nf(r.conns, 0))} ${esc(t("cx_k_conns"))}</span></span></button>`).join("")}</div>`;
  }

  function footHTML(d) {
    const db = d.db || {};
    let msg;
    if (db.ready) msg = `<span class="muted small">${esc(tv("cx_db_ok", { date: when(db.updated) }))}</span>`;
    else if (db.state === "error") msg = `<div class="notice warn">${icon("alert")}<span>${esc(tv("cx_db_error", { e: db.error }))}</span><button type="button" class="btn small" data-c="db-retry">${esc(t("cx_db_retry"))}</button></div>`;
    else msg = `<div class="notice">${icon("refresh")}<span>${esc(t("cx_db_loading"))}</span></div>`;
    const acct = `<label class="cx-acct"><span class="switch"><input type="checkbox" data-c="acct-toggle" ${d.acct ? "checked" : ""}><span></span></span><span><b>${esc(t("cx_acct"))}</b><span class="muted small">${esc(t("cx_acct_sub"))}</span></span></label>`;
    const hist = `<label class="cx-acct"><span class="switch"><input type="checkbox" data-c="hist-toggle" ${d.history_on ? "checked" : ""}><span></span></span><span><b>${esc(t("cx_hist"))}</b><span class="muted small">${esc(t("cx_hist_sub"))}</span></span></label>`;
    return `${msg}${acct}${hist}`;
  }

  // ---------------------------------------------------------------- map
  async function loadMap() {
    if (C.map) { drawMap(); return; }
    try {
      C.map = await api("/world.json");
    } catch (e) { C.map = null; return; }
    drawMap();
  }

  function drawMap() {
    const box = $("cx-map");
    if (!box || !C.map) return;
    const paths = Object.entries(C.map.paths).map(([cc, d]) => `<path d="${d}" data-cc="${cc}"/>`).join("");
    box.innerHTML = `<svg viewBox="${C.map.viewBox}" role="img" aria-label="${esc(t("cx_world"))}" preserveAspectRatio="xMidYMid meet"><g class="cx-land">${paths}</g></svg>`;
    const svg = box.querySelector("svg"), tip = $("cx-tip");
    svg.addEventListener("pointermove", (e) => {
      const p = e.target.closest("path");
      if (!p) { tip.hidden = true; return; }
      const cc = p.dataset.cc, c = C.data && C.data.countries.find((x) => x.cc === cc);
      tip.innerHTML = `<div class="t">${place(cc)}</div>${c ? `<div class="r"><b>${num(nf(c.conns, 0))}</b><span>${esc(t("cx_k_conns"))}</span></div><div class="r"><b>${num(nf(c.ips, 0))}</b><span>${esc(t("cx_k_ips"))}</span></div>${c.half ? `<div class="r"><b>${num(nf(c.half, 0))}</b><span>${esc(t("cx_k_half"))}</span></div>` : ""}` : `<div class="r muted">0</div>`}`;
      tip.hidden = false;
      const card = box.parentElement.getBoundingClientRect();
      const x = e.clientX - card.left, y = e.clientY - card.top, w = tip.offsetWidth;
      tip.style.left = `${Math.max(4, Math.min(card.width - w - 4, x + (x > card.width / 2 ? -w - 14 : 14)))}px`;
      tip.style.top = `${Math.max(4, y - 10)}px`;
    });
    svg.addEventListener("pointerleave", () => { tip.hidden = true; });
    svg.addEventListener("click", (e) => {
      const p = e.target.closest("path");
      if (!p) return;
      setFilter("cc", C.f.cc === p.dataset.cc ? "" : p.dataset.cc);
    });
    if (C.data) paintMap(C.data);
  }

  function paintMap(d) {
    const box = $("cx-map");
    if (!box || !C.map) return;
    const counts = Object.fromEntries(d.countries.map((c) => [c.cc, c]));
    const max = Math.max(1, ...d.countries.filter((c) => /^[A-Z]{2}$/.test(c.cc)).map((c) => c.conns));
    box.querySelectorAll("path").forEach((p) => {
      const c = counts[p.dataset.cc];
      const lvl = c ? Math.max(1, Math.ceil((Math.log(c.conns + 1) / Math.log(max + 1)) * 5)) : 0;
      const cls = `${lvl ? `l${lvl}` : ""}${c && c.half > c.conns / 3 ? " hot" : ""}${C.f.cc === p.dataset.cc ? " sel" : ""}`.trim();
      if (p.getAttribute("class") !== cls) p.setAttribute("class", cls);
    });
  }

  // ---------------------------------------------------------------- trend
  function paintTrend(d) {
    const card = $("cx-trend-card"), box = $("cx-trend");
    const h48 = C.trend === "h48";
    const tl = h48 ? (C.hist || []) : (d.timeline || []);
    if (!card || !box) return;
    if (C.dir === "out" || (!h48 && tl.length < 3 && !(d.history_on && d.db && d.db.ready))) { card.hidden = true; return; }
    card.hidden = false;
    put("cx-trend-sub", esc(t(h48 ? "cx_hist_sub" : "cx_trend_sub")));
    if (tl.length < 2) {
      box.innerHTML = `<div class="empty">${esc(t(h48 && !d.history_on ? "cx_hist_off" : h48 ? "cx_hist_empty" : "cx_loading"))}</div>`;
      put("cx-trend-legend", "");
      return;
    }
    const totals = {};
    tl.forEach((p) => Object.entries(p.cc || {}).forEach(([cc, n]) => { totals[cc] = (totals[cc] || 0) + n; }));
    const top = Object.entries(totals).filter(([cc]) => /^[A-Z]{2}$/.test(cc)).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([cc]) => cc);
    const series = [{ k: "in", name: t("cx_trend_total"), col: "var(--accent)", get: (p) => p.in, w: 2.2 },
      { k: "half", name: t("cx_trend_half"), col: "var(--s-bad)", get: (p) => p.half, w: 1.6, dash: "4 3" },
      ...top.map((cc, i) => ({ k: cc, name: ccName(cc), col: ["var(--c1)", "var(--c2)", "var(--c3)", "var(--s-warn)"][i], get: (p) => (p.cc || {})[cc] || 0, w: 1.6, flag: cc }))];
    const W = Math.max(300, Math.round(box.clientWidth) || 600), H = 170, L = 48, R = 8, T = 10, B = 22;
    const t0 = tl[0].t, t1 = tl[tl.length - 1].t, span = Math.max(1, t1 - t0);
    const max = Math.max(1, ...tl.map((p) => p.in));
    const X = (tt) => L + ((tt - t0) / span) * (W - L - R), Y = (v) => T + (1 - v / max) * (H - T - B);
    let grid = "";
    for (let i = 0; i <= 3; i++) { const v = (max * i) / 3; grid += `<line x1="${L}" x2="${W - R}" y1="${Y(v)}" y2="${Y(v)}"/><text x="${L - 6}" y="${Y(v) + 4}" text-anchor="end">${esc(nf(v, 0))}</text>`; }
    const hhmm = (s) => { const x = new Date(s * 1000); return `${span > 86400 ? `${x.getMonth() + 1}/${x.getDate()} ` : ""}${String(x.getHours()).padStart(2, "0")}:${String(x.getMinutes()).padStart(2, "0")}`; };
    grid += `<text x="${L}" y="${H - 6}">${hhmm(t0)}</text><text x="${(L + W - R) / 2}" y="${H - 6}" text-anchor="middle">${hhmm(t0 + span / 2)}</text><text x="${W - R}" y="${H - 6}" text-anchor="end">${hhmm(t1)}</text>`;
    const lines = series.map((s) => `<polyline points="${tl.map((p) => `${X(p.t).toFixed(1)},${Y(s.get(p)).toFixed(1)}`).join(" ")}" fill="none" stroke="${s.col}" stroke-width="${s.w}" ${s.dash ? `stroke-dasharray="${s.dash}"` : ""} stroke-linejoin="round"/>`).join("");
    box.innerHTML = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" style="height:${H}px" role="img" aria-label="${esc(t("cx_trend"))}"><g class="grid">${grid}</g>${lines}</svg>`;
    put("cx-trend-legend", series.map((s) => `<span><i style="background:${s.col}"></i>${s.flag ? flag(s.flag) : ""}${esc(s.name)}</span>`).join(""));
  }

  // ---------------------------------------------------------------- actions
  function setFilter(k, v) {
    if (k === "state" || k === "proto") {
      C.f[k] = v;
      const sel = $(`cx-${k}`);
      if (sel) sel.value = v;
    } else C.f[k] = C.f[k] === v ? "" : v;
    C.limit = 300;
    C.more = {};
    load(true);
  }

  async function onClick(e) {
    const b = e.target.closest("[data-c]");
    if (!b || b.disabled) return;
    const c = b.dataset.c;
    if (c === "dir") {
      C.dir = b.dataset.v;
      C.root.querySelectorAll('[data-c="dir"]').forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
      C.limit = 300; C.more = {};
      return load(true);
    }
    if (c === "filter") return setFilter(b.dataset.k, b.dataset.v);
    if (c === "unfilter") { C.f[b.dataset.k] = ""; return load(true); }
    if (c === "clear") {
      C.f = { cc: "", port: "", ip: "", asn: "", proto: "", state: "", q: "" };
      ["cx-q", "cx-proto", "cx-state"].forEach((id) => { const el = $(id); if (el) el.value = ""; });
      return load(true);
    }
    if (c === "pause") { C.paused = !C.paused; paintLive(); if (!C.paused) load(true); return; }
    if (c === "trend") {
      C.trend = b.dataset.v;
      C.root.querySelectorAll('[data-c="trend"]').forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
      if (C.trend === "h48") return loadHistory();
      return paintTrend(C.data);
    }
    if (c === "sort") {
      C.sort = C.sort.k === b.dataset.k ? { k: b.dataset.k, desc: !C.sort.desc } : { k: b.dataset.k, desc: true };
      return paint();
    }
    if (c === "sel-clear") { C.sel.clear(); return paint(); }
    if (c === "bulk") return bulkBan(b, +b.dataset.min);
    if (c === "csv") return exportCsv(b, b.dataset.k);
    if (c === "more") { C.more[b.dataset.k] = !C.more[b.dataset.k]; return paint(); }
    if (c === "rows-more") { C.limit = Math.min(2000, C.limit + 500); return load(true); }
    if (c === "ip") return ipDialog(b.dataset.ip);
    if (c === "report") return reportDialog(+b.dataset.id);
    if (c === "ban") return ban(b, b.dataset.ip, +b.dataset.min || 60);
    if (c === "block-cc") return blockCountry(b, b.dataset.cc);
    if (c === "block-net") return blockNet(b, b.dataset.net);
    if (c === "acct") return setAcct(b, b.dataset.on === "1");
    if (c === "db-retry") { if (await act(b, () => post("/api/defender/conns/geo", {}))) load(true); }
  }

  function onChange(e) {
    const el = e.target;
    if (el.dataset.c === "pick") { if (el.checked) C.sel.add(el.dataset.ip); else C.sel.delete(el.dataset.ip); return paint(); }
    if (el.dataset.c === "pick-all") {
      const ips = [...C.root.querySelectorAll('[data-c="pick"]')].map((x) => x.dataset.ip);
      ips.forEach((ip) => (el.checked ? C.sel.add(ip) : C.sel.delete(ip)));
      return paint();
    }
    if (el.dataset.c === "hist-toggle") {
      act(el, () => post("/api/defender/conns/history", { on: el.checked }), t("saved")).then((r) => { if (!r) el.checked = !el.checked; C.hist = null; C.histAt = 0; load(true); });
      return;
    }
    if (el.id === "cx-proto") return setFilter("proto", el.value);
    if (el.id === "cx-state") return setFilter("state", el.value);
    if (el.dataset.c === "acct-toggle") return setAcct(el, el.checked);
  }

  const DURS = [[60, "cx_h1"], [1440, "cx_h24"], [10080, "cx_d7"]];
  function bulkHTML() {
    if (!C.sel.size) return "";
    return `<div class="cx-bulkbar" role="region" aria-label="${esc(tv("cx_sel", { n: C.sel.size }))}"><b>${esc(tv("cx_sel", { n: nf(C.sel.size, 0) }))}</b>
      ${DURS.map(([m, k]) => `<button type="button" class="btn small danger" data-c="bulk" data-min="${m}">${icon("ban")}${esc(tv("cx_ban_sel", { d: t(k) }))}</button>`).join("")}
      <button type="button" class="btn small danger solid" data-c="bulk" data-min="0">${esc(t("cx_block_sel"))}</button>
      <button type="button" class="btn small ghost" data-c="sel-clear">${esc(t("cx_sel_clear"))}</button></div>`;
  }

  async function bulkBan(btn, minutes) {
    const ips = [...C.sel];
    const d = (DURS.find(([m]) => m === minutes) || [0, "cx_h1"])[1];
    const q = minutes ? tv("cx_bulk_q", { n: nf(ips.length, 0), d: t(d) }) : tv("cx_bulk_perm_q", { n: nf(ips.length, 0) });
    if (!(await confirmBox({ message: q, label: minutes ? tv("cx_ban_sel", { d: t(d) }) : t("cx_block_sel") }))) return;
    const r = await act(btn, () => post("/api/defender/conns/ban", { ips, minutes }));
    if (!r) return;
    toast(tv("cx_bulk_done", { n: nf(r.done.length, 0) }));
    if (r.skipped.length) toast(tv("cx_bulk_skip", { n: nf(r.skipped.length, 0) }), "warn");
    C.sel.clear();
    load(true);
  }

  async function exportCsv(btn, kind) {
    let d = C.data;
    if (!d) return;
    if (kind === "rows" && d.rows_total > d.rows.length) {        // everything that matches, not only what is shown
      const full = await act(btn, () => api("/api/defender/conns", { ...params(), limit: 2000 }));
      if (full) d = full;
    }
    const cell = (v) => { const s = String(v ?? ""); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
    let head, lines;
    if (kind === "ips") {
      head = ["ip", "country", "country_name", "asn", "network", "connections", "half_open", "ports", "bytes_in", "bytes_out", "first_seen", "status"];
      lines = d.ips.map((r) => [r.ip, r.cc || "", ccName(r.cc), r.asn || "", (d.orgs || {})[r.asn] || "", r.conns, r.half, r.ports.join(" "), r.bytes_in, r.bytes_out,
        r.first ? new Date(r.first * 1000).toISOString() : "", [r.banned && "banned", r.blocked && "blocked", r.allowed && "allowed", r.threat && "threat"].filter(Boolean).join(" ")]);
    } else {
      head = ["direction", "protocol", "ip", "country", "asn", "network", "port", "service", "forwarded_to", "state", "count", "half_open", "bytes_in", "bytes_out", "expires_s"];
      lines = d.rows.map((r) => [r.dir, r.proto, r.ip, r.cc || "", r.asn || "", (d.orgs || {})[r.asn] || "", r.port, r.svc, r.target, r.state, r.n, r.half, r.bytes_in, r.bytes_out, r.ttl]);
    }
    const csv = "\ufeff" + [head, ...lines].map((l) => l.map(cell).join(",")).join("\r\n");
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
    a.download = `connections-${kind}-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")}.csv`;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  }

  async function setAcct(el, on) {
    const r = await act(el, () => post("/api/defender/conns/acct", { on }), t("saved"));
    if (!r && el.type === "checkbox") el.checked = !on;
    load(true);
  }

  async function ban(btn, ip, minutes) {
    if (await act(btn, () => post("/api/defender/block", { ip, minutes, note: "connections page" }), tv("cx_ban_done", { ip }))) load(true);
  }

  async function blockNet(btn, net) {
    if (!(await confirmBox({ message: tv("cx_block_net_q", { net }), label: t("cx_block_net") }))) return;
    if (await act(btn, () => post("/api/defender/block", { ip: net, note: "connections page" }), tv("cx_block_net_done", { net }))) load(true);
  }

  async function blockCountry(btn, cc) {
    const c = (C.data && C.data.countries.find((x) => x.cc === cc)) || { conns: 0, ips: 0 };
    if (!(await confirmBox({ message: tv("cx_block_cc_q", { cc: ccName(cc), n: nf(c.conns, 0), ips: nf(c.ips, 0) }), label: t("cx_block_cc_btn") }))) return;
    const fr = await act(btn, () => api("/api/defender/fwrules"));
    if (!fr) return;
    const rules = JSON.parse(JSON.stringify(fr.rules || []));
    // add it to an existing plain "block these countries" rule, or make one
    const plain = rules.find((r) => r.action === "block" && r.enabled !== false && (r.direction || "in") === "in" && (r.country_mode || "in") === "in"
      && (r.countries || []).length && !(r.ips || []).length && (!r.proto || r.proto === "any") && !r.ports && !r.schedule && !r.expires);
    if (plain) {
      if (!plain.countries.map((x) => x.toLowerCase()).includes(cc.toLowerCase())) plain.countries.push(cc.toLowerCase());
    } else {
      const id = Array.from(crypto.getRandomValues(new Uint8Array(3)), (x) => x.toString(16).padStart(2, "0")).join("");
      rules.push({ id, name: t("cx_rule_name"), enabled: true, direction: "in", countries: [cc.toLowerCase()], country_mode: "in", ips: [], ip_mode: "in",
        proto: "any", ports: "", action: "block", limit: { rate: 10, burst: 20, ban: 0 }, schedule: null, expires: 0 });
    }
    const ok = await C.ctx.apply(btn, "config", { rules, _what: "rules" }, tv("cx_block_cc_done", { cc: ccName(cc) }));
    if (ok && C.ctx.D.st && C.ctx.D.st.enabled === false) toast(t("cx_off_note"), "warn");
    if (ok) load(true);
  }

  // ---------------------------------------------------------------- dialogs
  async function ipDialog(ip) {
    const dlg = openDialog({ title: tv("cx_ip_title", { ip }), wide: true, hideSubmit: true, cancel: t("close"), body: `<div id="cx-ipd"><div class="skeleton"></div></div>` });
    const box = dlg.querySelector("#cx-ipd");
    let d;
    try { d = await api("/api/defender/conns/ip", { ip }); } catch (e) { box.innerHTML = `<div class="notice bad">${icon("alert")}<span>${esc(e.message)}</span></div>`; return; }
    const s = d.summary;
    const lan = d.cc === "LAN";
    const durs = [[10, "cx_m10"], [60, "cx_h1"], [1440, "cx_h24"], [10080, "cx_d7"]];
    const rows = d.rows.map((r) => `<tr><td>${dirIcon(r.dir)}${num(esc(r.port ? `${r.port}/${r.proto}` : r.proto))}${r.svc ? ` <span class="cx-svc">${esc(r.svc)}</span>` : ""}${r.target ? `<span class="cx-target muted small">${r.dir === "out" ? "←" : "→"} ${num(esc(r.target))}</span>` : ""}</td>
      <td data-label="${esc(t("cx_c_state"))}">${statePill(r.state)}</td><td class="cx-num" data-label="${esc(t("cx_c_n"))}">${num(nf(r.n, 0))}</td>
      <td class="cx-num muted small" data-label="${esc(t("cx_c_ttl"))}">${num(esc(fmtTtl(r.ttl)))}</td></tr>`).join("");
    box.innerHTML = `<div class="cx-ipd">
      <div class="cx-ipd-head">
        <div class="cx-ipd-ip">${flag(d.cc)}<b>${num(esc(d.ip))}</b>${statusPills(d)}</div>
        <dl class="cx-dl">
          <div><dt>${esc(t("cx_c_where"))}</dt><dd>${esc(ccName(d.cc))}</dd></div>
          <div><dt>${esc(t("cx_c_net"))}</dt><dd>${d.asn ? `${orgHTML(d.org, d.asn)}<span class="muted small cx-asline">${num(`AS${d.asn}`)}</span>` : "–"}</dd></div>
          <div><dt>${esc(t("cx_c_state"))}</dt><dd class="cx-states">${Object.entries(s.states || {}).map(([k, n]) => `<span class="cx-stn">${esc(stName(k))} <b>${num(nf(n, 0))}</b></span>`).join("") || "–"}</dd></div>
          <div><dt>${esc(t("cx_ip_subnet"))}</dt><dd>${num(esc(d.subnet))}</dd></div>
          <div><dt>${esc(t("cx_k_conns"))}</dt><dd>${num(nf(s.conns, 0))}${s.half ? ` <span class="pill bad">${num(nf(s.half, 0))} ${esc(t("cx_k_half"))}</span>` : ""}</dd></div>
          ${d.first ? `<div><dt>${esc(t("cx_c_first"))}</dt><dd>${esc(ago(d.first))}</dd></div>` : ""}
          ${d.ptr ? `<div class="cx-wide"><dt>${esc(t("cx_ptr"))}</dt><dd><bdi class="cx-mono">${esc(d.ptr)}</bdi></dd></div>` : ""}
          ${d.threat && d.threat.length ? `<div class="cx-wide"><dt>${esc(t("cx_threat_lists"))}</dt><dd>${d.threat.map((n) => pill("warn", n)).join(" ")}</dd></div>` : ""}
        </dl>
      </div>
      ${lan || d.allowed ? "" : `<div class="cx-ipd-acts">
        <span class="muted">${esc(t("cx_ip_ban"))}</span>${durs.map(([m, k]) => `<button type="button" class="btn small danger" data-d="ban" data-min="${m}">${esc(t(k))}</button>`).join("")}
        <button type="button" class="btn small danger solid" data-d="block">${icon("ban")}${esc(t("cx_ip_block"))}</button>
        <button type="button" class="btn small" data-d="net">${icon("grid")}${esc(t("cx_block_net"))}</button>
        <button type="button" class="btn small" data-d="allow">${icon("check")}${esc(t("cx_ip_allow"))}</button></div>`}
      <div class="cx-ipd-acts">
        <button type="button" class="btn small ghost" data-d="copy">${icon("copy")}${esc(t("cx_ip_copy"))}</button>
        <button type="button" class="btn small ghost" data-d="filter">${icon("filter")}${esc(t("cx_show_only"))}</button>
        <span class="muted small">${esc(t("cx_ip_ext"))}</span>
        <a class="btn small ghost" href="https://bgp.he.net/ip/${encodeURIComponent(d.ip)}" target="_blank" rel="noopener noreferrer">${icon("link")}bgp.he.net</a>
        <a class="btn small ghost" href="https://www.abuseipdb.com/check/${encodeURIComponent(d.ip)}" target="_blank" rel="noopener noreferrer">${icon("link")}AbuseIPDB</a>
      </div>
      <h4 class="cx-h4">${esc(t("cx_ip_conns"))}</h4>
      ${d.rows.length ? `<div class="table-wrap cx-table cx-compact"><table><thead><tr><th>${esc(t("cx_c_port"))}</th><th>${esc(t("cx_c_state"))}</th><th>${esc(t("cx_c_n"))}</th><th>${esc(t("cx_c_ttl"))}</th></tr></thead><tbody>${rows}</tbody></table></div>` : `<div class="empty">${esc(t("cx_none"))}</div>`}
    </div>`;
    box.addEventListener("click", async (e) => {
      const b = e.target.closest("[data-d]");
      if (!b) return;
      const a = b.dataset.d;
      if (a === "ban") { if (await act(b, () => post("/api/defender/block", { ip: d.ip, minutes: +b.dataset.min, note: "connections page" }), tv("cx_ban_done", { ip: d.ip }))) { dlg.close(); load(true); } }
      if (a === "block") { if (await act(b, () => post("/api/defender/block", { ip: d.ip, note: "connections page" }), tv("cx_ban_done", { ip: d.ip }))) { dlg.close(); load(true); } }
      if (a === "net") { dlg.close(); blockNet(null, d.subnet); }
      if (a === "allow") { if (await act(b, () => post("/api/defender/allow", { ip: d.ip, note: "connections page" }), tv("cx_allow_done", { ip: d.ip }))) { dlg.close(); load(true); } }
      if (a === "copy") { try { await navigator.clipboard.writeText(d.ip); toast(t("cx_copied")); } catch (x) { /* no clipboard */ } }
      if (a === "filter") { dlg.close(); C.dir = "all"; C.root.querySelectorAll('[data-c="dir"]').forEach((x) => x.setAttribute("aria-pressed", String(x.dataset.v === "all"))); C.f.ip = ""; setFilter("ip", d.ip); }
    });
  }

  async function reportDialog(id) {
    const dlg = openDialog({ title: t("cx_reports"), wide: true, hideSubmit: true, cancel: t("close"), body: `<div id="cx-rep"><div class="skeleton"></div></div>` });
    const box = dlg.querySelector("#cx-rep");
    let r;
    try { r = await api("/api/defender/conns/report", { id }); } catch (e) { box.innerHTML = `<div class="notice bad">${icon("alert")}<span>${esc(e.message)}</span></div>`; return; }
    const list = (head, items, cells) => items.length ? `<div class="table-wrap cx-table cx-compact"><table><thead><tr>${head.map((h) => `<th>${esc(t(h))}</th>`).join("")}</tr></thead><tbody>${items.map((x) => `<tr>${cells(x)}</tr>`).join("")}</tbody></table></div>` : "";
    box.innerHTML = `<div class="cx-rep">
      <h4 class="cx-h4">${icon("flame")}${esc(tv("cx_report_title", { date: when(r.since) }))} · <span class="muted">${esc(r.ended ? tv("cx_report_lasted", { d: dur(r.ended - r.since) }) : t("cx_report_ongoing"))}</span></h4>
      <p>${esc(tv("cx_report_peak", { n: nf(r.conns, 0), half: nf(r.half, 0), ips: nf(r.ips, 0) }))} <span class="muted small">(${esc(when(r.at))})</span></p>
      <div class="cx-rep-grid">
        <div><h4 class="cx-h4">${esc(t("cx_countries"))}</h4>${list(["cx_c_where", "cx_c_conns", "cx_c_ips"], r.countries, (c) => `<td>${place(c.cc)}</td><td class="cx-num">${num(nf(c.conns, 0))}</td><td class="cx-num">${num(nf(c.ips, 0))}</td>`)}</div>
        <div><h4 class="cx-h4">${esc(t("cx_ports"))}</h4>${list(["cx_c_port", "cx_c_conns", "cx_c_ips"], r.ports, (p) => `<td>${num(esc(p.port ? `${p.port}/${p.proto}` : p.proto))}${p.svc ? ` <span class="cx-svc">${esc(p.svc)}</span>` : ""}</td><td class="cx-num">${num(nf(p.conns, 0))}</td><td class="cx-num">${num(nf(p.ips, 0))}</td>`)}</div>
        <div><h4 class="cx-h4">${esc(t("cx_asns"))}</h4>${list(["cx_c_net2", "cx_c_conns", "cx_c_ips"], r.asns, (a) => `<td>${flag(a.cc)}${orgHTML(a.org, a.asn)} <span class="muted small">${num(`AS${a.asn}`)}</span></td><td class="cx-num">${num(nf(a.conns, 0))}</td><td class="cx-num">${num(nf(a.ips, 0))}</td>`)}</div>
        <div><h4 class="cx-h4">${esc(t("cx_subnets"))}</h4>${list(["cx_subnets", "cx_c_conns", "cx_c_ips"], r.subnets, (s) => `<td>${flag(s.cc)}${num(esc(s.net))}</td><td class="cx-num">${num(nf(s.conns, 0))}</td><td class="cx-num">${num(nf(s.ips, 0))}</td>`)}</div>
      </div>
      <h4 class="cx-h4">${esc(t("cx_ips"))}</h4>${list(["cx_c_ip", "cx_c_where", "cx_c_net", "cx_c_conns"], r.ip_list, (x) => `<td>${num(esc(x.ip))}</td><td>${place(x.cc)}</td><td>${orgHTML((r.orgs || {})[x.asn], x.asn)}</td><td class="cx-num">${num(nf(x.conns, 0))}${x.half ? ` <span class="cx-half">${num(nf(x.half, 0))}</span>` : ""}</td>`)}
    </div>`;
  }

  window.DefenderConns = { render, mount, tick, reset() { C.root = null; } };
})();
