// Defender: firewall, anti-DDoS, SSH guard and hardening. The privileged work happens in the defender
// agent (defender/agent.py); this page only talks to it through /api/defender/*.
(() => {
  "use strict";
  const P = window.Panel;
  if (!P) return;
  const { t, esc, nf, num, fmtBytes, fmtRate, ago, icon, api, post, act, toast, openDialog, confirmBox, table, pill, field, btnIcon, drawChart, sparkline, tween, setHTML } = P;

  P.addIcons({
    zap: '<path d="M13 2 4 14h7l-1 8 9-12h-7l1-8z"/>',
    list: '<path d="M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
    terminal: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M13 15h4"/>',
    ban: '<circle cx="12" cy="12" r="9"/><path d="m5.6 5.6 12.8 12.8"/>',
    unlock: '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 7.6-1.7"/>',
    eye: '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    power: '<path d="M12 3v9"/><path d="M6.4 6.4a8 8 0 1 0 11.2 0"/>',
    flame: '<path d="M12 22c4.4 0 7-3 7-7 0-3.6-2.5-5.7-3.6-8.6-1 1.9-2.2 2.9-3.4 3.1.2-2.6-.9-5.3-3-7.5.1 4.6-4 6.6-4 13 0 4 2.6 7 7 7z"/>',
  });

  // ---------------------------------------------------------------- strings
  const EN = {
    df_nav: "Firewall", df_desc: "Firewall, DDoS protection, SSH brute-force guard and server hardening, all in one place. Changes are tested for 60 seconds and undone by themselves if the panel stops answering.",
    df_t_overview: "Overview", df_t_firewall: "Ports & rules", df_t_ddos: "Anti-DDoS", df_t_lists: "IP lists", df_t_ssh: "SSH", df_t_hardening: "Hardening",
    df_missing_title: "The firewall service is not running", df_missing_sub: "It is part of the monitoring stack. Re-run install.sh, or on the server run:",
    df_off_title: "Protection is off", df_off_sub: "The firewall is only watching. Turn protection on to block floods, scans and brute force. Nothing is closed: every port that works now keeps working.",
    df_on_title: "Your server is protected", df_on_sub: "Floods, scans and brute force are blocked automatically. Normal traffic is not touched.",
    df_attack_title: "Under attack: mitigating", df_attack_sub: "Started {since}. Peak {pps} packets/s, {drop} blocked/s.",
    df_esc_title: "Heightened protection", df_esc_sub: "\"Under attack\" limits are active after an attack and switch back by themselves 10 minutes after it ends.",
    df_enable: "Turn on protection", df_disable: "Turn off", df_enable_confirm: "Turn on the Firewall? It starts in open mode: no port is closed, only abusive traffic is blocked. If the panel stops answering, the change is undone after 60 seconds.",
    df_disable_confirm: "Turn off protection? All Firewall rules are removed and bans are lifted; monitoring continues.",
    df_p_normal: "Normal", df_p_strict: "Strict", df_p_attack: "Under attack", df_p_custom: "Custom",
    df_p_normal_d: "For everyday use. Generous limits that a real visitor never reaches.", df_p_strict_d: "Tighter limits for servers that are attacked often.", df_p_attack_d: "Emergency: very tight limits while an attack is going on.", df_p_custom_d: "Your own limits (Advanced settings below).",
    df_mode_open: "Open", df_mode_strict: "Strict",
    df_m_pps: "Incoming packets", df_m_bps: "Incoming traffic", df_m_conns: "New connections", df_m_drop: "Blocked", df_m_bans: "Banned IPs", df_m_ct: "Connection table",
    df_per_s: "per second", df_chart: "Incoming vs. blocked (last 5 minutes)", df_in: "incoming", df_blocked: "blocked",
    df_reasons: "What was blocked (last 5 minutes)", df_reasons_none: "Nothing was blocked in the last 5 minutes.",
    df_r_block: "Blocklist", df_r_ban: "Banned IPs", df_r_invalid: "Invalid packets", df_r_badflags: "Port scans (bad TCP flags)", df_r_ssh: "SSH connection flood",
    df_r_policy: "Closed ports (strict mode)", df_r_syn: "SYN flood", df_r_conn: "Connection flood", df_r_conc: "Too many connections", df_r_udp: "UDP flood", df_r_icmp: "Ping flood", df_r_autoban: "Banned while flooding",
    df_talkers: "Top sources right now", df_talkers_sub: "Addresses with the most open connections to this server.", df_conns: "Connections", df_you: "you",
    df_events: "Activity", df_events_none: "No activity yet.",
    df_ban1h: "Ban 1 hour", df_allow: "Allow", df_unban: "Unban", df_remove: "Remove",
    df_e_applied: "Rules applied", df_e_confirmed: "Changes kept", df_e_rollback: "Changes undone ({reason})", df_e_attack_start: "Attack detected: {pps} packets/s, {drop} blocked/s",
    df_e_attack_end: "Attack ended after {min} min", df_e_escalate: "Switched to \"Under attack\" limits", df_e_deescalate: "Back to the normal limits", df_e_ban: "{ip} banned for {minutes} min",
    df_e_ssh_ban: "{ip} banned: {failures} failed SSH logins", df_e_unban: "{ip} unbanned", df_e_block: "{ip} added to the blocklist", df_e_allow: "{ip} added to the allowlist",
    df_e_sysctl: "Kernel settings: {action}", df_e_started: "Firewall started",
    df_pending: "Testing the new rules: they are undone in {n} s unless kept.", df_keep: "Keep", df_undo: "Undo", df_kept: "Applied and kept", df_undone: "Changes undone",
    df_lost: "The panel lost the connection after applying. If it stays unreachable, the change is undone by itself within 60 seconds.",
    // firewall
    df_fw_mode: "Firewall mode", df_fw_mode_sub: "Open blocks only abuse. Strict also closes every port that is not on the list below.",
    df_mode_open_d: "Every port stays reachable; floods, scans and banned IPs are blocked.", df_mode_strict_d: "Only the ports you allow are reachable (TCP and UDP). Tunnels and other protocols keep working.",
    df_always: "Always open:", df_ssh: "SSH", df_panel: "Panel",
    df_services: "Services reachable from the internet", df_services_sub: "Programs listening on a public address right now.",
    df_port: "Port", df_proto: "Protocol", df_process: "Program", df_state: "In strict mode", df_open: "Open", df_closed: "Closed", df_only_from: "Only from listed IPs", df_locked: "Always open",
    df_open_it: "Allow", df_close_it: "Close", df_rules: "Port rules", df_rules_sub: "Ports that stay open in strict mode. A source limits a port to one IP or network.", df_add_rule: "Add rule",
    df_from: "Source", df_any: "Anyone", df_note: "Note", df_from_hint: "Optional: an IP or network (203.0.113.7 or 203.0.113.0/24). Empty = anyone.", df_port_hint: "One port (443) or a range (8000-8100).",
    df_ifaces: "Trusted interfaces", df_ifaces_sub: "Traffic arriving on these is never filtered (VPNs and tunnels). Loopback and Docker are always trusted. A * at the end matches a prefix.",
    df_iface_add: "Add interface", df_review: "Review rules", df_discard: "Discard", df_apply: "Save and apply", df_dirty: "Unsaved changes",
    df_strict_prefill: "Every port in use right now was added to the list so nothing breaks. Remove the ones that should not be public, then apply.",
    df_rules_title: "nftables rules that will be applied",
    // ddos
    df_profiles: "Protection level", df_profiles_sub: "Limits are per source IP: one visitor, bot or proxy. Traffic below them is never touched.",
    df_auto_esc: "Switch to \"Under attack\" automatically", df_auto_esc_sub: "When an attack is detected, the tightest limits apply until 10 minutes after it ends.",
    df_adv: "Advanced settings", df_adv_sub: "Exceeding a limit drops the extra packets. Going 3x over it bans the source for the ban time.",
    df_l_syn: "New TCP connections (SYN) per second", df_l_conn: "New connections of any kind per second", df_l_conc: "Open TCP connections at once", df_l_udp: "New UDP flows per second", df_l_icmp: "Pings per second", df_l_ban: "Ban time (minutes)",
    df_drop_invalid: "Drop invalid packets", df_bad_flags: "Drop impossible TCP flags (port scans)", df_save: "Save and apply",
    df_covers: "What is blocked", df_cv_syn: "SYN floods and half-open connection floods", df_cv_conn: "Connection floods and slow-loris style connection hoarding", df_cv_udp: "UDP and ping floods",
    df_cv_scan: "Port scans with forged TCP flags and invalid packets", df_cv_ssh: "SSH brute force (connections and failed logins)", df_cv_l7: "Not covered: floods of valid HTTP requests (use a CDN or a reverse proxy with rate limits for that).",
    // lists
    df_add_ip: "Add an address", df_ip: "IP or network", df_action: "Action", df_a_block: "Block permanently", df_a_ban1h: "Ban for 1 hour", df_a_ban24h: "Ban for 24 hours", df_a_ban7d: "Ban for 7 days", df_a_allow: "Allow (never blocked)",
    df_admins: "Trusted because they logged in over SSH (now or in the last 7 days), so they are never limited or banned: {ips}",
    df_cdn: "Trust Cloudflare's addresses", df_cdn_sub: "For sites and proxies behind Cloudflare: all their visitors arrive from Cloudflare's IPs, so per-IP limits would hit everyone at once. The blocklist still applies.", df_bans: "Banned now", df_filter: "Filter…", df_source: "Banned by", df_left: "Ends in",
    df_s_auto: "Flood", df_s_ssh: "SSH guard", df_s_manual: "Manual", df_s_fail2ban: "fail2ban", df_blocklist: "Blocklist", df_allowlist: "Allowlist", df_added: "Added",
    df_f2b_note: "fail2ban's bans are shown for reference; manage them with fail2ban-client.",
    // ssh
    df_ssh_title: "SSH brute-force guard", df_ssh_sub: "Reads the SSH login log and bans addresses that keep failing to log in. Logged-in users and addresses that logged in successfully today are never banned.",
    df_ssh_on: "Ban addresses with failed logins", df_ssh_l4: "Also limit new SSH connections (12 per minute per address)", df_ssh_private: "Never ban private networks",
    df_ssh_failures: "Failed logins before a ban", df_ssh_window: "Within (minutes)", df_ssh_ban: "Ban time (minutes)",
    df_ssh_24h: "Failed logins (since the agent started)", df_ssh_top: "Most failed logins", df_ssh_nolog: "The SSH log (/var/log/auth.log) is not readable, so only the connection limit is active.",
    df_f2b_present: "fail2ban is installed too. Both can run together; the firewall's guard also covers servers without it.", df_attempts: "Attempts",
    // hardening
    df_score: "Security score", df_checks: "Security checks", df_fix: "How to fix", df_kernel: "Kernel network hardening",
    df_kernel_sub: "Linux settings that make floods cheaper to absorb. They are re-applied after every reboot and can be restored to the original values.",
    df_setting: "Setting", df_current: "Current", df_recommended: "Recommended", df_apply_all: "Apply recommended", df_restore: "Restore originals",
    df_notify: "Telegram notifications", df_notify_attacks: "Attacks (started, ended, \"Under attack\" switched on)", df_notify_bans: "Every SSH brute-force ban",
    df_sev0: "OK", df_sev1: "Low", df_sev2: "Medium", df_sev3: "High",
    df_c_ssh_root_pw: ["Root can log in over SSH with a password", "Root login is restricted"], df_f_ssh_root_pw: "Set up SSH keys, then in /etc/ssh/sshd_config set PermitRootLogin prohibit-password and PasswordAuthentication no, and run systemctl restart ssh.",
    df_c_ssh_root: ["Root can log in over SSH", "Root cannot log in with a password"], df_f_ssh_root: "Set PermitRootLogin prohibit-password in /etc/ssh/sshd_config.",
    df_c_ssh_password: ["SSH accepts passwords", "SSH only accepts keys"], df_f_ssh_password: "Keys cannot be guessed. Add your key to ~/.ssh/authorized_keys, test it, then set PasswordAuthentication no.",
    df_c_ssh_port: ["SSH listens on the default port 22", "SSH listens on port {ports}"], df_f_ssh_port: "Another port only reduces automated noise; it is not a defence by itself. Keys and the SSH guard matter more.",
    df_c_ssh_bruteforce: ["{n} failed SSH logins in the log", "Few failed SSH logins ({n})"], df_f_ssh_bruteforce: "Keep the SSH guard on and switch to key-only logins.",
    df_c_fw_enabled: ["Firewall protection is off", "Firewall protection is on"], df_f_fw_enabled: "Turn protection on in the Overview tab.",
    df_c_internal_exposed: ["{name} (port {port}) is reachable from the internet", "No database or internal service is exposed"], df_f_internal_exposed: "Bind it to 127.0.0.1, or switch the firewall to strict mode and allow the port only from trusted IPs.",
    df_c_open_ports: ["{n} TCP ports are open to the internet", "{n} public TCP ports"], df_f_open_ports: "Strict mode closes everything you did not allow.",
    df_c_reboot: ["A reboot is needed to finish installing updates", "No reboot pending"], df_f_reboot: "Reboot the server at a quiet time; the whole stack starts again by itself.",
    df_c_auto_updates: ["Automatic security updates are off", "Automatic security updates are on"], df_f_auto_updates: "apt install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades",
    df_c_conntrack: ["Connection table {pct}% full", "Connection table {pct}% used"], df_f_conntrack: "Apply the kernel hardening below; it raises the limit.",
    df_c_kernel: ["{n} kernel network settings are not hardened", "Kernel network settings are hardened"], df_f_kernel: "Use \"Apply recommended\" below.",
    df_c_syncookies: ["SYN cookies are off", "SYN cookies are on"], df_f_syncookies: "Apply the kernel hardening below.",
    df_c_fail2ban: ["fail2ban is not installed", "fail2ban is installed"], df_f_fail2ban: "Optional: the firewall's SSH guard does the same job.",
    sc_syncookies: "Answers SYN floods without filling the connection queue", sc_synack: "Gives up on half-open connections sooner", sc_backlog: "Longer queue for connections being opened",
    sc_rfc1337: "Protects against TIME-WAIT assassination", sc_bcast: "Ignores pings to broadcast addresses (smurf attacks)", sc_bogus: "Ignores bogus ICMP error replies",
    sc_redirects: "Ignores ICMP redirects (route hijacking)", sc_send_redirects: "Does not send ICMP redirects", sc_source_route: "Rejects source-routed packets",
    sc_conntrack: "Room for more tracked connections during a flood", sc_ct_timeout: "Forgets idle connections after a day instead of five",
  };
  const FA = {
    df_nav: "فایروال", df_desc: "فایروال، محافظت در برابر DDoS، محافظ SSH و سخت‌سازی سرور در یک جا. هر تغییر ۶۰ ثانیه آزمایش می‌شود و اگر پنل دیگر جواب ندهد، خودش برمی‌گردد.",
    df_t_overview: "نمای کلی", df_t_firewall: "پورت‌ها و قوانین", df_t_ddos: "ضد DDoS", df_t_lists: "لیست آی‌پی‌ها", df_t_ssh: "SSH", df_t_hardening: "سخت‌سازی",
    df_missing_title: "سرویس فایروال اجرا نمی‌شود", df_missing_sub: "بخشی از استک مانیتورینگ است. install.sh را دوباره اجرا کنید یا روی سرور بزنید:",
    df_off_title: "محافظت خاموش است", df_off_sub: "فایروال فقط نگاه می‌کند. محافظت را روشن کنید تا فلاد، اسکن و حمله‌ی رمز بسته شود. هیچ پورتی بسته نمی‌شود و هر چیزی که الان کار می‌کند، کار می‌کند.",
    df_on_title: "سرور شما محافظت می‌شود", df_on_sub: "فلاد، اسکن و حمله‌ی رمز خودکار بسته می‌شوند. ترافیک عادی دست نمی‌خورد.",
    df_attack_title: "زیر حمله: در حال دفع", df_attack_sub: "شروع: {since}. اوج {pps} بسته در ثانیه، {drop} مسدود در ثانیه.",
    df_esc_title: "محافظت تشدیدشده", df_esc_sub: "محدودیت‌های «زیر حمله» بعد از حمله فعال‌اند و ۱۰ دقیقه بعد از پایان آن خودکار برمی‌گردند.",
    df_enable: "روشن کردن محافظت", df_disable: "خاموش", df_enable_confirm: "فایروال روشن شود؟ در حالت باز شروع می‌کند: هیچ پورتی بسته نمی‌شود و فقط ترافیک مخرب مسدود می‌شود. اگر پنل جواب ندهد، تغییر بعد از ۶۰ ثانیه برمی‌گردد.",
    df_disable_confirm: "محافظت خاموش شود؟ همه‌ی قوانین فایروال حذف و مسدودی‌ها برداشته می‌شوند؛ مانیتورینگ ادامه دارد.",
    df_p_normal: "عادی", df_p_strict: "سخت‌گیر", df_p_attack: "زیر حمله", df_p_custom: "سفارشی",
    df_p_normal_d: "برای استفاده‌ی روزانه. محدودیت‌هایی که هیچ بازدیدکننده‌ی واقعی به آن نمی‌رسد.", df_p_strict_d: "محدودیت‌های تنگ‌تر برای سرورهایی که زیاد حمله می‌خورند.", df_p_attack_d: "اضطراری: محدودیت‌های خیلی تنگ وقتی حمله در جریان است.", df_p_custom_d: "محدودیت‌های خودتان (تنظیمات پیشرفته پایین).",
    df_mode_open: "باز", df_mode_strict: "سخت‌گیر",
    df_m_pps: "بسته‌های ورودی", df_m_bps: "ترافیک ورودی", df_m_conns: "اتصال‌های جدید", df_m_drop: "مسدودشده", df_m_bans: "آی‌پی‌های مسدود", df_m_ct: "جدول اتصال‌ها",
    df_per_s: "در ثانیه", df_chart: "ورودی در برابر مسدودشده (۵ دقیقه‌ی اخیر)", df_in: "ورودی", df_blocked: "مسدود",
    df_reasons: "چه چیزی مسدود شد (۵ دقیقه‌ی اخیر)", df_reasons_none: "در ۵ دقیقه‌ی اخیر چیزی مسدود نشده.",
    df_r_block: "لیست سیاه", df_r_ban: "آی‌پی‌های مسدود", df_r_invalid: "بسته‌های نامعتبر", df_r_badflags: "اسکن پورت (فلگ‌های غلط TCP)", df_r_ssh: "فلاد اتصال SSH",
    df_r_policy: "پورت‌های بسته (حالت سخت‌گیر)", df_r_syn: "SYN فلاد", df_r_conn: "فلاد اتصال", df_r_conc: "اتصال‌های بیش از حد", df_r_udp: "UDP فلاد", df_r_icmp: "پینگ فلاد", df_r_autoban: "مسدود حین فلاد",
    df_talkers: "پرترافیک‌ترین منبع‌ها", df_talkers_sub: "آدرس‌هایی که بیشترین اتصال باز را به این سرور دارند.", df_conns: "اتصال‌ها", df_you: "شما",
    df_events: "رویدادها", df_events_none: "هنوز رویدادی نیست.",
    df_ban1h: "مسدود ۱ ساعت", df_allow: "مجاز", df_unban: "رفع مسدودی", df_remove: "حذف",
    df_e_applied: "قوانین اعمال شد", df_e_confirmed: "تغییرات ماند", df_e_rollback: "تغییرات برگشت ({reason})", df_e_attack_start: "حمله شناسایی شد: {pps} بسته در ثانیه، {drop} مسدود در ثانیه",
    df_e_attack_end: "حمله بعد از {min} دقیقه تمام شد", df_e_escalate: "محدودیت‌های «زیر حمله» فعال شد", df_e_deescalate: "بازگشت به محدودیت‌های عادی", df_e_ban: "{ip} برای {minutes} دقیقه مسدود شد",
    df_e_ssh_ban: "{ip} مسدود شد: {failures} ورود ناموفق SSH", df_e_unban: "مسدودی {ip} برداشته شد", df_e_block: "{ip} به لیست سیاه اضافه شد", df_e_allow: "{ip} به لیست سفید اضافه شد",
    df_e_sysctl: "تنظیمات کرنل: {action}", df_e_started: "فایروال شروع به کار کرد",
    df_pending: "قوانین جدید در حال آزمایش‌اند: اگر نگهشان ندارید {n} ثانیه‌ی دیگر برمی‌گردند.", df_keep: "نگه دار", df_undo: "برگردان", df_kept: "اعمال شد و ماند", df_undone: "تغییرات برگشت",
    df_lost: "پنل بعد از اعمال، ارتباط را از دست داد. اگر همچنان در دسترس نباشد، تغییر حداکثر تا ۶۰ ثانیه خودش برمی‌گردد.",
    df_fw_mode: "حالت فایروال", df_fw_mode_sub: "حالت باز فقط ترافیک مخرب را می‌بندد. حالت سخت‌گیر هر پورتی که در لیست پایین نیست را هم می‌بندد.",
    df_mode_open_d: "همه‌ی پورت‌ها در دسترس می‌مانند؛ فلاد، اسکن و آی‌پی‌های مسدود بسته می‌شوند.", df_mode_strict_d: "فقط پورت‌هایی که اجازه می‌دهید در دسترس‌اند (TCP و UDP). تانل‌ها و پروتکل‌های دیگر کار می‌کنند.",
    df_always: "همیشه باز:", df_ssh: "SSH", df_panel: "پنل",
    df_services: "سرویس‌هایی که از اینترنت در دسترس‌اند", df_services_sub: "برنامه‌هایی که همین الان روی آدرس عمومی گوش می‌دهند.",
    df_port: "پورت", df_proto: "پروتکل", df_process: "برنامه", df_state: "در حالت سخت‌گیر", df_open: "باز", df_closed: "بسته", df_only_from: "فقط از آی‌پی‌های مشخص", df_locked: "همیشه باز",
    df_open_it: "اجازه", df_close_it: "بستن", df_rules: "قوانین پورت", df_rules_sub: "پورت‌هایی که در حالت سخت‌گیر باز می‌مانند. منبع، پورت را به یک آی‌پی یا شبکه محدود می‌کند.", df_add_rule: "افزودن قانون",
    df_from: "منبع", df_any: "همه", df_note: "توضیح", df_from_hint: "اختیاری: یک آی‌پی یا شبکه (203.0.113.7 یا 203.0.113.0/24). خالی = همه.", df_port_hint: "یک پورت (443) یا یک بازه (8000-8100).",
    df_ifaces: "اینترفیس‌های مورد اعتماد", df_ifaces_sub: "ترافیکی که از این‌ها می‌آید هرگز فیلتر نمی‌شود (VPN و تانل‌ها). لوپ‌بک و داکر همیشه مورد اعتمادند. * در آخر یعنی هر نامی که با آن شروع شود.",
    df_iface_add: "افزودن اینترفیس", df_review: "دیدن قوانین", df_discard: "لغو تغییرات", df_apply: "ذخیره و اعمال", df_dirty: "تغییرات ذخیره‌نشده",
    df_strict_prefill: "همه‌ی پورت‌هایی که الان استفاده می‌شوند به لیست اضافه شدند تا چیزی از کار نیفتد. آن‌هایی که نباید عمومی باشند را حذف کنید و بعد اعمال کنید.",
    df_rules_title: "قوانین nftables که اعمال می‌شوند",
    df_profiles: "سطح محافظت", df_profiles_sub: "محدودیت‌ها برای هر آی‌پی جداست: یک بازدیدکننده، ربات یا پروکسی. ترافیک زیر این حد هرگز دست نمی‌خورد.",
    df_auto_esc: "رفتن خودکار به حالت «زیر حمله»", df_auto_esc_sub: "وقتی حمله شناسایی شود، سخت‌ترین محدودیت‌ها تا ۱۰ دقیقه بعد از پایان آن فعال می‌شوند.",
    df_adv: "تنظیمات پیشرفته", df_adv_sub: "عبور از هر حد، بسته‌های اضافه را دور می‌ریزد. سه برابر عبور از آن، منبع را به مدت زمان مسدودی می‌بندد.",
    df_l_syn: "اتصال TCP جدید (SYN) در ثانیه", df_l_conn: "هر نوع اتصال جدید در ثانیه", df_l_conc: "اتصال TCP باز هم‌زمان", df_l_udp: "جریان UDP جدید در ثانیه", df_l_icmp: "پینگ در ثانیه", df_l_ban: "مدت مسدودی (دقیقه)",
    df_drop_invalid: "دور ریختن بسته‌های نامعتبر", df_bad_flags: "دور ریختن فلگ‌های ناممکن TCP (اسکن پورت)", df_save: "ذخیره و اعمال",
    df_covers: "چه چیزی مسدود می‌شود", df_cv_syn: "SYN فلاد و فلاد اتصال‌های نیمه‌باز", df_cv_conn: "فلاد اتصال و احتکار اتصال (مثل slow-loris)", df_cv_udp: "UDP فلاد و پینگ فلاد",
    df_cv_scan: "اسکن پورت با فلگ‌های جعلی و بسته‌های نامعتبر", df_cv_ssh: "حمله‌ی رمز به SSH (اتصال‌ها و ورودهای ناموفق)", df_cv_l7: "پوشش داده نمی‌شود: فلاد درخواست‌های HTTP معتبر (برای آن از CDN یا ریورس‌پروکسی با محدودیت نرخ استفاده کنید).",
    df_add_ip: "افزودن آدرس", df_ip: "آی‌پی یا شبکه", df_action: "کار", df_a_block: "مسدود همیشگی", df_a_ban1h: "مسدود ۱ ساعت", df_a_ban24h: "مسدود ۲۴ ساعت", df_a_ban7d: "مسدود ۷ روز", df_a_allow: "مجاز (هرگز مسدود نشود)",
    df_admins: "این آدرس‌ها چون با SSH وارد شده‌اند (الان یا در ۷ روز اخیر) مورد اعتمادند و هرگز محدود یا مسدود نمی‌شوند: {ips}",
    df_cdn: "اعتماد به آدرس‌های Cloudflare", df_cdn_sub: "برای سایت‌ها و پروکسی‌های پشت Cloudflare: همه‌ی کاربرانشان از آی‌پی‌های Cloudflare می‌آیند، پس محدودیت هر آی‌پی همه را با هم می‌بندد. لیست سیاه همچنان اعمال می‌شود.", df_bans: "مسدودهای فعلی", df_filter: "جستجو…", df_source: "مسدودکننده", df_left: "پایان تا",
    df_s_auto: "فلاد", df_s_ssh: "محافظ SSH", df_s_manual: "دستی", df_s_fail2ban: "fail2ban", df_blocklist: "لیست سیاه", df_allowlist: "لیست سفید", df_added: "افزوده‌شده",
    df_f2b_note: "مسدودی‌های fail2ban فقط برای اطلاع نمایش داده می‌شوند؛ با fail2ban-client مدیریتشان کنید.",
    df_ssh_title: "محافظ حمله‌ی رمز SSH", df_ssh_sub: "لاگ ورود SSH را می‌خواند و آدرس‌هایی که مدام ورود ناموفق دارند را مسدود می‌کند. کاربرهای واردشده و آدرس‌هایی که امروز موفق وارد شده‌اند هرگز مسدود نمی‌شوند.",
    df_ssh_on: "مسدود کردن آدرس‌های با ورود ناموفق", df_ssh_l4: "محدود کردن اتصال‌های جدید SSH (۱۲ در دقیقه برای هر آدرس)", df_ssh_private: "شبکه‌های خصوصی هرگز مسدود نشوند",
    df_ssh_failures: "ورود ناموفق قبل از مسدودی", df_ssh_window: "در مدت (دقیقه)", df_ssh_ban: "مدت مسدودی (دقیقه)",
    df_ssh_24h: "ورودهای ناموفق (از شروع سرویس)", df_ssh_top: "بیشترین ورود ناموفق", df_ssh_nolog: "لاگ SSH (/var/log/auth.log) خوانا نیست، پس فقط محدودیت اتصال فعال است.",
    df_f2b_present: "fail2ban هم نصب است. هر دو با هم کار می‌کنند؛ محافظ فایروال سرورهای بدون آن را هم پوشش می‌دهد.", df_attempts: "تلاش‌ها",
    df_score: "امتیاز امنیت", df_checks: "بررسی‌های امنیتی", df_fix: "راه رفع", df_kernel: "سخت‌سازی شبکه‌ی کرنل",
    df_kernel_sub: "تنظیمات لینوکس که تحمل فلاد را ارزان‌تر می‌کنند. بعد از هر ری‌بوت دوباره اعمال می‌شوند و قابل بازگشت به مقدار اصلی‌اند.",
    df_setting: "تنظیم", df_current: "فعلی", df_recommended: "پیشنهادی", df_apply_all: "اعمال پیشنهادها", df_restore: "بازگشت به اصلی",
    df_notify: "اعلان تلگرام", df_notify_attacks: "حمله‌ها (شروع، پایان، فعال شدن «زیر حمله»)", df_notify_bans: "هر مسدودی محافظ SSH",
    df_sev0: "خوب", df_sev1: "کم", df_sev2: "متوسط", df_sev3: "زیاد",
    df_c_ssh_root_pw: ["root می‌تواند با رمز از SSH وارد شود", "ورود root محدود است"], df_f_ssh_root_pw: "کلید SSH بسازید، بعد در /etc/ssh/sshd_config بگذارید PermitRootLogin prohibit-password و PasswordAuthentication no و بزنید systemctl restart ssh.",
    df_c_ssh_root: ["root می‌تواند از SSH وارد شود", "root با رمز وارد نمی‌شود"], df_f_ssh_root: "در /etc/ssh/sshd_config بگذارید PermitRootLogin prohibit-password.",
    df_c_ssh_password: ["SSH رمز عبور قبول می‌کند", "SSH فقط کلید قبول می‌کند"], df_f_ssh_password: "کلید حدس‌زدنی نیست. کلیدتان را در ~/.ssh/authorized_keys بگذارید، تست کنید، بعد PasswordAuthentication no.",
    df_c_ssh_port: ["SSH روی پورت پیش‌فرض ۲۲ است", "SSH روی پورت {ports} است"], df_f_ssh_port: "پورت دیگر فقط اسکن‌های خودکار را کم می‌کند و به‌تنهایی دفاع نیست. کلید و محافظ SSH مهم‌ترند.",
    df_c_ssh_bruteforce: ["{n} ورود ناموفق SSH در لاگ", "ورود ناموفق SSH کم است ({n})"], df_f_ssh_bruteforce: "محافظ SSH را روشن نگه دارید و به ورود فقط با کلید بروید.",
    df_c_fw_enabled: ["محافظت فایروال خاموش است", "محافظت فایروال روشن است"], df_f_fw_enabled: "از تب نمای کلی محافظت را روشن کنید.",
    df_c_internal_exposed: ["{name} (پورت {port}) از اینترنت در دسترس است", "هیچ دیتابیس یا سرویس داخلی‌ای باز نیست"], df_f_internal_exposed: "آن را روی 127.0.0.1 ببندید، یا فایروال را سخت‌گیر کنید و پورت را فقط برای آی‌پی‌های مورد اعتماد باز بگذارید.",
    df_c_open_ports: ["{n} پورت TCP به اینترنت باز است", "{n} پورت TCP عمومی"], df_f_open_ports: "حالت سخت‌گیر هر چیزی که اجازه نداده‌اید را می‌بندد.",
    df_c_reboot: ["برای تمام شدن نصب آپدیت‌ها ری‌بوت لازم است", "ری‌بوتی لازم نیست"], df_f_reboot: "در زمان خلوت سرور را ری‌بوت کنید؛ کل استک خودش بالا می‌آید.",
    df_c_auto_updates: ["آپدیت امنیتی خودکار خاموش است", "آپدیت امنیتی خودکار روشن است"], df_f_auto_updates: "apt install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades",
    df_c_conntrack: ["جدول اتصال‌ها {pct} درصد پر است", "{pct} درصد از جدول اتصال‌ها استفاده شده"], df_f_conntrack: "سخت‌سازی کرنل پایین را اعمال کنید؛ ظرفیت را بالا می‌برد.",
    df_c_kernel: ["{n} تنظیم شبکه‌ی کرنل سخت‌سازی نشده", "تنظیمات شبکه‌ی کرنل سخت‌سازی شده"], df_f_kernel: "از دکمه‌ی «اعمال پیشنهادها» پایین استفاده کنید.",
    df_c_syncookies: ["SYN cookie خاموش است", "SYN cookie روشن است"], df_f_syncookies: "سخت‌سازی کرنل پایین را اعمال کنید.",
    df_c_fail2ban: ["fail2ban نصب نیست", "fail2ban نصب است"], df_f_fail2ban: "اختیاری: محافظ SSH فایروال همین کار را می‌کند.",
    sc_syncookies: "بدون پر شدن صف، به SYN فلاد جواب می‌دهد", sc_synack: "اتصال‌های نیمه‌باز را زودتر رها می‌کند", sc_backlog: "صف بلندتر برای اتصال‌های در حال باز شدن",
    sc_rfc1337: "محافظت در برابر حمله‌ی TIME-WAIT", sc_bcast: "پینگ به آدرس broadcast را نادیده می‌گیرد (حمله‌ی smurf)", sc_bogus: "پاسخ‌های خطای جعلی ICMP را نادیده می‌گیرد",
    sc_redirects: "ICMP redirect را نادیده می‌گیرد (ربودن مسیر)", sc_send_redirects: "ICMP redirect نمی‌فرستد", sc_source_route: "بسته‌های source-routed را رد می‌کند",
    sc_conntrack: "جای بیشتر برای اتصال‌ها هنگام فلاد", sc_ct_timeout: "اتصال‌های بی‌کار را بعد از یک روز فراموش می‌کند نه پنج روز",
  };
  P.addStrings(EN, FA);
  const tt = (k, i, vars) => { const v = t(k); const s = Array.isArray(v) ? v[i] : v; return vars ? Object.entries(vars).reduce((a, [x, y]) => a.replace(`{${x}}`, y), s) : s; };

  // ---------------------------------------------------------------- state
  const TABS = [["overview", "grid"], ["firewall", "lock"], ["ddos", "zap"], ["rules", "rule"], ["lists", "list"], ["threat", "radar"], ["ssh", "terminal"], ["f2b", "jail"], ["hardening", "shield"], ["advanced", "sliders"]];
  const store = { get(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } }, set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* ignore */ } } };
  const D = { tab: store.get("df_tab", "overview"), st: null, err: "", samples: [], lastT: 0, timer: null, ticks: 0, fw: null, talkers: [], events: [], root: null, heroKey: "" };
  if (!TABS.some(([id]) => id === D.tab)) D.tab = "overview";
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const sev = (n) => pill(["ok", "", "warn", "bad"][n], t(`df_sev${n}`));
  const KEEP = 300;

  // ---------------------------------------------------------------- shell
  async function build() {
    D.tab = store.get("df_tab", D.tab);
    if (!TABS.some(([id]) => id === D.tab)) D.tab = "overview";
    try { D.st = await api("/api/defender/status"); D.err = ""; } catch (e) { D.st = null; D.err = e.message; }
    if (!D.st) {
      return `<div class="hero card warn df-hero"><div class="hero-icon">${icon("alert")}</div><div class="hero-text"><h2>${esc(t("df_missing_title"))}</h2>
        <p>${esc(t("df_missing_sub"))}</p><pre class="logs df-cmd">cd /opt/server-monitoring && docker compose up -d --build defender</pre><p class="muted">${esc(D.err)}</p></div></div>`;
    }
    const tabs = TABS.map(([id, ic]) => `<button type="button" role="tab" class="df-tab${id === D.tab ? " on" : ""}" aria-selected="${id === D.tab}" data-a="tab" data-tab="${id}">${icon(ic)}<span>${esc(t(`df_t_${id}`))}</span></button>`).join("");
    return `<div class="df-tabs" role="tablist" aria-label="${esc(t("df_nav"))}">${tabs}</div><div id="df-pending"></div><div id="df-body" class="df-body"><div class="skeleton"></div></div>`;
  }

  function bind(root) {
    D.root = root;
    root.addEventListener("click", onClick);
    root.addEventListener("change", onChange);
    root.addEventListener("submit", onSubmit);
    root.addEventListener("input", (e) => {
      if (e.target.id === "df-ban-filter") filterBans(e.target.value);
    });
    if (D.st) { paintPending(D.st.pending); showTab(D.tab); }
    clearInterval(D.timer);
    D.timer = setInterval(loop, pace());
    loop();
  }
  // the firewall page follows the live pace picked in the top bar (at least every 2 s: the agent samples that often)
  const pace = () => Math.max(2, P.state.liveEvery || 1) * 1000;
  window.addEventListener("live-every", () => {
    if (!D.timer) return;
    clearInterval(D.timer);
    D.timer = setInterval(loop, pace());
  });

  async function showTab(id) {
    D.tab = id;
    store.set("df_tab", id);
    D.root.querySelectorAll(".df-tab").forEach((b) => { const on = b.dataset.tab === id; b.classList.toggle("on", on); b.setAttribute("aria-selected", String(on)); });
    const body = D.root.querySelector("#df-body");
    if (!body) return;
    try {
      body.innerHTML = await RENDER[id]();
      if (id === "overview") paintLive();
    } catch (e) {
      if (e.message !== "unauthorized") body.innerHTML = `<div class="notice bad">${icon("bell")}<span>${esc(e.message)}</span></div>`;
    }
  }

  async function loop() {
    if (P.state.view !== "defender" || !document.body.contains(D.root)) { clearInterval(D.timer); D.timer = null; return; }
    if (document.hidden || !D.st) return;
    try {
      const live = await api("/api/defender/live", { since: D.lastT });
      for (const s of live.samples) if (s.t > D.lastT) D.samples.push(s);
      if (D.samples.length > KEEP) D.samples.splice(0, D.samples.length - KEEP);
      if (D.samples.length) D.lastT = D.samples[D.samples.length - 1].t;
      Object.assign(D.st, { attack: live.attack, escalated: live.escalated, applied: live.applied, bans: live.bans, pending: live.pending });
      paintPending(live.pending);
      D.ticks++;
      if (D.tab === "overview") {
        paintLive();
        if (D.ticks % 5 === 0) refreshOverviewSlow();
      }
      if (D.tab === "ssh" && D.sv && D.sv.pending) {
        D.sv.pending.left = Math.max(0, D.sv.pending.left - 2);
        if (D.sv.pending.left === 0 || D.ticks % 10 === 0) { const fresh = await api("/api/defender/sshd").catch(() => null); if (fresh) D.sv = fresh; }
        svFormToDraft();
        repaintSv();
      }
      if (D.tab === "rules" && D.ticks % 5 === 0 && !document.querySelector("dialog[open]")) {
        const fr = await api("/api/defender/fwrules").catch(() => null);
        if (fr && D.tab === "rules") { D.rules = fr.rules; D.ruleHits = fr.hits || {}; repaintRules(); }
      }
    } catch (e) { /* the next tick tries again */ }
  }

  // ---------------------------------------------------------------- applying changes safely
  function paintPending(p, lost = false) {
    const box = D.root && D.root.querySelector("#df-pending");
    if (!box) return;
    if (lost) { box.innerHTML = `<div class="notice bad">${icon("alert")}<span>${esc(t("df_lost"))}</span></div>`; return; }
    if (!p) { box.innerHTML = ""; return; }
    box.innerHTML = `<div class="notice warn df-pend">${icon("clock")}<span>${esc(t("df_pending", { n: p.left }))}</span>
      <button type="button" class="btn small primary" data-a="keep">${esc(t("df_keep"))}</button><button type="button" class="btn small" data-a="undo">${esc(t("df_undo"))}</button></div>`;
  }

  // POST a change; when the agent asks for confirmation, prove the panel is still reachable and keep it.
  async function apply(btn, path, body, okMsg) {
    const res = await act(btn, () => post(`/api/defender/${path}`, body));
    if (!res) return false;
    if (res.enabled !== undefined) D.st = Object.assign(D.st || {}, res);
    if (res.pending) {
      paintPending(res.pending);
      await sleep(1200);
      try {
        await api("/api/defender/status");
        D.st = await post("/api/defender/confirm", {});
        toast(okMsg || t("df_kept"));
      } catch (e) {
        paintPending(null, true);
        return false;
      }
    } else if (okMsg) toast(okMsg);
    paintPending(D.st && D.st.pending);
    return true;
  }

  // ---------------------------------------------------------------- overview
  // value -> HTML; the unit stays outside the left-to-right number so it reads right in Persian too
  const perSec = (v) => `${num(esc(nf(v, 0)))} <small>${esc(t("df_per_s"))}</small>`;
  const METRICS = [
    ["pps", "down", perSec],
    ["bps", "activity", (v) => num(esc(fmtRate(v)))],
    ["conns", "plus", perSec],
    ["drop", "ban", perSec],
    ["bans", "lock", (v) => num(esc(nf(v, 0)))],
    ["ct", "server", (v) => num(esc(`${nf(v, 1)}%`))],
  ];

  function heroState(st) {
    if (!st.enabled) return { tone: "warn", ic: "power", title: "df_off_title", sub: t("df_off_sub") };
    if (st.attack && st.attack.active) {
      const pk = st.attack.peak || {};
      return { tone: "bad", ic: "flame", title: "df_attack_title", sub: t("df_attack_sub", { since: ago(st.attack.since), pps: nf(pk.pps, 0), drop: nf(pk.drop, 0) }) };
    }
    if (st.escalated) return { tone: "warn", ic: "alert", title: "df_esc_title", sub: t("df_esc_sub") };
    return { tone: "", ic: "shield", title: "df_on_title", sub: t("df_on_sub") };
  }

  function heroHTML() {
    const st = D.st, h = heroState(st), fw = st.config.firewall;
    const chips = st.enabled ? [
      `<span class="chip">${icon("zap")}<b>${esc(t(`df_p_${st.escalated ? "attack" : st.profile}`))}</b></span>`,
      `<span class="chip">${icon("lock")}<b>${esc(t(fw.mode === "strict" ? "df_mode_strict" : "df_mode_open"))}</b></span>`,
      `<span class="chip">${icon("terminal")}${esc(t("df_t_ssh"))} <b>${esc(st.config.ssh_guard.enabled ? "✓" : "–")}</b></span>`,
    ].join("") : "";
    const profiles = st.enabled ? `<div class="df-seg" role="group" aria-label="${esc(t("df_profiles"))}">${["normal", "strict", "attack"].map((p) =>
      `<button type="button" class="${st.profile === p ? "on" : ""}" aria-pressed="${st.profile === p}" data-a="profile" data-p="${p}">${esc(t(`df_p_${p}`))}</button>`).join("")}</div>` : "";
    const cta = st.enabled
      ? `<button type="button" class="btn small ghost danger" data-a="disable">${icon("power")}<span>${esc(t("df_disable"))}</span></button>`
      : `<button type="button" class="btn primary df-cta" data-a="enable">${icon("shield")}<span>${esc(t("df_enable"))}</span></button>`;
    const err = st.error ? `<div class="notice bad">${icon("alert")}<span>${esc(st.error)}</span></div>` : "";
    return `<section class="card hero df-hero ${h.tone}"><div class="hero-icon">${icon(h.ic)}</div>
      <div class="hero-text"><h2 aria-live="polite">${esc(t(h.title))}</h2><p>${esc(h.sub)}</p><div class="hero-meta">${chips}</div></div>
      <div class="df-hero-act">${profiles}${cta}</div></section>${err}`;
  }

  async function renderOverview() {
    D.heroKey = "";
    const tiles = METRICS.map(([k, ic]) => `<div class="card stat" data-dm="${k}"><div class="label">${icon(ic)}${esc(t(`df_m_${k}`))}</div><div class="value"></div><div class="spark"></div></div>`).join("");
    const chart = `<div class="chart"><header><h3>${esc(t("df_chart"))}<span class="live-tag"><i></i>${esc(t("live_tag"))}</span></h3></header>
      <div class="legend"><span><i style="background:var(--c1)"></i>${esc(t("df_in"))}</span><span><i style="background:var(--c2)"></i>${esc(t("df_blocked"))}</span></div><div class="plot" id="df-plot"><div class="skeleton"></div></div></div>`;
    const [tk, ev] = await Promise.all([api("/api/defender/talkers").catch(() => ({ rows: [] })), api("/api/defender/events").catch(() => ({ rows: [] }))]);
    D.talkers = tk.rows; D.events = ev.rows;
    return `<div id="df-hero">${heroHTML()}</div><div class="tiles df-tiles">${tiles}</div>${chart}
      <div class="df-grid2"><section class="sec"><div class="sec-head"><h3>${icon("ban")}${esc(t("df_reasons"))}</h3></div><div id="df-reasons" class="df-bars"></div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("eye")}${esc(t("df_talkers"))}</h3><p class="muted">${esc(t("df_talkers_sub"))}</p></div><div id="df-talkers">${talkersHTML()}</div></section></div>
      <section class="sec"><div class="sec-head"><h3>${icon("clock")}${esc(t("df_events"))}</h3></div><div id="df-events">${eventsHTML()}</div></section>`;
  }

  function talkersHTML() {
    const admins = new Set(D.st.admin_ips || []);
    return table([
      { h: "df_ip", cls: "strong", cell: (r) => `${num(esc(r.ip))}${admins.has(r.ip) ? `<span class="tag">${esc(t("df_you"))}</span>` : ""}` },
      { h: "df_conns", cell: (r) => num(nf(r.conns, 0)) },
      { h: "actions", cell: (r) => admins.has(r.ip) ? "–" : `<div class="row-actions">${btnIcon("ban", t("df_ban1h"), `data-a="ban" data-ip="${esc(r.ip)}" data-min="60"`, "danger")}${btnIcon("check", t("df_allow"), `data-a="allow" data-ip="${esc(r.ip)}"`)}</div>` },
    ], D.talkers.slice(0, 10));
  }

  const EVENT_IC = { f2b_ban: "jail", f2b_unban: "unlock", f2b_config: "sliders", f2b_service: "jail", attack_start: "flame", attack_end: "okmark", escalate: "alert", deescalate: "shield", ban: "ban", ssh_ban: "terminal", unban: "unlock", block: "ban", allow: "check", rollback: "refresh", applied: "sliders", confirmed: "okmark", sysctl: "gear", started: "power" };
  function eventText(e) {
    const p = { ...e };
    if (e.kind === "attack_start") { p.pps = nf(e.pps, 0); p.drop = nf(e.drop, 0); }
    if (e.kind === "attack_end") p.min = nf((e.seconds || 0) / 60, 0);
    return t(`df_e_${e.kind}`, p);
  }
  function eventsHTML() {
    const rows = D.events.slice(-14).reverse();
    if (!rows.length) return `<div class="empty">${esc(t("df_events_none"))}</div>`;
    return `<ol class="df-events">${rows.map((e) => `<li class="ev-${esc(e.kind)}"><span class="ev-ic">${icon(EVENT_IC[e.kind] || "bell")}</span><span class="ev-t">${esc(eventText(e))}</span><time>${esc(ago(e.t))}</time></li>`).join("")}</ol>`;
  }

  async function refreshOverviewSlow() {
    const [tk, ev] = await Promise.all([api("/api/defender/talkers").catch(() => null), api("/api/defender/events").catch(() => null)]);
    if (D.tab !== "overview") return;
    if (tk) { D.talkers = tk.rows; setHTML(D.root.querySelector("#df-talkers"), talkersHTML()); }
    if (ev) { D.events = ev.rows; setHTML(D.root.querySelector("#df-events"), eventsHTML()); }
  }

  function paintLive() {
    const root = D.root, S = D.samples;
    if (!root || !root.querySelector("#df-hero")) return;
    const h = heroState(D.st), key = [D.st.enabled, h.title, D.st.profile, D.st.escalated, D.st.error, D.st.config.firewall.mode, P.state.lang].join("|");
    if (key !== D.heroKey) { D.heroKey = key; root.querySelector("#df-hero").innerHTML = heroHTML(); }
    const last = S[S.length - 1] || {};
    for (const [k, , fmt] of METRICS) {
      const card = root.querySelector(`[data-dm="${k}"]`);
      if (!card) continue;
      const v = k === "bans" ? D.st.bans : last[k];
      tween(card.querySelector(".value"), v == null ? null : v, (x) => (x == null ? "–" : fmt(x)));
      card.classList.toggle("alert-on", k === "drop" && (last.drop || 0) > 50);
      setHTML(card.querySelector(".spark"), k === "bans" ? "" : sparkline(S.slice(-120).map((s) => [s.t, s[k]]), `var(${k === "drop" ? "--c2" : "--c1"})`));
    }
    const box = root.querySelector("#df-plot");
    if (box) {
      if (S.length >= 2) {
        const end = S[S.length - 1].t;
        drawChart(box, { title: "df_chart", fmt: (v) => nf(v, 0), colors: ["--c1", "--c2"], names: ["df_in", "df_blocked"] },
          [{ name: "in", points: S.map((s) => [s.t, s.pps]) }, { name: "drop", points: S.map((s) => [s.t, s.drop]) }], "df", [end - (KEEP - 1), end]);
      } else box.innerHTML = `<div class="empty">${esc(t("live_waiting"))}</div>`;
    }
    const totals = {};
    S.forEach((s, i) => {   // rates per second; samples are 1 s apart while watched, 2 s when idle
      const dt = i ? Math.min(5, Math.max(0.2, s.t - S[i - 1].t)) : 1;
      for (const [k, v] of Object.entries(s.drops || {})) totals[k] = (totals[k] || 0) + v * dt;
    });
    const rows = Object.entries(totals).filter(([, v]) => v >= 1).sort((a, b) => b[1] - a[1]);
    const max = rows.length ? rows[0][1] : 1;
    setHTML(root.querySelector("#df-reasons"), rows.length ? rows.map(([k, v]) => `<div class="df-bar"><span>${esc(t(`df_r_${k}`))}</span><b>${num(nf(v, 0))}</b><i style="width:${Math.max(2, (v / max) * 100).toFixed(1)}%"></i></div>`).join("")
      : `<div class="empty">${esc(t("df_reasons_none"))}</div>`);
  }

  // ---------------------------------------------------------------- firewall
  const clone = (o) => JSON.parse(JSON.stringify(o));
  async function renderFirewall() {
    if (!D.fw) D.fw = clone(D.st.config.firewall);
    const ports = await api("/api/defender/ports");
    D.ports = ports.rows;
    return firewallHTML();
  }
  const portLabel = (p) => `${p.port}/${p.proto === "both" ? "tcp+udp" : p.proto}`;
  function ruleFor(r) { return D.fw.ports.findIndex((p) => !p.from && (p.proto === r.proto || p.proto === "both") && (() => { const [a, b] = String(p.port).split("-"); return +a <= r.port && r.port <= +(b || a); })()); }
  function firewallHTML() {
    const fw = D.fw, strict = fw.mode === "strict", st = D.st;
    const dirty = JSON.stringify(fw) !== JSON.stringify(st.config.firewall);
    const opt = (m) => `<button type="button" class="df-opt${fw.mode === m ? " on" : ""}" aria-pressed="${fw.mode === m}" data-a="fw-mode" data-mode="${m}">
      <span class="df-opt-ic">${icon(m === "open" ? "unlock" : "lock")}</span><b>${esc(t(`df_mode_${m}`))}</b><span>${esc(t(`df_mode_${m}_d`))}</span></button>`;
    const always = [...st.ssh_ports.map((p) => `<span class="chip">${icon("lock")}${esc(t("df_ssh"))} <b>${num(p)}</b></span>`), ...st.panel_ports.map((p) => `<span class="chip">${icon("lock")}${esc(t("df_panel"))} <b>${num(p)}</b></span>`)].join("");
    const services = table([
      { h: "df_port", cls: "strong", cell: (r) => `${num(esc(`${r.port}/${r.proto}`))}${r.docker ? '<span class="tag">docker</span>' : ""}` },
      { h: "df_process", cell: (r) => esc(r.process || "–") },
      { h: "df_state", cell: (r) => r.always ? pill("ok", t("df_locked")) : ruleFor(r) >= 0 ? pill("ok", t("df_open")) : r.restricted ? pill("warn", t("df_only_from")) : strict ? pill("bad", t("df_closed")) : pill("", t("df_open")) },
      { h: "actions", cell: (r) => r.always ? "–" : ruleFor(r) >= 0
        ? `<button type="button" class="btn small" data-a="fw-close" data-proto="${r.proto}" data-port="${r.port}">${esc(t("df_close_it"))}</button>`
        : `<button type="button" class="btn small" data-a="fw-open" data-proto="${r.proto}" data-port="${r.port}" data-note="${esc(r.process)}">${esc(t("df_open_it"))}</button>` },
    ], D.ports || []);
    const rules = table([
      { h: "df_port", cls: "strong", cell: (p) => num(esc(portLabel(p))) },
      { h: "df_from", cell: (p) => (p.from ? num(esc(p.from)) : esc(t("df_any"))) },
      { h: "df_note", cell: (p) => esc(p.note || "") },
      { h: "actions", cell: (p, i) => btnIcon("trash", t("df_remove"), `data-a="fw-del" data-i="${D.fw.ports.indexOf(p)}"`, "danger") },
    ], fw.ports);
    const ifaces = fw.trusted_ifaces.map((n, i) => `<span class="chip">${num(esc(n))}<button type="button" class="chip-x" data-a="if-del" data-i="${i}" aria-label="${esc(t("df_remove"))} ${esc(n)}">${icon("x")}</button></span>`).join("");
    const known = (st.interfaces || []).map((n) => `<option value="${esc(n)}">`).join("");
    return `<section class="sec"><div class="sec-head"><h3>${icon("lock")}${esc(t("df_fw_mode"))}</h3><p class="muted">${esc(t("df_fw_mode_sub"))}</p></div>
        <div class="df-choice">${opt("open")}${opt("strict")}</div><div class="chips df-always"><span class="muted">${esc(t("df_always"))}</span>${always}</div>
        ${D.prefilled ? `<div class="notice warn">${icon("bell")}<span>${esc(t("df_strict_prefill"))}</span></div>` : ""}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("globe")}${esc(t("df_services"))}</h3><p class="muted">${esc(t("df_services_sub"))}</p></div>${services}</section>
      <section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("list")}${esc(t("df_rules"))}</h3><p class="muted">${esc(t("df_rules_sub"))}</p></div>
        <button type="button" class="btn small primary" data-a="fw-add">${icon("plus")}<span>${esc(t("df_add_rule"))}</span></button></div>${rules}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("network")}${esc(t("df_ifaces"))}</h3><p class="muted">${esc(t("df_ifaces_sub"))}</p></div>
        <form data-f="cdn" class="df-cdn"><label class="df-switch"><span class="switch"><input type="checkbox" name="trust_cdn" ${st.config.trust_cdn !== false ? "checked" : ""}><span></span></span><span><b>${esc(t("df_cdn"))}</b><small>${esc(t("df_cdn_sub"))}</small></span></label></form>
        <div class="chips">${ifaces}</div><form class="inline-field df-inline" data-f="if-add"><input name="iface" dir="ltr" list="df-iflist" placeholder="wg0" autocomplete="off" aria-label="${esc(t("df_iface_add"))}" maxlength="16"><datalist id="df-iflist">${known}</datalist><button type="submit" class="btn small">${icon("plus")}<span>${esc(t("df_iface_add"))}</span></button></form></section>
      <div class="df-actions${dirty ? " dirty" : ""}"><span class="muted">${dirty ? esc(t("df_dirty")) : ""}</span>
        <button type="button" class="btn" data-a="rules">${icon("eye")}<span>${esc(t("df_review"))}</span></button>
        <button type="button" class="btn" data-a="fw-reset" ${dirty ? "" : "disabled"}>${esc(t("df_discard"))}</button>
        <button type="button" class="btn primary" data-a="fw-apply" ${dirty ? "" : "disabled"}>${icon("check")}<span>${esc(t("df_apply"))}</span></button></div>`;
  }
  const repaintFw = () => { const b = D.root.querySelector("#df-body"); if (b && D.tab === "firewall") b.innerHTML = firewallHTML(); };

  function addRuleDialog() {
    openDialog({
      title: t("df_add_rule"), submit: t("add"),
      body: `<div class="field-row">${field(t("df_port"), '<input name="port" dir="ltr" required placeholder="443" autocomplete="off" pattern="\\d{1,5}(-\\d{1,5})?">', t("df_port_hint"))}
        ${field(t("df_proto"), '<select name="proto"><option value="tcp">TCP</option><option value="udp">UDP</option><option value="both">TCP + UDP</option></select>')}</div>
        ${field(t("df_from"), '<input name="from" dir="ltr" placeholder="203.0.113.0/24" autocomplete="off">', t("df_from_hint"))}
        ${field(t("df_note"), '<input name="note" maxlength="80" autocomplete="off">')}`,
      onSubmit: async (form) => {
        const r = { proto: form.elements.proto.value, port: form.elements.port.value.trim(), from: form.elements.from.value.trim(), note: form.elements.note.value.trim() };
        if (!/^\d{1,5}(-\d{1,5})?$/.test(r.port)) throw new Error(t("df_port_hint"));
        D.fw.ports.push(r);
        repaintFw();
      },
    });
  }

  function rulesDialog() {
    openDialog({
      title: t("df_rules_title"), wide: true, hideSubmit: true, cancel: t("close"),
      body: `<pre class="logs df-rules" dir="ltr">…</pre>`,
      onOpen: async (dlg) => {
        try { dlg.querySelector("pre").textContent = (await api("/api/defender/rules")).text; } catch (e) { dlg.querySelector("pre").textContent = e.message; }
      },
    });
  }

  // ---------------------------------------------------------------- anti-DDoS
  const LIMITS = [["syn", 1, 100000], ["conn", 1, 100000], ["conc", 5, 1000000], ["udp", 1, 1000000], ["icmp", 1, 10000], ["ban", 1, 10080]];
  async function renderDdos() {
    const st = D.st;
    const card = (p) => {
      const L = p === "custom" ? st.limits : st.profiles[p];
      const on = st.profile === p;
      return `<button type="button" class="df-opt df-prof${on ? " on" : ""}" aria-pressed="${on}" data-a="profile" data-p="${p}" ${p === "custom" ? "disabled" : ""}>
        <b>${esc(t(`df_p_${p}`))}</b><span>${esc(t(`df_p_${p}_d`))}</span>
        <span class="df-nums">${num(`SYN ${nf(L.syn, 0)}/s · ${t("df_conns")} ${nf(L.conc, 0)} · ${t("df_l_ban").replace(/ \(.*/, "")} ${nf(L.ban, 0)}m`)}</span></button>`;
    };
    const inputs = LIMITS.map(([k, lo, hi]) => field(t(`df_l_${k}`), `<input type="number" name="${k}" min="${lo}" max="${hi}" step="1" required value="${esc(st.limits[k])}" dir="ltr" inputmode="numeric">`)).join("");
    const sw = (name, on, label, sub = "") => `<label class="df-switch"><span class="switch"><input type="checkbox" name="${name}" ${on ? "checked" : ""}><span></span></span><span><b>${esc(label)}</b>${sub ? `<small>${esc(sub)}</small>` : ""}</span></label>`;
    return `<section class="sec"><div class="sec-head"><h3>${icon("zap")}${esc(t("df_profiles"))}</h3><p class="muted">${esc(t("df_profiles_sub"))}</p></div>
        <div class="df-choice df-choice4">${["normal", "strict", "attack", "custom"].map(card).join("")}</div>
        <form data-f="esc">${sw("auto_escalate", st.config.auto_escalate, t("df_auto_esc"), t("df_auto_esc_sub"))}</form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("sliders")}${esc(t("df_adv"))}</h3><p class="muted">${esc(t("df_adv_sub"))}</p></div>
        <form class="subcard" data-f="ddos"><div class="df-form-grid">${inputs}</div>
        ${sw("drop_invalid", st.config.ddos.drop_invalid, t("df_drop_invalid"))}${sw("bad_flags", st.config.ddos.bad_flags, t("df_bad_flags"))}
        <div class="actions-row"><button type="submit" class="btn primary">${icon("check")}<span>${esc(t("df_save"))}</span></button></div></form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("shield")}${esc(t("df_covers"))}</h3></div>
        <ul class="df-covers">${["syn", "conn", "udp", "scan", "ssh"].map((k) => `<li>${icon("okmark")}<span>${esc(t(`df_cv_${k}`))}</span></li>`).join("")}<li class="no">${icon("alert")}<span>${esc(t("df_cv_l7"))}</span></li></ul></section>`;
  }

  // ---------------------------------------------------------------- IP lists
  async function renderLists() {
    const b = await api("/api/defender/bans");
    D.bans = b;
    const admins = b.admin_ips.length ? `<div class="notice ok">${icon("check")}<span>${esc(t("df_admins", { ips: b.admin_ips.join("، ") }))}</span></div>` : "";
    const left = (s) => (s == null ? "–" : s > 86400 ? `${nf(s / 86400, 1)}d` : s > 3600 ? `${nf(s / 3600, 1)}h` : `${nf(s / 60, 0)}m`);
    const bans = table([
      { h: "df_ip", cls: "strong", cell: (r) => num(esc(r.ip)) },
      { h: "df_source", cell: (r) => pill(r.source === "manual" || r.source === "fail2ban" ? "" : "warn", r.jail ? t("df_s_fail2ban_jail", { jail: r.jail }) : t(`df_s_${r.source}`)) },
      { h: "df_left", cell: (r) => num(esc(left(r.left))) },
      { h: "actions", cell: (r) => (r.source === "fail2ban" ? (r.jail ? `<button type="button" class="btn small" data-a="f2b-unban" data-ip="${esc(r.ip)}" data-jail="${esc(r.jail)}">${esc(t("df_unban"))}</button>` : "–")
        : `<button type="button" class="btn small" data-a="unban" data-ip="${esc(r.ip)}">${esc(t("df_unban"))}</button>`) },
    ], b.rows, (r) => `data-ip="${esc(r.ip)}"`);
    const listTable = (rows, kind) => table([
      { h: "df_ip", cls: "strong", cell: (r) => num(esc(r.ip)) },
      { h: "df_note", cell: (r) => esc(r.note || "") },
      { h: "df_added", cell: (r) => (r.added ? esc(ago(r.added)) : "–") },
      { h: "actions", cell: (r) => btnIcon("trash", `${t("df_remove")} ${r.ip}`, `data-a="un${kind}" data-ip="${esc(r.ip)}"`, "danger") },
    ], rows);
    const f2b = "";
    return `<section class="sec"><div class="sec-head"><h3>${icon("plus")}${esc(t("df_add_ip"))}</h3></div>${admins}
        <form class="subcard df-addip" data-f="list-add"><div class="df-form-grid">
          ${field(t("df_ip"), '<input name="ip" dir="ltr" required placeholder="203.0.113.7 / 203.0.113.0/24" autocomplete="off">')}
          ${field(t("df_action"), `<select name="action"><option value="ban60">${esc(t("df_a_ban1h"))}</option><option value="ban1440">${esc(t("df_a_ban24h"))}</option><option value="ban10080">${esc(t("df_a_ban7d"))}</option><option value="block">${esc(t("df_a_block"))}</option><option value="allow">${esc(t("df_a_allow"))}</option></select>`)}
          ${field(t("df_note"), '<input name="note" maxlength="80" autocomplete="off">')}</div>
          <div class="actions-row"><button type="submit" class="btn primary">${icon("plus")}<span>${esc(t("add"))}</span></button></div></form></section>
      <section class="sec"><div class="sec-head df-head-row"><h3>${icon("ban")}${esc(t("df_bans"))} <span class="badge">${num(b.rows.length)}</span></h3>
        <input type="search" id="df-ban-filter" class="df-filter" placeholder="${esc(t("df_filter"))}" aria-label="${esc(t("df_filter"))}" dir="ltr"></div><div id="df-bans">${bans}</div>${f2b}</section>
      <div class="df-grid2"><section class="sec"><div class="sec-head"><h3>${icon("ban")}${esc(t("df_blocklist"))}</h3></div>${listTable(b.block, "block")}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("check")}${esc(t("df_allowlist"))}</h3></div>${listTable(b.allow, "allow")}</section></div>`;
  }
  function filterBans(q) {
    q = q.trim().toLowerCase();
    D.root.querySelectorAll("#df-bans tbody tr").forEach((tr) => { tr.hidden = !!q && !(tr.dataset.ip || "").toLowerCase().includes(q); });
  }

  // ---------------------------------------------------------------- SSH guard
  async function renderSsh() {
    const s = await api("/api/defender/ssh"), g = s.config;
    const sw = (name, on, label) => `<label class="df-switch"><span class="switch"><input type="checkbox" name="${name}" ${on ? "checked" : ""}><span></span></span><span><b>${esc(label)}</b></span></label>`;
    const top = table([
      { h: "df_ip", cls: "strong", cell: (r) => num(esc(r.ip)) },
      { h: "df_attempts", cell: (r) => num(nf(r.n, 0)) },
      { h: "actions", cell: (r) => btnIcon("ban", `${t("df_ban1h")} ${r.ip}`, `data-a="ban" data-ip="${esc(r.ip)}" data-min="60"`, "danger") },
    ], s.top);
    return `<section class="sec"><div class="sec-head"><h3>${icon("terminal")}${esc(t("df_ssh_title"))}</h3><p class="muted">${esc(t("df_ssh_sub"))}</p></div>
        ${s.available ? "" : `<div class="notice warn">${icon("bell")}<span>${esc(t("df_ssh_nolog"))}</span></div>`}
        ${s.fail2ban ? `<div class="notice">${icon("shield")}<span>${esc(t("df_f2b_present"))}</span></div>` : ""}
        <form class="subcard" data-f="ssh">${sw("enabled", g.enabled, t("df_ssh_on"))}${sw("l4", g.l4, t("df_ssh_l4"))}${sw("exempt_private", g.exempt_private, t("df_ssh_private"))}
          <div class="df-form-grid">${field(t("df_ssh_failures"), `<input type="number" name="failures" min="2" max="100" value="${g.failures}" dir="ltr" required>`)}
          ${field(t("df_ssh_window"), `<input type="number" name="window" min="1" max="1440" value="${g.window}" dir="ltr" required>`)}
          ${field(t("df_ssh_ban"), `<input type="number" name="ban" min="1" max="525600" value="${g.ban}" dir="ltr" required>`)}</div>
          <div class="actions-row"><button type="submit" class="btn primary">${icon("check")}<span>${esc(t("df_save"))}</span></button></div></form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("alert")}${esc(t("df_ssh_top"))}</h3><p class="muted">${esc(t("df_ssh_24h"))}: <b>${num(nf(s.failures_24h, 0))}</b></p></div>${top}</section>`;
  }

  // ---------------------------------------------------------------- hardening
  async function renderHardening() {
    const a = await api("/api/defender/audit");
    const lv = a.score >= 85 ? "" : a.score >= 60 ? "warn" : "bad";
    const grade = a.score >= 90 ? "A" : a.score >= 75 ? "B" : a.score >= 60 ? "C" : a.score >= 40 ? "D" : "F";
    const C = 2 * Math.PI * 42;
    const ring = `<div class="ring ${lv} df-score-ring"><svg viewBox="0 0 104 104" aria-hidden="true"><circle class="track" cx="52" cy="52" r="42" fill="none" stroke-width="10"/><circle class="fill" cx="52" cy="52" r="42" fill="none" stroke-width="10" stroke-dasharray="${((C * a.score) / 100).toFixed(1)} ${C.toFixed(1)}"/></svg><div class="center"><span class="value num">${a.score}</span></div></div>`;
    const checks = [...a.checks].sort((x, y) => y.sev - x.sev);
    const items = checks.map((c) => {
      const p = c.params || {};
      const title = tt(`df_c_${c.id}`, c.sev ? 0 : 1, p);
      return `<li class="df-check s${c.sev}">${sev(c.sev)}<div><b>${esc(title)}</b>${c.sev ? `<p>${esc(t(`df_f_${c.id}`))}</p>` : ""}</div></li>`;
    }).join("");
    const sys = table([
      { h: "df_setting", cls: "wrap-cell", cell: (r) => `<code dir="ltr">${esc(r.key)}</code><div class="sub-line">${esc(t(r.why))}</div>` },
      { h: "df_current", cell: (r) => num(esc(r.current ?? "–")) },
      { h: "df_recommended", cell: (r) => num(esc(r.recommended)) },
      { h: "status", cell: (r) => (r.ok == null ? "–" : r.ok ? pill("ok", t("df_sev0")) : pill("warn", t("df_sev1"))) },
    ], a.sysctl);
    const n = D.st.config.notify;
    const sw = (name, on, label) => `<label class="df-switch"><span class="switch"><input type="checkbox" name="${name}" ${on ? "checked" : ""}><span></span></span><span><b>${esc(label)}</b></span></label>`;
    return `<section class="card df-score ${lv}">${ring}<div><h3>${esc(t("df_score"))} <span class="df-grade">${grade}</span></h3><p class="muted">${esc(tt(`df_c_fw_enabled`, D.st.enabled ? 1 : 0))}</p></div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("check")}${esc(t("df_checks"))}</h3></div><ul class="df-checks">${items}</ul></section>
      <section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("gear")}${esc(t("df_kernel"))}</h3><p class="muted">${esc(t("df_kernel_sub"))}</p></div>
        <div class="row-actions"><button type="button" class="btn small primary" data-a="sysctl" data-act="apply">${esc(t("df_apply_all"))}</button><button type="button" class="btn small" data-a="sysctl" data-act="restore" ${a.sysctl_applied.length ? "" : "disabled"}>${esc(t("df_restore"))}</button></div></div>${sys}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("send")}${esc(t("df_notify"))}</h3></div><form class="subcard" data-f="notify">${sw("attacks", n.attacks, t("df_notify_attacks"))}${sw("bans", n.bans, t("df_notify_bans"))}</form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("download")}${esc(t("df_backup"))}</h3><p class="muted">${esc(t("df_backup_sub"))}</p></div>
        <div class="row-actions"><button type="button" class="btn" data-a="export">${icon("download")}<span>${esc(t("df_export"))}</span></button>
        <label class="btn">${icon("upload")}<span>${esc(t("df_import"))}</span><input type="file" accept="application/json,.json" data-import hidden></label></div></section>`;
  }

  // ---------------------------------------------------------------- strings for countries, fail2ban, backup
  P.addStrings({
    df_t_countries: "Countries", df_t_f2b: "fail2ban", df_r_geo: "Blocked countries",
    // countries
    df_geo_title: "Block countries", df_geo_sub: "Drop every connection that comes from the selected countries. The address lists are downloaded from ipdeny.com and refreshed every week.",
    df_geo_warn: "Visitors from these countries will not reach any service on this server, including your VPN or sites. Logged-in admins, the allowlist and Cloudflare are not affected.",
    df_geo_selected: "Blocked countries", df_geo_none: "No country is blocked.", df_geo_search: "Search countries…", df_geo_ranges: "{n} ranges", df_geo_off: "Turn protection on (Overview) for country blocking to take effect.",
    df_geo_all: "All countries",
    // fail2ban
    df_f2b_what: "fail2ban reads the logs of your services and bans addresses that keep failing: wrong passwords, scanners, abusers. Each protection it runs is called a jail.",
    df_f2b_running: "fail2ban is running", df_f2b_stopped: "fail2ban is installed but stopped", df_f2b_missing: "fail2ban is not installed",
    df_f2b_stopped_sub: "Nothing is banned while it is stopped. Start it to protect your services again.",
    df_f2b_missing_sub: "Install it with one click: it watches SSH logins right away, and you can turn on more protections below.",
    df_f2b_nopm: "This server has no supported package manager (apt, dnf, yum), so fail2ban cannot be installed from here.",
    df_f2b_install: "Install fail2ban", df_f2b_uninstall: "Uninstall", df_f2b_start: "Start", df_f2b_stop: "Stop", df_f2b_restart: "Restart", df_f2b_reload: "Reload settings",
    df_f2b_boot_on: "Starts at boot", df_f2b_boot_off: "Does not start at boot", df_f2b_boot_enable: "Start at boot", df_f2b_boot_disable: "Do not start at boot",
    df_f2b_version: "Version", df_f2b_jails_n: "Protections", df_f2b_banned_now: "Banned now",
    df_f2b_install_confirm: "Install fail2ban with the system package manager? This takes a minute or two.",
    df_f2b_uninstall_confirm: "Uninstall fail2ban? Its bans are lifted.", df_f2b_purge: "Also delete its settings files",
    df_f2b_stop_confirm: "Stop fail2ban? Nobody is banned while it is stopped and current bans are lifted.",
    df_f2b_job_install: "Installing fail2ban…", df_f2b_job_uninstall: "Removing fail2ban…", df_f2b_job_ok: "Done", df_f2b_job_fail: "Failed; see the output below",
    df_f2b_jails: "Protections (jails)", df_f2b_jails_sub: "Each switch turns one protection on or off. Changes are checked by fail2ban before they are applied.",
    df_f2b_on: "On", df_f2b_off: "Off", df_f2b_failed: "Failing now", df_f2b_total: "Banned in total",
    df_f2b_rule: "{tries} failures within {window} → banned for {ban}", df_f2b_settings: "Settings", df_f2b_bans: "Banned IPs",
    df_f2b_custom: "Custom protection set up on this server.", df_f2b_source: "Reads", df_f2b_journal: "system journal",
    df_f2b_tries: "Failures allowed", df_f2b_window: "Within", df_f2b_bantime: "Ban for", df_f2b_forever: "forever",
    df_f2b_defaults: "General settings", df_f2b_defaults_sub: "Used by every protection that does not set its own value.",
    df_f2b_increment: "Ban repeat offenders for longer each time", df_f2b_increment_sub: "Every new ban of the same address lasts longer, up to the maximum below.", df_f2b_maxtime: "Longest ban",
    df_f2b_ignore: "Never ban these addresses", df_f2b_ignore_sub: "Your own IPs, office, monitoring. Networks like 10.0.0.0/8 work too.", df_f2b_add_trusted: "Add trusted SSH addresses",
    df_f2b_ban_ip: "Ban an address in this jail", df_f2b_no_bans: "Nobody is banned in this jail.", df_f2b_log: "fail2ban log", df_f2b_log_sub: "The latest lines of /var/log/fail2ban.log.",
    df_f2b_saved: "Saved and applied", df_f2b_ends: "Ends",
    f2bj_sshd: "SSH logins", f2bd_sshd: "Bans addresses that guess SSH passwords or users.",
    f2bj_recidive: "Repeat offenders", f2bd_recidive: "Addresses fail2ban had to ban again and again are banned from every port for a long time.",
    "f2bj_3x-ipl": "3x-ui IP limit", "f2bd_3x-ipl": "Made by 3x-ui: bans VPN users that connect from more devices than their plan allows.",
    "f2bj_nginx-http-auth": "Nginx password pages", "f2bd_nginx-http-auth": "Bans addresses that guess passwords of pages protected by Nginx.",
    "f2bj_nginx-botsearch": "Nginx vulnerability scanners", "f2bd_nginx-botsearch": "Bans bots that probe for admin pages and known weak spots.",
    "f2bj_nginx-bad-request": "Nginx malformed requests", "f2bd_nginx-bad-request": "Bans clients that send broken HTTP requests (usually scanners).",
    "f2bj_nginx-limit-req": "Nginx request floods", "f2bd_nginx-limit-req": "Bans clients Nginx had to throttle (needs limit_req in your Nginx config).",
    "f2bj_apache-auth": "Apache password pages", "f2bd_apache-auth": "Bans addresses that guess passwords of pages protected by Apache.",
    "f2bj_apache-badbots": "Apache bad bots", "f2bd_apache-badbots": "Bans known spam and e-mail harvesting bots.",
    f2bj_postfix: "Mail server (Postfix)", f2bd_postfix: "Bans addresses that abuse the mail server.",
    f2bj_dovecot: "Mailboxes (Dovecot)", f2bd_dovecot: "Bans addresses that guess mailbox passwords.",
    f2bj_vsftpd: "FTP logins", f2bd_vsftpd: "Bans addresses that guess FTP passwords.",
    "f2bj_mysqld-auth": "MySQL logins", "f2bd_mysqld-auth": "Bans addresses that guess database passwords.",
    df_e_f2b_ban: "fail2ban [{jail}] banned {ip}", df_e_f2b_unban: "fail2ban: {ip} unbanned", df_e_f2b_config: "fail2ban settings changed ({what})", df_e_f2b_service: "fail2ban: {action}",
    df_s_fail2ban_jail: "fail2ban · {jail}",
    df_c_fail2ban_stopped: ["fail2ban is installed but not running", "fail2ban is running"], df_f_fail2ban_stopped: "Start it in the fail2ban tab.",
    // backup
    df_backup: "Backup and restore", df_backup_sub: "Download every firewall setting (rules, lists, limits, countries, fail2ban) as a file, or load one from another server.",
    df_export: "Download backup", df_import: "Restore from file", df_import_confirm: "Replace the firewall settings with the ones in {name}? The rules are tested for 60 seconds like any other change.",
    df_import_bad: "This is not a firewall backup file.",
  }, {
    df_t_countries: "کشورها", df_t_f2b: "fail2ban", df_r_geo: "کشورهای مسدود",
    df_geo_title: "مسدود کردن کشورها", df_geo_sub: "هر اتصالی که از کشورهای انتخاب‌شده بیاید دور ریخته می‌شود. لیست آی‌پی‌ها از ipdeny.com دانلود و هر هفته بروز می‌شود.",
    df_geo_warn: "بازدیدکننده‌های این کشورها به هیچ سرویسی روی این سرور نمی‌رسند، از جمله VPN یا سایت‌هایتان. ادمین‌های واردشده، لیست سفید و Cloudflare تحت تأثیر نیستند.",
    df_geo_selected: "کشورهای مسدود", df_geo_none: "هیچ کشوری مسدود نیست.", df_geo_search: "جستجوی کشور…", df_geo_ranges: "{n} بازه", df_geo_off: "برای اثر کردن مسدودی کشورها، محافظت را (در نمای کلی) روشن کنید.",
    df_geo_all: "همه‌ی کشورها",
    df_f2b_what: "fail2ban لاگ سرویس‌هایتان را می‌خواند و آدرس‌هایی که مدام خطا می‌کنند را مسدود می‌کند: رمز اشتباه، اسکنر، سوءاستفاده. به هر محافظتش «جیل» می‌گویند.",
    df_f2b_running: "fail2ban در حال اجراست", df_f2b_stopped: "fail2ban نصب است ولی متوقف است", df_f2b_missing: "fail2ban نصب نیست",
    df_f2b_stopped_sub: "تا متوقف است هیچ‌کس مسدود نمی‌شود. برای محافظت دوباره روشنش کنید.",
    df_f2b_missing_sub: "با یک کلیک نصبش کنید: بلافاصله ورودهای SSH را زیر نظر می‌گیرد و محافظت‌های بیشتری را پایین می‌توانید روشن کنید.",
    df_f2b_nopm: "این سرور مدیر بسته‌ی پشتیبانی‌شده (apt، dnf، yum) ندارد، پس از اینجا نمی‌شود fail2ban را نصب کرد.",
    df_f2b_install: "نصب fail2ban", df_f2b_uninstall: "حذف", df_f2b_start: "شروع", df_f2b_stop: "توقف", df_f2b_restart: "ری‌استارت", df_f2b_reload: "بارگذاری دوباره‌ی تنظیمات",
    df_f2b_boot_on: "با روشن شدن سرور اجرا می‌شود", df_f2b_boot_off: "با روشن شدن سرور اجرا نمی‌شود", df_f2b_boot_enable: "اجرا هنگام بوت", df_f2b_boot_disable: "اجرا نشدن هنگام بوت",
    df_f2b_version: "نسخه", df_f2b_jails_n: "محافظت‌ها", df_f2b_banned_now: "مسدود فعلی",
    df_f2b_install_confirm: "fail2ban با مدیر بسته‌ی سیستم نصب شود؟ یکی دو دقیقه طول می‌کشد.",
    df_f2b_uninstall_confirm: "fail2ban حذف شود؟ مسدودی‌هایش برداشته می‌شوند.", df_f2b_purge: "فایل‌های تنظیماتش هم پاک شوند",
    df_f2b_stop_confirm: "fail2ban متوقف شود؟ تا متوقف است کسی مسدود نمی‌شود و مسدودی‌های فعلی برداشته می‌شوند.",
    df_f2b_job_install: "در حال نصب fail2ban…", df_f2b_job_uninstall: "در حال حذف fail2ban…", df_f2b_job_ok: "انجام شد", df_f2b_job_fail: "ناموفق؛ خروجی پایین را ببینید",
    df_f2b_jails: "محافظت‌ها (جیل‌ها)", df_f2b_jails_sub: "هر کلید یک محافظت را روشن یا خاموش می‌کند. هر تغییر قبل از اعمال توسط خود fail2ban بررسی می‌شود.",
    df_f2b_on: "روشن", df_f2b_off: "خاموش", df_f2b_failed: "خطای فعلی", df_f2b_total: "کل مسدودها",
    df_f2b_rule: "{tries} خطا در {window} ← مسدود به مدت {ban}", df_f2b_settings: "تنظیمات", df_f2b_bans: "آی‌پی‌های مسدود",
    df_f2b_custom: "محافظت سفارشی که روی این سرور تنظیم شده.", df_f2b_source: "می‌خواند", df_f2b_journal: "ژورنال سیستم",
    df_f2b_tries: "تعداد خطای مجاز", df_f2b_window: "در مدت", df_f2b_bantime: "مدت مسدودی", df_f2b_forever: "همیشه",
    df_f2b_defaults: "تنظیمات کلی", df_f2b_defaults_sub: "برای هر محافظتی که مقدار خودش را ندارد استفاده می‌شود.",
    df_f2b_increment: "مسدودی تکراری هر بار طولانی‌تر شود", df_f2b_increment_sub: "هر مسدودی جدید همان آدرس طولانی‌تر است، تا سقف پایین.", df_f2b_maxtime: "طولانی‌ترین مسدودی",
    df_f2b_ignore: "این آدرس‌ها هرگز مسدود نشوند", df_f2b_ignore_sub: "آی‌پی‌های خودتان، دفتر، مانیتورینگ. شبکه هم می‌شود مثل 10.0.0.0/8.", df_f2b_add_trusted: "افزودن آدرس‌های مورد اعتماد SSH",
    df_f2b_ban_ip: "مسدود کردن یک آدرس در این جیل", df_f2b_no_bans: "در این جیل کسی مسدود نیست.", df_f2b_log: "لاگ fail2ban", df_f2b_log_sub: "آخرین خط‌های /var/log/fail2ban.log.",
    df_f2b_saved: "ذخیره و اعمال شد", df_f2b_ends: "پایان",
    f2bj_sshd: "ورود SSH", f2bd_sshd: "آدرس‌هایی که رمز یا کاربر SSH را حدس می‌زنند مسدود می‌کند.",
    f2bj_recidive: "متخلفان تکراری", f2bd_recidive: "آدرس‌هایی که fail2ban بارها مسدودشان کرده، برای مدت طولانی از همه‌ی پورت‌ها مسدود می‌شوند.",
    "f2bj_3x-ipl": "محدودیت آی‌پی 3x-ui", "f2bd_3x-ipl": "ساخته‌ی 3x-ui: کاربران VPN که با دستگاه‌های بیشتر از پلنشان وصل شوند مسدود می‌شوند.",
    "f2bj_nginx-http-auth": "صفحه‌های رمزدار Nginx", "f2bd_nginx-http-auth": "آدرس‌هایی که رمز صفحه‌های محافظت‌شده با Nginx را حدس می‌زنند مسدود می‌کند.",
    "f2bj_nginx-botsearch": "اسکنرهای آسیب‌پذیری Nginx", "f2bd_nginx-botsearch": "ربات‌هایی که دنبال صفحه‌ی مدیریت و نقطه‌ضعف‌های شناخته‌شده می‌گردند مسدود می‌کند.",
    "f2bj_nginx-bad-request": "درخواست‌های خراب Nginx", "f2bd_nginx-bad-request": "کلاینت‌هایی که درخواست HTTP خراب می‌فرستند (معمولاً اسکنر) مسدود می‌کند.",
    "f2bj_nginx-limit-req": "فلاد درخواست Nginx", "f2bd_nginx-limit-req": "کلاینت‌هایی که Nginx محدودشان کرده مسدود می‌کند (به limit_req در تنظیمات Nginx نیاز دارد).",
    "f2bj_apache-auth": "صفحه‌های رمزدار Apache", "f2bd_apache-auth": "آدرس‌هایی که رمز صفحه‌های محافظت‌شده با Apache را حدس می‌زنند مسدود می‌کند.",
    "f2bj_apache-badbots": "ربات‌های بد Apache", "f2bd_apache-badbots": "ربات‌های اسپم و جمع‌کننده‌ی ایمیل را مسدود می‌کند.",
    f2bj_postfix: "سرور ایمیل (Postfix)", f2bd_postfix: "آدرس‌هایی که از سرور ایمیل سوءاستفاده می‌کنند مسدود می‌کند.",
    f2bj_dovecot: "صندوق‌های ایمیل (Dovecot)", f2bd_dovecot: "آدرس‌هایی که رمز صندوق ایمیل را حدس می‌زنند مسدود می‌کند.",
    f2bj_vsftpd: "ورود FTP", f2bd_vsftpd: "آدرس‌هایی که رمز FTP را حدس می‌زنند مسدود می‌کند.",
    "f2bj_mysqld-auth": "ورود MySQL", "f2bd_mysqld-auth": "آدرس‌هایی که رمز دیتابیس را حدس می‌زنند مسدود می‌کند.",
    df_e_f2b_ban: "fail2ban [{jail}] آدرس {ip} را مسدود کرد", df_e_f2b_unban: "fail2ban: مسدودی {ip} برداشته شد", df_e_f2b_config: "تنظیمات fail2ban تغییر کرد ({what})", df_e_f2b_service: "fail2ban: {action}",
    df_s_fail2ban_jail: "fail2ban · {jail}",
    df_c_fail2ban_stopped: ["fail2ban نصب است ولی اجرا نمی‌شود", "fail2ban در حال اجراست"], df_f_fail2ban_stopped: "از تب fail2ban روشنش کنید.",
    df_backup: "پشتیبان‌گیری و بازگردانی", df_backup_sub: "همه‌ی تنظیمات فایروال (قوانین، لیست‌ها، محدودیت‌ها، کشورها، fail2ban) را به‌صورت فایل دانلود کنید، یا فایل یک سرور دیگر را بارگذاری کنید.",
    df_export: "دانلود پشتیبان", df_import: "بازگردانی از فایل", df_import_confirm: "تنظیمات فایروال با تنظیمات {name} جایگزین شود؟ قوانین مثل هر تغییر دیگری ۶۰ ثانیه آزمایش می‌شوند.",
    df_import_bad: "این فایل پشتیبان فایروال نیست.",
  });
  P.addIcons({
    jail: '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M9 3v18M15 3v18M4 12h16"/>',
    download: '<path d="M12 4v11M7 10l5 5 5-5M5 20h14"/>',
    upload: '<path d="M12 20V9M7 14l5-5 5 5M5 4h14"/>',
  });

  // ---------------------------------------------------------------- countries
  const COUNTRIES = ("ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bl bm bn bo bq br bs bt bw by bz ca cd cf cg ch ci ck cl cm cn co cr cu cv cw cy cz de dj dk dm do dz ec ee eg er es et fi fj fk fm fo fr ga gb gd ge gf gg gh gi gl gm gn gp gq gr gt gu gw gy hk hn hr ht hu id ie il im in io iq ir is it je jm jo jp ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc md me mf mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz na nc ne nf ng ni nl no np nr nu nz om pa pe pf pg ph pk pl pm pr ps pt pw py qa re ro rs ru rw sa sb sc sd se sg si sk sl sm sn so sr ss st sv sx sy sz tc td tg th tj tk tl tm tn to tr tt tv tw tz ua ug us uy uz va vc ve vg vi vn vu wf ws ye yt za zm zw").split(" ");
  let regionNames = null;
  const ccName = (cc) => {
    try {
      if (!regionNames || regionNames._lang !== P.state.lang) { regionNames = new Intl.DisplayNames([P.state.lang === "fa" ? "fa" : "en"], { type: "region" }); regionNames._lang = P.state.lang; }
      return regionNames.of(cc.toUpperCase()) || cc.toUpperCase();
    } catch (e) { return cc.toUpperCase(); }
  };
  let enNames = null;
  const ccEnglish = (cc) => { try { enNames = enNames || new Intl.DisplayNames(["en"], { type: "region" }); return enNames.of(cc.toUpperCase()) || ""; } catch (e) { return ""; } };
  const flag = (cc) => String.fromCodePoint(...[...cc.toUpperCase()].map((c) => 0x1f1e6 - 65 + c.charCodeAt(0)));

  // ---------------------------------------------------------------- fail2ban
  const fmtSecs = (s) => {
    s = Number(s);
    if (s < 0) return t("df_f2b_forever");
    if (!(s >= 0)) return "–";
    const u = [[604800, "w"], [86400, "d"], [3600, "h"], [60, "m"], [1, "s"]].find(([n]) => s >= n && s % n === 0) || [1, "s"];
    return `${nf(s / u[0], 0)}${u[1]}`;
  };
  const DUR = { "1m": 60, "5m": 300, "10m": 600, "30m": 1800, "1h": 3600, "3h": 10800, "6h": 21600, "12h": 43200, "1d": 86400, "3d": 259200, "1w": 604800, "2w": 1209600, "4w": 2419200, "-1": -1 };
  const durSelect = (name, cur, keys) => {
    const curS = typeof cur === "number" ? cur : DUR[cur] ?? null;
    let found = false;
    const opts = keys.map((k) => { const on = DUR[k] === curS; found = found || on; return `<option value="${k}" ${on ? "selected" : ""}>${esc(k === "-1" ? t("df_f2b_forever") : fmtSecs(DUR[k]))}</option>`; }).join("");
    const extra = !found && cur != null ? `<option value="${esc(typeof cur === "number" ? `${cur}` : cur)}" selected>${esc(typeof cur === "number" ? fmtSecs(cur) : cur)}</option>` : "";
    return `<select name="${name}">${extra}${opts}</select>`;
  };
  const WINDOWS = ["1m", "5m", "10m", "30m", "1h", "3h", "6h", "12h", "1d"], BANS_T = ["10m", "30m", "1h", "3h", "6h", "12h", "1d", "3d", "1w", "2w", "4w", "-1"];
  const jailTitle = (n) => { const k = `f2bj_${n}`, v = t(k); return v === k ? n : v; };
  const jailDesc = (n) => { const k = `f2bd_${n}`, v = t(k); return v === k ? t("df_f2b_custom") : v; };

  async function renderF2b() {
    D.f2b = await api("/api/defender/f2b");
    schedJob();
    setTimeout(fillFiles, 0);
    return f2bHTML();
  }
  async function fillFiles() {
    const box = D.root && D.root.querySelector("#df-f2b-files");
    if (box && D.f2b && D.f2b.installed) box.innerHTML = await filesSection();
  }
  function schedJob() {
    clearTimeout(D.f2bJobT);
    if (D.f2b && D.f2b.job && D.f2b.job.running) D.f2bJobT = setTimeout(async () => { if (D.tab === "f2b") { D.f2b = await api("/api/defender/f2b").catch(() => D.f2b); paintF2b(); schedJob(); } }, 1500);
  }
  const paintF2b = () => { const b = D.root.querySelector("#df-body"); if (b && D.tab === "f2b") { b.innerHTML = f2bHTML(); fillFiles(); } };

  function f2bHTML() {
    const f = D.f2b, job = f.job || {};
    const jobBox = job.action && (job.running || Date.now() / 1000 - job.ended < 600)
      ? `<div class="notice ${job.running ? "warn" : job.ok ? "ok" : "bad"}">${icon(job.running ? "clock" : job.ok ? "okmark" : "alert")}<span>${esc(job.running ? t(`df_f2b_job_${job.action}`) : job.ok ? t("df_f2b_job_ok") : t("df_f2b_job_fail"))}</span></div>
         <pre class="logs df-joblog" dir="ltr">${esc(job.log || "…")}</pre>` : "";
    const busy = job.running ? "disabled" : "";
    if (!f.installed) {
      return `<section class="card hero warn df-hero"><div class="hero-icon">${icon("jail")}</div><div class="hero-text"><h2>${esc(t("df_f2b_missing"))}</h2><p>${esc(t("df_f2b_missing_sub"))}</p><p class="muted">${esc(t("df_f2b_what"))}</p></div>
        <div class="df-hero-act">${f.pm ? `<button type="button" class="btn primary df-cta" data-a="f2b-install" ${busy}>${icon("download")}<span>${esc(t("df_f2b_install"))}</span></button>` : ""}</div></section>
        ${f.pm ? "" : `<div class="notice bad">${icon("alert")}<span>${esc(t("df_f2b_nopm"))}</span></div>`}${jobBox}`;
    }
    const banned = (f.jails || []).reduce((a, j) => a + (j.banned || 0), 0);
    const tone = f.running ? "" : "bad";
    const svc = f.running
      ? `<button type="button" class="btn small" data-a="f2b-svc" data-act="restart" ${busy}>${icon("refresh")}<span>${esc(t("df_f2b_restart"))}</span></button>
         <button type="button" class="btn small" data-a="f2b-svc" data-act="reload" ${busy}>${icon("sliders")}<span>${esc(t("df_f2b_reload"))}</span></button>
         <button type="button" class="btn small ghost danger" data-a="f2b-svc" data-act="stop" ${busy}>${icon("stop")}<span>${esc(t("df_f2b_stop"))}</span></button>`
      : `<button type="button" class="btn primary" data-a="f2b-svc" data-act="start" ${busy}>${icon("play")}<span>${esc(t("df_f2b_start"))}</span></button>`;
    const boot = f.boot === "enabled"
      ? `<button type="button" class="btn small ghost" data-a="f2b-svc" data-act="disable" ${busy}>${esc(t("df_f2b_boot_disable"))}</button>`
      : `<button type="button" class="btn small" data-a="f2b-svc" data-act="enable" ${busy}>${esc(t("df_f2b_boot_enable"))}</button>`;
    const hero = `<section class="card hero df-hero ${tone}"><div class="hero-icon">${icon("jail")}</div>
      <div class="hero-text"><h2>${esc(t(f.running ? "df_f2b_running" : "df_f2b_stopped"))}</h2><p>${esc(f.running ? t("df_f2b_what") : t("df_f2b_stopped_sub"))}</p>
        <div class="hero-meta">${f.version ? `<span class="chip">${esc(t("df_f2b_version"))} <b>${num(esc(f.version))}</b></span>` : ""}
          <span class="chip">${icon("jail")}${esc(t("df_f2b_jails_n"))} <b>${num((f.jails || []).length)}</b></span>
          <span class="chip">${icon("ban")}${esc(t("df_f2b_banned_now"))} <b>${num(banned)}</b></span>
          <span class="chip">${icon(f.boot === "enabled" ? "okmark" : "alert")}${esc(t(f.boot === "enabled" ? "df_f2b_boot_on" : "df_f2b_boot_off"))}</span></div></div>
      <div class="df-hero-act"><div class="row-actions">${svc}</div><div class="row-actions">${boot}<button type="button" class="btn small ghost danger" data-a="f2b-uninstall" ${busy}>${icon("trash")}<span>${esc(t("df_f2b_uninstall"))}</span></button></div></div></section>`;
    const managed = f.managed || { default: {}, jails: {} };
    const running = new Map((f.jails || []).map((j) => [j.name, j]));
    const names = [...running.keys(), ...Object.keys(managed.jails).filter((n) => !running.has(n) && managed.jails[n].enabled === false), ...(f.available || []).map((a) => a.name).filter((n) => !running.has(n) && !(n in managed.jails && managed.jails[n].enabled === false))];
    const cards = [...new Set(names)].map((n) => jailCard(n, running.get(n))).join("");
    const d = managed.default || {}, ref = (f.jails || []).find((j) => j.name === "sshd") || (f.jails || [])[0] || {};
    const ignore = d.ignoreip || ref.ignoreip || [];
    D.f2bIgnore = D.f2bIgnore || [...ignore];
    const ignChips = D.f2bIgnore.map((ip, i) => `<span class="chip">${num(esc(ip))}<button type="button" class="chip-x" data-a="f2b-ign-del" data-i="${i}" aria-label="${esc(t("df_remove"))} ${esc(ip)}">${icon("x")}</button></span>`).join("");
    const defaults = `<section class="sec"><div class="sec-head"><h3>${icon("sliders")}${esc(t("df_f2b_defaults"))}</h3><p class="muted">${esc(t("df_f2b_defaults_sub"))}</p></div>
      <form class="subcard" data-f="f2b-defaults"><div class="df-form-grid">
        ${field(t("df_f2b_tries"), `<input type="number" name="maxretry" min="1" max="100" value="${esc(d.maxretry || ref.maxretry || 5)}" dir="ltr" required>`)}
        ${field(t("df_f2b_window"), durSelect("findtime", d.findtime || ref.findtime || 600, WINDOWS))}
        ${field(t("df_f2b_bantime"), durSelect("bantime", d.bantime || ref.bantime || 600, BANS_T))}
        ${field(t("df_f2b_maxtime"), durSelect("maxtime", d["bantime.maxtime"] || "4w", ["1d", "3d", "1w", "2w", "4w", "-1"]))}</div>
        <label class="df-switch"><span class="switch"><input type="checkbox" name="increment" ${d["bantime.increment"] ? "checked" : ""}><span></span></span><span><b>${esc(t("df_f2b_increment"))}</b><small>${esc(t("df_f2b_increment_sub"))}</small></span></label>
        <div class="field"><label>${esc(t("df_f2b_ignore"))}</label><p class="hint">${esc(t("df_f2b_ignore_sub"))}</p><div class="chips">${ignChips}</div>
          <div class="inline-field df-inline"><input name="newip" dir="ltr" placeholder="203.0.113.7" autocomplete="off" aria-label="${esc(t("df_f2b_ignore"))}"><button type="button" class="btn small" data-a="f2b-ign-add">${icon("plus")}<span>${esc(t("add"))}</span></button>
          ${(f.admin_ips || []).length ? `<button type="button" class="btn small" data-a="f2b-ign-trusted">${icon("check")}<span>${esc(t("df_f2b_add_trusted"))}</span></button>` : ""}</div></div>
        <div class="actions-row"><button type="submit" class="btn primary" ${busy}>${icon("check")}<span>${esc(t("df_save"))}</span></button></div></form></section>`;
    const logSec = f.log ? `<section class="sec"><details class="df-logbox"><summary data-a="f2b-log-open"><b>${icon("file")}${esc(t("df_f2b_log"))}</b> <span class="muted">${esc(t("df_f2b_log_sub"))}</span></summary>
      <div class="row-actions" style="margin:10px 0"><button type="button" class="btn small" data-a="f2b-log">${icon("refresh")}<span>${esc(t("refresh"))}</span></button></div><pre class="logs df-joblog" id="df-f2b-log" dir="ltr">…</pre></details></section>` : "";
    return `${hero}${f.error ? `<div class="notice bad">${icon("alert")}<span>${esc(f.error)}</span></div>` : ""}${jobBox}
      <section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("shield")}${esc(t("df_f2b_jails"))}</h3><p class="muted">${esc(t("df_f2b_jails_sub"))}</p></div>
        <button type="button" class="btn small primary" data-a="f2b-jail-new" ${busy}>${icon("plus")}<span>${esc(t("df_j_new"))}</span></button></div><div class="f2b-grid">${cards}</div></section>
      ${defaults}<div id="df-f2b-files"></div>${logSec}`;
  }

  function jailCard(name, j) {
    const on = !!j;
    const rule = j ? t("df_f2b_rule", { tries: nf(j.maxretry, 0), window: fmtSecs(j.findtime), ban: fmtSecs(j.bantime) }) : "";
    const src = j ? (j.source === "journal" ? t("df_f2b_journal") : j.source) : "";
    return `<article class="f2b-jail${on ? " on" : ""}">
      <header><span class="f2b-ic">${icon(name === "sshd" ? "terminal" : name === "recidive" ? "clock" : "jail")}</span>
        <div class="f2b-name"><b>${esc(jailTitle(name))}</b><small dir="ltr">${esc(name)}</small></div>
        <label class="switch" title="${esc(t(on ? "df_f2b_on" : "df_f2b_off"))}"><input type="checkbox" data-jail-toggle="${esc(name)}" ${on ? "checked" : ""} aria-label="${esc(jailTitle(name))}"><span></span></label></header>
      <p class="f2b-desc">${esc(jailDesc(name))}</p>
      ${j ? `<div class="f2b-stats"><div class="${j.banned ? "hot" : ""}"><b>${num(nf(j.banned, 0))}</b><span>${esc(t("df_f2b_banned_now"))}</span></div><div><b>${num(nf(j.banned_total, 0))}</b><span>${esc(t("df_f2b_total"))}</span></div><div><b>${num(nf(j.failed, 0))}</b><span>${esc(t("df_f2b_failed"))}</span></div></div>
        <p class="f2b-rule">${icon("sliders")}<span>${esc(rule)}</span></p>${src ? `<p class="f2b-src muted">${esc(t("df_f2b_source"))}: <span dir="ltr">${esc(src)}</span></p>` : ""}
        <footer><button type="button" class="btn small" data-a="f2b-jail-set" data-jail="${esc(name)}">${icon("gear")}<span>${esc(t("df_f2b_settings"))}</span></button>
          <button type="button" class="btn small" data-a="f2b-jail-bans" data-jail="${esc(name)}">${icon("ban")}<span>${esc(t("df_f2b_bans"))} (${num(j.banned)})</span></button></footer>` : ""}
      <footer class="f2b-manage"><button type="button" class="btn small ghost" data-a="f2b-jail-edit" data-jail="${esc(name)}">${icon("sliders")}<span>${esc(t("df_j_edit"))}</span></button>
        <button type="button" class="btn small ghost danger" data-a="f2b-jail-del" data-jail="${esc(name)}">${icon("trash")}<span>${esc(t("df_j_delete"))}</span></button></footer>
    </article>`;
  }

  function jailSettingsDialog(name) {
    const j = (D.f2b.jails || []).find((x) => x.name === name) || {};
    openDialog({
      title: `${jailTitle(name)} · ${t("df_f2b_settings")}`, submit: t("df_save"),
      body: `<p class="muted">${esc(jailDesc(name))}</p><div class="field-row">
        ${field(t("df_f2b_tries"), `<input type="number" name="maxretry" min="1" max="100" value="${esc(j.maxretry || 5)}" dir="ltr" required>`)}
        ${field(t("df_f2b_window"), durSelect("findtime", j.findtime, WINDOWS))}</div>
        ${field(t("df_f2b_bantime"), durSelect("bantime", j.bantime, BANS_T))}`,
      onSubmit: async (form) => {
        D.f2b = await post("/api/defender/f2b/jail", { name, maxretry: +form.elements.maxretry.value, findtime: form.elements.findtime.value, bantime: form.elements.bantime.value });
        toast(t("df_f2b_saved"));
        paintF2b();
      },
    });
  }

  function jailBansDialog(name) {
    const left = (u) => (u ? `${fmtSecs(Math.max(0, Math.round(u - Date.now() / 1000)))}` : "–");
    const dlg = openDialog({
      title: `${jailTitle(name)} · ${t("df_f2b_bans")}`, wide: true, hideSubmit: true, cancel: t("close"),
      body: `<form class="inline-field df-inline" data-f="f2b-ban" style="margin:0 0 14px"><input name="ip" dir="ltr" required placeholder="203.0.113.7" autocomplete="off" aria-label="${esc(t("df_f2b_ban_ip"))}"><button type="submit" class="btn small danger">${icon("ban")}<span>${esc(t("df_f2b_ban_ip"))}</span></button></form><div id="df-jb"><div class="skeleton"></div></div>`,
      onOpen: async (d) => {
        const box = d.querySelector("#df-jb");
        const load = async () => {
          try {
            const r = await api("/api/defender/f2b/bans", { jail: name });
            box.innerHTML = r.rows.length ? table([
              { h: "df_ip", cls: "strong", cell: (x) => num(esc(x.ip)) },
              { h: "df_left", cell: (x) => num(esc(left(x.until))) },
              { h: "actions", cell: (x) => `<button type="button" class="btn small" data-unban="${esc(x.ip)}">${esc(t("df_unban"))}</button>` },
            ], r.rows) : `<div class="empty">${esc(t("df_f2b_no_bans"))}</div>`;
          } catch (e) { box.innerHTML = `<div class="notice bad">${esc(e.message)}</div>`; }
        };
        box.addEventListener("click", async (e) => {
          const b = e.target.closest("[data-unban]");
          if (b && await act(b, () => post("/api/defender/f2b/unban", { jail: name, ip: b.dataset.unban }), `${b.dataset.unban} ✓`)) load();
        });
        d.querySelector('[data-f="f2b-ban"]').addEventListener("submit", async (e) => {
          e.preventDefault();
          const ip = e.target.elements.ip.value.trim();
          if (await act(e.target.querySelector("button"), () => post("/api/defender/f2b/ban", { jail: name, ip }), `${ip} ✓`)) { e.target.reset(); load(); }
        });
        load();
      },
    });
    dlg.addEventListener("close", () => { if (D.tab === "f2b") showTab("f2b"); });
  }

  function uninstallDialog() {
    openDialog({
      title: t("df_f2b_uninstall"), submit: t("df_f2b_uninstall"), danger: true,
      body: `<p>${esc(t("df_f2b_uninstall_confirm"))}</p><label class="df-switch"><span class="switch"><input type="checkbox" name="purge"><span></span></span><span><b>${esc(t("df_f2b_purge"))}</b></span></label>`,
      onSubmit: async (form) => {
        const r = await post("/api/defender/f2b/uninstall", { purge: form.elements.purge.checked });
        D.f2b = { ...D.f2b, job: r.job };
        paintF2b();
        schedJob();
      },
    });
  }

  // ---------------------------------------------------------------- backup (hardening tab)
  async function exportBackup(btn) {
    const data = await act(btn, () => api("/api/defender/export"));
    if (!data) return;
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `firewall-backup-${new Date().toISOString().slice(0, 10)}.json`;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  }
  async function importBackup(file) {
    let data;
    try { data = JSON.parse(await file.text()); } catch (e) { return toast(t("df_import_bad"), "bad"); }
    if (!data || data.app !== "server-monitor-firewall") return toast(t("df_import_bad"), "bad");
    if (!(await confirmBox({ message: t("df_import_confirm", { name: file.name }), label: t("df_import"), danger: false }))) return;
    if (await apply(null, "import", { data })) { D.fw = null; D.adv = null; rerender(); }
  }

  // ---------------------------------------------------------------- full control: jail editor, files, advanced
  P.addStrings({
    df_t_advanced: "Advanced",
    df_j_edit: "Edit", df_j_delete: "Delete", df_j_new: "New jail", df_j_name: "Jail name", df_j_name_hint: "Letters, digits, - _ . (for example my-app).",
    df_j_enabled: "Enabled", df_j_port: "Ports", df_j_port_hint: "ssh, http,https, 8080 or 1000:2000. Empty = the jail's default.", df_j_protocol: "Protocol",
    df_j_filter: "Filter", df_j_filter_hint: "Which patterns count as a failure (files in filter.d).", df_j_logpath: "Log files", df_j_logpath_hint: "One path per line. Not needed with the systemd backend.",
    df_j_backend: "How to read logs", df_j_banaction: "Ban action", df_j_banaction_hint: "How addresses are blocked (nftables, iptables-multiport, …).", df_j_action: "Actions (advanced)",
    df_j_ignoreip: "Never ban (this jail)", df_j_increment: "Longer bans for repeat offenders", df_j_inherit: "Like the general settings", df_j_on: "On", df_j_off: "Off",
    df_j_extra: "More settings", df_j_extra_hint: "Any other fail2ban option, one `key = value` per line.", df_j_from: "from {file}", df_j_defined: "Defined in: {files}",
    df_j_delete_confirm: "Delete the jail {name}? Its section is removed from the files under /etc/fail2ban (a backup is kept in /etc/fail2ban/.panel-backup).",
    df_j_deleted: "Jail deleted", df_j_stock_off: "This jail ships with fail2ban (jail.conf), so it was switched off and its overrides were removed.", df_j_saved: "Saved, checked and applied",
    df_files: "Configuration files", df_files_sub: "Every fail2ban file, for anything the forms do not cover. Each save is checked with fail2ban-client -t; on an error the file goes back to how it was.",
    df_file_new: "New file", df_file_path: "File", df_file_path_hint: "jail.d/name.local, filter.d/name.conf, action.d/name.conf, jail.local …", df_file_size: "Size", df_file_mtime: "Changed",
    df_file_panel: "Written by the panel: changes here are replaced the next time a form is saved.", df_file_deleted: "File deleted", df_file_delete_confirm: "Delete {path}? A backup is kept in /etc/fail2ban/.panel-backup.",
    df_file_bad: "Use a path like jail.d/name.local or filter.d/name.conf",
    df_adv_title: "Advanced settings", df_adv_sub: "Everything the other tabs keep fixed. Changes are tested like any other rule change.",
    df_adv_panel: "Who can open the panel", df_adv_panel_sub: "Only these addresses reach the panel port; everyone else gets no answer. Logged-in SSH users and the allowlist always can. Empty = everyone.",
    df_adv_my_ip: "Add my address ({ip})", df_adv_safety: "Safety", df_adv_rollback: "Test time before changes are kept", df_adv_rollback_off: "Off (apply at once)",
    df_adv_lock: "Keep SSH and panel ports always open", df_adv_lock_sub: "Off: they follow strict mode like any other port. A mistake can lock you out.",
    df_adv_docker: "Never filter Docker traffic", df_adv_docker_sub: "Off: traffic from containers is filtered like any other.", df_adv_logged: "Trust addresses that logged in over SSH", df_adv_logged_sub: "Off: they are limited like anyone else.",
    df_adv_detect: "Attack detection", df_adv_detect_sub: "An attack starts when one of these is passed for 3 seconds, and ends after the calm time.",
    df_adv_drops: "Blocked packets per second", df_adv_cookies: "SYN cookies per second", df_adv_pps: "Incoming packets per second", df_adv_ct: "Connection table full (%)", df_adv_calm: "Calm time (seconds)",
    df_adv_deesc: "Back to normal limits after (minutes)", df_adv_bans: "Bans", df_adv_factor: "Ban a source going this many times over a limit (0 = never ban)",
    df_adv_ssh_rate: "New SSH connections per minute before a ban (0 = no limit)", df_adv_ssh_ban: "SSH ban time (minutes)",
    df_adv_custom: "Custom nftables rules", df_adv_custom_sub: "Statements for new connections, one per line, run before the strict-mode and flood rules. For example: tcp dport 9000 ip saddr 203.0.113.0/24 accept",
    df_adv_sysctl: "Custom kernel settings", df_adv_sysctl_sub: "Any net.*, kernel.*, vm.* or fs.* setting. Applied now and after every reboot; removing one restores the original value.",
    df_adv_key: "Setting", df_adv_value: "Value", df_adv_set: "Set",
  }, {
    df_t_advanced: "پیشرفته",
    df_j_edit: "ویرایش", df_j_delete: "حذف", df_j_new: "جیل جدید", df_j_name: "نام جیل", df_j_name_hint: "حروف، عدد، - _ . (مثلاً my-app).",
    df_j_enabled: "فعال", df_j_port: "پورت‌ها", df_j_port_hint: "ssh، http,https، 8080 یا 1000:2000. خالی = پیش‌فرض جیل.", df_j_protocol: "پروتکل",
    df_j_filter: "فیلتر", df_j_filter_hint: "چه الگوهایی خطا حساب شوند (فایل‌های filter.d).", df_j_logpath: "فایل‌های لاگ", df_j_logpath_hint: "هر خط یک مسیر. با backend سیستم‌دی لازم نیست.",
    df_j_backend: "روش خواندن لاگ", df_j_banaction: "روش مسدودی", df_j_banaction_hint: "آدرس‌ها چطور بسته شوند (nftables، iptables-multiport، …).", df_j_action: "اکشن‌ها (پیشرفته)",
    df_j_ignoreip: "هرگز مسدود نشوند (این جیل)", df_j_increment: "مسدودی طولانی‌تر برای تکرار", df_j_inherit: "مثل تنظیمات کلی", df_j_on: "روشن", df_j_off: "خاموش",
    df_j_extra: "تنظیمات بیشتر", df_j_extra_hint: "هر گزینه‌ی دیگر fail2ban، هر خط یک `key = value`.", df_j_from: "از {file}", df_j_defined: "تعریف‌شده در: {files}",
    df_j_delete_confirm: "جیل {name} حذف شود؟ بخش آن از فایل‌های /etc/fail2ban پاک می‌شود (یک پشتیبان در /etc/fail2ban/.panel-backup می‌ماند).",
    df_j_deleted: "جیل حذف شد", df_j_stock_off: "این جیل همراه خود fail2ban است (jail.conf)، پس خاموش شد و تنظیمات اضافه‌اش پاک شد.", df_j_saved: "ذخیره، بررسی و اعمال شد",
    df_files: "فایل‌های تنظیمات", df_files_sub: "همه‌ی فایل‌های fail2ban، برای هر چیزی که فرم‌ها پوشش نمی‌دهند. هر ذخیره با fail2ban-client -t بررسی می‌شود و اگر خطا داشت فایل به حالت قبل برمی‌گردد.",
    df_file_new: "فایل جدید", df_file_path: "فایل", df_file_path_hint: "jail.d/name.local، filter.d/name.conf، action.d/name.conf، jail.local …", df_file_size: "حجم", df_file_mtime: "تغییر",
    df_file_panel: "این فایل را پنل می‌نویسد: تغییرات اینجا دفعه‌ی بعدی که فرمی ذخیره شود جایگزین می‌شود.", df_file_deleted: "فایل حذف شد", df_file_delete_confirm: "{path} حذف شود؟ یک پشتیبان در /etc/fail2ban/.panel-backup می‌ماند.",
    df_file_bad: "مسیری مثل jail.d/name.local یا filter.d/name.conf بنویسید",
    df_adv_title: "تنظیمات پیشرفته", df_adv_sub: "هر چیزی که تب‌های دیگر ثابت نگه می‌دارند. تغییرات مثل هر تغییر قانون دیگری آزمایش می‌شوند.",
    df_adv_panel: "چه کسی پنل را باز کند", df_adv_panel_sub: "فقط این آدرس‌ها به پورت پنل می‌رسند؛ بقیه هیچ جوابی نمی‌گیرند. کاربرهای واردشده با SSH و لیست سفید همیشه می‌توانند. خالی = همه.",
    df_adv_my_ip: "افزودن آدرس من ({ip})", df_adv_safety: "ایمنی", df_adv_rollback: "مدت آزمایش قبل از ماندن تغییرات", df_adv_rollback_off: "خاموش (فوری اعمال شود)",
    df_adv_lock: "پورت SSH و پنل همیشه باز بماند", df_adv_lock_sub: "خاموش: مثل بقیه‌ی پورت‌ها از حالت سخت‌گیر پیروی می‌کنند. یک اشتباه می‌تواند دسترسی شما را قطع کند.",
    df_adv_docker: "ترافیک داکر هرگز فیلتر نشود", df_adv_docker_sub: "خاموش: ترافیک کانتینرها مثل بقیه فیلتر می‌شود.", df_adv_logged: "اعتماد به آدرس‌هایی که با SSH وارد شده‌اند", df_adv_logged_sub: "خاموش: مثل بقیه محدود می‌شوند.",
    df_adv_detect: "تشخیص حمله", df_adv_detect_sub: "وقتی یکی از این‌ها ۳ ثانیه رد شود حمله شروع می‌شود و بعد از زمان آرامش تمام می‌شود.",
    df_adv_drops: "بسته‌ی مسدود در ثانیه", df_adv_cookies: "SYN cookie در ثانیه", df_adv_pps: "بسته‌ی ورودی در ثانیه", df_adv_ct: "پر شدن جدول اتصال (درصد)", df_adv_calm: "زمان آرامش (ثانیه)",
    df_adv_deesc: "بازگشت به محدودیت عادی بعد از (دقیقه)", df_adv_bans: "مسدودی‌ها", df_adv_factor: "منبعی که چند برابر حد برود مسدود شود (۰ = هرگز مسدود نکن)",
    df_adv_ssh_rate: "اتصال جدید SSH در دقیقه قبل از مسدودی (۰ = بدون محدودیت)", df_adv_ssh_ban: "مدت مسدودی SSH (دقیقه)",
    df_adv_custom: "قوانین دلخواه nftables", df_adv_custom_sub: "دستورهایی برای اتصال‌های جدید، هر خط یکی، قبل از قوانین حالت سخت‌گیر و فلاد. مثال: tcp dport 9000 ip saddr 203.0.113.0/24 accept",
    df_adv_sysctl: "تنظیمات دلخواه کرنل", df_adv_sysctl_sub: "هر تنظیم net.*، kernel.*، vm.* یا fs.*. همین الان و بعد از هر ری‌بوت اعمال می‌شود؛ حذفش مقدار اصلی را برمی‌گرداند.",
    df_adv_key: "تنظیم", df_adv_value: "مقدار", df_adv_set: "اعمال",
  });

  // ---- jail editor
  const BACKENDS = ["auto", "systemd", "polling", "pyinotify"];
  const BANACTIONS = ["nftables", "nftables[type=allports]", "nftables-multiport", "iptables-multiport", "iptables-allports", "ufw", "route"];
  async function jailEditor(name, create = false) {
    const d = create ? { values: {}, base: {}, panel: {}, sources: {}, defined: [], filters: (await api("/api/defender/f2b/jail", { jail: "sshd" }).catch(() => ({ filters: [] }))).filters }
      : await api("/api/defender/f2b/jail", { jail: name });
    const live = ((D.f2b && D.f2b.jails) || []).find((j) => j.name === name) || {};   // what the running jail really uses
    const cur = (k) => { const p = d.panel || {}; const v = p[k] !== undefined ? p[k] : d.values[k] !== undefined ? d.values[k] : ["maxretry", "findtime", "bantime"].includes(k) ? live[k] : undefined; return v === true ? "true" : v === false ? "false" : v ?? ""; };
    const inp = (k, label, hint = "", attrs = "") => field(label, `<input name="${k}" dir="ltr" value="${esc(cur(k))}" autocomplete="off" ${attrs}>`, hint) ;
    const area = (k, label, hint = "", rows = 3) => field(label, `<textarea name="${k}" dir="ltr" rows="${rows}" spellcheck="false">${esc(cur(k).replace(/\n\s+/g, "\n"))}</textarea>`, hint);
    const sel = (k, label, opts) => { const v = cur(k); const has = !v || opts.includes(v); return field(label, `<select name="${k}"><option value="">${esc(t("df_j_inherit"))}</option>${has ? "" : `<option selected value="${esc(v)}">${esc(v)}</option>`}${opts.map((o) => `<option value="${esc(o)}" ${o === v ? "selected" : ""}>${esc(o)}</option>`).join("")}</select>`); };
    const enabled = create ? true : String(cur("enabled")).toLowerCase() === "true";
    const extra = (d.panel || {}).extra || "";
    openDialog({
      title: create ? t("df_j_new") : `${jailTitle(name)} · ${t("df_j_edit")}`, submit: t("df_save"), wide: true,
      body: `${create ? field(t("df_j_name"), '<input name="name" dir="ltr" required pattern="[A-Za-z0-9_.\\-]{1,40}" autocomplete="off">', t("df_j_name_hint"))
        : `<p class="muted">${esc(t("df_j_defined", { files: (d.defined || []).join("، ") || "—" }))}</p>`}
        <label class="df-switch"><span class="switch"><input type="checkbox" name="enabled" ${enabled ? "checked" : ""}><span></span></span><span><b>${esc(t("df_j_enabled"))}</b></span></label>
        <div class="field-row">${field(t("df_j_filter"), `<input name="filter" dir="ltr" list="df-filters" value="${esc(cur("filter"))}" autocomplete="off" ${create ? "required" : ""}><datalist id="df-filters">${(d.filters || []).map((f) => `<option value="${esc(f)}">`).join("")}</datalist>`, t("df_j_filter_hint"))}
          ${sel("backend", t("df_j_backend"), BACKENDS)}</div>
        ${area("logpath", t("df_j_logpath"), t("df_j_logpath_hint"), 2)}
        <div class="field-row">${inp("port", t("df_j_port"), t("df_j_port_hint"))}${sel("protocol", t("df_j_protocol"), ["tcp", "udp", "all"])}</div>
        <div class="field-row">${inp("maxretry", t("df_f2b_tries"), "", 'inputmode="numeric"')}${inp("findtime", t("df_f2b_window"), "10m, 1h, 1d")}</div>
        <div class="field-row">${inp("bantime", t("df_f2b_bantime"), "10m, 1h, 1d, 1w, -1")}${field(t("df_j_increment"), `<select name="bantime.increment"><option value="">${esc(t("df_j_inherit"))}</option><option value="true" ${cur("bantime.increment") === "true" ? "selected" : ""}>${esc(t("df_j_on"))}</option><option value="false" ${cur("bantime.increment") === "false" ? "selected" : ""}>${esc(t("df_j_off"))}</option></select>`)}</div>
        ${field(t("df_j_banaction"), `<input name="banaction" dir="ltr" list="df-banactions" value="${esc(cur("banaction"))}" autocomplete="off"><datalist id="df-banactions">${BANACTIONS.map((b) => `<option value="${esc(b)}">`).join("")}</datalist>`, t("df_j_banaction_hint"))}
        ${area("ignoreip", t("df_j_ignoreip"), t("df_f2b_ignore_sub"), 2)}
        <details class="df-adv"><summary>${esc(t("df_j_extra"))}</summary>${area("action", t("df_j_action"), "", 3)}
          ${field(t("df_j_extra"), `<textarea name="extra" dir="ltr" rows="4" spellcheck="false" placeholder="usedns = no&#10;bantime.factor = 2">${esc(extra)}</textarea>`, t("df_j_extra_hint"))}</details>`,
      onSubmit: async (form) => {
        const el = form.elements, base = d.base || {};
        const body = { name: create ? el.name.value.trim() : name, replace: true };
        if (create) body.create = true;
        const baseEnabled = String(base.enabled ?? "false").toLowerCase() === "true";
        if (create || el.enabled.checked !== baseEnabled) body.enabled = el.enabled.checked;
        for (const k of ["filter", "backend", "logpath", "port", "protocol", "maxretry", "findtime", "bantime", "bantime.increment", "banaction", "ignoreip", "action"]) {
          const v = (el[k].value || "").trim();
          const b = String(base[k] ?? "").replace(/\n\s+/g, "\n").trim();
          if (v && v !== b) body[k] = v;
        }
        if (el.extra.value.trim()) body.extra = el.extra.value;
        D.f2b = await post("/api/defender/f2b/jail", body);
        toast(t("df_j_saved"));
        paintF2b();
      },
    });
  }

  async function deleteJail(name, btn) {
    if (!(await confirmBox({ message: t("df_j_delete_confirm", { name }), label: t("df_j_delete") }))) return;
    const r = await act(btn, () => post("/api/defender/f2b/jail/delete", { name }));
    if (!r) return;
    D.f2b = r;
    toast(r.disabled_only ? t("df_j_stock_off") : t("df_j_deleted"), r.disabled_only ? "warn" : "");
    paintF2b();
  }

  // ---- file editor
  const FILE_RE = /^(jail\.local|jail\.conf|fail2ban\.local|fail2ban\.conf|paths-[a-z]+\.conf|(jail\.d|filter\.d|action\.d|fail2ban\.d)\/[A-Za-z0-9_.\-]{1,80}\.(conf|local))$/;
  async function filesSection() {
    const r = await api("/api/defender/f2b/files").catch(() => ({ rows: [] }));
    const rows = table([
      { h: "df_file_path", cls: "strong", cell: (f) => `<code dir="ltr">${esc(f.path)}</code>${f.panel ? '<span class="tag">panel</span>' : ""}` },
      { h: "df_file_size", cell: (f) => num(esc(fmtBytes(f.size))) },
      { h: "df_file_mtime", cell: (f) => esc(ago(f.mtime)) },
      { h: "actions", cell: (f) => `<button type="button" class="btn small" data-a="f2b-file" data-path="${esc(f.path)}">${icon("file")}<span>${esc(t("df_j_edit"))}</span></button>` },
    ], r.rows);
    return `<section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("file")}${esc(t("df_files"))}</h3><p class="muted">${esc(t("df_files_sub"))}</p></div>
      <button type="button" class="btn small" data-a="f2b-file-new">${icon("plus")}<span>${esc(t("df_file_new"))}</span></button></div>
      <details class="df-adv"><summary>${esc(t("df_files"))} (${num(r.rows.length)})</summary>${rows}</details></section>`;
  }
  async function fileEditor(path, isNew = false) {
    const f = isNew ? { path, text: "", exists: false } : await api("/api/defender/f2b/file", { path });
    const dlg = openDialog({
      title: path, submit: t("df_save"), wide: true,
      body: `${f.path.endsWith("zzz-panel.local") ? `<div class="notice warn">${icon("alert")}<span>${esc(t("df_file_panel"))}</span></div>` : ""}
        <textarea name="text" class="df-code" dir="ltr" spellcheck="false" rows="22">${esc(f.text)}</textarea>
        ${f.exists && !/^(jail|fail2ban)\.conf$/.test(f.path) ? `<p><button type="button" class="btn small danger" data-del>${icon("trash")}<span>${esc(t("df_j_delete"))}</span></button></p>` : ""}`,
      onSubmit: async (form) => {
        await post("/api/defender/f2b/file", { path, text: form.elements.text.value });
        toast(t("df_j_saved"));
        if (D.tab === "f2b") showTab("f2b");
      },
    });
    const del = dlg.querySelector("[data-del]");
    if (del) del.addEventListener("click", async () => {
      if (!(await confirmBox({ message: t("df_file_delete_confirm", { path }), label: t("df_j_delete") }))) return;
      if (await act(del, () => post("/api/defender/f2b/file/delete", { path }), t("df_file_deleted"))) { dlg.close(); if (D.tab === "f2b") showTab("f2b"); }
    });
  }
  function newFileDialog() {
    openDialog({
      title: t("df_file_new"), submit: t("df_j_edit"),
      body: field(t("df_file_path"), '<input name="path" dir="ltr" required placeholder="jail.d/my-app.local" autocomplete="off">', t("df_file_path_hint")),
      onSubmit: async (form) => {
        const p = form.elements.path.value.trim().replace(/^\/?etc\/fail2ban\//, "");
        if (!FILE_RE.test(p)) throw new Error(t("df_file_bad"));
        setTimeout(() => fileEditor(p, true), 50);
      },
    });
  }

  // ---- advanced tab
  async function renderAdvanced() {
    const [sec, au] = await Promise.all([api("/api/security").catch(() => ({ ip: "" })), api("/api/defender/audit").catch(() => ({ sysctl_custom: {} }))]);
    D.myIp = sec.ip;
    if (!D.adv) D.adv = JSON.parse(JSON.stringify(D.st.config.advanced));
    D.sysCustom = au.sysctl_custom || {};
    return advancedHTML();
  }
  function advancedHTML() {
    const a = D.adv, c = D.st.config;
    const num_ = (k, label, min = 0) => field(label, `<input type="number" name="${k}" min="${min}" value="${esc(a[k])}" dir="ltr" required>`);
    const sw = (name, on, label, sub) => `<label class="df-switch"><span class="switch"><input type="checkbox" name="${name}" ${on ? "checked" : ""}><span></span></span><span><b>${esc(label)}</b><small>${esc(sub)}</small></span></label>`;
    const chips = a.panel_allow.map((ip, i) => `<span class="chip">${num(esc(ip))}<button type="button" class="chip-x" data-a="adv-pa-del" data-i="${i}" aria-label="${esc(t("df_remove"))} ${esc(ip)}">${icon("x")}</button></span>`).join("");
    const sysRows = Object.entries(D.sysCustom).map(([k, v]) => `<span class="chip"><code dir="ltr">${esc(k)} = ${esc(v)}</code><button type="button" class="chip-x" data-a="adv-sys-del" data-key="${esc(k)}" aria-label="${esc(t("df_remove"))} ${esc(k)}">${icon("x")}</button></span>`).join("");
    const rb = [0, 30, 60, 120, 300, 600];
    return `<section class="sec"><div class="sec-head"><h3>${icon("sliders")}${esc(t("df_adv_title"))}</h3><p class="muted">${esc(t("df_adv_sub"))}</p></div></section>
      <form data-f="adv" class="df-body">
      <section class="sec"><div class="sec-head"><h3>${icon("lock")}${esc(t("df_adv_panel"))}</h3><p class="muted">${esc(t("df_adv_panel_sub"))}</p></div>
        <div class="chips">${chips}</div>
        <div class="inline-field df-inline"><input name="pa_new" dir="ltr" placeholder="203.0.113.7 / 203.0.113.0/24" autocomplete="off" aria-label="${esc(t("df_adv_panel"))}"><button type="button" class="btn small" data-a="adv-pa-add">${icon("plus")}<span>${esc(t("add"))}</span></button>
        ${D.myIp ? `<button type="button" class="btn small" data-a="adv-pa-me">${icon("check")}<span>${esc(t("df_adv_my_ip", { ip: D.myIp }))}</span></button>` : ""}</div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("shield")}${esc(t("df_adv_safety"))}</h3></div><div class="subcard">
        ${field(t("df_adv_rollback"), `<select name="rollback_seconds">${rb.map((s) => `<option value="${s}" ${+a.rollback_seconds === s ? "selected" : ""}>${s ? `${s} s` : esc(t("df_adv_rollback_off"))}</option>`).join("")}</select>`)}
        ${sw("lock_ports", a.lock_ports, t("df_adv_lock"), t("df_adv_lock_sub"))}${sw("trust_docker", a.trust_docker, t("df_adv_docker"), t("df_adv_docker_sub"))}
        ${sw("trust_logged_in", a._logged ?? c.trust_logged_in !== false, t("df_adv_logged"), t("df_adv_logged_sub"))}${sw("trust_cdn", a._cdn ?? c.trust_cdn !== false, t("df_cdn"), t("df_cdn_sub"))}</div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("flame")}${esc(t("df_adv_detect"))}</h3><p class="muted">${esc(t("df_adv_detect_sub"))}</p></div>
        <div class="subcard"><div class="df-form-grid">${num_("detect_drops", t("df_adv_drops"), 1)}${num_("detect_cookies", t("df_adv_cookies"), 1)}${num_("detect_pps", t("df_adv_pps"), 1)}${num_("detect_conntrack", t("df_adv_ct"), 1)}${num_("calm_seconds", t("df_adv_calm"), 5)}${num_("deescalate_minutes", t("df_adv_deesc"))}</div></div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("ban")}${esc(t("df_adv_bans"))}</h3></div>
        <div class="subcard"><div class="df-form-grid">${num_("autoban_factor", t("df_adv_factor"))}${num_("ssh_rate", t("df_adv_ssh_rate"))}${num_("ssh_ban_minutes", t("df_adv_ssh_ban"), 1)}</div></div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("terminal")}${esc(t("df_adv_custom"))}</h3><p class="muted">${esc(t("df_adv_custom_sub"))}</p></div>
        <textarea name="custom_rules" class="df-code" dir="ltr" rows="7" spellcheck="false" placeholder="tcp dport 9000 ip saddr 203.0.113.0/24 accept&#10;udp dport 27015 limit rate over 200/second drop">${esc(a.custom_rules)}</textarea></section>
      <div class="df-actions dirty"><span class="muted"></span><button type="button" class="btn" data-a="rules">${icon("eye")}<span>${esc(t("df_review"))}</span></button>
        <button type="submit" class="btn primary">${icon("check")}<span>${esc(t("df_apply"))}</span></button></div></form>
      <section class="sec"><div class="sec-head"><h3>${icon("gear")}${esc(t("df_adv_sysctl"))}</h3><p class="muted">${esc(t("df_adv_sysctl_sub"))}</p></div>
        <div class="chips">${sysRows}</div>
        <form class="inline-field df-inline" data-f="adv-sys"><input name="key" dir="ltr" placeholder="net.core.somaxconn" required autocomplete="off" aria-label="${esc(t("df_adv_key"))}"><input name="value" dir="ltr" placeholder="65535" required autocomplete="off" aria-label="${esc(t("df_adv_value"))}"><button type="submit" class="btn small">${esc(t("df_adv_set"))}</button></form></section>`;
  }
  const repaintAdv = () => { const b = D.root.querySelector("#df-body"); if (b && D.tab === "advanced") b.innerHTML = advancedHTML(); };
  function advFormToDraft(form) {
    if (!form) return;
    const el = form.elements;
    for (const k of ["rollback_seconds", "detect_drops", "detect_cookies", "detect_pps", "detect_conntrack", "calm_seconds", "deescalate_minutes", "autoban_factor", "ssh_rate", "ssh_ban_minutes"]) D.adv[k] = +el[k].value;
    D.adv.lock_ports = el.lock_ports.checked;
    D.adv.trust_docker = el.trust_docker.checked;
    D.adv.custom_rules = el.custom_rules.value;
    D.adv._logged = el.trust_logged_in.checked;
    D.adv._cdn = el.trust_cdn.checked;
  }

  // ---------------------------------------------------------------- firewall rules (country / address / port → action)
  P.addStrings({
    df_t_rules: "Rules", df_r_title: "Firewall rules",
    df_r_sub: "Decide what happens to new connections by country, address, protocol and port, like the firewall rules of Cloudflare or ArvanCloud. Rules run from top to bottom; the first Allow or Block that matches decides.",
    df_r_exempt: "Logged-in SSH users, the allowlist and Cloudflare (when trusted) are never affected by these rules.", df_r_off: "Protection is off, so the rules are saved but not active. Turn it on in the Overview tab.",
    df_r_new: "New rule", df_r_templates: "Start from a template", df_r_empty: "No rules yet. Pick a template above or create a rule.",
    df_r_tpl_block: "Block countries", df_r_tpl_only: "Allow only some countries", df_r_tpl_strict: "Strict limit for countries", df_r_tpl_allow: "Always allow an address", df_r_tpl_port: "Close a port to everyone else",
    df_r_name: "Rule name", df_r_when: "When the connection…", df_r_then: "Then", df_r_country: "Comes from", df_r_addr: "Comes from the address", df_r_proto: "Uses the protocol", df_r_ports: "Goes to ports",
    df_r_any_country: "any country", df_r_in: "one of these", df_r_not_in: "none of these", df_r_any_addr: "any address", df_r_any_proto: "any protocol", df_r_ping: "Ping (ICMP)",
    df_r_ports_hint: "For example 22 or 80,443 or 8000-8100. Empty = every port.", df_r_ips_hint: "One address or network per line (203.0.113.7, 203.0.113.0/24, 2001:db8::/32).",
    df_r_search: "Search countries…", df_r_selected: "{n} selected",
    df_r_a_allow: "Allow", df_r_a_block: "Block", df_r_a_limit: "Limit", df_r_a_log: "Count only",
    df_r_a_allow_d: "Always let it through, past the flood limits and strict mode.", df_r_a_block_d: "Drop it. The sender gets no answer.",
    df_r_a_limit_d: "Allow, but each address may only open a few new connections per second.", df_r_a_log_d: "Do nothing, only count the matching traffic (to test a rule first).",
    df_r_sens: "Sensitivity", df_r_s_low: "Low", df_r_s_medium: "Medium", df_r_s_high: "High", df_r_s_vhigh: "Very high", df_r_s_custom: "Custom",
    df_r_per_s: "new connections per second per address", df_r_burst: "Short bursts up to", df_r_ban: "Ban addresses that go over it", df_r_ban_no: "No, only slow them down",
    df_r_need_cond: "Pick at least one condition (country, address, protocol or port).", df_r_need_country: "Pick at least one country.", df_r_need_ip: "Enter at least one address.",
    df_r_hits: "{n} packets", df_r_hits_none: "no matches yet", df_r_up: "Move up", df_r_down: "Move down", df_r_dup: "Duplicate", df_r_delete_confirm: "Delete the rule \"{name}\"?", df_r_copy: "copy",
    df_r_if: "If", df_r_and: "and", df_r_country_is: "country is {list}", df_r_country_not: "country is not {list}", df_r_addr_is: "address is {list}", df_r_addr_not: "address is not {list}",
    df_r_proto_is: "protocol is {p}", df_r_ports_is: "port is {list}", df_r_arrow: "→", df_r_limit_sum: "limit to {rate}/s per address", df_r_ban_sum: "ban for {m} min",
    df_r_saved: "Rules applied", df_r_disabled: "Off",
    df_r_dir: "Direction", df_r_dir_in: "Incoming connections (to this server)", df_r_dir_out: "Outgoing connections (from this server, its containers and VPN users)",
    df_r_to_country: "Goes to country", df_r_to_addr: "Goes to address", df_r_out_badge: "outgoing", df_r_out_sum: "Outgoing:",
    df_r_when_active: "Active", df_r_always: "Always", df_r_sched: "Only at these times", df_r_days: "Days", df_r_sched_bad: "Pick at least one day and two different times.", df_r_from: "From", df_r_to: "To",
    df_r_tz: "Server time (UTC), now {now}.", df_r_expires: "Remove after", df_r_never: "Never (permanent)", df_r_exp_in: "ends in {left}", df_r_expired: "ended",
    df_r_sched_sum: "{days} {from}–{to}", df_r_every_day: "every day",
    df_r_tpl_mail: "Block outgoing mail (spam)", df_r_tpl_temp: "Block an address for 24 hours",
  }, {
    df_t_rules: "قوانین", df_r_title: "قوانین فایروال",
    df_r_sub: "تعیین کنید با اتصال‌های جدید بر اساس کشور، آدرس، پروتکل و پورت چه شود؛ مثل قوانین فایروال Cloudflare یا ابر آروان. قوانین از بالا به پایین اجرا می‌شوند و اولین «اجازه» یا «مسدود» که بخورد تصمیم می‌گیرد.",
    df_r_exempt: "کاربرهای واردشده با SSH، لیست سفید و Cloudflare (اگر مورد اعتماد باشد) هرگز تحت تأثیر این قوانین نیستند.", df_r_off: "محافظت خاموش است؛ قوانین ذخیره می‌شوند ولی فعال نیستند. از تب نمای کلی روشنش کنید.",
    df_r_new: "قانون جدید", df_r_templates: "شروع از یک الگو", df_r_empty: "هنوز قانونی نیست. یک الگو از بالا انتخاب کنید یا قانون جدید بسازید.",
    df_r_tpl_block: "مسدود کردن کشورها", df_r_tpl_only: "فقط چند کشور وصل شوند", df_r_tpl_strict: "محدودیت سخت برای کشورها", df_r_tpl_allow: "همیشه اجازه به یک آدرس", df_r_tpl_port: "بستن یک پورت برای بقیه",
    df_r_name: "نام قانون", df_r_when: "وقتی اتصال…", df_r_then: "آن‌وقت", df_r_country: "از کشور", df_r_addr: "از آدرس", df_r_proto: "با پروتکل", df_r_ports: "به پورت",
    df_r_any_country: "هر کشوری", df_r_in: "یکی از این‌ها", df_r_not_in: "هیچ‌کدام از این‌ها", df_r_any_addr: "هر آدرسی", df_r_any_proto: "هر پروتکلی", df_r_ping: "پینگ (ICMP)",
    df_r_ports_hint: "مثلاً 22 یا 80,443 یا 8000-8100. خالی = همه‌ی پورت‌ها.", df_r_ips_hint: "هر خط یک آدرس یا شبکه (203.0.113.7، 203.0.113.0/24، 2001:db8::/32).",
    df_r_search: "جستجوی کشور…", df_r_selected: "{n} انتخاب‌شده",
    df_r_a_allow: "اجازه", df_r_a_block: "مسدود", df_r_a_limit: "محدود", df_r_a_log: "فقط شمارش",
    df_r_a_allow_d: "همیشه رد شود، حتی از محدودیت‌های فلاد و حالت سخت‌گیر.", df_r_a_block_d: "دور ریخته شود. فرستنده هیچ جوابی نمی‌گیرد.",
    df_r_a_limit_d: "اجازه، ولی هر آدرس فقط چند اتصال جدید در ثانیه.", df_r_a_log_d: "کاری نکن، فقط ترافیک منطبق را بشمار (برای آزمایش یک قانون).",
    df_r_sens: "حساسیت", df_r_s_low: "کم", df_r_s_medium: "متوسط", df_r_s_high: "زیاد", df_r_s_vhigh: "خیلی زیاد", df_r_s_custom: "دلخواه",
    df_r_per_s: "اتصال جدید در ثانیه برای هر آدرس", df_r_burst: "جهش کوتاه تا", df_r_ban: "آدرس‌هایی که از آن رد شوند مسدود شوند", df_r_ban_no: "نه، فقط کندشان کن",
    df_r_need_cond: "حداقل یک شرط (کشور، آدرس، پروتکل یا پورت) انتخاب کنید.", df_r_need_country: "حداقل یک کشور انتخاب کنید.", df_r_need_ip: "حداقل یک آدرس وارد کنید.",
    df_r_hits: "{n} بسته", df_r_hits_none: "هنوز منطبقی نبوده", df_r_up: "بالاتر", df_r_down: "پایین‌تر", df_r_dup: "کپی", df_r_delete_confirm: "قانون «{name}» حذف شود؟", df_r_copy: "کپی",
    df_r_if: "اگر", df_r_and: "و", df_r_country_is: "کشور {list} باشد", df_r_country_not: "کشور {list} نباشد", df_r_addr_is: "آدرس {list} باشد", df_r_addr_not: "آدرس {list} نباشد",
    df_r_proto_is: "پروتکل {p} باشد", df_r_ports_is: "پورت {list} باشد", df_r_arrow: "←", df_r_limit_sum: "محدود به {rate} در ثانیه برای هر آدرس", df_r_ban_sum: "مسدودی {m} دقیقه",
    df_r_saved: "قوانین اعمال شد", df_r_disabled: "خاموش",
    df_r_dir: "جهت", df_r_dir_in: "اتصال‌های ورودی (به این سرور)", df_r_dir_out: "اتصال‌های خروجی (از این سرور، کانتینرها و کاربران VPN)",
    df_r_to_country: "به کشور", df_r_to_addr: "به آدرس", df_r_out_badge: "خروجی", df_r_out_sum: "خروجی:",
    df_r_when_active: "فعال بودن", df_r_always: "همیشه", df_r_sched: "فقط در این زمان‌ها", df_r_days: "روزها", df_r_sched_bad: "دست‌کم یک روز و دو ساعت متفاوت انتخاب کنید.", df_r_from: "از", df_r_to: "تا",
    df_r_tz: "به وقت سرور (UTC)، الان {now}.", df_r_expires: "حذف خودکار بعد از", df_r_never: "هرگز (دائمی)", df_r_exp_in: "{left} مانده", df_r_expired: "تمام شده",
    df_r_sched_sum: "{days} {from}–{to}", df_r_every_day: "هر روز",
    df_r_tpl_mail: "مسدود کردن ایمیل خروجی (اسپم)", df_r_tpl_temp: "مسدود کردن یک آدرس برای ۲۴ ساعت",
  });
  P.addIcons({ rule: '<path d="M4 5h16l-6 7.5V19l-4 1.5v-8L4 5z"/>', up: '<path d="m6 15 6-6 6 6"/>', down2: '<path d="m6 9 6 6 6-6"/>', dup: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/>' });

  const SENS = { low: [100, 200], medium: [30, 60], high: [10, 20], vhigh: [3, 6] };
  const sensOf = (L) => Object.keys(SENS).find((k) => SENS[k][0] === L.rate && SENS[k][1] === L.burst) || "custom";
  const newId = () => Array.from(crypto.getRandomValues(new Uint8Array(3)), (b) => b.toString(16).padStart(2, "0")).join("");
  const blankRule = (over = {}) => ({ id: newId(), name: "", enabled: true, direction: "in", countries: [], country_mode: "in", ips: [], ip_mode: "in", proto: "any", ports: "", action: "block",
    limit: { rate: 10, burst: 20, ban: 0 }, schedule: null, expires: 0, ...over });
  const TEMPLATES = {
    block: () => blankRule({ name: t("df_r_tpl_block"), action: "block", _c: true }),
    only: () => blankRule({ name: t("df_r_tpl_only"), country_mode: "not_in", action: "block", _c: true }),
    strict: () => blankRule({ name: t("df_r_tpl_strict"), action: "limit", limit: { rate: 3, burst: 6, ban: 60 }, _c: true }),
    allow: () => blankRule({ name: t("df_r_tpl_allow"), action: "allow", _a: true }),
    port: () => blankRule({ name: t("df_r_tpl_port"), ip_mode: "not_in", proto: "tcp", action: "block", _a: true }),
    mail: () => blankRule({ name: t("df_r_tpl_mail"), direction: "out", proto: "tcp", ports: "25,465,587", action: "block" }),
    temp: () => blankRule({ name: t("df_r_tpl_temp"), action: "block", _a: true, expires: Math.floor(Date.now() / 1000) + 86400 }),
  };

  const shortList = (items, f = (x) => x) => (items.length > 3 ? `${items.slice(0, 3).map(f).join("، ")} +${items.length - 3}` : items.map(f).join("، "));
  function summary(r) {
    const c = [];
    if (r.countries.length) c.push(t(r.country_mode === "not_in" ? "df_r_country_not" : "df_r_country_is", { list: shortList(r.countries, ccName) }));
    if (r.ips.length) c.push(t(r.ip_mode === "not_in" ? "df_r_addr_not" : "df_r_addr_is", { list: shortList(r.ips) }));
    if (r.proto !== "any") c.push(t("df_r_proto_is", { p: r.proto === "icmp" ? t("df_r_ping") : r.proto.toUpperCase() }));
    if (r.ports) c.push(t("df_r_ports_is", { list: r.ports.replace(/,/g, "، ") }));
    let act = t(`df_r_a_${r.action}`);
    if (r.action === "limit") act = t("df_r_limit_sum", { rate: r.limit.rate }) + (r.limit.ban ? ` · ${t("df_r_ban_sum", { m: r.limit.ban })}` : "");
    let sum = `${r.direction === "out" ? `${t("df_r_out_sum")} ` : ""}${t("df_r_if")} ${c.join(` ${t("df_r_and")} `)} ${t("df_r_arrow")} ${act}`;
    if (r.schedule) sum += ` · ⏰ ${schedText(r.schedule)}`;
    return sum;
  }
  const dayName = (d) => { try { return new Intl.DateTimeFormat(P.state.lang === "fa" ? "fa" : "en", { weekday: "short" }).format(new Date(Date.UTC(2024, 0, 7 + d, 12))); } catch (e) { return String(d); } };
  const schedText = (sc) => t("df_r_sched_sum", { days: sc.days.length === 7 ? t("df_r_every_day") : sc.days.map(dayName).join("، "), from: sc.from, to: sc.to });
  const leftText = (ts) => { const s = ts - Date.now() / 1000; return s <= 0 ? t("df_r_expired") : t("df_r_exp_in", { left: s > 86400 ? `${nf(s / 86400, 1)}d` : s > 3600 ? `${nf(s / 3600, 1)}h` : `${Math.ceil(s / 60)}m` }); };
  const ACT_TONE = { allow: "ok", block: "bad", limit: "warn", log: "" };

  async function renderRules() {
    const r = await api("/api/defender/fwrules");
    D.rules = r.rules;
    D.ruleHits = r.hits || {};
    return rulesHTML();
  }
  function rulesHTML() {
    const tpl = Object.keys(TEMPLATES).map((k) => `<button type="button" class="btn small" data-a="r-tpl" data-tpl="${k}">${icon("plus")}<span>${esc(t(`df_r_tpl_${k}`))}</span></button>`).join("");
    const list = D.rules.length ? `<ol class="fw-rules">${D.rules.map((r, i) => {
      const hits = D.ruleHits[r.id];
      return `<li class="fw-rule${r.enabled ? "" : " off"}"><span class="fw-n">${num(i + 1)}</span>
        <div class="fw-main"><div class="fw-top"><b>${esc(r.name)}</b>${pill(ACT_TONE[r.action], t(`df_r_a_${r.action}`))}${r.direction === "out" ? `<span class="tag">↗ ${esc(t("df_r_out_badge"))}</span>` : ""}${r.expires ? `<span class="tag">⌛ ${esc(leftText(r.expires))}</span>` : ""}${r.enabled ? "" : pill("", t("df_r_disabled"), false)}</div>
          <p class="fw-sum">${esc(summary(r))}</p>
          <small class="muted">${hits && hits.packets ? esc(t("df_r_hits", { n: nf(hits.packets, 0) })) : esc(t("df_r_hits_none"))}</small></div>
        <div class="fw-act"><label class="switch" title="${esc(r.enabled ? t("df_f2b_on") : t("df_f2b_off"))}"><input type="checkbox" data-rule-toggle="${i}" ${r.enabled ? "checked" : ""} aria-label="${esc(r.name)}"><span></span></label>
          <div class="row-actions">${btnIcon("up", t("df_r_up"), `data-a="r-move" data-i="${i}" data-d="-1" ${i ? "" : "disabled"}`)}${btnIcon("down2", t("df_r_down"), `data-a="r-move" data-i="${i}" data-d="1" ${i < D.rules.length - 1 ? "" : "disabled"}`)}
          ${btnIcon("sliders", t("df_j_edit"), `data-a="r-edit" data-i="${i}"`)}${btnIcon("dup", t("df_r_dup"), `data-a="r-dup" data-i="${i}"`)}${btnIcon("trash", t("df_j_delete"), `data-a="r-del" data-i="${i}"`, "danger")}</div></div></li>`;
    }).join("")}</ol>` : `<div class="empty">${esc(t("df_r_empty"))}</div>`;
    return `<section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("rule")}${esc(t("df_r_title"))}</h3><p class="muted">${esc(t("df_r_sub"))}</p></div>
        <button type="button" class="btn primary" data-a="r-new">${icon("plus")}<span>${esc(t("df_r_new"))}</span></button></div>
        <div class="notice">${icon("shield")}<span>${esc(t("df_r_exempt"))}</span></div>
        ${D.st.enabled ? "" : `<div class="notice warn">${icon("bell")}<span>${esc(t("df_r_off"))}</span></div>`}
        <h4 class="df-h4">${esc(t("df_r_templates"))}</h4><div class="row-actions fw-tpls">${tpl}</div></section>
      <section class="sec">${list}</section>`;
  }
  const repaintRules = () => { const b = D.root.querySelector("#df-body"); if (b && D.tab === "rules") b.innerHTML = rulesHTML(); };

  async function saveRules(btn, rules) {
    const ok = await apply(btn, "config", { rules, _what: "rules" }, t("df_r_saved"));
    if (ok) { D.rules = rules; if (D.tab === "rules") showTab("rules"); }
    return ok;
  }

  function ruleEditor(rule, index) {
    const r = JSON.parse(JSON.stringify(rule));
    const isNew = index == null;
    let picked = new Set(r.countries);
    const cmode = r.countries.length || r._c ? r.country_mode : "any";
    const amode = r.ips.length || r._a ? r.ip_mode : "any";
    delete r._c;
    delete r._a;
    const sens = sensOf(r.limit);
    const actCard = (a) => `<label class="fw-actopt ${a}"><input type="radio" name="action" value="${a}" ${r.action === a ? "checked" : ""}><span><b>${esc(t(`df_r_a_${a}`))}</b><small>${esc(t(`df_r_a_${a}_d`))}</small></span></label>`;
    const sensBtns = ["low", "medium", "high", "vhigh", "custom"].map((k) => `<label class="fw-sens"><input type="radio" name="sens" value="${k}" ${sens === k ? "checked" : ""}><span>${esc(t(`df_r_s_${k}`))}${SENS[k] ? `<small>${SENS[k][0]}/s</small>` : ""}</span></label>`).join("");
    const dlg = openDialog({
      title: isNew ? t("df_r_new") : `${r.name} · ${t("df_j_edit")}`, submit: t("df_save"), wide: true,
      body: `${field(t("df_r_name"), `<input name="name" maxlength="80" value="${esc(r.name)}" required autocomplete="off">`)}
        ${field(t("df_r_dir"), `<select name="direction"><option value="in">${esc(t("df_r_dir_in"))}</option><option value="out" ${r.direction === "out" ? "selected" : ""}>${esc(t("df_r_dir_out"))}</option></select>`)}
        <h4 class="fw-h">${esc(t("df_r_when"))}</h4>
        <div class="fw-cond"><div class="field-row">${field(t("df_r_country"), `<select name="cmode"><option value="any">${esc(t("df_r_any_country"))}</option><option value="in" ${cmode === "in" ? "selected" : ""}>${esc(t("df_r_in"))}</option><option value="not_in" ${cmode === "not_in" ? "selected" : ""}>${esc(t("df_r_not_in"))}</option></select>`)}
          <div class="field fw-cc-count"><label>&nbsp;</label><span class="muted" data-cc-count></span></div></div>
          <div class="fw-cc" ${cmode === "any" ? "hidden" : ""}><div class="chips" data-cc-chips></div>
            <input type="search" class="df-filter" data-cc-q placeholder="${esc(t("df_r_search"))}" aria-label="${esc(t("df_r_search"))}"><div class="geo-grid fw-cc-list" data-cc-list></div></div></div>
        <div class="fw-cond">${field(t("df_r_addr"), `<select name="amode"><option value="any">${esc(t("df_r_any_addr"))}</option><option value="in" ${amode === "in" ? "selected" : ""}>${esc(t("df_r_in"))}</option><option value="not_in" ${amode === "not_in" ? "selected" : ""}>${esc(t("df_r_not_in"))}</option></select>`)}
          <div class="fw-ips" ${amode === "any" ? "hidden" : ""}>${field("", `<textarea name="ips" dir="ltr" rows="3" spellcheck="false" placeholder="203.0.113.7&#10;198.51.100.0/24">${esc(r.ips.join("\n"))}</textarea>`, t("df_r_ips_hint"))}</div></div>
        <div class="fw-cond field-row">${field(t("df_r_proto"), `<select name="proto">${[["any", t("df_r_any_proto")], ["tcp", "TCP"], ["udp", "UDP"], ["icmp", t("df_r_ping")]].map(([v, l]) => `<option value="${v}" ${r.proto === v ? "selected" : ""}>${esc(l)}</option>`).join("")}</select>`)}
          ${field(t("df_r_ports"), `<input name="ports" dir="ltr" value="${esc(r.ports)}" placeholder="22, 80,443, 8000-8100" autocomplete="off">`, t("df_r_ports_hint"))}</div>
        <div class="fw-cond"><div class="field-row">${field(t("df_r_when_active"), `<select name="smode"><option value="always">${esc(t("df_r_always"))}</option><option value="sched" ${r.schedule ? "selected" : ""}>${esc(t("df_r_sched"))}</option></select>`)}
          ${field(t("df_r_expires"), `<select name="expires"><option value="0">${esc(t("df_r_never"))}</option>${[[3600, "1 h"], [21600, "6 h"], [86400, "24 h"], [259200, "3 d"], [604800, "7 d"]].map(([v, l]) => `<option value="+${v}">${l}</option>`).join("")}${r.expires ? `<option value="${r.expires}" selected>${esc(leftText(r.expires))}</option>` : ""}</select>`)}</div>
          <div class="fw-sched" ${r.schedule ? "" : "hidden"}><label class="fw-lbl">${esc(t("df_r_days"))}</label><div class="fw-days">${[0, 1, 2, 3, 4, 5, 6].map((d) => `<label class="fw-sens"><input type="checkbox" name="day" value="${d}" ${!r.schedule || r.schedule.days.includes(d) ? "checked" : ""}><span>${esc(dayName(d))}</span></label>`).join("")}</div>
            <div class="field-row">${field(t("df_r_from"), `<input type="time" name="tfrom" value="${esc(r.schedule ? r.schedule.from : "09:00")}" dir="ltr">`)}${field(t("df_r_to"), `<input type="time" name="tto" value="${esc(r.schedule ? r.schedule.to : "17:00")}" dir="ltr">`)}</div>
            <p class="hint">${esc(t("df_r_tz", { now: new Date().toISOString().slice(11, 16) }))}</p></div></div>
        <h4 class="fw-h">${esc(t("df_r_then"))}</h4><div class="fw-actions">${["allow", "block", "limit", "log"].map(actCard).join("")}</div>
        <div class="fw-limit" ${r.action === "limit" ? "" : "hidden"}><label class="fw-lbl">${esc(t("df_r_sens"))}</label><div class="fw-sensrow">${sensBtns}</div>
          <div class="field-row fw-custom" ${sens === "custom" ? "" : "hidden"}>${field(t("df_r_per_s"), `<input type="number" name="rate" min="1" value="${r.limit.rate}" dir="ltr">`)}${field(t("df_r_burst"), `<input type="number" name="burst" min="1" value="${r.limit.burst}" dir="ltr">`)}</div>
          ${field(t("df_r_ban"), `<select name="ban">${[[0, t("df_r_ban_no")], [10, "10 min"], [60, "1 h"], [360, "6 h"], [1440, "1 d"], [10080, "1 w"]].map(([v, l]) => `<option value="${v}" ${+r.limit.ban === v ? "selected" : ""}>${esc(l)}</option>`).join("")}</select>`)}</div>
        <p class="fw-preview" data-preview></p>`,
      onSubmit: async () => {
        const out = collect();
        if (!out.countries.length && !out.ips.length && out.proto === "any" && !out.ports) throw new Error(t("df_r_need_cond"));
        if (dlg.querySelector('[name="cmode"]').value !== "any" && !out.countries.length) throw new Error(t("df_r_need_country"));
        if (dlg.querySelector('[name="amode"]').value !== "any" && !out.ips.length) throw new Error(t("df_r_need_ip"));
        if (out.schedule && (!out.schedule.days.length || out.schedule.from === out.schedule.to)) throw new Error(t("df_r_sched_bad"));
        const rules = [...D.rules];
        if (isNew) rules.push(out); else rules[index] = out;
        if (!(await saveRules(null, rules))) throw new Error("");   // the reason is already shown as a message
      },
    });
    const $q = (s) => dlg.querySelector(s);
    function collect() {
      const el = $q("form").elements;
      const cm = el.cmode.value, am = el.amode.value, sens = el.sens.value;
      const lim = sens === "custom" ? { rate: +el.rate.value || 1, burst: +el.burst.value || (+el.rate.value || 1) * 2 } : { rate: SENS[sens][0], burst: SENS[sens][1] };
      const dayVals = [...$q("form").querySelectorAll('input[name="day"]:checked')].map((x) => +x.value);
      const exp = el.expires.value.startsWith("+") ? Math.floor(Date.now() / 1000) + +el.expires.value.slice(1) : +el.expires.value;
      return {
        ...r, name: el.name.value.trim() || t("df_r_new"), direction: el.direction.value,
        schedule: el.smode.value === "sched" ? { days: dayVals, from: el.tfrom.value || "00:00", to: el.tto.value || "23:59" } : null, expires: exp,
        countries: cm === "any" ? [] : [...picked], country_mode: cm === "not_in" ? "not_in" : "in",
        ips: am === "any" ? [] : el.ips.value.split(/[\s,]+/).map((x) => x.trim()).filter(Boolean), ip_mode: am === "not_in" ? "not_in" : "in",
        proto: el.proto.value, ports: el.proto.value === "icmp" ? "" : el.ports.value.replace(/\s+/g, ""),
        action: el.action.value, limit: { ...lim, ban: +el.ban.value },
      };
    }
    function paintCountries() {
      const q = ($q("[data-cc-q]").value || "").trim().toLowerCase();
      $q("[data-cc-chips]").innerHTML = [...picked].map((cc) => `<span class="chip">${flag(cc)} <b>${esc(ccName(cc))}</b><button type="button" class="chip-x" data-cc-del="${cc}" aria-label="${esc(t("df_remove"))} ${esc(ccName(cc))}">${icon("x")}</button></span>`).join("");
      $q("[data-cc-count]").textContent = picked.size ? t("df_r_selected", { n: picked.size }) : "";
      $q("[data-cc-list]").innerHTML = COUNTRIES.map((cc) => [cc, ccName(cc)]).filter(([cc, n]) => !q || cc.includes(q) || n.toLowerCase().includes(q) || ccEnglish(cc).toLowerCase().includes(q))
        .sort((a, b) => a[1].localeCompare(b[1], P.state.lang))
        .map(([cc, n]) => `<label class="geo-item${picked.has(cc) ? " on" : ""}"><input type="checkbox" data-cc="${cc}" ${picked.has(cc) ? "checked" : ""}><span class="geo-flag">${flag(cc)}</span><span>${esc(n)}</span><code>${cc.toUpperCase()}</code></label>`).join("");
    }
    function sync() {
      const el = $q("form").elements;
      $q(".fw-cc").hidden = el.cmode.value === "any";
      $q(".fw-ips").hidden = el.amode.value === "any";
      el.ports.disabled = el.proto.value === "icmp";
      const out = el.direction.value === "out";
      $q(".fw-sched").hidden = el.smode.value !== "sched";
      dlg.querySelector('.fw-actopt.limit').hidden = out;
      if (out && el.action.value === "limit") dlg.querySelector('input[name="action"][value="block"]').checked = true;
      dlg.querySelectorAll(".fw-cond")[0].querySelector("label").textContent = t(out ? "df_r_to_country" : "df_r_country");
      dlg.querySelectorAll(".fw-cond")[1].querySelector("label").textContent = t(out ? "df_r_to_addr" : "df_r_addr");
      $q(".fw-limit").hidden = el.action.value !== "limit";
      $q(".fw-custom").hidden = el.sens.value !== "custom";
      const preview = collect();
      $q("[data-preview]").textContent = preview.countries.length || preview.ips.length || preview.proto !== "any" || preview.ports ? summary(preview) : "";
    }
    $q("form").addEventListener("change", (e) => {
      if (e.target.dataset.cc) { if (e.target.checked) picked.add(e.target.dataset.cc); else picked.delete(e.target.dataset.cc); paintCountries(); }
      sync();
    });
    $q("form").addEventListener("input", (e) => { if (e.target.matches("[data-cc-q]")) paintCountries(); else if (["ips", "ports", "rate", "tfrom", "tto"].includes(e.target.name)) sync(); });
    $q("form").addEventListener("click", (e) => { const x = e.target.closest("[data-cc-del]"); if (x) { e.preventDefault(); picked.delete(x.dataset.ccDel); paintCountries(); sync(); } });
    paintCountries();
    sync();
  }

  // ---------------------------------------------------------------- SSH server, address tester, threat lists
  P.addStrings({
    df_sv_title: "SSH server", df_sv_sub: "Port, login options and keys of the SSH server itself. Every change is tested: if SSH does not answer on every port, the old settings come back at once; otherwise you have {m} minutes to log in again and keep it, or it is undone by itself. Open sessions stay connected.",
    df_sv_ports: "SSH ports", df_sv_ports_hint: "During a move keep both ports: add the new one, keep the change after you logged in through it, then remove the old one.",
    df_sv_add_port: "Add port", df_sv_root: "Root login", df_sv_root_yes: "Allowed (password or key)", df_sv_root_key: "Only with a key", df_sv_root_no: "Not allowed",
    df_sv_password: "Password login", df_sv_password_sub: "Off: only SSH keys work. Much safer; add your key below first.", df_sv_tries: "Wrong passwords per connection", df_sv_grace: "Seconds to log in",
    df_sv_idle: "Disconnect idle sessions after", df_sv_idle_never: "Never", df_sv_x11: "X11 forwarding", df_sv_tcpfwd: "TCP forwarding (tunnels)", df_sv_save: "Apply to SSH",
    df_sv_confirm: "Apply these SSH settings? SSH restarts (this session stays open). Ports: {ports}. If your hosting provider has its own firewall (for example the Hetzner Cloud Firewall), allow the new port there too.",
    df_sv_pending: "Log in again now with the new settings, for example: {cmd}. If it works press Keep; otherwise they are undone in {left}.", df_sv_kept: "SSH settings kept", df_sv_undone: "SSH settings undone",
    df_sv_applied: "Applied. SSH answers on every port; now test a new login.", df_sv_socket: "systemd socket", df_sv_last_port: "SSH needs at least one port",
    df_sv_keys: "SSH keys of root", df_sv_keys_sub: "Public keys that may log in as root (/root/.ssh/authorized_keys).", df_sv_key_add: "Add key", df_sv_key_ph: "ssh-ed25519 AAAA… you@laptop",
    df_sv_key_hint: "Paste the content of your id_ed25519.pub (or id_rsa.pub). On your computer: ssh-keygen -t ed25519 creates one.", df_sv_key_del: "Remove key {name}?", df_sv_no_keys: "No key yet: only passwords work.",
    df_sv_type: "Type", df_sv_comment: "Name", df_sv_fp: "Fingerprint",
    df_tt_title: "Check an address", df_tt_sub: "What happens to a connection from this address, step by step through every layer of the firewall.",
    df_tt_ip: "Address", df_tt_port: "Port (optional)", df_tt_check: "Check", df_tt_country: "Country: {c}", df_tt_country_unknown: "Country: unknown (no list downloaded for it)",
    df_tt_allow: "Allowed", df_tt_block: "Blocked", df_tt_limit: "Limited",
    df_tt_off: "Protection is off: everything is allowed.", df_tt_admin: "Trusted: it logged in over SSH.", df_tt_allowlist: "On the allowlist ({entry}).", df_tt_blocklist: "On the blocklist ({entry}).",
    df_tt_banned: "Banned by the firewall, {left} left.", df_tt_fail2ban: "Banned by fail2ban ({jail}).", df_tt_panel_allow: "Only the listed addresses may open the panel.", df_tt_cdn: "A Cloudflare address (trusted).",
    df_tt_threat: "Listed in: {feeds}.", df_tt_rule_allow: "Rule \"{name}\": allow.", df_tt_rule_block: "Rule \"{name}\": block.", df_tt_rule_limit: "Rule \"{name}\": limited to {rate}/s.", df_tt_rule_count: "Rule \"{name}\": counted.",
    df_tt_strict: "Strict mode: port {port} is not open.", df_tt_limits: "Allowed, within the flood limits ({syn} SYN/s, {conc} connections).", df_tt_sched: " (only at its scheduled times)",
  }, {
    df_sv_title: "سرور SSH", df_sv_sub: "پورت، گزینه‌های ورود و کلیدهای خود سرور SSH. هر تغییر آزمایش می‌شود: اگر SSH روی همه‌ی پورت‌ها جواب ندهد، تنظیمات قبلی فوراً برمی‌گردد؛ وگرنه {m} دقیقه وقت دارید دوباره وارد شوید و آن را نگه دارید، وگرنه خودش برمی‌گردد. نشست‌های باز وصل می‌مانند.",
    df_sv_ports: "پورت‌های SSH", df_sv_ports_hint: "هنگام جابه‌جایی هر دو پورت را نگه دارید: پورت جدید را اضافه کنید، بعد از ورود موفق با آن تغییر را نگه دارید، و بعد پورت قدیمی را حذف کنید.",
    df_sv_add_port: "افزودن پورت", df_sv_root: "ورود root", df_sv_root_yes: "مجاز (با رمز یا کلید)", df_sv_root_key: "فقط با کلید", df_sv_root_no: "ممنوع",
    df_sv_password: "ورود با رمز", df_sv_password_sub: "خاموش: فقط کلید SSH کار می‌کند. خیلی امن‌تر؛ اول کلیدتان را پایین اضافه کنید.", df_sv_tries: "رمز اشتباه در هر اتصال", df_sv_grace: "ثانیه برای ورود",
    df_sv_idle: "قطع نشست بی‌کار بعد از", df_sv_idle_never: "هرگز", df_sv_x11: "X11 forwarding", df_sv_tcpfwd: "TCP forwarding (تانل)", df_sv_save: "اعمال روی SSH",
    df_sv_confirm: "این تنظیمات روی SSH اعمال شود؟ SSH ری‌استارت می‌شود (این نشست باز می‌ماند). پورت‌ها: {ports}. اگر هاستینگ شما فایروال جدا دارد (مثل Hetzner Cloud Firewall)، پورت جدید را آن‌جا هم باز کنید.",
    df_sv_pending: "همین حالا با تنظیمات جدید دوباره وارد شوید، مثلاً: {cmd}. اگر کار کرد «نگه دار» را بزنید؛ وگرنه {left} دیگر خودش برمی‌گردد.", df_sv_kept: "تنظیمات SSH ماند", df_sv_undone: "تنظیمات SSH برگشت",
    df_sv_applied: "اعمال شد. SSH روی همه‌ی پورت‌ها جواب می‌دهد؛ حالا یک ورود جدید را امتحان کنید.", df_sv_socket: "systemd socket", df_sv_last_port: "SSH حداقل یک پورت لازم دارد",
    df_sv_keys: "کلیدهای SSH کاربر root", df_sv_keys_sub: "کلیدهای عمومی که می‌توانند با root وارد شوند (/root/.ssh/authorized_keys).", df_sv_key_add: "افزودن کلید", df_sv_key_ph: "ssh-ed25519 AAAA… you@laptop",
    df_sv_key_hint: "محتوای فایل id_ed25519.pub (یا id_rsa.pub) را بچسبانید. روی کامپیوترتان ssh-keygen -t ed25519 یکی می‌سازد.", df_sv_key_del: "کلید {name} حذف شود؟", df_sv_no_keys: "هنوز کلیدی نیست: فقط رمز کار می‌کند.",
    df_sv_type: "نوع", df_sv_comment: "نام", df_sv_fp: "اثر انگشت",
    df_tt_title: "بررسی یک آدرس", df_tt_sub: "با اتصالی از این آدرس چه می‌شود، قدم‌به‌قدم در همه‌ی لایه‌های فایروال.",
    df_tt_ip: "آدرس", df_tt_port: "پورت (اختیاری)", df_tt_check: "بررسی", df_tt_country: "کشور: {c}", df_tt_country_unknown: "کشور: نامعلوم (لیستی برایش دانلود نشده)",
    df_tt_allow: "مجاز", df_tt_block: "مسدود", df_tt_limit: "محدود",
    df_tt_off: "محافظت خاموش است: همه چیز مجاز است.", df_tt_admin: "مورد اعتماد: با SSH وارد شده.", df_tt_allowlist: "در لیست سفید ({entry}).", df_tt_blocklist: "در لیست سیاه ({entry}).",
    df_tt_banned: "توسط فایروال مسدود است، {left} مانده.", df_tt_fail2ban: "توسط fail2ban مسدود است ({jail}).", df_tt_panel_allow: "فقط آدرس‌های مشخص اجازه‌ی باز کردن پنل دارند.", df_tt_cdn: "آدرس Cloudflare (مورد اعتماد).",
    df_tt_threat: "در این لیست‌ها: {feeds}.", df_tt_rule_allow: "قانون «{name}»: اجازه.", df_tt_rule_block: "قانون «{name}»: مسدود.", df_tt_rule_limit: "قانون «{name}»: محدود به {rate} در ثانیه.", df_tt_rule_count: "قانون «{name}»: شمرده می‌شود.",
    df_tt_strict: "حالت سخت‌گیر: پورت {port} باز نیست.", df_tt_limits: "مجاز، در حد محدودیت‌های فلاد ({syn} SYN در ثانیه، {conc} اتصال).", df_tt_sched: " (فقط در زمان‌بندی‌اش)",
  });

  // ---- SSH server
  const portsChips = (ports, removable) => ports.map((p, i) => `<span class="chip">${icon("terminal")}<b>${num(p)}</b>${removable && ports.length > 1 ? `<button type="button" class="chip-x" data-a="sv-port-del" data-i="${i}" aria-label="${esc(t("df_remove"))} ${p}">${icon("x")}</button>` : ""}</span>`).join("");
  const fmtLeft = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  async function renderSshAll() {
    const sv = await api("/api/defender/sshd").catch((e) => ({ error: e.message }));
    D.sv = sv;
    if (!sv.error && !D.svDraft) D.svDraft = { ports: [...sv.ports], permit_root: sv.permit_root, password: sv.password, max_auth_tries: sv.max_auth_tries, login_grace: sv.login_grace, idle_timeout: sv.idle_timeout, x11: sv.x11, tcp_forwarding: sv.tcp_forwarding };
    return `<div id="df-sv">${svHTML()}</div>` + (await renderSsh());
  }
  function svHTML() {
    const sv = D.sv;
    if (sv.error) return `<div class="notice bad">${icon("alert")}<span>${esc(sv.error)}</span></div>`;
    const d = D.svDraft, ip = ((P.state.overview && P.state.overview.public_ip && P.state.overview.public_ip.v4) || location.hostname);
    const pend = sv.pending ? `<div class="notice warn df-pend">${icon("clock")}<span>${esc(t("df_sv_pending", { cmd: `ssh -p ${sv.pending.ports[sv.pending.ports.length - 1]} root@${ip}`, left: fmtLeft(sv.pending.left) }))}</span>
      <button type="button" class="btn small primary" data-a="sv-keep">${esc(t("df_keep"))}</button><button type="button" class="btn small" data-a="sv-undo">${esc(t("df_undo"))}</button></div>` : "";
    const sel = (name, opts) => `<select name="${name}">${opts.map(([v, l]) => `<option value="${v}" ${String(d[name]) === String(v) ? "selected" : ""}>${esc(l)}</option>`).join("")}</select>`;
    const keys = sv.keys.length ? table([
      { h: "df_sv_type", cell: (k) => `<code dir="ltr">${esc(k.type)}</code>` },
      { h: "df_sv_comment", cls: "strong", cell: (k) => esc(k.comment || "—") },
      { h: "df_sv_fp", cls: "wrap-cell", cell: (k) => `<code dir="ltr" class="muted">${esc(k.fingerprint)}</code>` },
      { h: "actions", cell: (k) => btnIcon("trash", `${t("df_remove")} ${k.comment}`, `data-a="sv-key-del" data-i="${k.index}" data-name="${esc(k.comment || k.type)}"`, "danger") },
    ], sv.keys) : `<div class="empty">${esc(t("df_sv_no_keys"))}</div>`;
    return `${pend}<section class="sec"><div class="sec-head"><h3>${icon("terminal")}${esc(t("df_sv_title"))}${sv.socket ? `<span class="tag">${esc(t("df_sv_socket"))}</span>` : ""}</h3><p class="muted">${esc(t("df_sv_sub", { m: Math.round(D.sv.confirm_seconds / 60) }))}</p></div>
      <form class="subcard" data-f="sv">
        <div class="field"><label>${esc(t("df_sv_ports"))}</label><div class="chips">${portsChips(d.ports, true)}</div>
          <div class="inline-field df-inline"><input name="newport" type="number" min="1" max="65535" dir="ltr" placeholder="2222" aria-label="${esc(t("df_sv_add_port"))}"><button type="button" class="btn small" data-a="sv-port-add">${icon("plus")}<span>${esc(t("df_sv_add_port"))}</span></button></div>
          <p class="hint">${esc(t("df_sv_ports_hint"))}</p></div>
        <div class="df-form-grid">
          ${field(t("df_sv_root"), sel("permit_root", [["yes", t("df_sv_root_yes")], ["prohibit-password", t("df_sv_root_key")], ["no", t("df_sv_root_no")]]))}
          ${field(t("df_sv_tries"), `<input type="number" name="max_auth_tries" min="1" max="50" value="${esc(d.max_auth_tries)}" dir="ltr">`)}
          ${field(t("df_sv_grace"), `<input type="number" name="login_grace" min="5" max="600" value="${esc(d.login_grace)}" dir="ltr">`)}
          ${field(t("df_sv_idle"), sel("idle_timeout", [[0, t("df_sv_idle_never")], [300, "5 min"], [900, "15 min"], [1800, "30 min"], [3600, "1 h"]].concat([[0, 300, 900, 1800, 3600].includes(+d.idle_timeout) ? [] : [[d.idle_timeout, `${d.idle_timeout} s`]]])))}
          ${field(t("df_sv_tcpfwd"), sel("tcp_forwarding", [["yes", t("df_j_on")], ["no", t("df_j_off")], ["local", "local"], ["remote", "remote"]]))}
          ${field(t("df_sv_x11"), sel("x11", [["yes", t("df_j_on")], ["no", t("df_j_off")]]))}</div>
        <label class="df-switch"><span class="switch"><input type="checkbox" name="password" ${d.password === "yes" ? "checked" : ""}><span></span></span><span><b>${esc(t("df_sv_password"))}</b><small>${esc(t("df_sv_password_sub"))}</small></span></label>
        <div class="actions-row"><button type="submit" class="btn primary" ${sv.pending ? "disabled" : ""}>${icon("check")}<span>${esc(t("df_sv_save"))}</span></button></div></form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("key")}${esc(t("df_sv_keys"))}</h3><p class="muted">${esc(t("df_sv_keys_sub"))}</p></div>${keys}
        <form class="subcard" data-f="sv-key" style="margin-top:12px">${field(t("df_sv_key_add"), `<textarea name="key" dir="ltr" rows="3" spellcheck="false" placeholder="${esc(t("df_sv_key_ph"))}" required></textarea>`, t("df_sv_key_hint"))}
          <div class="actions-row"><button type="submit" class="btn">${icon("plus")}<span>${esc(t("df_sv_key_add"))}</span></button></div></form></section>`;
  }
  const repaintSv = () => { const box = D.root.querySelector("#df-sv"); if (box) box.innerHTML = svHTML(); };
  function svFormToDraft() {
    const f = D.root.querySelector('form[data-f="sv"]');
    if (!f) return;
    const el = f.elements;
    Object.assign(D.svDraft, { permit_root: el.permit_root.value, max_auth_tries: +el.max_auth_tries.value, login_grace: +el.login_grace.value,
      idle_timeout: +el.idle_timeout.value, tcp_forwarding: el.tcp_forwarding.value, x11: el.x11.value, password: el.password.checked ? "yes" : "no" });
  }

  // ---- address tester + threat lists (IP lists tab)
  function testerHTML() {
    return `<section class="sec"><div class="sec-head"><h3>${icon("search")}${esc(t("df_tt_title"))}</h3><p class="muted">${esc(t("df_tt_sub"))}</p></div>
      <form class="subcard" data-f="tt"><div class="df-form-grid">${field(t("df_tt_ip"), '<input name="ip" dir="ltr" required placeholder="203.0.113.7" autocomplete="off">')}
        ${field(t("df_tt_port"), '<input name="port" type="number" min="0" max="65535" dir="ltr" placeholder="443">')}
        ${field(t("df_r_proto"), '<select name="proto"><option value="tcp">TCP</option><option value="udp">UDP</option><option value="icmp">ICMP</option></select>')}</div>
        <div class="actions-row"><button type="submit" class="btn primary">${icon("search")}<span>${esc(t("df_tt_check"))}</span></button></div><div id="df-tt-out"></div></form></section>`;
  }
  function testResult(r) {
    const tone = { allow: "ok", block: "bad", limit: "warn", count: "" };
    const text = (s) => {
      if (s.kind === "rule") return t(`df_tt_rule_${s.result}`, { name: s.name, rate: s.limit ? s.limit.rate : "" }) + (s.schedule ? t("df_tt_sched") : "");
      if (s.kind === "banned") return t("df_tt_banned", { left: s.left ? fmtLeft(s.left) : "–" });
      if (s.kind === "fail2ban") return t("df_tt_fail2ban", { jail: s.jail || "fail2ban" });
      if (s.kind === "threat") return t("df_tt_threat", { feeds: s.feeds.join("، ") });
      if (s.kind === "threat_log") return t("df_tt_threat_log", { feeds: s.feeds.join("، ") });
      if (s.kind === "limits") return t("df_tt_limits", { syn: s.limits.syn, conc: s.limits.conc });
      return t(`df_tt_${s.kind}`, s);
    };
    return `<div class="tt-verdict ${tone[r.verdict] || ""}">${pill(tone[r.verdict] || "", t(`df_tt_${r.verdict === "count" ? "allow" : r.verdict}`))}
      <span dir="ltr"><b>${esc(r.ip)}</b>${r.port ? `:${r.port}/${r.proto}` : ""}</span><span class="muted">${esc(r.country ? t("df_tt_country", { c: `${flag(r.country)} ${ccName(r.country)}` }) : t("df_tt_country_unknown"))}</span></div>
      <ol class="tt-steps">${r.steps.map((s) => `<li class="${tone[s.result] || ""}">${pill(tone[s.result] || "", t(`df_tt_${s.result === "count" ? "allow" : s.result}`), false)}<span>${esc(text(s))}</span></li>`).join("")}</ol>`;
  }
  // ---------------------------------------------------------------- threat lists (own tab)
  P.addIcons({ radar: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4.5"/><path d="M12 12 18.4 5.6"/>' });
  P.addStrings({
    df_t_threat: "Threat lists",
    df_th_title: "Threat lists", df_th_sub: "Public lists of attacking, hijacked and botnet addresses. Everything a listed address starts is dropped before any other check; replies to connections this server opens itself still pass. Private networks are always left out.",
    df_th_on: "Lists on", df_th_blocked_n: "Packets blocked", df_th_since: "since the rules were applied", df_th_kernel: "Entries in the firewall", df_th_cover: "IPv4 addresses covered",
    df_th_out_n: "Outgoing blocked", df_th_next: "Next check", df_th_now: "updating…",
    df_th_recommended: "Turn on the recommended lists", df_th_update_all: "Update all now", df_th_updated_n: "{n} list(s) had new content", df_th_up_to_date: "All lists are up to date",
    df_th_settings: "Settings", df_th_outbound: "Also block this server connecting to them", df_th_outbound_sub: "Stops malware or a hacked app on this server (or a VPN client) from reaching botnet servers. Only lists in block mode.",
    df_th_refresh: "Refresh every", df_th_hours: "{n} h", df_th_save: "Save",
    df_th_mode_block: "Block", df_th_mode_log: "Watch only", df_th_mode_hint: "Watch only counts what the list would block, without blocking: try a list this way first.",
    df_th_rec: "Recommended", df_th_risky: "may hit real users", df_th_entries: "{n} entries", df_th_v6: "{n} IPv6", df_th_addrs: "{n} IPv4 addresses",
    df_th_never: "not downloaded yet", df_th_hits: "{n} packets", df_th_err: "Last update failed: {e}", df_th_update: "Update now", df_th_remove: "Remove",
    df_th_k_hijacked: "Hijacked networks", df_th_k_mixed: "Mixed", df_th_k_botnet: "Botnet servers", df_th_k_compromised: "Compromised hosts", df_th_k_attackers: "Attackers",
    df_th_k_anonymizer: "Anonymizer", df_th_k_custom: "Your list",
    df_th_spamhaus: "Networks stolen by spammers and criminals. Practically never blocks a real user.", df_th_firehol: "A careful mix of the worst lists (attacks, malware, hijacked and unused networks).",
    df_th_feodo: "Command servers of banking trojans and botnets (abuse.ch). Best together with blocking outgoing connections.", df_th_et: "Compromised hosts tracked by Emerging Threats.",
    df_th_cins: "Addresses with a bad reputation from the CINS Army sensors.", df_th_blocklistde: "Addresses that attacked servers in the last 48 hours (SSH, mail, web). Large; shared home addresses can be in it.",
    df_th_ipsum: "Addresses reported by at least 3 different blocklists in the last day.", df_th_greensnow: "Addresses caught scanning and brute-forcing by the GreenSnow sensors.",
    df_th_tor: "Exit nodes of the Tor network. Not attackers as such: turn on only if you don't want anonymous visitors.", df_th_custom: "Your own list from {site}.",
    df_th_add: "Add your own list", df_th_add_sub: "Any https address of a plain list (one address, network or range per line; # and ; start comments). It starts in watch-only mode.",
    df_th_name: "Name", df_th_url: "List address (https)", df_th_add_btn: "Add list", df_th_added: "List added", df_th_removed: "List removed", df_th_remove_confirm: "Remove the list \"{name}\"?",
    df_th_recent: "Recently matched addresses", df_th_recent_sub: "Addresses that hit a list in the last hour. If a real user is among them, allow the address: the allowlist always wins.",
    df_th_none_recent: "No address hit the lists in the last hour.", df_th_r_ip: "Address", df_th_r_kind: "Result", df_th_r_lists: "Lists", df_th_r_when: "When",
    df_th_r_block: "blocked", df_th_r_log: "watched", df_th_allow: "Allow", df_th_allowed: "{ip} is now allowed",
    df_tt_threat_log: "In a watch-only list (not blocked): {feeds}.",
  }, {
    df_t_threat: "لیست‌های تهدید",
    df_th_title: "لیست‌های تهدید", df_th_sub: "لیست‌های عمومی آدرس‌های مهاجم، ربوده‌شده و بات‌نت. هر چیزی که یک آدرس لیست‌شده شروع کند قبل از هر بررسی دیگری دور ریخته می‌شود؛ جواب اتصال‌هایی که خود این سرور باز می‌کند رد می‌شود. شبکه‌های خصوصی همیشه کنار گذاشته می‌شوند.",
    df_th_on: "لیست‌های روشن", df_th_blocked_n: "بسته‌های مسدودشده", df_th_since: "از وقتی قوانین اعمال شده", df_th_kernel: "ردیف‌ها در فایروال", df_th_cover: "آدرس IPv4 پوشش داده‌شده",
    df_th_out_n: "خروجی مسدودشده", df_th_next: "بررسی بعدی", df_th_now: "در حال بروزرسانی…",
    df_th_recommended: "روشن کردن لیست‌های پیشنهادی", df_th_update_all: "بروزرسانی همه همین حالا", df_th_updated_n: "{n} لیست محتوای جدید داشت", df_th_up_to_date: "همه‌ی لیست‌ها بروز هستند",
    df_th_settings: "تنظیمات", df_th_outbound: "اتصال این سرور به آن‌ها هم مسدود شود", df_th_outbound_sub: "جلوی رسیدن بدافزار یا برنامه‌ی هک‌شده روی این سرور (یا کاربر VPN) به سرورهای بات‌نت را می‌گیرد. فقط لیست‌های حالت مسدود.",
    df_th_refresh: "بروزرسانی هر", df_th_hours: "{n} ساعت", df_th_save: "ذخیره",
    df_th_mode_block: "مسدود", df_th_mode_log: "فقط نظارت", df_th_mode_hint: "«فقط نظارت» چیزی را مسدود نمی‌کند، فقط می‌شمارد که لیست چه چیزهایی را مسدود می‌کرد: اول یک لیست را این‌طور امتحان کنید.",
    df_th_rec: "پیشنهادی", df_th_risky: "ممکن است کاربر واقعی را بگیرد", df_th_entries: "{n} ردیف", df_th_v6: "{n} IPv6", df_th_addrs: "{n} آدرس IPv4",
    df_th_never: "هنوز دانلود نشده", df_th_hits: "{n} بسته", df_th_err: "آخرین بروزرسانی ناموفق بود: {e}", df_th_update: "بروزرسانی", df_th_remove: "حذف",
    df_th_k_hijacked: "شبکه‌های ربوده‌شده", df_th_k_mixed: "ترکیبی", df_th_k_botnet: "سرورهای بات‌نت", df_th_k_compromised: "میزبان‌های آلوده", df_th_k_attackers: "مهاجم‌ها",
    df_th_k_anonymizer: "ناشناس‌ساز", df_th_k_custom: "لیست شما",
    df_th_spamhaus: "شبکه‌هایی که اسپمرها و مجرمان دزدیده‌اند. تقریباً هیچ‌وقت کاربر واقعی را نمی‌گیرد.", df_th_firehol: "ترکیب دقیق بدترین لیست‌ها (حمله، بدافزار، شبکه‌های ربوده‌شده و استفاده‌نشده).",
    df_th_feodo: "سرورهای فرمان تروجان‌های بانکی و بات‌نت‌ها (abuse.ch). بهترین حالت همراه با مسدود کردن اتصال خروجی است.", df_th_et: "میزبان‌های آلوده‌ای که Emerging Threats رصد می‌کند.",
    df_th_cins: "آدرس‌های بدنام از حسگرهای CINS Army.", df_th_blocklistde: "آدرس‌هایی که در ۴۸ ساعت اخیر به سرورها حمله کرده‌اند (SSH، ایمیل، وب). بزرگ است و ممکن است آدرس‌های مشترک خانگی در آن باشد.",
    df_th_ipsum: "آدرس‌هایی که در روز گذشته دست‌کم در ۳ لیست سیاه مختلف گزارش شده‌اند.", df_th_greensnow: "آدرس‌هایی که حسگرهای GreenSnow حین اسکن و حدس رمز گرفته‌اند.",
    df_th_tor: "نودهای خروجی شبکه‌ی Tor. خودشان مهاجم نیستند: فقط اگر بازدیدکننده‌ی ناشناس نمی‌خواهید روشن کنید.", df_th_custom: "لیست خودتان از {site}.",
    df_th_add: "افزودن لیست خودتان", df_th_add_sub: "هر آدرس https یک لیست ساده (در هر خط یک آدرس، شبکه یا بازه؛ # و ; شروع توضیح). اول در حالت «فقط نظارت» شروع می‌شود.",
    df_th_name: "نام", df_th_url: "آدرس لیست (https)", df_th_add_btn: "افزودن لیست", df_th_added: "لیست اضافه شد", df_th_removed: "لیست حذف شد", df_th_remove_confirm: "لیست «{name}» حذف شود؟",
    df_th_recent: "آدرس‌هایی که اخیراً منطبق شدند", df_th_recent_sub: "آدرس‌هایی که در یک ساعت اخیر به یکی از لیست‌ها خورده‌اند. اگر کاربر واقعی بین‌شان است، آن آدرس را مجاز کنید: لیست سفید همیشه مقدم است.",
    df_th_none_recent: "در یک ساعت اخیر هیچ آدرسی به لیست‌ها نخورده است.", df_th_r_ip: "آدرس", df_th_r_kind: "نتیجه", df_th_r_lists: "لیست‌ها", df_th_r_when: "زمان",
    df_th_r_block: "مسدود شد", df_th_r_log: "نظارت شد", df_th_allow: "مجاز کن", df_th_allowed: "{ip} حالا مجاز است",
    df_tt_threat_log: "در لیستی با حالت «فقط نظارت» (مسدود نمی‌شود): {feeds}.",
  });

  function threatCard(id, f) {
    const on = f.enabled;
    const desc = f.custom ? t("df_th_custom", { site: f.site }) : t(`df_th_${id}`);
    const stats = f.updated
      ? [t("df_th_entries", { n: nf(f.v4 + f.v6, 0) }), f.addresses ? t("df_th_addrs", { n: nf(f.addresses, 0) }) : "", f.v6 ? t("df_th_v6", { n: nf(f.v6, 0) }) : "", ago(f.updated)].filter(Boolean).join(" · ")
      : t("df_th_never");
    const mode = on ? `<div class="df-seg th-mode" role="group" aria-label="${esc(t("df_th_mode_hint"))}">${["block", "log"].map((m) =>
      `<button type="button" class="${f.mode === m ? "on" : ""}" aria-pressed="${f.mode === m}" data-a="th-mode" data-id="${esc(id)}" data-mode="${m}">${esc(t(`df_th_mode_${m}`))}</button>`).join("")}</div>` : "";
    return `<article class="th-feed${on ? " on" : ""}${on && f.mode === "log" ? " watch" : ""}">
      <label class="th-top"><span class="switch"><input type="checkbox" data-feed="${esc(id)}" ${on ? "checked" : ""}><span></span></span>
        <span class="th-body"><b>${esc(f.name)}</b><span class="th-tags">${pill("", t(`df_th_k_${f.kind}`), false)}${f.safe ? pill("ok", t("df_th_rec"), false) : `<small class="muted">${esc(t("df_th_risky"))}</small>`}</span></span></label>
      <small class="th-desc">${esc(desc)}</small>
      <small class="muted">${esc(stats)} · <span dir="ltr">${esc(f.site)}</span></small>
      ${f.error ? `<small class="th-err">${icon("alert")}<span>${esc(t("df_th_err", { e: f.error }))}</span></small>` : ""}
      <div class="th-foot">${mode}${on && f.hits ? `<span class="pill ${f.mode === "log" ? "warn" : "bad"}">${esc(t("df_th_hits", { n: nf(f.hits, 0) }))}</span>` : ""}
        <span class="th-btns">${on ? btnIcon("refresh", t("df_th_update"), `data-a="th-refresh" data-id="${esc(id)}"`) : ""}${f.custom ? btnIcon("trash", t("df_th_remove"), `data-a="th-del" data-id="${esc(id)}" data-name="${esc(f.name)}"`, "danger") : ""}</span></div>
    </article>`;
  }

  async function renderThreat() {
    const th = await api("/api/defender/threat");
    D.th = th;
    const ids = th.order.filter((id) => th.feeds[id]);
    const on = ids.filter((id) => th.feeds[id].enabled);
    const stat = (label, value, sub = "") => `<div class="th-stat"><span class="muted">${esc(label)}</span><b>${esc(value)}</b>${sub ? `<small class="muted">${esc(sub)}</small>` : ""}</div>`;
    const next = th.refreshing ? t("df_th_now") : th.next_check ? new Date(th.next_check * 1000).toLocaleTimeString(P.state.lang === "fa" ? "fa-IR" : "en-GB", { hour: "2-digit", minute: "2-digit" }) : "–";
    const stats = `<div class="th-stats">${stat(t("df_th_on"), `${nf(on.length, 0)} / ${nf(ids.length, 0)}`)}${stat(t("df_th_blocked_n"), th.blocked == null ? "–" : nf(th.blocked, 0), t("df_th_since"))}
      ${stat(t("df_th_kernel"), nf(th.entries, 0))}${stat(t("df_th_cover"), nf(th.addresses, 0))}${th.outbound ? stat(t("df_th_out_n"), th.blocked_out == null ? "–" : nf(th.blocked_out, 0)) : ""}${on.length ? stat(t("df_th_next"), next) : ""}</div>`;
    const recSafe = ids.filter((id) => th.feeds[id].safe && !th.feeds[id].enabled);
    const tools = `<div class="actions-row">${recSafe.length ? `<button type="button" class="btn primary" data-a="th-recommended">${icon("shield")}<span>${esc(t("df_th_recommended"))}</span></button>` : ""}
      ${on.length ? `<button type="button" class="btn" data-a="th-refresh">${icon("refresh")}<span>${esc(t("df_th_update_all"))}</span></button>` : ""}</div>`;
    const hours = [3, 6, 12, 24, 48].includes(th.refresh_hours) ? [3, 6, 12, 24, 48] : [3, 6, 12, 24, 48, th.refresh_hours].sort((a, b) => a - b);
    const settings = `<form class="subcard th-set" data-f="th-set"><h4>${icon("sliders")}${esc(t("df_th_settings"))}</h4>
      <label class="df-switch"><span class="switch"><input type="checkbox" name="outbound" ${th.outbound ? "checked" : ""}><span></span></span><span><b>${esc(t("df_th_outbound"))}</b><small>${esc(t("df_th_outbound_sub"))}</small></span></label>
      <div class="field-row">${field(t("df_th_refresh"), `<select name="hours">${hours.map((h) => `<option value="${h}" ${h === th.refresh_hours ? "selected" : ""}>${esc(t("df_th_hours", { n: nf(h, 0) }))}</option>`).join("")}</select>`)}
        <div class="field"><label>&nbsp;</label><button type="submit" class="btn">${icon("check")}<span>${esc(t("df_th_save"))}</span></button></div></div>
      <p class="hint">${esc(t("df_th_mode_hint"))}</p></form>`;
    const customN = ids.filter((id) => th.feeds[id].custom).length;
    const add = customN < th.custom_max ? `<form class="subcard" data-f="th-add"><h4>${icon("plus")}${esc(t("df_th_add"))}</h4><p class="muted">${esc(t("df_th_add_sub"))}</p>
      <div class="df-form-grid">${field(t("df_th_name"), '<input name="name" maxlength="60" required autocomplete="off">')}${field(t("df_th_url"), '<input name="url" type="url" dir="ltr" required placeholder="https://example.com/blocklist.txt" autocomplete="off">')}</div>
      <div class="actions-row"><button type="submit" class="btn primary">${icon("plus")}<span>${esc(t("df_th_add_btn"))}</span></button></div></form>` : "";
    const names = Object.fromEntries(ids.map((id) => [id, th.feeds[id].name]));
    const recent = th.recent.length ? table([
      { h: "df_th_r_ip", cell: (r) => `<code dir="ltr">${esc(r.ip)}</code>` },
      { h: "df_th_r_kind", cell: (r) => pill(r.kind === "block" ? "bad" : "warn", t(`df_th_r_${r.kind}`)) },
      { h: "df_th_r_lists", cell: (r) => esc(r.lists.map((x) => names[x] || x).join("، ") || "–") },
      { h: "df_th_r_when", cell: (r) => esc(ago(Date.now() / 1000 - r.ago)) },
      { h: "actions", cell: (r) => `<button type="button" class="btn small" data-a="th-allow" data-ip="${esc(r.ip)}">${icon("check")}<span>${esc(t("df_th_allow"))}</span></button>` },
    ], th.recent) : `<div class="empty">${esc(t("df_th_none_recent"))}</div>`;
    return `<section class="sec"><div class="sec-head"><h3>${icon("radar")}${esc(t("df_th_title"))}</h3><p class="muted">${esc(t("df_th_sub"))}</p></div>
        ${th.protection ? "" : `<div class="notice warn">${icon("bell")}<span>${esc(t("df_r_off"))}</span></div>`}
        ${stats}${tools}</section>
      <section class="sec"><div class="th-grid">${ids.map((id) => threatCard(id, th.feeds[id])).join("")}</div></section>
      <section class="sec"><div class="th-two">${settings}${add}</div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("eye")}${esc(t("df_th_recent"))}</h3><p class="muted">${esc(t("df_th_recent_sub"))}</p></div>${recent}</section>`;
  }

  async function threatSave(el, patch, what) {
    const ok = await apply(el, "config", { threat: patch, _what: what }, t("df_r_saved"));
    if (D.tab === "threat") showTab("threat");
    return ok;
  }

  async function renderListsAll() {
    return testerHTML() + await renderLists();
  }

  const RENDER = { advanced: renderAdvanced, overview: renderOverview, firewall: renderFirewall, ddos: renderDdos, rules: renderRules, lists: renderListsAll, threat: renderThreat, ssh: renderSshAll, f2b: renderF2b, hardening: renderHardening };
  const rerender = () => showTab(D.tab);

  // ---------------------------------------------------------------- events
  async function onClick(e) {
    const b = e.target.closest("[data-a]");
    if (!b || b.disabled) return;
    const a = b.dataset.a;
    if (a === "tab") return showTab(b.dataset.tab);
    if (a === "th-mode") {
      if (b.classList.contains("on")) return;
      return threatSave(b, { mode: { ...D.th.feeds && Object.fromEntries(Object.entries(D.th.feeds).map(([id, f]) => [id, f.mode])), [b.dataset.id]: b.dataset.mode } }, "threat list mode");
    }
    if (a === "th-recommended") {
      const feeds = [...new Set([...D.th.enabled, ...D.th.order.filter((id) => D.th.feeds[id] && D.th.feeds[id].safe)])];
      return threatSave(b, { feeds }, "threat lists");
    }
    if (a === "th-refresh") {
      const r = await act(b, () => post("/api/defender/threat/refresh", b.dataset.id ? { id: b.dataset.id } : {}));
      if (r) {
        const failed = Object.values(r.feeds).filter((f) => f.enabled && f.error && f.error_at > Date.now() / 1000 - 300);
        if (failed.length) toast(t("df_th_err", { e: failed.map((f) => `${f.name}: ${f.error}`).join(" · ") }), "warn");
        else toast(r.changed.length ? t("df_th_updated_n", { n: r.changed.length }) : t("df_th_up_to_date"));
        if (D.tab === "threat") showTab("threat");
      }
      return;
    }
    if (a === "th-del") {
      if (!(await confirmBox({ message: t("df_th_remove_confirm", { name: b.dataset.name }), label: t("df_th_remove") }))) return;
      if (await act(b, () => post("/api/defender/threat/custom/remove", { id: b.dataset.id }), t("df_th_removed"))) showTab("threat");
      return;
    }
    if (a === "th-allow") {
      if (await act(b, () => post("/api/defender/allow", { ip: b.dataset.ip, note: "threat list" }), t("df_th_allowed", { ip: b.dataset.ip }))) showTab("threat");
      return;
    }
    if (a === "keep") { if (await act(b, () => post("/api/defender/confirm", {}), t("df_kept"))) paintPending(null); return; }
    if (a === "undo") { const r = await act(b, () => post("/api/defender/revert", {}), t("df_undone")); if (r) { D.st = r; D.fw = null; paintPending(null); rerender(); } return; }
    if (a === "enable") {
      if (!(await confirmBox({ message: t("df_enable_confirm"), label: t("df_enable"), danger: false }))) return;
      if (await apply(b, "config", { enabled: true, _what: "enable" })) rerender();
      return;
    }
    if (a === "disable") {
      if (!(await confirmBox({ message: t("df_disable_confirm"), label: t("df_disable") }))) return;
      if (await apply(b, "config", { enabled: false, _what: "disable", _rollback: false })) rerender();
      return;
    }
    if (a === "profile") { if (await apply(b, "config", { profile: b.dataset.p, _what: "profile" })) rerender(); return; }
    if (a === "ban") { if (await act(b, () => post("/api/defender/block", { ip: b.dataset.ip, minutes: +b.dataset.min }), `${b.dataset.ip} ✓`)) { D.st.bans++; if (D.tab !== "overview") rerender(); else refreshOverviewSlow(); } return; }
    if (a === "allow") { if (await act(b, () => post("/api/defender/allow", { ip: b.dataset.ip }), `${b.dataset.ip} ✓`)) refreshOverviewSlow(); return; }
    if (a === "unban") { if (await act(b, () => post("/api/defender/unban", { ip: b.dataset.ip }), `${b.dataset.ip} ✓`)) rerender(); return; }
    if (a === "unblock" || a === "unallow") { if (await act(b, () => post(`/api/defender/${a}`, { ip: b.dataset.ip }), `${b.dataset.ip} ✓`)) rerender(); return; }
    if (a === "fw-mode") {
      const m = b.dataset.mode;
      if (m === "strict" && D.fw.mode !== "strict") {   // pre-select every port in use so switching cannot break a service
        D.prefilled = false;
        for (const r of D.ports || []) if (!r.always && ruleFor(r) < 0 && !r.restricted) { D.fw.ports.push({ proto: r.proto, port: String(r.port), from: "", note: r.process || "" }); D.prefilled = true; }
      }
      D.fw.mode = m;
      return repaintFw();
    }
    if (a === "fw-open") { D.fw.ports.push({ proto: b.dataset.proto, port: b.dataset.port, from: "", note: b.dataset.note || "" }); return repaintFw(); }
    if (a === "fw-close") { const i = ruleFor({ proto: b.dataset.proto, port: +b.dataset.port }); if (i >= 0) D.fw.ports.splice(i, 1); return repaintFw(); }
    if (a === "fw-del") { D.fw.ports.splice(+b.dataset.i, 1); return repaintFw(); }
    if (a === "fw-add") return addRuleDialog();
    if (a === "if-del") { D.fw.trusted_ifaces.splice(+b.dataset.i, 1); return repaintFw(); }
    if (a === "fw-reset") { D.fw = clone(D.st.config.firewall); D.prefilled = false; return repaintFw(); }
    if (a === "rules") return rulesDialog();
    if (a === "fw-apply") {
      if (await apply(b, "config", { firewall: D.fw, _what: "firewall" })) { D.fw = null; D.prefilled = false; rerender(); }
      return;
    }
    if (a === "sv-port-add" || a === "sv-port-del") {
      svFormToDraft();
      if (a === "sv-port-del") D.svDraft.ports.splice(+b.dataset.i, 1);
      else {
        const v = +D.root.querySelector('form[data-f="sv"] [name="newport"]').value;
        if (v >= 1 && v <= 65535 && !D.svDraft.ports.includes(v)) D.svDraft.ports.push(v);
      }
      return repaintSv();
    }
    if (a === "sv-keep" || a === "sv-undo") {
      const r = await act(b, () => post(`/api/defender/sshd/${a === "sv-keep" ? "confirm" : "revert"}`, {}), t(a === "sv-keep" ? "df_sv_kept" : "df_sv_undone"));
      if (r) { D.sv = { ...D.sv, ...r }; D.svDraft = null; showTab("ssh"); }
      return;
    }
    if (a === "sv-key-del") {
      if (!(await confirmBox({ message: t("df_sv_key_del", { name: b.dataset.name }), label: t("df_remove") }))) return;
      const r = await act(b, () => post("/api/defender/sshd/key/remove", { index: +b.dataset.i }), t("saved"));
      if (r) { D.sv.keys = r.keys; svFormToDraft(); repaintSv(); }
      return;
    }
    if (a === "r-new") return ruleEditor(blankRule(), null);
    if (a === "r-tpl") return ruleEditor(TEMPLATES[b.dataset.tpl](), null);
    if (a === "r-edit") return ruleEditor(D.rules[+b.dataset.i], +b.dataset.i);
    if (a === "r-dup") {
      const src = D.rules[+b.dataset.i];
      const rules = [...D.rules];
      rules.splice(+b.dataset.i + 1, 0, { ...JSON.parse(JSON.stringify(src)), id: newId(), name: `${src.name} (${t("df_r_copy")})`, enabled: false });
      return saveRules(b, rules);
    }
    if (a === "r-move") {
      const i = +b.dataset.i, j = i + +b.dataset.d;
      if (j < 0 || j >= D.rules.length) return;
      const rules = [...D.rules];
      [rules[i], rules[j]] = [rules[j], rules[i]];
      return saveRules(b, rules);
    }
    if (a === "r-del") {
      const r = D.rules[+b.dataset.i];
      if (!(await confirmBox({ message: t("df_r_delete_confirm", { name: r.name }), label: t("df_j_delete") }))) return;
      return saveRules(b, D.rules.filter((_, k) => k !== +b.dataset.i));
    }
    if (a === "f2b-install") {
      if (!(await confirmBox({ message: t("df_f2b_install_confirm"), label: t("df_f2b_install"), danger: false }))) return;
      const r = await act(b, () => post("/api/defender/f2b/install", {}));
      if (r) { D.f2b = { ...D.f2b, job: r.job }; paintF2b(); schedJob(); }
      return;
    }
    if (a === "f2b-uninstall") return uninstallDialog();
    if (a === "f2b-svc") {
      const action = b.dataset.act;
      if (action === "stop" && !(await confirmBox({ message: t("df_f2b_stop_confirm"), label: t("df_f2b_stop") }))) return;
      const r = await act(b, () => post("/api/defender/f2b/service", { action }), t("df_f2b_job_ok"));
      if (r) { D.f2b = r; paintF2b(); }
      return;
    }
    if (a === "f2b-jail-set") return jailSettingsDialog(b.dataset.jail);
    if (a === "f2b-jail-edit") return jailEditor(b.dataset.jail).catch((x) => toast(x.message, "bad"));
    if (a === "f2b-jail-new") return jailEditor("", true).catch((x) => toast(x.message, "bad"));
    if (a === "f2b-jail-del") return deleteJail(b.dataset.jail, b);
    if (a === "f2b-file") return fileEditor(b.dataset.path).catch((x) => toast(x.message, "bad"));
    if (a === "f2b-file-new") return newFileDialog();
    if (a === "adv-pa-del" || a === "adv-pa-add" || a === "adv-pa-me") {
      const form = D.root.querySelector('form[data-f="adv"]');
      advFormToDraft(form);
      if (a === "adv-pa-del") D.adv.panel_allow.splice(+b.dataset.i, 1);
      else {
        const v = a === "adv-pa-me" ? D.myIp : form.elements.pa_new.value.trim();
        if (v && !D.adv.panel_allow.includes(v)) D.adv.panel_allow.push(v);
      }
      return repaintAdv();
    }
    if (a === "adv-sys-del") {
      const r = await act(b, () => post("/api/defender/sysctl", { action: "custom_del", key: b.dataset.key }), t("saved"));
      if (r) { D.sysCustom = r.custom || {}; advFormToDraft(D.root.querySelector('form[data-f="adv"]')); repaintAdv(); }
      return;
    }
    if (a === "f2b-jail-bans") return jailBansDialog(b.dataset.jail);
    if (a === "f2b-unban") { if (await act(b, () => post("/api/defender/f2b/unban", { ip: b.dataset.ip, jail: b.dataset.jail }), `${b.dataset.ip} ✓`)) rerender(); return; }
    if (a === "f2b-ign-del") { D.f2bIgnore.splice(+b.dataset.i, 1); return paintF2b(); }
    if (a === "f2b-ign-add" || a === "f2b-ign-trusted") {
      const add = a === "f2b-ign-trusted" ? D.f2b.admin_ips : [b.closest("form").elements.newip.value.trim()].filter(Boolean);
      for (const ip of add) if (!D.f2bIgnore.includes(ip)) D.f2bIgnore.push(ip);
      return paintF2b();
    }
    if (a === "f2b-log" || a === "f2b-log-open") {
      setTimeout(async () => {
        const pre = D.root.querySelector("#df-f2b-log");
        if (!pre || (a === "f2b-log-open" && !pre.closest("details").open)) return;
        try { pre.textContent = (await api("/api/defender/f2b/log")).text || "—"; pre.scrollTop = pre.scrollHeight; } catch (e) { pre.textContent = e.message; }
      }, 0);
      return;
    }
    if (a === "export") return exportBackup(b);
    if (a === "sysctl") {
      const r = await act(b, () => post("/api/defender/sysctl", { action: b.dataset.act }), t("saved"));
      if (r) rerender();
    }
  }

  async function onChange(e) {
    const el = e.target;
    if (el.dataset.feed) {
      const feeds = [...D.root.querySelectorAll("[data-feed]")].filter((x) => x.checked).map((x) => x.dataset.feed);
      D.root.querySelectorAll("[data-feed]").forEach((x) => { x.disabled = true; });
      if (!(await threatSave(el, { feeds }, "threat lists"))) el.checked = !el.checked;
      D.root.querySelectorAll("[data-feed]").forEach((x) => { x.disabled = false; });
      return;
    }
    if (el.dataset.ruleToggle !== undefined) {
      const rules = D.rules.map((r, k) => (k === +el.dataset.ruleToggle ? { ...r, enabled: el.checked } : r));
      el.disabled = true;
      if (!(await saveRules(el, rules))) { el.checked = !el.checked; el.disabled = false; }
      return;
    }
    if (el.dataset.jailToggle) {
      const name = el.dataset.jailToggle, on = el.checked;
      el.disabled = true;
      try { D.f2b = await post("/api/defender/f2b/jail", { name, enabled: on }); toast(t("df_f2b_saved")); paintF2b(); }
      catch (x) { el.checked = !on; el.disabled = false; if (x.message !== "unauthorized") toast(x.message, "bad"); }
      return;
    }
    if (el.matches("[data-import]")) { const f = el.files[0]; el.value = ""; if (f) importBackup(f); return; }
    const form = e.target.closest("form[data-f]");
    if (!form || e.target.type !== "checkbox" || form.dataset.f === "adv") return;
    const f = form.dataset.f, on = e.target.checked, name = e.target.name;
    if (f === "esc") { if (!(await apply(e.target, "config", { auto_escalate: on, _rollback: false }, t("saved")))) e.target.checked = !on; }
    if (f === "cdn") { if (!(await apply(e.target, "config", { trust_cdn: on, _what: "cdn" }, t("df_kept")))) e.target.checked = !on; }
    if (f === "notify") { if (!(await apply(e.target, "config", { notify: { [name]: on }, _rollback: false }, t("saved")))) e.target.checked = !on; }
  }

  async function onSubmit(e) {
    const form = e.target.closest("form[data-f]");
    if (!form) return;
    e.preventDefault();
    const f = form.dataset.f, btn = form.querySelector('[type="submit"]'), el = form.elements;
    if (f === "if-add") {
      const v = el.iface.value.trim();
      if (!/^[A-Za-z0-9_.\-]{1,15}\*?$/.test(v)) return toast(t("df_ifaces_sub"), "warn");
      if (!D.fw.trusted_ifaces.includes(v)) D.fw.trusted_ifaces.push(v);
      return repaintFw();
    }
    if (f === "ddos") {
      const limits = Object.fromEntries(LIMITS.map(([k]) => [k, +el[k].value]));
      if (await apply(btn, "config", { limits, ddos: { drop_invalid: el.drop_invalid.checked, bad_flags: el.bad_flags.checked }, _what: "limits" })) rerender();
      return;
    }
    if (f === "ssh") {
      const g = { enabled: el.enabled.checked, l4: el.l4.checked, exempt_private: el.exempt_private.checked, failures: +el.failures.value, window: +el.window.value, ban: +el.ban.value };
      if (await apply(btn, "config", { ssh_guard: g, _what: "ssh guard" }, t("saved"))) rerender();
      return;
    }
    if (f === "sv") {
      svFormToDraft();
      if (!D.svDraft.ports.length) return toast(t("df_sv_last_port"), "bad");
      if (!(await confirmBox({ message: t("df_sv_confirm", { ports: D.svDraft.ports.join(", ") }), label: t("df_sv_save"), danger: false }))) return;
      const r = await act(btn, () => post("/api/defender/sshd/apply", D.svDraft), t("df_sv_applied"));
      if (r) { D.sv = { ...D.sv, ...r }; D.svDraft = null; if (r.warning) toast(r.warning, "warn"); showTab("ssh"); }
      return;
    }
    if (f === "sv-key") {
      const r = await act(btn, () => post("/api/defender/sshd/key/add", { key: el.key.value }), t("saved"));
      if (r) { D.sv.keys = r.keys; svFormToDraft(); repaintSv(); }
      return;
    }
    if (f === "th-set") {
      await threatSave(btn, { outbound: el.outbound.checked, refresh_hours: +el.hours.value }, "threat settings");
      return;
    }
    if (f === "th-add") {
      if (await act(btn, () => post("/api/defender/threat/custom/add", { name: el.name.value.trim(), url: el.url.value.trim() }), t("df_th_added"))) showTab("threat");
      return;
    }
    if (f === "tt") {
      const out = D.root.querySelector("#df-tt-out");
      const r = await act(btn, () => post("/api/defender/test", { ip: el.ip.value.trim(), port: +el.port.value || 0, proto: el.proto.value }));
      if (r && out) out.innerHTML = testResult(r);
      return;
    }
    if (f === "adv") {
      advFormToDraft(form);
      const { _logged, _cdn, ...advanced } = D.adv;
      if (await apply(btn, "config", { advanced, trust_logged_in: _logged, trust_cdn: _cdn, _what: "advanced" })) { D.adv = null; rerender(); }
      return;
    }
    if (f === "adv-sys") {
      const r = await act(btn, () => post("/api/defender/sysctl", { action: "custom_set", key: el.key.value.trim(), value: el.value.value.trim() }), t("saved"));
      if (r) { D.sysCustom = r.custom || {}; advFormToDraft(D.root.querySelector('form[data-f="adv"]')); repaintAdv(); }
      return;
    }
    if (f === "f2b-defaults") {
      const body = { maxretry: +el.maxretry.value, findtime: el.findtime.value, bantime: el.bantime.value,
        "bantime.maxtime": el.maxtime.value, "bantime.increment": el.increment.checked, ignoreip: D.f2bIgnore };
      const r = await act(btn, () => post("/api/defender/f2b/defaults", body), t("df_f2b_saved"));
      if (r) { D.f2b = r; D.f2bIgnore = null; paintF2b(); }
      return;
    }
    if (f === "list-add") {
      const ip = el.ip.value.trim(), action = el.action.value, note = el.note.value.trim();
      const call = action === "allow" ? () => post("/api/defender/allow", { ip, note })
        : action === "block" ? () => post("/api/defender/block", { ip, note })
        : () => post("/api/defender/block", { ip, note, minutes: +action.slice(3) });
      if (await act(btn, call, `${ip} ✓`)) rerender();
    }
  }

  P.registerView({ id: "defender", icon: "shield", label: "df_nav", desc: "df_desc", group: "monitor", static: true }, { build: async () => ({ html: await build(), tools: "" }), bind }, "overview");
  P.setTabs(["overview", "defender", "websites", "alerts"]);
})();
