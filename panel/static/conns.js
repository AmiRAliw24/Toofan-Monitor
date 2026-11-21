// Firewall > Connections: who talks to this server, how much, from which country and network, to which
// port, live. Two kinds of numbers, both from the defender agent (/api/defender/conns):
//   requests  - connections each address opened over a period (exact: counted from the kernel's events)
//   open now  - connections open at this moment (the kernel's connection table)
// This file only draws them.
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
    sliders: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
    chevron: '<path d="m6 9 6 6 6-6"/>',
  });

  // ---------------------------------------------------------------- strings
  const EN = {
    df_t_conns: "Connections", cx_n_ips: "{n} IPs",
    df_e_attack_sources: "Attack sources: {cc} sent {pct}% of {conns} incoming connections, most to {port}",
    df_e_bulk_ban: "{n} addresses banned from the connections page", df_e_conn_acct: "Per-connection traffic counting: {state}", df_on: "on", df_off: "off",
    cx_title: "Connections and requests",
    cx_sub: "Who talks to this server and how much. A request is one connection an address opened; every one is counted, also the ones that closed long ago.",
    cx_in: "Incoming", cx_out: "Outgoing", cx_all: "Both",
    cx_w_now: "Now", cx_w_1h: "1 hour", cx_w_24h: "24 hours",
    cx_w_long_now: "open right now", cx_w_long_1h: "in the last hour", cx_w_long_24h: "in the last 24 hours",
    cx_win_off: "Request counting is off (turn it on under More)",
    cx_live: "Live · every {s}", cx_paused: "Paused", cx_pause: "Pause", cx_resume: "Resume",
    cx_search: "Search an address, country, network, port...", cx_kbd: "Press / to search",
    cx_filters: "Filters", cx_proto: "Protocol", cx_state: "State of open connections", cx_any: "Any",
    cx_half_state: "Half-open / never completed", cx_clear: "Clear filters",
    cx_f_cc: "Country", cx_f_port: "Port", cx_f_ip: "Address", cx_f_asn: "Network", cx_f_proto: "Protocol", cx_f_state: "State",
    // tiles
    cx_k_req: "Requests", cx_k_req_sub: "{rate} a minute", cx_k_failed: "{n} never completed",
    cx_k_open: "Open now", cx_k_half: "{n} half-open",
    cx_k_ips: "Addresses", cx_k_ips_sub: "{cc} countries · {asn} networks",
    cx_k_bytes: "Traffic", cx_k_bytes_open: "of the open connections", cx_bytes_off: "Traffic per address is not counted", cx_bytes_on: "Count traffic",
    cx_k_req_off: "Not counted", cx_req_on: "Count requests",
    cx_since: "Counting started {ago}: the numbers cover only the time since then.",
    cx_lost: "Under heavy load the kernel dropped some events: the request counts may be a little low.",
    cx_act_err: "Requests cannot be counted: {e}",
    // address list
    cx_ips: "Addresses", cx_ips_note_win: "Sorted by requests {w}. Open now: connections open at this moment.",
    cx_ips_note_now: "Sorted by connections open right now.",
    cx_c_ip: "Address", cx_c_req: "Requests", cx_c_req_1h: "Requests · 1 h", cx_c_open: "Open now", cx_c_bytes: "Traffic", cx_c_ports: "Ports",
    cx_share: "{p} of all", cx_failed_t: "never completed (scan or flood)", cx_sort: "Sort", cx_sort_by: "Sort by",
    cx_top_of: "The busiest {n} of {total} addresses.", cx_other: "Plus {n} requests from addresses too many to list one by one (a flood of many addresses).",
    cx_more: "Show more", cx_less: "Show less", cx_none: "Nothing matches these filters.", cx_none_in: "Nobody is connected to this server right now.",
    cx_none_win: "No requests {w}.",
    cx_sel: "{n} selected", cx_sel_all: "Select all shown", cx_sel_clear: "Clear selection", cx_ban_sel: "Ban {d}", cx_block_sel: "Block permanently",
    cx_bulk_q: "Ban {n} addresses for {d}?", cx_bulk_perm_q: "Add {n} addresses to the permanent blocklist?", cx_bulk_done: "{n} banned", cx_bulk_skip: "{n} skipped (yours, allowlisted or invalid)",
    cx_csv: "CSV", cx_csv_t: "Download as CSV (opens in Excel)",
    // breakdowns
    cx_world: "Where they come from", cx_world_out: "Where this server connects to", cx_countries: "Countries",
    cx_ports: "Ports and services", cx_ports_out: "Remote ports", cx_asns: "Networks (providers)", cx_subnets: "Subnets",
    cx_by_req: "requests {w}", cx_by_open: "connections open now",
    cx_lan: "Local network", cx_unknown: "Unknown",
    cx_trend_req: "Requests per minute", cx_trend_req_sub: "Every point is the average of 5 minutes (1 hour) or of one hour (24 hours). The busiest countries are drawn separately.",
    cx_trend: "Open connections over time", cx_trend_sub: "Since this page was opened. The busiest countries are drawn separately.",
    cx_trend_total: "All", cx_trend_half: "Half-open", cx_trend_failed: "Never completed",
    cx_trend_wait: "The chart fills in as counting goes on: a point every 5 minutes (1 hour) or every hour (24 hours).",
    cx_live30: "Live (30 min)", cx_h48: "48 hours", cx_hist_empty: "The history fills up by itself: a point every 5 minutes, also when this page is closed.",
    cx_hist_off: "Background history is off.", cx_per_min: "/min",
    // findings
    cx_what_req: "incoming requests", cx_what_open: "open incoming connections",
    cx_ins_country: "{share} of {what} come from {cc} ({ips} addresses).",
    cx_ins_half: "{share} of open incoming connections are half-open ({n}): a typical sign of a SYN flood.",
    cx_ins_failed: "{share} of incoming requests never completed ({n}): a typical sign of a scan or a SYN flood.",
    cx_ins_subnet: "{share} of {what} come from one subnet, {net} ({ips} addresses).",
    cx_ins_ip: "One address makes {share} of {what}: {ip} ({n}).",
    cx_ins_asn: "{share} of {what} come from one network: {org}.",
    cx_attack: "An attack is in progress. The busiest sources are shown below; a report is being recorded.",
    cx_show_only: "Show only these", cx_block_cc: "Block {cc}", cx_block_net: "Block this subnet", cx_ban: "Ban 1 hour", cx_details: "Details",
    cx_banned: "banned", cx_blocked: "blocklisted", cx_allowed: "allowlisted", cx_threat: "on a threat list",
    cx_block_cc_q: "Block all incoming traffic from {cc}? About {n} connections from {ips} addresses are open now. You (logged-in and allowlisted addresses) are never blocked, and the change is tested for 60 seconds first.",
    cx_block_cc_btn: "Block country", cx_block_cc_done: "{cc} is blocked", cx_rule_name: "Blocked countries", cx_off_note: "Protection is off: the rule is saved and works once protection is turned on.",
    cx_block_net_q: "Add {net} to the blocklist? Every address in it is blocked until you remove it.", cx_block_net_done: "{net} is blocked",
    cx_ban_done: "{ip} is banned", cx_allow_done: "{ip} is allowlisted", cx_copied: "Copied",
    // more
    cx_adv: "More", cx_adv_sub: "Subnets, every open connection, attack reports and settings",
    cx_rows: "Every open connection", cx_rows_sub: "Identical connections (same address, port and state) are shown once with their count.",
    cx_c_dir: "", cx_c_proto: "Protocol", cx_c_to: "To", cx_c_from: "From", cx_c_n: "Count", cx_c_ttl: "Expires in", cx_c_port: "Port", cx_c_svc: "Service",
    cx_c_state: "State", cx_c_where: "Location", cx_c_net: "Network", cx_c_conns: "Connections", cx_c_ips: "Addresses", cx_c_net2: "Network", cx_c_first: "Seen since",
    cx_k_table: "Kernel table: {n} of {max} entries, read in {s}", cx_truncated: "The connection table is very large; only the first {n} entries were read.",
    cx_settings: "Settings",
    cx_acts: "Count requests per address", cx_acts_sub: "Counts every connection each address opens, from the kernel's connection events (about 1% of one core on a busy server). Keeps 24 hours.",
    cx_acct: "Count traffic per address", cx_acct_sub: "The kernel's connection accounting (a little CPU). Counts connections that start after it is turned on.",
    cx_hist: "Keep a 48-hour history of open connections", cx_hist_sub: "Every 5 minutes, also when this page is closed (about 0.3% of one core).",
    // dialogs
    cx_ip_title: "Address {ip}", cx_ip_conns: "Its open connections", cx_ip_ban: "Ban for", cx_ip_block: "Block permanently", cx_ip_allow: "Allowlist", cx_ip_copy: "Copy address",
    cx_ip_ext: "Look it up", cx_ip_subnet: "Subnet", cx_ip_hours: "Requests per hour, last 24 hours", cx_ip_ports: "Ports it requested (24 hours)",
    cx_ip_r1: "Requests · 1 hour", cx_ip_r24: "Requests · 24 hours", cx_ip_t24: "Traffic · 24 hours", cx_ip_no_open: "No open connection right now.",
    cx_ptr: "Host name", cx_threat_lists: "Threat lists", cx_program: "program", cx_c_prog: "Program / service",
    cx_m10: "10 minutes", cx_h1: "1 hour", cx_h24: "1 day", cx_d7: "7 days",
    cx_reports: "Attack reports", cx_reports_sub: "When an attack is detected, the busiest moment of its incoming connections is saved here: where it came from and what it hit.",
    cx_reports_none: "No attacks recorded yet.", cx_report_title: "Attack of {date}", cx_report_ongoing: "ongoing", cx_report_lasted: "lasted {d}",
    cx_report_peak: "At its peak: {n} incoming connections, {half} half-open, from {ips} addresses.",
    cx_db_loading: "Downloading the country and network database (about 40 MB, once a month). Addresses show without their country until it is ready.",
    cx_db_error: "The country and network database could not be downloaded: {e}", cx_db_retry: "Try again",
    cx_db_ok: "Locations: DB-IP Lite (CC BY 4.0), ip-location-db (CC0) and iptoasn.com, updated {date}. Map: svg-maps (CC BY 4.0). Flags: country-flag-icons (MIT).",
    cx_loading: "Reading the connections...",
    cx_st: { ESTABLISHED: "Established", SYN_RECV: "Half-open (in)", SYN_SENT: "Connecting", TIME_WAIT: "Closing (wait)", CLOSE_WAIT: "Closing", FIN_WAIT: "Closing", LAST_ACK: "Closing", CLOSE: "Closed", UNREPLIED: "No reply", ACTIVE: "Active" },
  };
  const FA = {
    df_t_conns: "اتصال‌ها", cx_n_ips: "{n} آی‌پی",
    df_e_attack_sources: "منشأ حمله: {cc} با {pct}٪ از {conns} اتصال ورودی، بیشتر به {port}",
    df_e_bulk_ban: "{n} آی‌پی از صفحه‌ی اتصال‌ها مسدود شد", df_e_conn_acct: "شمارش حجم هر اتصال: {state}", df_on: "روشن", df_off: "خاموش",
    cx_title: "اتصال‌ها و درخواست‌ها",
    cx_sub: "چه کسی با این سرور کار دارد و چقدر. هر درخواست یعنی یک اتصالی که آن آی‌پی باز کرده؛ همه شمرده می‌شوند، حتی آن‌هایی که خیلی وقت پیش بسته شده‌اند.",
    cx_in: "ورودی", cx_out: "خروجی", cx_all: "هر دو",
    cx_w_now: "الان", cx_w_1h: "۱ ساعت", cx_w_24h: "۲۴ ساعت",
    cx_w_long_now: "باز در همین لحظه", cx_w_long_1h: "در یک ساعت گذشته", cx_w_long_24h: "در ۲۴ ساعت گذشته",
    cx_win_off: "شمارش درخواست‌ها خاموش است (از بخش «بیشتر» روشنش کنید)",
    cx_live: "زنده · هر {s}", cx_paused: "متوقف", cx_pause: "توقف", cx_resume: "ادامه",
    cx_search: "جستجوی آی‌پی، کشور، شبکه، پورت...", cx_kbd: "برای جستجو / را بزنید",
    cx_filters: "فیلترها", cx_proto: "پروتکل", cx_state: "وضعیت اتصال‌های باز", cx_any: "همه",
    cx_half_state: "نیمه‌باز / ناتمام", cx_clear: "پاک کردن فیلترها",
    cx_f_cc: "کشور", cx_f_port: "پورت", cx_f_ip: "آدرس", cx_f_asn: "شبکه", cx_f_proto: "پروتکل", cx_f_state: "وضعیت",
    cx_k_req: "درخواست", cx_k_req_sub: "{rate} در دقیقه", cx_k_failed: "{n} ناتمام",
    cx_k_open: "اتصال باز الان", cx_k_half: "{n} نیمه‌باز",
    cx_k_ips: "آی‌پی", cx_k_ips_sub: "{cc} کشور · {asn} شبکه",
    cx_k_bytes: "حجم ترافیک", cx_k_bytes_open: "اتصال‌های باز", cx_bytes_off: "حجم هر آی‌پی شمرده نمی‌شود", cx_bytes_on: "شمارش حجم",
    cx_k_req_off: "شمرده نمی‌شود", cx_req_on: "شمارش درخواست‌ها",
    cx_since: "شمارش {ago} شروع شده؛ عددها فقط از آن موقع تا الان هستند.",
    cx_lost: "زیر بار سنگین، کرنل بخشی از رویدادها را جا انداخت؛ تعداد درخواست‌ها ممکن است کمی کمتر از واقع باشد.",
    cx_act_err: "درخواست‌ها شمرده نمی‌شوند: {e}",
    cx_ips: "آی‌پی‌ها", cx_ips_note_win: "به ترتیب تعداد درخواست {w}. «باز الان» یعنی اتصال‌هایی که همین لحظه باز هستند.",
    cx_ips_note_now: "به ترتیب اتصال‌هایی که همین الان باز هستند.",
    cx_c_ip: "آی‌پی", cx_c_req: "درخواست", cx_c_req_1h: "درخواست · ۱ ساعت", cx_c_open: "باز الان", cx_c_bytes: "حجم", cx_c_ports: "پورت‌ها",
    cx_share: "{p} از کل", cx_failed_t: "ناتمام (اسکن یا حمله)", cx_sort: "مرتب‌سازی", cx_sort_by: "مرتب‌سازی بر اساس",
    cx_top_of: "{n} آی‌پی پرکارتر از {total} آی‌پی.", cx_other: "به‌علاوه‌ی {n} درخواست از آدرس‌هایی که تعدادشان برای فهرست کردن تک‌تک زیاد بود (حمله با آدرس‌های زیاد).",
    cx_more: "نمایش بیشتر", cx_less: "نمایش کمتر", cx_none: "چیزی با این فیلترها پیدا نشد.", cx_none_in: "الان کسی به این سرور وصل نیست.",
    cx_none_win: "{w} درخواستی نبوده.",
    cx_sel: "{n} انتخاب شد", cx_sel_all: "انتخاب همه‌ی موارد نمایش‌داده‌شده", cx_sel_clear: "لغو انتخاب", cx_ban_sel: "مسدود {d}", cx_block_sel: "مسدود دائمی",
    cx_bulk_q: "{n} آی‌پی برای {d} مسدود شود؟", cx_bulk_perm_q: "{n} آی‌پی به لیست سیاه دائمی اضافه شود؟", cx_bulk_done: "{n} آی‌پی مسدود شد", cx_bulk_skip: "{n} مورد رد شد (خودتان، مجاز یا نامعتبر)",
    cx_csv: "CSV", cx_csv_t: "دانلود به‌صورت CSV (در اکسل باز می‌شود)",
    cx_world: "از کجا وصل می‌شوند", cx_world_out: "این سرور به کجا وصل می‌شود", cx_countries: "کشورها",
    cx_ports: "پورت‌ها و سرویس‌ها", cx_ports_out: "پورت‌های مقصد", cx_asns: "شبکه‌ها (ارائه‌دهنده)", cx_subnets: "زیرشبکه‌ها",
    cx_by_req: "درخواست {w}", cx_by_open: "اتصال باز الان",
    cx_lan: "شبکه‌ی محلی", cx_unknown: "نامشخص",
    cx_trend_req: "درخواست در دقیقه", cx_trend_req_sub: "هر نقطه میانگین ۵ دقیقه (حالت ۱ ساعت) یا یک ساعت (حالت ۲۴ ساعت) است. پرکارترین کشورها جدا رسم شده‌اند.",
    cx_trend: "اتصال‌های باز در طول زمان", cx_trend_sub: "از وقتی این صفحه باز شده. پرکارترین کشورها جدا رسم شده‌اند.",
    cx_trend_total: "همه", cx_trend_half: "نیمه‌باز", cx_trend_failed: "ناتمام",
    cx_trend_wait: "نمودار با ادامه‌ی شمارش پر می‌شود: هر ۵ دقیقه یک نقطه (حالت ۱ ساعت) یا هر ساعت یک نقطه (حالت ۲۴ ساعت).",
    cx_live30: "زنده (۳۰ دقیقه)", cx_h48: "۴۸ ساعت", cx_hist_empty: "تاریخچه خودش پر می‌شود: هر ۵ دقیقه یک نقطه، حتی وقتی این صفحه بسته است.",
    cx_hist_off: "ثبت تاریخچه در پس‌زمینه خاموش است.", cx_per_min: "/دقیقه",
    cx_what_req: "درخواست‌های ورودی", cx_what_open: "اتصال‌های باز ورودی",
    cx_ins_country: "{share} {what} از {cc} است ({ips} آی‌پی).",
    cx_ins_half: "{share} اتصال‌های باز ورودی نیمه‌باز است ({n})؛ نشانه‌ی معمول حمله‌ی ⁦SYN flood⁩.",
    cx_ins_failed: "{share} درخواست‌های ورودی ناتمام ماندند ({n})؛ نشانه‌ی معمول اسکن یا حمله‌ی ⁦SYN flood⁩.",
    cx_ins_subnet: "{share} {what} از یک زیرشبکه است: {net} ({ips} آی‌پی).",
    cx_ins_ip: "یک آی‌پی {share} {what} را دارد: {ip} ({n}).",
    cx_ins_asn: "{share} {what} از یک شبکه است: {org}.",
    cx_attack: "حمله در جریان است. پرکارترین منبع‌ها پایین آمده‌اند و گزارش آن ذخیره می‌شود.",
    cx_show_only: "فقط همین‌ها", cx_block_cc: "مسدود کردن {cc}", cx_block_net: "مسدود کردن زیرشبکه", cx_ban: "مسدود ۱ ساعت", cx_details: "جزئیات",
    cx_banned: "مسدود موقت", cx_blocked: "در لیست سیاه", cx_allowed: "مجاز", cx_threat: "در لیست تهدید",
    cx_block_cc_q: "همه‌ی ترافیک ورودی از {cc} مسدود شود؟ الان حدود {n} اتصال از {ips} آی‌پی باز است. خود شما (آدرس‌های واردشده و مجاز) هیچ‌وقت مسدود نمی‌شوید و تغییر اول ۶۰ ثانیه آزمایش می‌شود.",
    cx_block_cc_btn: "مسدود کردن کشور", cx_block_cc_done: "{cc} مسدود شد", cx_rule_name: "کشورهای مسدود", cx_off_note: "حفاظت خاموش است: قانون ذخیره شد و با روشن کردن حفاظت اعمال می‌شود.",
    cx_block_net_q: "{net} به لیست سیاه اضافه شود؟ همه‌ی آدرس‌های آن تا وقتی حذفش کنید مسدود می‌مانند.", cx_block_net_done: "{net} مسدود شد",
    cx_ban_done: "{ip} مسدود شد", cx_allow_done: "{ip} مجاز شد", cx_copied: "کپی شد",
    cx_adv: "بیشتر", cx_adv_sub: "زیرشبکه‌ها، تک‌تک اتصال‌های باز، گزارش حمله‌ها و تنظیمات",
    cx_rows: "تک‌تک اتصال‌های باز", cx_rows_sub: "اتصال‌های یکسان (همان آی‌پی، پورت و وضعیت) یک بار با تعدادشان نشان داده می‌شوند.",
    cx_c_dir: "", cx_c_proto: "پروتکل", cx_c_to: "به", cx_c_from: "از", cx_c_n: "تعداد", cx_c_ttl: "انقضا", cx_c_port: "پورت", cx_c_svc: "سرویس",
    cx_c_state: "وضعیت", cx_c_where: "موقعیت", cx_c_net: "شبکه", cx_c_conns: "اتصال", cx_c_ips: "آی‌پی", cx_c_net2: "شبکه", cx_c_first: "دیده‌شده از",
    cx_k_table: "جدول کرنل: {n} از {max} مورد، خواندن در {s}", cx_truncated: "جدول اتصال‌ها خیلی بزرگ است؛ فقط {n} مورد اول خوانده شد.",
    cx_settings: "تنظیمات",
    cx_acts: "شمارش درخواست‌های هر آی‌پی", cx_acts_sub: "هر اتصالی که هر آی‌پی باز می‌کند را از رویدادهای اتصال کرنل می‌شمارد (روی سرور شلوغ حدود ۱٪ یک هسته). ۲۴ ساعت نگه می‌دارد.",
    cx_acct: "شمارش حجم ترافیک هر آی‌پی", cx_acct_sub: "از شمارش اتصال کرنل استفاده می‌کند (کمی CPU). اتصال‌هایی شمرده می‌شوند که بعد از روشن کردن شروع شوند.",
    cx_hist: "نگه‌داشتن تاریخچه‌ی ۴۸ ساعته‌ی اتصال‌های باز", cx_hist_sub: "هر ۵ دقیقه، حتی وقتی این صفحه بسته است (حدود ۰٫۳٪ یک هسته).",
    cx_ip_title: "آی‌پی {ip}", cx_ip_conns: "اتصال‌های باز آن", cx_ip_ban: "مسدود برای", cx_ip_block: "مسدود دائمی", cx_ip_allow: "مجاز کردن", cx_ip_copy: "کپی آی‌پی",
    cx_ip_ext: "جستجو در", cx_ip_subnet: "زیرشبکه", cx_ip_hours: "درخواست در هر ساعت، ۲۴ ساعت گذشته", cx_ip_ports: "پورت‌هایی که درخواست داده (۲۴ ساعت)",
    cx_ip_r1: "درخواست · ۱ ساعت", cx_ip_r24: "درخواست · ۲۴ ساعت", cx_ip_t24: "حجم · ۲۴ ساعت", cx_ip_no_open: "الان اتصال بازی ندارد.",
    cx_ptr: "نام میزبان", cx_threat_lists: "لیست‌های تهدید", cx_program: "برنامه", cx_c_prog: "برنامه / سرویس",
    cx_m10: "۱۰ دقیقه", cx_h1: "۱ ساعت", cx_h24: "۱ روز", cx_d7: "۷ روز",
    cx_reports: "گزارش حمله‌ها", cx_reports_sub: "وقتی حمله‌ای تشخیص داده شود، شلوغ‌ترین لحظه‌ی اتصال‌های ورودی‌اش اینجا ذخیره می‌شود: از کجا آمده و به چه چیزی زده.",
    cx_reports_none: "هنوز حمله‌ای ثبت نشده.", cx_report_title: "حمله‌ی {date}", cx_report_ongoing: "در جریان", cx_report_lasted: "{d} طول کشید",
    cx_report_peak: "در اوج: {n} اتصال ورودی، {half} نیمه‌باز، از {ips} آی‌پی.",
    cx_db_loading: "در حال دریافت پایگاه‌داده‌ی کشور و شبکه‌ی آی‌پی‌ها (حدود ۴۰ مگابایت، ماهی یک بار). تا آماده شود آی‌پی‌ها بدون کشور نشان داده می‌شوند.",
    cx_db_error: "پایگاه‌داده‌ی کشور و شبکه دریافت نشد: {e}", cx_db_retry: "تلاش دوباره",
    cx_db_ok: "موقعیت‌ها: ⁦DB-IP Lite⁩ (⁦CC BY 4.0⁩)، ip-location-db (⁦CC0⁩) و iptoasn.com، به‌روزرسانی {date}. نقشه: svg-maps (⁦CC BY 4.0⁩). پرچم‌ها: country-flag-icons (⁦MIT⁩).",
    cx_loading: "در حال خواندن اتصال‌ها...",
    cx_st: { ESTABLISHED: "برقرار", SYN_RECV: "نیمه‌باز (ورودی)", SYN_SENT: "در حال اتصال", TIME_WAIT: "در حال بستن", CLOSE_WAIT: "در حال بستن", FIN_WAIT: "در حال بستن", LAST_ACK: "در حال بستن", CLOSE: "بسته", UNREPLIED: "بی‌پاسخ", ACTIVE: "فعال" },
  };
  P.addStrings(EN, FA);
  const tv = (k, vars) => Object.entries(vars || {}).reduce((s, [x, y]) => s.split(`{${x}}`).join(y), t(k));
  const stName = (s) => { const m = t("cx_st"); return (m && typeof m === "object" && m[s]) || s; };
  const pct = (x) => `${nf(x * 100, x > 0 && x < 0.1 ? 1 : 0)}%`;
  const n0 = (n) => num(nf(n, 0));

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
  // the panel's flag images; before they are loaded a colour emoji, or a code badge where there is none (Windows)
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
    const img = P.flagImg(cc, "cx-flag");
    if (img) return img;
    if (flagEmoji) return `<span class="cx-flag" aria-hidden="true">${String.fromCodePoint(...[...cc].map((ch) => 0x1f1a5 + ch.charCodeAt(0)))}</span>`;
    return `<span class="cx-flag cx-code" aria-hidden="true">${cc}</span>`;
  };
  const place = (cc) => `<span class="cx-place">${flag(cc)}<span>${esc(ccName(cc))}</span></span>`;
  const orgShort = (org) => String(org || "").replace(/^[A-Z0-9_.-]+(?: - |\s)(?=\S)/, "").trim() || org || "";
  const orgHTML = (org, asn) => `<bdi>${esc(orgShort(org) || (asn ? `AS${asn}` : "–"))}</bdi>`;
  let enNames = null;
  const enName = (cc) => { try { enNames = enNames || new Intl.DisplayNames(["en"], { type: "region" }); return enNames.of(cc) || cc; } catch (e) { return cc; } };

  // ---------------------------------------------------------------- state
  const NOF = () => ({ cc: "", port: "", ip: "", asn: "", proto: "", state: "", q: "" });
  const C = {
    dir: "in", win: "1h", f: NOF(), limit: 300, data: null, paused: false, busy: false,
    last: 0, root: null, ctx: null, map: null, more: {}, err: "", adv: false,
    trend: "live", hist: null, histAt: 0, sel: new Set(), sort: null, html: {},
  };
  // the period the numbers cover, as the agent answered it ("now" when requests are not counted)
  const W = () => (C.data && C.data.win) || "now";
  const isWin = () => W() !== "now";
  const counting = () => !!(C.data && C.data.act && C.data.act.counting);
  const wLong = (w) => t(`cx_w_long_${w || W()}`);

  function params() {
    const p = { dir: C.dir, limit: C.limit, win: C.win };
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

  window.addEventListener("panel:flags", () => {
    C.html = {};
    paint();
    const tip = $("cx-tip");
    if (tip) tip.hidden = true;
  });

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
    if (C.trend === "h48" && !isWin() && Date.now() - C.histAt > 60000) loadHistory();
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
  const card = (id, ic, title, body, extra = "") => `<div class="chart cx-card" id="${id}-card"><header><h3 id="${id}-h">${icon(ic)}<span>${esc(title)}</span></h3>${extra}</header><p class="cx-card-sub muted small" id="${id}-sub"></p><div id="${id}">${body}</div></div>`;

  function render(ctx) {
    C.ctx = ctx;
    return `<section class="sec cx" id="cx">
      <div class="cx-head">
        <div class="cx-head-t"><h3>${icon("network")}${esc(t("cx_title"))}</h3><p class="muted small">${esc(t("cx_sub"))}</p></div>
        <div class="cx-live" id="cx-live"></div>
      </div>
      <div class="cx-bar">
        <div class="seg cx-seg" role="group" aria-label="${esc(t("cx_title"))}" id="cx-dir">${dirSeg()}</div>
        <div class="seg cx-seg" role="group" aria-label="${esc(t("cx_k_req"))}" id="cx-win">${winSeg()}</div>
        <label class="cx-search" title="${esc(t("cx_kbd"))}">${icon("search")}<input type="search" id="cx-q" placeholder="${esc(t("cx_search"))}" value="${esc(C.f.q)}" autocomplete="off" spellcheck="false" aria-label="${esc(t("cx_search"))}"><kbd class="cx-kbd" aria-hidden="true">/</kbd></label>
        <div class="cx-fmenu" id="cx-fmenu">
          <button type="button" class="btn ghost cx-fbtn" data-c="fmenu" aria-expanded="false" aria-controls="cx-fpop">${icon("sliders")}<span>${esc(t("cx_filters"))}</span><span class="cx-fcount" id="cx-fcount"></span></button>
          <div class="cx-fpop" id="cx-fpop" hidden>
            <label class="field"><span>${esc(t("cx_proto"))}</span><select id="cx-proto">${opts([["", t("cx_any")], ["tcp", "TCP"], ["udp", "UDP"], ["icmp", "ICMP"], ["ipv6-icmp", "ICMPv6"]], C.f.proto)}</select></label>
            <label class="field"><span>${esc(t("cx_state"))}</span><select id="cx-state">${opts([["", t("cx_any")], ["HALF", t("cx_half_state")], ...["ESTABLISHED", "SYN_RECV", "SYN_SENT", "TIME_WAIT", "CLOSE_WAIT", "UNREPLIED", "ACTIVE"].map((s) => [s, stName(s)])], C.f.state)}</select></label>
          </div>
        </div>
      </div>
      <div class="cx-chips" id="cx-chips"></div>
      <div id="cx-alerts"></div>
      <div class="cx-kpis" id="cx-kpis"><div class="skeleton"></div></div>
      <div id="cx-notes"></div>
      <div class="chart cx-card cx-main">
        <header><h3>${icon("globe")}<span>${esc(t("cx_ips"))}</span><span class="cx-count" id="cx-ips-n"></span></h3>
          <label class="cx-sortm"><span class="sr-only">${esc(t("cx_sort_by"))}</span><select id="cx-sortm" aria-label="${esc(t("cx_sort_by"))}"></select></label>
          <button type="button" class="btn small ghost cx-csv" data-c="csv" data-k="ips" title="${esc(t("cx_csv_t"))}">${icon("file")}${esc(t("cx_csv"))}</button></header>
        <p class="cx-card-sub muted small" id="cx-ips-sub"></p>
        <div id="cx-bulk"></div><div id="cx-ips"></div></div>
      <div class="cx-geo">
        <div class="chart cx-card cx-map-card"><header><h3 id="cx-world-h">${icon("globe")}<span>${esc(t("cx_world"))}</span></h3></header><div class="cx-map" id="cx-map"></div><div class="cx-tip" id="cx-tip" hidden></div></div>
        ${card("cx-cc", "pin", t("cx_countries"), "")}
      </div>
      <div class="cx-grid">
        ${card("cx-ports", "server", t("cx_ports"), "")}
        ${card("cx-asns", "network", t("cx_asns"), "")}
      </div>
      <div class="chart cx-card cx-trend-card" id="cx-trend-card" hidden><header><h3 id="cx-trend-h">${icon("activity")}<span>${esc(t("cx_trend_req"))}</span></h3>
        <div class="seg" role="group" id="cx-trend-seg" aria-label="${esc(t("cx_trend"))}">${[["live", "cx_live30"], ["h48", "cx_h48"]].map(([k, l]) => `<button type="button" data-c="trend" data-v="${k}" aria-pressed="${C.trend === k}">${esc(t(l))}</button>`).join("")}</div></header>
        <p class="cx-card-sub muted small" id="cx-trend-sub"></p><div class="legend" id="cx-trend-legend"></div><div class="plot" id="cx-trend"></div></div>
      <details class="cx-adv" id="cx-adv" ${C.adv ? "open" : ""}>
        <summary><span class="cx-adv-t">${icon("list")}<b>${esc(t("cx_adv"))}</b><span class="muted small">${esc(t("cx_adv_sub"))}</span></span>${icon("chevron")}</summary>
        <div class="cx-adv-body">
          ${card("cx-subnets", "grid", t("cx_subnets"), "")}
          <div class="chart cx-card"><header><h3>${icon("list")}<span>${esc(t("cx_rows"))}</span></h3>
            <button type="button" class="btn small ghost cx-csv" data-c="csv" data-k="rows" title="${esc(t("cx_csv_t"))}">${icon("file")}${esc(t("cx_csv"))}</button></header>
            <p class="cx-card-sub muted small">${esc(t("cx_rows_sub"))}</p><div id="cx-rows"></div></div>
          <div class="chart cx-card"><header><h3>${icon("report")}<span>${esc(t("cx_reports"))}</span></h3></header><p class="cx-card-sub muted small">${esc(t("cx_reports_sub"))}</p><div id="cx-reports"></div></div>
          <div class="chart cx-card"><header><h3>${icon("sliders")}<span>${esc(t("cx_settings"))}</span></h3></header><div class="cx-foot" id="cx-foot"></div></div>
        </div>
      </details>
      <div class="cx-credit" id="cx-credit"></div>
    </section>`;
  }
  const opts = (list, cur) => list.map(([v, l]) => `<option value="${esc(v)}" ${v === cur ? "selected" : ""}>${esc(l)}</option>`).join("");
  const dirSeg = () => [["in", "arrow-in", "cx_in"], ["out", "arrow-out", "cx_out"], ["all", "arrow-both", "cx_all"]]
    .map(([d, ic, k]) => `<button type="button" data-c="dir" data-v="${d}" aria-pressed="${C.dir === d}">${icon(ic)}<span>${esc(t(k))}</span></button>`).join("");
  const winSeg = () => {
    const off = C.data && C.data.act && !C.data.act.counting;
    return [["now", "cx_w_now"], ["1h", "cx_w_1h"], ["24h", "cx_w_24h"]].map(([w, k]) => {
      const dis = off && w !== "now";
      const on = (off ? "now" : C.win) === w;
      return `<button type="button" data-c="win" data-v="${w}" aria-pressed="${on}" ${dis ? `disabled title="${esc(t("cx_win_off"))}"` : ""}>${w === "now" ? '<span class="cx-dot sm" aria-hidden="true"></span>' : icon("clock")}<span>${esc(t(k))}</span></button>`;
    }).join("");
  };

  async function mount(body) {
    C.root = body.querySelector("#cx");
    if (!C.root) return;
    C.root.addEventListener("click", onClick);
    C.root.addEventListener("change", onChange);
    const adv = C.root.querySelector("#cx-adv");
    adv.addEventListener("toggle", () => { C.adv = adv.open; });
    const q = C.root.querySelector("#cx-q");
    let deb = 0;
    q.addEventListener("input", () => { clearTimeout(deb); deb = setTimeout(() => { C.f.q = q.value.trim(); C.limit = 300; load(true); }, 350); });
    if (!C.keyBound) {
      C.keyBound = true;
      document.addEventListener("keydown", (e) => {
        if (!C.root || !document.body.contains(C.root)) return;
        if (e.key === "Escape") { fmenu(false); return; }
        if (e.key !== "/" || e.ctrlKey || e.metaKey || e.altKey) return;
        const tag = (document.activeElement && document.activeElement.tagName) || "";
        if (/^(INPUT|TEXTAREA|SELECT)$/.test(tag) || document.querySelector("dialog[open]")) return;
        e.preventDefault();
        const box = $("cx-q");
        if (box) box.focus();
      });
      document.addEventListener("click", (e) => { if (C.root && !e.target.closest("#cx-fmenu")) fmenu(false); });
    }
    C.html = {};
    paintLive();
    loadMap();
    await load(true);
  }
  function fmenu(open) {
    const pop = $("cx-fpop"), b = C.root && C.root.querySelector('[data-c="fmenu"]');
    if (!pop || !b) return;
    pop.hidden = !open;
    b.setAttribute("aria-expanded", String(open));
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
    const out = C.dir === "out";
    put("cx-dir", dirSeg());
    put("cx-win", winSeg());
    put("cx-chips", chipsHTML());
    put("cx-fcount", (C.f.proto ? 1 : 0) + (C.f.state ? 1 : 0) ? esc(String((C.f.proto ? 1 : 0) + (C.f.state ? 1 : 0))) : "");
    put("cx-alerts", alertsHTML(d));
    put("cx-kpis", kpisHTML(d));
    put("cx-notes", notesHTML(d));
    put("cx-ips-n", d.ips_total ? esc(nf(d.ips_total, 0)) : "");
    put("cx-ips-sub", esc(isWin() ? tv("cx_ips_note_win", { w: wLong() }) : t("cx_ips_note_now")));
    put("cx-sortm", sortOptions(d));
    put("cx-ips", ipsHTML(d));
    put("cx-bulk", bulkHTML());
    const by = esc(isWin() ? tv("cx_by_req", { w: wLong() }) : t("cx_by_open"));
    put("cx-world-h", `${icon("globe")}<span>${esc(t(out ? "cx_world_out" : "cx_world"))}</span>`);
    put("cx-cc", countriesHTML(d));
    put("cx-cc-sub", by);
    paintMap(d);
    put("cx-ports-h", `${icon("server")}<span>${esc(t(out ? "cx_ports_out" : "cx_ports"))}</span>`);
    put("cx-ports", portsHTML(d));
    put("cx-ports-sub", by);
    put("cx-asns", asnsHTML(d));
    put("cx-asns-sub", by);
    put("cx-subnets", subnetsHTML(d));
    put("cx-subnets-sub", by);
    paintTrend(d);
    put("cx-rows", rowsHTML(d));
    put("cx-reports", reportsHTML(d));
    put("cx-foot", footHTML(d));
    put("cx-credit", creditHTML(d));
  }

  function paintLive() {
    const d = C.data;
    const every = d ? `${nf(Math.round(d.interval), 0)}s` : "…";
    put("cx-live", `${C.paused ? `<span class="cx-dot off"></span><span>${esc(t("cx_paused"))}</span>` : `<span class="cx-dot"></span><span>${esc(tv("cx_live", { s: every }))}</span>`}
      <button type="button" class="btn small ghost icon" data-c="pause" title="${esc(t(C.paused ? "cx_resume" : "cx_pause"))}" aria-label="${esc(t(C.paused ? "cx_resume" : "cx_pause"))}">${icon(C.paused ? "play" : "pause")}</button>`);
  }

  function chipsHTML() {
    const lab = {
      cc: (v) => `${flag(v)}${esc(ccName(v))}`, port: (v) => num(esc(v)), ip: (v) => num(esc(v)),
      asn: (v) => esc(`AS${v} ${orgShort((C.data && C.data.orgs && C.data.orgs[v]) || "")}`),
      proto: (v) => esc(v.toUpperCase()), state: (v) => esc(v === "HALF" ? t("cx_half_state") : stName(v)),
    };
    const chips = ["cc", "port", "ip", "asn", "proto", "state"].filter((k) => C.f[k]).map((k) => `<button type="button" class="chip cx-chip" data-c="unfilter" data-k="${k}" aria-label="${esc(`${t(`cx_f_${k}`)}: ${t("cx_clear")}`)}">
      <span class="muted">${esc(t(`cx_f_${k}`))}:</span>${lab[k](C.f[k])}${icon("x")}</button>`);
    if (!chips.length) return "";
    return `${chips.join("")}<button type="button" class="btn small ghost" data-c="clear">${esc(t("cx_clear"))}</button>`;
  }

  function alertsHTML(d) {
    const out = [];
    const st = C.ctx && C.ctx.D && C.ctx.D.st;
    if (st && st.attack && st.attack.active) out.push(`<div class="notice bad cx-alert">${icon("flame")}<span class="cx-alert-t">${esc(t("cx_attack"))}</span></div>`);
    const what = esc(t(isWin() ? "cx_what_req" : "cx_what_open"));
    for (const i of d.insights || []) {
      let text = "", acts = "";
      const share = `<b>${num(pct(i.share))}</b>`;
      if (i.kind === "country") {
        text = tv("cx_ins_country", { share, what, cc: `${flag(i.cc)}<b>${esc(ccName(i.cc))}</b>`, ips: n0(i.ips) });
        acts = `<button type="button" class="btn small" data-c="filter" data-k="cc" data-v="${esc(i.cc)}">${icon("filter")}${esc(t("cx_show_only"))}</button>
          <button type="button" class="btn small danger" data-c="block-cc" data-cc="${esc(i.cc)}">${icon("ban")}${esc(tv("cx_block_cc", { cc: ccName(i.cc) }))}</button>`;
      } else if (i.kind === "half") {
        text = tv(isWin() ? "cx_ins_failed" : "cx_ins_half", { share, n: n0(i.conns) });
        acts = `<button type="button" class="btn small" data-c="filter" data-k="state" data-v="HALF">${icon("filter")}${esc(t("cx_show_only"))}</button>`;
      } else if (i.kind === "subnet") {
        text = tv("cx_ins_subnet", { share, what, net: `${flag(i.cc)}<b>${num(esc(i.net))}</b>`, ips: n0(i.ips) });
        acts = `<button type="button" class="btn small" data-c="filter" data-k="ip" data-v="${esc(i.net)}">${icon("filter")}${esc(t("cx_show_only"))}</button>
          <button type="button" class="btn small danger" data-c="block-net" data-net="${esc(i.net)}">${icon("ban")}${esc(t("cx_block_net"))}</button>`;
      } else if (i.kind === "ip") {
        text = tv("cx_ins_ip", { share, what, ip: `${flag(i.cc)}<b>${num(esc(i.ip))}</b>`, n: n0(i.conns) });
        acts = `<button type="button" class="btn small" data-c="ip" data-ip="${esc(i.ip)}">${icon("eye")}${esc(t("cx_details"))}</button>
          <button type="button" class="btn small danger" data-c="ban" data-ip="${esc(i.ip)}" data-min="60">${icon("ban")}${esc(t("cx_ban"))}</button>`;
      } else if (i.kind === "asn") {
        text = tv("cx_ins_asn", { share, what, org: `<b>${orgHTML(d.orgs[i.asn], i.asn)}</b>` });
        acts = `<button type="button" class="btn small" data-c="filter" data-k="asn" data-v="${esc(i.asn)}">${icon("filter")}${esc(t("cx_show_only"))}</button>`;
      }
      if (text) out.push(`<div class="notice warn cx-alert">${icon("alert")}<span class="cx-alert-t">${text}</span><span class="cx-alert-a">${acts}</span></div>`);
    }
    return out.join("");
  }

  // the series' rate per minute (a bucket that just started counts only its elapsed seconds)
  const rates = (series) => (series || []).map((p) => (p.in * 60) / Math.max(60, p.span || 60));

  function kpisHTML(d) {
    const s = d.summary, a = d.act || {}, w = isWin();
    const tile = (label, value, sub = "", cls = "", extra = "") => `<div class="cx-kpi ${cls}"><span class="cx-kpi-l">${label}</span><b class="cx-kpi-v">${value}</b>${sub ? `<span class="cx-kpi-s">${sub}</span>` : ""}${extra}</div>`;
    const tiles = [];
    // 1. requests
    if (a.counting) {
      const mins = Math.max(1, (a.series || []).reduce((x, p) => x + (p.span || 0), 0) / 60);
      const rate = a.req / mins;
      const failed = a.failed && a.req ? `<span class="cx-kpi-bad">${icon("alert")}${esc(tv("cx_k_failed", { n: nf(a.failed, 0) }))}</span>` : "";
      const bad = a.req >= 50 && a.failed / a.req >= 0.25 ? "warn" : "";
      tiles.push(tile(`${esc(t("cx_k_req"))}<span class="cx-kpi-w">${esc(t(`cx_w_${a.win}`))}</span>`, n0(a.req),
        `${esc(tv("cx_k_req_sub", { rate: nf(rate, rate < 10 ? 1 : 0) }))}${failed}`, `accent ${bad}`, spark(rates(a.series))));
    } else {
      tiles.push(`<div class="cx-kpi muted-kpi"><span class="cx-kpi-l">${esc(t("cx_k_req"))}</span><span class="cx-kpi-s">${esc(a.error && a.on ? tv("cx_act_err", { e: a.error }) : t("cx_k_req_off"))}</span>${a.on === false ? `<button type="button" class="btn small" data-c="acts" data-on="1">${esc(t("cx_req_on"))}</button>` : ""}</div>`);
    }
    // 2. open now
    const halfShare = s.conns ? s.half / s.conns : 0;
    tiles.push(tile(esc(t("cx_k_open")), n0(s.conns), s.half ? `<span class="${halfShare >= 0.25 && s.half >= 50 ? "cx-kpi-bad" : ""}">${esc(tv("cx_k_half", { n: nf(s.half, 0) }))}</span>` : "",
      halfShare >= 0.25 && s.half >= 50 ? "bad" : "", w ? "" : spark((d.timeline || []).map((p) => p.in || 0))));
    // 3. addresses
    const ips = w ? a.ips : s.ips, ccs = w ? a.countries : s.countries, asns = w ? a.asns : s.asns;
    tiles.push(tile(esc(t("cx_k_ips")), n0(ips), esc(tv("cx_k_ips_sub", { cc: nf(ccs, 0), asn: nf(asns, 0) }))));
    // 4. traffic
    if (d.acct) {
      const bi = s.bytes_in + (w ? a.bytes_in : 0), bo = s.bytes_out + (w ? a.bytes_out : 0);
      tiles.push(tile(`${esc(t("cx_k_bytes"))}${w ? `<span class="cx-kpi-w">${esc(t(`cx_w_${a.win}`))}</span>` : ""}`, num(esc(fmtBytes(bi + bo))),
        `${icon("down")}${num(esc(fmtBytes(bi)))}<span class="cx-sep"></span>${icon("up")}${num(esc(fmtBytes(bo)))}${w ? "" : `<span class="muted">· ${esc(t("cx_k_bytes_open"))}</span>`}`));
    } else {
      tiles.push(`<div class="cx-kpi muted-kpi"><span class="cx-kpi-l">${esc(t("cx_k_bytes"))}</span><span class="cx-kpi-s">${esc(t("cx_bytes_off"))}</span><button type="button" class="btn small" data-c="acct" data-on="1">${esc(t("cx_bytes_on"))}</button></div>`);
    }
    return tiles.join("");
  }

  function notesHTML(d) {
    const a = d.act || {}, out = [];
    if (a.counting && a.since && Date.now() / 1000 - a.since < (isWin() ? a.secs : 3600)) out.push(`<p class="cx-note">${icon("clock")}<span>${esc(tv("cx_since", { ago: ago(a.since) }))}</span></p>`);
    if (a.counting && a.lost) out.push(`<p class="cx-note warn">${icon("alert")}<span>${esc(t("cx_lost"))}</span></p>`);
    if (a.on && !a.running && a.error) out.push(`<p class="cx-note warn">${icon("alert")}<span>${esc(tv("cx_act_err", { e: a.error }))}</span></p>`);
    return out.join("");
  }

  function spark(v) {
    if (!v || v.length < 2) return "";
    const max = Math.max(1, ...v), W2 = 120, H = 28;
    const pts = v.map((y, i) => [(i / (v.length - 1)) * W2, H - 2 - (y / max) * (H - 6)]);
    const line = pts.map((p) => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ");
    return `<svg class="cx-spark" viewBox="0 0 ${W2} ${H}" preserveAspectRatio="none" aria-hidden="true"><polygon points="0,${H} ${line} ${W2},${H}" fill="var(--accent)" opacity=".12"/><polyline points="${line}" fill="none" stroke="var(--accent)" stroke-width="1.6" vector-effect="non-scaling-stroke" stroke-linejoin="round"/></svg>`;
  }

  const moreBtn = (key, total, shown) => (total > shown || C.more[key])
    ? `<button type="button" class="btn small ghost cx-more" data-c="more" data-k="${key}">${icon("chevron")}${esc(t(C.more[key] ? "cx_less" : "cx_more"))}${C.more[key] ? "" : ` (${n0(total - shown)})`}</button>` : "";
  const take = (key, list, n) => (C.more[key] ? list : list.slice(0, n));
  const empty = (d) => {
    const filtered = Object.values(C.f).some(Boolean);
    const msg = filtered ? t("cx_none") : isWin() ? tv("cx_none_win", { w: wLong() }) : C.dir === "in" ? t("cx_none_in") : t("cx_none");
    return `<div class="empty cx-empty">${icon("globe")}<span>${esc(msg)}</span></div>`;
  };
  const meter = (n, max, bad) => `<span class="cx-meter" aria-hidden="true"><i class="${bad ? "bad" : ""}" style="--w:${max ? Math.max(1.5, (n / max) * 100).toFixed(1) : 0}%"></i></span>`;
  const mainTotal = (d) => Math.max(1, isWin() ? d.act.req : d.summary.conns);

  // one ranked list for countries, ports, networks and subnets: name and count on top, a bar and the share below
  function ranks(d, list, key, n, o) {
    if (!list.length) return empty(d);
    const max = list[0].conns, total = mainTotal(d);
    const rows = take(key, list, n).map((x) => {
      const v = o.v(x), on = o.on(x);
      return `<div class="cx-rl-row${on ? " on" : ""}">
        <button type="button" class="cx-rl-main" data-c="filter" data-k="${o.k}" data-v="${esc(v)}" aria-pressed="${on}">
          <span class="cx-rl-name">${o.label(x)}</span>
          <span class="cx-rl-n">${n0(x.conns)}</span>
          ${meter(x.conns, max, x.half >= 10 && x.half > x.conns / 3)}
          <span class="cx-rl-sub">${num(pct(x.conns / total))}<span class="cx-dotsep" aria-hidden="true"></span>${esc(tv("cx_n_ips", { n: nf(x.ips, 0) }))}</span>
        </button>${o.act ? o.act(x) : ""}</div>`;
    }).join("");
    return `<div class="cx-rl">${rows}</div>${moreBtn(key, list.length, n)}`;
  }

  function countriesHTML(d) {
    return ranks(d, d.countries, "cc", 8, {
      k: "cc", v: (c) => c.cc, on: (c) => C.f.cc === c.cc, label: (c) => place(c.cc),
      act: (c) => (C.dir !== "out" && /^[A-Z]{2}$/.test(c.cc) ? `<button type="button" class="btn small icon ghost danger cx-rl-act" data-c="block-cc" data-cc="${esc(c.cc)}" title="${esc(tv("cx_block_cc", { cc: ccName(c.cc) }))}" aria-label="${esc(tv("cx_block_cc", { cc: ccName(c.cc) }))}">${icon("ban")}</button>` : ""),
    });
  }

  function portsHTML(d) {
    return ranks(d, d.ports, "ports", 6, {
      k: "port", v: (p) => p.port, on: (p) => !!p.port && C.f.port === p.port,
      label: (p) => `<span class="cx-port">${num(esc(p.port ? `${p.port}/${p.proto}` : p.proto))}</span>${p.svc ? `<span class="cx-svc">${esc(p.svc)}</span>` : ""}${p.ccs.length ? `<span class="cx-flags">${p.ccs.slice(0, 3).map((c) => flag(c)).join("")}</span>` : ""}`,
    });
  }

  function asnsHTML(d) {
    return ranks(d, d.asns, "asns", 6, {
      k: "asn", v: (a) => a.asn, on: (a) => C.f.asn === String(a.asn),
      label: (a) => `${flag(a.cc)}<span class="cx-org">${orgHTML(a.org || d.orgs[a.asn], a.asn)}</span><span class="cx-asn">${num(`AS${a.asn}`)}</span>`,
    });
  }

  function subnetsHTML(d) {
    return ranks(d, d.subnets, "subnets", 8, {
      k: "ip", v: (s) => s.net, on: (s) => C.f.ip === s.net, label: (s) => `${flag(s.cc)}<span class="cx-port">${num(esc(s.net))}</span>`,
      act: (s) => (C.dir !== "out" && s.cc !== "LAN" ? `<button type="button" class="btn small icon ghost danger cx-rl-act" data-c="block-net" data-net="${esc(s.net)}" title="${esc(t("cx_block_net"))}" aria-label="${esc(t("cx_block_net"))} ${esc(s.net)}">${icon("ban")}</button>` : ""),
    });
  }

  // ---------------------------------------------------------------- the address list
  const statusPills = (r) => [r.banned ? pill("bad", t("cx_banned")) : "", r.blocked ? pill("bad", t("cx_blocked")) : "", r.allowed ? pill("ok", t("cx_allowed")) : "", r.threat && r.threat.length !== 0 ? pill("warn", t("cx_threat")) : ""].join("");
  const statePill = (s) => {
    const kind = s === "ESTABLISHED" || s === "ACTIVE" ? "ok" : s === "SYN_RECV" || s === "UNREPLIED" ? "bad" : s === "SYN_SENT" ? "warn" : "";
    return `<span class="pill ${kind} cx-st">${esc(stName(s))}</span>`;
  };
  const SORTS = { req: (r) => r.req, conns: (r) => r.conns, bytes: (r) => r.bytes_in + r.bytes_out, failed: (r) => r.failed + r.half };
  const showBytes = (d) => d.acct || d.ips.some((r) => r.bytes_in + r.bytes_out > 0);
  const sortKey = (d) => {
    const k = C.sort && C.sort.k;
    if (k === "req" && !counting()) return "conns";
    if (k === "bytes" && !showBytes(d)) return isWin() ? "req" : "conns";
    return k && SORTS[k] ? k : isWin() ? "req" : "conns";
  };
  const sortDesc = () => !C.sort || C.sort.desc;
  const selectable = (r) => C.dir !== "out" && r.cc !== "LAN" && !r.allowed && !r.banned && !r.blocked;
  const reqLabel = () => t(isWin() ? "cx_c_req" : "cx_c_req_1h");

  function sortOptions(d) {
    const k = sortKey(d), list = [];
    if (counting()) list.push(["req", reqLabel()]);
    list.push(["conns", t("cx_c_open")]);
    if (showBytes(d)) list.push(["bytes", t("cx_c_bytes")]);
    if (counting()) list.push(["failed", t("cx_failed_t")]);
    return opts(list, k);
  }

  function ipsHTML(d) {
    if (!d.ips.length) return empty(d);
    const req = counting(), bytes = showBytes(d), out = C.dir === "out", k = sortKey(d), f = SORTS[k], desc = sortDesc();
    const sorted = d.ips.slice().sort((a, b) => (desc ? f(b) - f(a) : f(a) - f(b)) || b.req - a.req || b.conns - a.conns);
    const shown = take("ips", sorted, 15), canSel = shown.filter(selectable);
    const allOn = canSel.length && canSel.every((r) => C.sel.has(r.ip));
    const totReq = Math.max(1, d.act ? d.act.req : 1), maxReq = Math.max(1, ...d.ips.map((r) => r.req)), maxOpen = Math.max(1, ...d.ips.map((r) => r.conns));
    const cols = ["who", req && "req", "open", bytes && "bytes", "ports", "act"].filter(Boolean);
    const th = (key, label, sortable = true) => {
      if (!sortable) return `<div class="cx-il-h cx-il-${key}" role="columnheader">${esc(label)}</div>`;
      const on = k === key;
      return `<div class="cx-il-h cx-il-${key}" role="columnheader" aria-sort="${on ? (desc ? "descending" : "ascending") : "none"}"><button type="button" class="cx-th${on ? " on" : ""}" data-c="sort" data-k="${key}" title="${esc(t("cx_sort"))}">${esc(label)}<span class="cx-th-i" aria-hidden="true">${on ? (desc ? "▾" : "▴") : "▾"}</span></button></div>`;
    };
    const head = `<div class="cx-il-row cx-il-head" role="row">
      <div class="cx-il-h cx-il-who" role="columnheader">${canSel.length ? `<input type="checkbox" class="cx-pick" data-c="pick-all" ${allOn ? "checked" : ""} aria-label="${esc(t("cx_sel_all"))}" title="${esc(t("cx_sel_all"))}">` : ""}${esc(t("cx_c_ip"))}</div>
      ${req ? th("req", reqLabel()) : ""}${th("conns", t("cx_c_open"))}${bytes ? th("bytes", t("cx_c_bytes")) : ""}${th("ports", t("cx_c_ports"), false)}<div class="cx-il-h cx-il-act" role="columnheader"></div></div>`;
    const rows = shown.map((r, i) => {
      const picked = C.sel.has(r.ip);
      const failed = r.failed ? `<span class="cx-bad-n" title="${esc(t("cx_failed_t"))}">${icon("alert")}${n0(r.failed)}</span>` : "";
      const where = `<button type="button" class="cx-link" data-c="filter" data-k="cc" data-v="${esc(r.cc || "?")}">${esc(ccName(r.cc || "?"))}</button>${r.asn ? `<span class="cx-dotsep" aria-hidden="true"></span><button type="button" class="cx-link cx-org" data-c="filter" data-k="asn" data-v="${esc(r.asn)}">${orgHTML(d.orgs[r.asn], r.asn)}</button>` : ""}`;
      return `<div class="cx-il-row${r.banned || r.blocked ? " cx-dim" : ""}${picked ? " cx-picked" : ""}" role="row">
        <div class="cx-il-who" role="cell">
          ${selectable(r) ? `<input type="checkbox" class="cx-pick" data-c="pick" data-ip="${esc(r.ip)}" ${picked ? "checked" : ""} aria-label="${esc(r.ip)}">` : `<span class="cx-pick-gap"></span>`}
          <span class="cx-rk" aria-hidden="true">${num(String(i + 1))}</span>
          <span class="cx-who-flag">${flag(r.cc || "?")}</span>
          <span class="cx-who-t">
            <span class="cx-who-1"><button type="button" class="cx-link cx-ip" data-c="ip" data-ip="${esc(r.ip)}">${num(esc(r.ip))}</button>${statusPills(r)}</span>
            <span class="cx-who-2">${where}</span>
          </span>
        </div>
        ${req ? `<div class="cx-il-req" role="cell" data-label="${esc(reqLabel())}">
          <span class="cx-v"><b>${n0(r.req)}</b><span class="cx-pct">${r.req ? num(pct(r.req / totReq)) : ""}</span>${failed}</span>${meter(r.req, maxReq, r.failed > r.req / 3)}</div>` : ""}
        <div class="cx-il-open" role="cell" data-label="${esc(t("cx_c_open"))}">
          <span class="cx-v"><b class="${r.conns ? "" : "muted"}">${r.conns ? n0(r.conns) : "0"}</b>${r.half ? `<span class="cx-bad-n" title="${esc(tv("cx_k_half", { n: nf(r.half, 0) }))}">${n0(r.half)}</span>` : ""}</span>${req ? "" : meter(r.conns, maxOpen, r.half > r.conns / 3)}</div>
        ${bytes ? `<div class="cx-il-bytes" role="cell" data-label="${esc(t("cx_c_bytes"))}">${r.bytes_in + r.bytes_out ? `<span class="cx-v"><b>${num(esc(fmtBytes(r.bytes_in + r.bytes_out)))}</b></span><span class="cx-io">${icon("down")}${num(esc(fmtBytes(r.bytes_in)))}<span class="cx-sep"></span>${icon("up")}${num(esc(fmtBytes(r.bytes_out)))}</span>` : `<span class="muted">–</span>`}</div>` : ""}
        <div class="cx-il-ports" role="cell" data-label="${esc(t(out ? "cx_c_port" : "cx_c_ports"))}"><span class="cx-ports">${r.ports.slice(0, 3).map((p) => `<button type="button" class="chip" data-c="filter" data-k="port" data-v="${esc(p.split("/")[0])}">${num(esc(p))}</button>`).join("")}${r.nports > 3 ? `<span class="muted small">+${num(String(r.nports - 3))}</span>` : ""}</span></div>
        <div class="cx-il-act" role="cell"><div class="row-actions">
          <button type="button" class="btn small icon ghost" data-c="ip" data-ip="${esc(r.ip)}" title="${esc(t("cx_details"))}" aria-label="${esc(t("cx_details"))} ${esc(r.ip)}">${icon("eye")}</button>
          ${out || r.cc === "LAN" || r.allowed ? "" : `<button type="button" class="btn small icon ghost danger" data-c="ban" data-ip="${esc(r.ip)}" data-min="60" title="${esc(t("cx_ban"))}" aria-label="${esc(t("cx_ban"))} ${esc(r.ip)}">${icon("ban")}</button>`}
        </div></div></div>`;
    }).join("");
    const tmpl = cols.map((c) => ({ who: "minmax(230px, 2.6fr)", req: "minmax(120px, 1.3fr)", open: "minmax(84px, .8fr)", bytes: "minmax(120px, 1.1fr)", ports: "minmax(110px, 1.2fr)", act: "auto" })[c]).join(" ");
    const foot = [];
    if (d.ips_total > d.ips.length) foot.push(tv("cx_top_of", { n: nf(d.ips.length, 0), total: nf(d.ips_total, 0) }));
    if (d.act && d.act.other && isWin()) foot.push(tv("cx_other", { n: nf(d.act.other, 0) }));
    return `<div class="cx-il" role="table" aria-label="${esc(t("cx_ips"))}" style="--cols:${tmpl}">${head}${rows}</div>
      ${moreBtn("ips", d.ips.length, 15)}${foot.length ? `<p class="muted small cx-il-foot">${esc(foot.join(" "))}</p>` : ""}`;
  }

  // ---------------------------------------------------------------- every open connection
  const dirIcon = (dr) => `<span class="cx-dir ${dr}" title="${esc(t(dr === "in" ? "cx_in" : dr === "out" ? "cx_out" : "cx_all"))}">${icon(dr === "in" ? "arrow-in" : dr === "out" ? "arrow-out" : "arrow-both")}</span>`;

  function rowsHTML(d) {
    if (!d.rows.length) return `<div class="empty cx-empty">${esc(t(Object.values(C.f).some(Boolean) ? "cx_none" : "cx_none_in"))}</div>`;
    const rows = d.rows.map((r) => `<tr>
      <td class="cx-r-ip">${dirIcon(r.dir)}<button type="button" class="cx-link cx-ip" data-c="ip" data-ip="${esc(r.ip)}">${flag(r.cc)}${num(esc(r.ip))}</button></td>
      <td class="cx-r-port" data-label="${esc(t(r.dir === "out" ? "cx_c_to" : "cx_c_port"))}"><button type="button" class="cx-link" data-c="filter" data-k="port" data-v="${esc(r.port)}">${num(esc(r.port ? `${r.port}/${r.proto}` : r.proto))}</button>${r.svc ? ` <span class="cx-svc">${esc(r.svc)}</span>` : ""}${r.target ? `<span class="cx-target muted small">${r.dir === "out" ? "←" : "→"} ${num(esc(r.target))}</span>` : ""}</td>
      <td class="cx-r-state" data-label="${esc(t("cx_c_state"))}">${statePill(r.state)}</td>
      <td class="cx-num cx-r-n" data-label="${esc(t("cx_c_n"))}">${r.n > 1 ? `<b>×${n0(r.n)}</b>` : num("1")}</td>
      ${d.acct ? `<td class="cx-num cx-r-bytes" data-label="${esc(t("cx_c_bytes"))}">${r.bytes_in + r.bytes_out ? `${icon("down")}${num(esc(fmtBytes(r.bytes_in)))} ${icon("up")}${num(esc(fmtBytes(r.bytes_out)))}` : "–"}</td>` : ""}
      <td class="cx-num muted small cx-r-ttl" data-label="${esc(t("cx_c_ttl"))}">${num(esc(fmtTtl(r.ttl)))}</td></tr>`).join("");
    const more = d.rows_total > d.rows.length ? `<button type="button" class="btn small ghost cx-more" data-c="rows-more">${esc(t("cx_more"))} (${n0(d.rows_total - d.rows.length)})</button>` : "";
    return `<div class="table-wrap cx-table cx-rows"><table><thead><tr><th>${esc(t("cx_c_ip"))}</th><th>${esc(t("cx_c_port"))}</th><th>${esc(t("cx_c_state"))}</th><th>${esc(t("cx_c_n"))}</th>${d.acct ? `<th>${esc(t("cx_c_bytes"))}</th>` : ""}<th>${esc(t("cx_c_ttl"))}</th></tr></thead><tbody>${rows}</tbody></table></div>${more}`;
  }
  const fmtTtl = (s) => (s >= 86400 ? `${Math.floor(s / 86400)}d` : s >= 3600 ? `${Math.floor(s / 3600)}h` : s >= 60 ? `${Math.floor(s / 60)}m` : `${s}s`);

  const when = (ts) => { try { return new Intl.DateTimeFormat(P.state.lang === "fa" ? "fa-IR-u-ca-gregory-nu-latn" : "en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(ts * 1000)); } catch (e) { return new Date(ts * 1000).toLocaleString(); } };
  const dur = (s) => (s >= 3600 ? `${Math.floor(s / 3600)}h ${Math.round((s % 3600) / 60)}m` : s >= 60 ? `${Math.round(s / 60)}m` : `${s}s`);

  function reportsHTML(d) {
    if (!d.reports || !d.reports.length) return `<div class="empty cx-empty">${esc(t("cx_reports_none"))}</div>`;
    return `<div class="cx-reports">${d.reports.map((r) => `<button type="button" class="cx-report" data-c="report" data-id="${r.id}">
      <span class="cx-report-t">${icon("flame")}<b>${esc(when(r.since))}</b><span class="muted small">${esc(r.ended ? tv("cx_report_lasted", { d: dur(r.ended - r.since) }) : t("cx_report_ongoing"))}</span></span>
      <span class="cx-report-m">${r.top_cc ? place(r.top_cc) : ""}${r.top_port ? `<span class="chip">${num(esc(r.top_port))}</span>` : ""}<span class="muted small">${n0(r.conns)} ${esc(t("cx_c_conns"))}</span></span></button>`).join("")}</div>`;
  }

  function footHTML(d) {
    const a = d.act || {};
    const sw = (c, on, title, sub) => `<label class="cx-acct"><span class="switch"><input type="checkbox" data-c="${c}" ${on ? "checked" : ""}><span></span></span><span><b>${esc(t(title))}</b><span class="muted small">${esc(t(sub))}</span></span></label>`;
    const table = `<p class="muted small">${esc(tv("cx_k_table", { n: nf(d.entries, 0), max: d.max ? nf(d.max, 0) : "?", s: `${nf(d.took, 2)}s` }))}${d.truncated ? ` · ${esc(tv("cx_truncated", { n: nf(d.entries, 0) }))}` : ""}</p>`;
    return `${"on" in a ? sw("acts-toggle", a.on, "cx_acts", "cx_acts_sub") : ""}${sw("acct-toggle", d.acct, "cx_acct", "cx_acct_sub")}${sw("hist-toggle", d.history_on, "cx_hist", "cx_hist_sub")}${table}`;
  }

  function creditHTML(d) {
    const db = d.db || {};
    if (db.ready) return `<span class="muted small">${esc(tv("cx_db_ok", { date: when(db.updated) }))}</span>`;
    if (db.state === "error") return `<div class="notice warn">${icon("alert")}<span>${esc(tv("cx_db_error", { e: db.error }))}</span><button type="button" class="btn small" data-c="db-retry">${esc(t("cx_db_retry"))}</button></div>`;
    return `<div class="notice">${icon("refresh")}<span>${esc(t("cx_db_loading"))}</span></div>`;
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
      const what = t(isWin() ? "cx_c_req" : "cx_c_open");
      tip.innerHTML = `<div class="t">${place(cc)}</div>${c ? `<div class="r"><span>${esc(what)}</span><b>${n0(c.conns)}</b></div><div class="r"><span>${esc(t("cx_k_ips"))}</span><b>${n0(c.ips)}</b></div>${c.half ? `<div class="r"><span>${esc(t(isWin() ? "cx_trend_failed" : "cx_trend_half"))}</span><b>${n0(c.half)}</b></div>` : ""}` : `<div class="r muted">0</div>`}`;
      tip.hidden = false;
      const rc = box.parentElement.getBoundingClientRect();
      const x = e.clientX - rc.left, y = e.clientY - rc.top, w = tip.offsetWidth;
      tip.style.left = `${Math.max(4, Math.min(rc.width - w - 4, x + (x > rc.width / 2 ? -w - 14 : 14)))}px`;
      tip.style.top = `${Math.max(4, y - 10)}px`;
    });
    svg.addEventListener("pointerleave", () => { tip.hidden = true; });
    svg.addEventListener("click", (e) => {
      const p = e.target.closest("path");
      if (!p) return;
      setFilter("cc", p.dataset.cc);
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
      const lvl = c && c.conns ? Math.max(1, Math.ceil((Math.log(c.conns + 1) / Math.log(max + 1)) * 5)) : 0;
      const cls = `${lvl ? `l${lvl}` : ""}${c && c.half >= 20 && c.half > c.conns / 3 ? " hot" : ""}${C.f.cc === p.dataset.cc ? " sel" : ""}`.trim();
      if (p.getAttribute("class") !== cls) p.setAttribute("class", cls);
    });
  }

  // ---------------------------------------------------------------- trend
  function paintTrend(d) {
    const cardEl = $("cx-trend-card"), box = $("cx-trend");
    if (!cardEl || !box) return;
    const w = isWin(), h48 = !w && C.trend === "h48";
    const seg = $("cx-trend-seg");
    if (seg) seg.hidden = w;
    let tl, get, getHalf, getCc, unit = "";
    if (w) {
      tl = (d.act && d.act.series) || [];
      const per = (p, v) => (v * 60) / Math.max(60, p.span || 60);
      get = (p) => per(p, p.in); getHalf = (p) => per(p, p.half); getCc = (p, cc) => per(p, (p.cc || {})[cc] || 0);
      unit = t("cx_per_min");
    } else {
      tl = h48 ? (C.hist || []) : (d.timeline || []);
      get = (p) => p.in; getHalf = (p) => p.half; getCc = (p, cc) => (p.cc || {})[cc] || 0;
    }
    if (C.dir === "out" && !w) { cardEl.hidden = true; return; }
    if (!w && !h48 && tl.length < 3 && !(d.history_on && d.db && d.db.ready)) { cardEl.hidden = true; return; }
    cardEl.hidden = false;
    put("cx-trend-h", `${icon("activity")}<span>${esc(t(w ? "cx_trend_req" : "cx_trend"))}</span>`);
    put("cx-trend-sub", esc(t(w ? "cx_trend_req_sub" : h48 ? "cx_hist_sub" : "cx_trend_sub")));
    if (tl.length < 2) {
      box.innerHTML = `<div class="empty cx-empty">${esc(t(w ? "cx_trend_wait" : h48 && !d.history_on ? "cx_hist_off" : h48 ? "cx_hist_empty" : "cx_loading"))}</div>`;
      put("cx-trend-legend", "");
      return;
    }
    const totals = {};
    tl.forEach((p) => Object.entries(p.cc || {}).forEach(([cc, n]) => { totals[cc] = (totals[cc] || 0) + n; }));
    const top = Object.entries(totals).filter(([cc]) => /^[A-Z]{2}$/.test(cc)).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([cc]) => cc);
    const series = [{ name: t("cx_trend_total"), col: "var(--accent)", get, w: 2.2, area: true },
      { name: t(w ? "cx_trend_failed" : "cx_trend_half"), col: "var(--s-bad)", get: getHalf, w: 1.6, dash: "4 3" },
      ...top.map((cc, i) => ({ name: ccName(cc), col: ["var(--c1)", "var(--c2)", "var(--c3)", "var(--s-warn)"][i], get: (p) => getCc(p, cc), w: 1.6, flag: cc }))];
    const Wd = Math.max(300, Math.round(box.clientWidth) || 600), H = 180, L = 52, R = 10, T = 10, B = 22;
    const t0 = tl[0].t, t1 = tl[tl.length - 1].t, span = Math.max(1, t1 - t0);
    const max = Math.max(1, ...tl.map(get));
    const X = (tt) => L + ((tt - t0) / span) * (Wd - L - R), Y = (v) => T + (1 - v / max) * (H - T - B);
    let grid = "";
    for (let i = 0; i <= 3; i++) { const v = (max * i) / 3; grid += `<line x1="${L}" x2="${Wd - R}" y1="${Y(v)}" y2="${Y(v)}"/><text x="${L - 6}" y="${Y(v) + 4}" text-anchor="end">${esc(nf(v, v < 10 && max < 10 ? 1 : 0))}</text>`; }
    const hhmm = (s) => { const x = new Date(s * 1000); return `${span > 86400 ? `${x.getMonth() + 1}/${x.getDate()} ` : ""}${String(x.getHours()).padStart(2, "0")}:${String(x.getMinutes()).padStart(2, "0")}`; };
    grid += `<text x="${L}" y="${H - 6}">${hhmm(t0)}</text><text x="${(L + Wd - R) / 2}" y="${H - 6}" text-anchor="middle">${hhmm(t0 + span / 2)}</text><text x="${Wd - R}" y="${H - 6}" text-anchor="end">${hhmm(t1)}</text>`;
    if (unit) grid += `<text x="${L - 6}" y="${T - 1}" text-anchor="end" class="u">${esc(unit)}</text>`;
    const pts = (s) => tl.map((p) => `${X(p.t).toFixed(1)},${Y(s.get(p)).toFixed(1)}`).join(" ");
    const lines = series.map((s) => `${s.area ? `<polygon points="${X(t0).toFixed(1)},${Y(0)} ${pts(s)} ${X(t1).toFixed(1)},${Y(0)}" fill="${s.col}" opacity=".1"/>` : ""}<polyline points="${pts(s)}" fill="none" stroke="${s.col}" stroke-width="${s.w}" ${s.dash ? `stroke-dasharray="${s.dash}"` : ""} stroke-linejoin="round"/>`).join("");
    box.innerHTML = `<svg viewBox="0 0 ${Wd} ${H}" width="${Wd}" height="${H}" style="height:${H}px" role="img" aria-label="${esc(t(w ? "cx_trend_req" : "cx_trend"))}"><g class="grid">${grid}</g>${lines}</svg>`;
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
    if (!b || b.disabled || b.tagName === "INPUT" || b.tagName === "SELECT") return;
    const c = b.dataset.c;
    if (c === "fmenu") { fmenu($("cx-fpop").hidden); return; }
    if (c === "dir") {
      C.dir = b.dataset.v;
      C.limit = 300; C.more = {}; C.sel.clear();
      put("cx-dir", dirSeg());
      return load(true);
    }
    if (c === "win") {
      C.win = b.dataset.v;
      C.more = {}; C.sort = null;
      put("cx-win", winSeg());
      return load(true);
    }
    if (c === "filter") return setFilter(b.dataset.k, b.dataset.v);
    if (c === "unfilter") {
      const k = b.dataset.k;
      C.f[k] = "";
      if (k === "proto" || k === "state") { const el = $(`cx-${k}`); if (el) el.value = ""; }
      return load(true);
    }
    if (c === "clear") {
      C.f = NOF();
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
      const k = b.dataset.k, cur = C.data ? sortKey(C.data) : "";
      C.sort = cur === k ? { k, desc: !sortDesc() } : { k, desc: true };
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
    if (c === "acts") return setActs(b, b.dataset.on === "1");
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
    if (el.id === "cx-sortm") { C.sort = { k: el.value, desc: true }; return paint(); }
    if (el.id === "cx-proto") return setFilter("proto", el.value);
    if (el.id === "cx-state") return setFilter("state", el.value);
    if (el.dataset.c === "acct-toggle") return setAcct(el, el.checked);
    if (el.dataset.c === "acts-toggle") return setActs(el, el.checked);
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
      const w = d.win === "now" ? "1h" : d.win;
      head = ["ip", "country", "country_name", "asn", "network", `requests_${w}`, `never_completed_${w}`, "open_now", "half_open_now", "ports", "bytes_in", "bytes_out", "first_seen", "status"];
      lines = d.ips.map((r) => [r.ip, r.cc || "", ccName(r.cc), r.asn || "", (d.orgs || {})[r.asn] || "", r.req, r.failed, r.conns, r.half, r.ports.join(" "), r.bytes_in, r.bytes_out,
        r.first ? new Date(r.first * 1000).toISOString() : "", [r.banned && "banned", r.blocked && "blocked", r.allowed && "allowed", r.threat && r.threat.length && "threat"].filter(Boolean).join(" ")]);
    } else {
      head = ["direction", "protocol", "ip", "country", "asn", "network", "port", "service", "forwarded_to", "state", "count", "half_open", "bytes_in", "bytes_out", "expires_s"];
      lines = d.rows.map((r) => [r.dir, r.proto, r.ip, r.cc || "", r.asn || "", (d.orgs || {})[r.asn] || "", r.port, r.svc, r.target, r.state, r.n, r.half, r.bytes_in, r.bytes_out, r.ttl]);
    }
    const csv = "﻿" + [head, ...lines].map((l) => l.map(cell).join(",")).join("\r\n");
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

  async function setActs(el, on) {
    const r = await act(el, () => post("/api/defender/conns/activity", { on }), t("saved"));
    if (!r && el.type === "checkbox") el.checked = !on;
    if (r && !on) C.win = "now";
    if (r && on && C.win === "now") C.win = "1h";
    setTimeout(() => load(true), on ? 1500 : 0);   // give the event reader a moment to start
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
  // requests per hour over the last day, as bars (the part that never completed in red)
  function hoursChart(hours) {
    const now = Date.now() / 1000, H0 = Math.floor(now / 3600) * 3600;
    const by = Object.fromEntries((hours || []).map((h) => [h[0], h]));
    const list = Array.from({ length: 24 }, (_, i) => { const s = H0 - (23 - i) * 3600; const h = by[s]; return { s, req: h ? h[1] : 0, bytes: h ? h[2] : 0, failed: h ? h[3] : 0 }; });
    const max = Math.max(1, ...list.map((x) => x.req)), Wd = 600, H = 120, B = 18, bw = Wd / 24;
    const lab = (s) => `${String(new Date(s * 1000).getHours()).padStart(2, "0")}:00`;
    const bars = list.map((x, i) => {
      const h = (x.req / max) * (H - B - 6), fh = Math.min(h, (Math.min(x.failed, x.req) / max) * (H - B - 6));
      return `<g><title>${esc(`${lab(x.s)} · ${nf(x.req, 0)} ${t("cx_k_req")}${x.failed ? ` · ${nf(x.failed, 0)} ${t("cx_trend_failed")}` : ""}${x.bytes ? ` · ${fmtBytes(x.bytes)}` : ""}`)}</title>
        <rect x="${(i * bw + 2).toFixed(1)}" y="${(H - B - h).toFixed(1)}" width="${(bw - 4).toFixed(1)}" height="${Math.max(x.req ? 1.5 : 0, h).toFixed(1)}" rx="2" fill="var(--accent)" opacity="${i === 23 ? ".55" : ".9"}"/>
        ${fh ? `<rect x="${(i * bw + 2).toFixed(1)}" y="${(H - B - fh).toFixed(1)}" width="${(bw - 4).toFixed(1)}" height="${fh.toFixed(1)}" rx="2" fill="var(--s-bad)"/>` : ""}</g>`;
    }).join("");
    const ticks = [0, 6, 12, 18, 23].map((i) => `<text x="${(i * bw + bw / 2).toFixed(1)}" y="${H - 4}" text-anchor="middle">${lab(list[i].s)}</text>`).join("");
    return `<svg class="cx-hours" viewBox="0 0 ${Wd} ${H}" preserveAspectRatio="none" role="img" aria-label="${esc(t("cx_ip_hours"))}"><line x1="0" x2="${Wd}" y1="${H - B}" y2="${H - B}" class="base"/>${bars}<g class="grid">${ticks}</g></svg>
      <div class="cx-hours-max muted small">${esc(`max ${nf(max, 0)}`)}</div>`;
  }

  async function ipDialog(ip) {
    const dlg = openDialog({ title: tv("cx_ip_title", { ip }), wide: true, hideSubmit: true, cancel: t("close"), body: `<div id="cx-ipd"><div class="skeleton"></div></div>` });
    const box = dlg.querySelector("#cx-ipd");
    let d;
    try { d = await api("/api/defender/conns/ip", { ip }); } catch (e) { box.innerHTML = `<div class="notice bad">${icon("alert")}<span>${esc(e.message)}</span></div>`; return; }
    const s = d.summary, a = d.activity;
    const lan = d.cc === "LAN";
    const durs = [[10, "cx_m10"], [60, "cx_h1"], [1440, "cx_h24"], [10080, "cx_d7"]];
    const stat = (label, value, sub = "", cls = "") => `<div class="cx-kpi ${cls}"><span class="cx-kpi-l">${esc(label)}</span><b class="cx-kpi-v">${value}</b>${sub ? `<span class="cx-kpi-s">${sub}</span>` : ""}</div>`;
    const stats = [];
    if (a) {
      stats.push(stat(t("cx_ip_r1"), n0(a.h1 ? a.h1.req : 0), a.h1 && a.h1.failed ? `<span class="cx-kpi-bad">${esc(tv("cx_k_failed", { n: nf(a.h1.failed, 0) }))}</span>` : "", "accent"));
      stats.push(stat(t("cx_ip_r24"), n0(a.h24 ? a.h24.req : 0), a.h24 && a.h24.failed ? `<span class="cx-kpi-bad">${esc(tv("cx_k_failed", { n: nf(a.h24.failed, 0) }))}</span>` : ""));
    }
    stats.push(stat(t("cx_k_open"), n0(s.conns), s.half ? `<span class="cx-kpi-bad">${esc(tv("cx_k_half", { n: nf(s.half, 0) }))}</span>` : ""));
    if (d.acct || (a && a.h24 && a.h24.bytes_in + a.h24.bytes_out)) {
      const bi = (a && a.h24 ? a.h24.bytes_in : 0) + s.bytes_in, bo = (a && a.h24 ? a.h24.bytes_out : 0) + s.bytes_out;
      stats.push(stat(t("cx_ip_t24"), num(esc(fmtBytes(bi + bo))), `${icon("down")}${num(esc(fmtBytes(bi)))}<span class="cx-sep"></span>${icon("up")}${num(esc(fmtBytes(bo)))}`));
    }
    const ports24 = a && a.h24 ? a.h24.ports : [];
    const pmax = Math.max(1, ...ports24.map((p) => p[1]));
    const rows = d.rows.map((r) => `<tr><td>${dirIcon(r.dir)}${num(esc(r.port ? `${r.port}/${r.proto}` : r.proto))}${r.svc ? ` <span class="cx-svc">${esc(r.svc)}</span>` : ""}${r.target ? `<span class="cx-target muted small">${r.dir === "out" ? "←" : "→"} ${num(esc(r.target))}</span>` : ""}</td>
      <td data-label="${esc(t("cx_c_state"))}">${statePill(r.state)}</td><td class="cx-num" data-label="${esc(t("cx_c_n"))}">${n0(r.n)}</td>
      <td class="cx-num muted small" data-label="${esc(t("cx_c_ttl"))}">${num(esc(fmtTtl(r.ttl)))}</td></tr>`).join("");
    box.innerHTML = `<div class="cx-ipd">
      <div class="cx-ipd-head">
        <span class="cx-ipd-flag">${flag(d.cc)}</span>
        <div class="cx-ipd-who">
          <div class="cx-ipd-ip"><b>${num(esc(d.ip))}</b>${statusPills(d)}</div>
          <div class="cx-ipd-meta muted">${esc(ccName(d.cc))}${d.asn ? `<span class="cx-dotsep" aria-hidden="true"></span>${orgHTML(d.org, d.asn)}<span class="cx-dotsep" aria-hidden="true"></span>${num(`AS${d.asn}`)}` : ""}</div>
          ${d.ptr ? `<div class="cx-ipd-ptr"><bdi class="cx-mono">${esc(d.ptr)}</bdi></div>` : ""}
        </div>
      </div>
      <div class="cx-kpis cx-ipd-kpis">${stats.join("")}</div>
      ${a ? `<div class="cx-ipd-sec"><h4 class="cx-h4">${icon("activity")}${esc(t("cx_ip_hours"))}</h4>${hoursChart(a.hours)}</div>` : ""}
      ${ports24.length ? `<div class="cx-ipd-sec"><h4 class="cx-h4">${icon("server")}${esc(t("cx_ip_ports"))}</h4><div class="cx-rl">${ports24.map(([p, n]) => `<div class="cx-rl-row"><div class="cx-rl-main static"><span class="cx-rl-name"><span class="cx-port">${num(esc(p))}</span></span><span class="cx-rl-n">${n0(n)}</span>${meter(n, pmax)}<span class="cx-rl-sub"></span></div></div>`).join("")}</div></div>` : ""}
      <dl class="cx-dl">
        <div><dt>${esc(t("cx_ip_subnet"))}</dt><dd>${num(esc(d.subnet))}</dd></div>
        ${d.first ? `<div><dt>${esc(t("cx_c_first"))}</dt><dd>${esc(ago(d.first))}</dd></div>` : ""}
        ${Object.keys(s.states || {}).length ? `<div><dt>${esc(t("cx_c_state"))}</dt><dd class="cx-states">${Object.entries(s.states).map(([k, n]) => `<span class="cx-stn">${esc(stName(k))} <b>${n0(n)}</b></span>`).join("")}</dd></div>` : ""}
        ${d.threat && d.threat.length ? `<div class="cx-wide"><dt>${esc(t("cx_threat_lists"))}</dt><dd>${d.threat.map((n) => pill("warn", n)).join(" ")}</dd></div>` : ""}
      </dl>
      ${lan || d.allowed ? "" : `<div class="cx-ipd-acts">
        <span class="muted small">${esc(t("cx_ip_ban"))}</span>${durs.map(([m, k]) => `<button type="button" class="btn small danger" data-d="ban" data-min="${m}">${esc(t(k))}</button>`).join("")}
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
      <div class="cx-ipd-sec"><h4 class="cx-h4">${icon("list")}${esc(t("cx_ip_conns"))}</h4>
      ${d.rows.length ? `<div class="table-wrap cx-table cx-compact"><table><thead><tr><th>${esc(t("cx_c_port"))}</th><th>${esc(t("cx_c_state"))}</th><th>${esc(t("cx_c_n"))}</th><th>${esc(t("cx_c_ttl"))}</th></tr></thead><tbody>${rows}</tbody></table></div>` : `<div class="empty cx-empty">${esc(t("cx_ip_no_open"))}</div>`}</div>
    </div>`;
    box.addEventListener("click", async (e) => {
      const b = e.target.closest("[data-d]");
      if (!b) return;
      const x = b.dataset.d;
      if (x === "ban") { if (await act(b, () => post("/api/defender/block", { ip: d.ip, minutes: +b.dataset.min, note: "connections page" }), tv("cx_ban_done", { ip: d.ip }))) { dlg.close(); load(true); } }
      if (x === "block") { if (await act(b, () => post("/api/defender/block", { ip: d.ip, note: "connections page" }), tv("cx_ban_done", { ip: d.ip }))) { dlg.close(); load(true); } }
      if (x === "net") { dlg.close(); blockNet(null, d.subnet); }
      if (x === "allow") { if (await act(b, () => post("/api/defender/allow", { ip: d.ip, note: "connections page" }), tv("cx_allow_done", { ip: d.ip }))) { dlg.close(); load(true); } }
      if (x === "copy") { try { await navigator.clipboard.writeText(d.ip); toast(t("cx_copied")); } catch (err) { /* no clipboard */ } }
      if (x === "filter") { dlg.close(); C.dir = "all"; put("cx-dir", dirSeg()); C.f.ip = ""; setFilter("ip", d.ip); }
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
        <div><h4 class="cx-h4">${esc(t("cx_countries"))}</h4>${list(["cx_c_where", "cx_c_conns", "cx_c_ips"], r.countries, (c) => `<td>${place(c.cc)}</td><td class="cx-num">${n0(c.conns)}</td><td class="cx-num">${n0(c.ips)}</td>`)}</div>
        <div><h4 class="cx-h4">${esc(t("cx_ports"))}</h4>${list(["cx_c_port", "cx_c_conns", "cx_c_ips"], r.ports, (p) => `<td>${num(esc(p.port ? `${p.port}/${p.proto}` : p.proto))}${p.svc ? ` <span class="cx-svc">${esc(p.svc)}</span>` : ""}</td><td class="cx-num">${n0(p.conns)}</td><td class="cx-num">${n0(p.ips)}</td>`)}</div>
        <div><h4 class="cx-h4">${esc(t("cx_asns"))}</h4>${list(["cx_c_net2", "cx_c_conns", "cx_c_ips"], r.asns, (a) => `<td>${flag(a.cc)}${orgHTML(a.org, a.asn)} <span class="muted small">${num(`AS${a.asn}`)}</span></td><td class="cx-num">${n0(a.conns)}</td><td class="cx-num">${n0(a.ips)}</td>`)}</div>
        <div><h4 class="cx-h4">${esc(t("cx_subnets"))}</h4>${list(["cx_subnets", "cx_c_conns", "cx_c_ips"], r.subnets, (s) => `<td>${flag(s.cc)}${num(esc(s.net))}</td><td class="cx-num">${n0(s.conns)}</td><td class="cx-num">${n0(s.ips)}</td>`)}</div>
      </div>
      <h4 class="cx-h4">${esc(t("cx_c_ip"))}</h4>${list(["cx_c_ip", "cx_c_where", "cx_c_net", "cx_c_conns"], r.ip_list, (x) => `<td>${num(esc(x.ip))}</td><td>${place(x.cc)}</td><td>${orgHTML((r.orgs || {})[x.asn], x.asn)}</td><td class="cx-num">${n0(x.conns)}${x.half ? ` <span class="cx-bad-n">${n0(x.half)}</span>` : ""}</td>`)}
    </div>`;
  }

  window.DefenderConns = { render, mount, tick, reset() { C.root = null; } };
})();
