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
    df_nav: "Defender", df_desc: "Firewall, DDoS protection, SSH brute-force guard and server hardening, all in one place. Changes are tested for 60 seconds and undone by themselves if the panel stops answering.",
    df_t_overview: "Overview", df_t_firewall: "Firewall", df_t_ddos: "Anti-DDoS", df_t_lists: "IP lists", df_t_ssh: "SSH guard", df_t_hardening: "Hardening",
    df_missing_title: "The Defender agent is not running", df_missing_sub: "It is part of the monitoring stack. Re-run install.sh, or on the server run:",
    df_off_title: "Protection is off", df_off_sub: "The Defender is only watching. Turn protection on to block floods, scans and brute force. Nothing is closed: every port that works now keeps working.",
    df_on_title: "Your server is protected", df_on_sub: "Floods, scans and brute force are blocked automatically. Normal traffic is not touched.",
    df_attack_title: "Under attack: mitigating", df_attack_sub: "Started {since}. Peak {pps} packets/s, {drop} blocked/s.",
    df_esc_title: "Heightened protection", df_esc_sub: "\"Under attack\" limits are active after an attack and switch back by themselves 10 minutes after it ends.",
    df_enable: "Turn on protection", df_disable: "Turn off", df_enable_confirm: "Turn on the Defender? It starts in open mode: no port is closed, only abusive traffic is blocked. If the panel stops answering, the change is undone after 60 seconds.",
    df_disable_confirm: "Turn off protection? All Defender rules are removed and bans are lifted; monitoring continues.",
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
    df_e_sysctl: "Kernel settings: {action}", df_e_started: "Defender started",
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
    df_admins: "Logged in over SSH from {ips}: these addresses are always allowed.", df_bans: "Banned now", df_filter: "Filter…", df_source: "Banned by", df_left: "Ends in",
    df_s_auto: "Flood", df_s_ssh: "SSH guard", df_s_manual: "Manual", df_s_fail2ban: "fail2ban", df_blocklist: "Blocklist", df_allowlist: "Allowlist", df_added: "Added",
    df_f2b_note: "fail2ban's bans are shown for reference; manage them with fail2ban-client.",
    // ssh
    df_ssh_title: "SSH brute-force guard", df_ssh_sub: "Reads the SSH login log and bans addresses that keep failing to log in. Logged-in users and addresses that logged in successfully today are never banned.",
    df_ssh_on: "Ban addresses with failed logins", df_ssh_l4: "Also limit new SSH connections (12 per minute per address)", df_ssh_private: "Never ban private networks",
    df_ssh_failures: "Failed logins before a ban", df_ssh_window: "Within (minutes)", df_ssh_ban: "Ban time (minutes)",
    df_ssh_24h: "Failed logins (since the agent started)", df_ssh_top: "Most failed logins", df_ssh_nolog: "The SSH log (/var/log/auth.log) is not readable, so only the connection limit is active.",
    df_f2b_present: "fail2ban is installed too. Both can run together; the Defender's guard also covers servers without it.", df_attempts: "Attempts",
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
    df_c_fw_enabled: ["Defender protection is off", "Defender protection is on"], df_f_fw_enabled: "Turn protection on in the Overview tab.",
    df_c_internal_exposed: ["{name} (port {port}) is reachable from the internet", "No database or internal service is exposed"], df_f_internal_exposed: "Bind it to 127.0.0.1, or switch the firewall to strict mode and allow the port only from trusted IPs.",
    df_c_open_ports: ["{n} TCP ports are open to the internet", "{n} public TCP ports"], df_f_open_ports: "Strict mode closes everything you did not allow.",
    df_c_reboot: ["A reboot is needed to finish installing updates", "No reboot pending"], df_f_reboot: "Reboot the server at a quiet time; the whole stack starts again by itself.",
    df_c_auto_updates: ["Automatic security updates are off", "Automatic security updates are on"], df_f_auto_updates: "apt install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades",
    df_c_conntrack: ["Connection table {pct}% full", "Connection table {pct}% used"], df_f_conntrack: "Apply the kernel hardening below; it raises the limit.",
    df_c_kernel: ["{n} kernel network settings are not hardened", "Kernel network settings are hardened"], df_f_kernel: "Use \"Apply recommended\" below.",
    df_c_syncookies: ["SYN cookies are off", "SYN cookies are on"], df_f_syncookies: "Apply the kernel hardening below.",
    df_c_fail2ban: ["fail2ban is not installed", "fail2ban is installed"], df_f_fail2ban: "Optional: the Defender's SSH guard does the same job.",
    sc_syncookies: "Answers SYN floods without filling the connection queue", sc_synack: "Gives up on half-open connections sooner", sc_backlog: "Longer queue for connections being opened",
    sc_rfc1337: "Protects against TIME-WAIT assassination", sc_bcast: "Ignores pings to broadcast addresses (smurf attacks)", sc_bogus: "Ignores bogus ICMP error replies",
    sc_redirects: "Ignores ICMP redirects (route hijacking)", sc_send_redirects: "Does not send ICMP redirects", sc_source_route: "Rejects source-routed packets",
    sc_conntrack: "Room for more tracked connections during a flood", sc_ct_timeout: "Forgets idle connections after a day instead of five",
  };
  const FA = {
    df_nav: "دیفندر", df_desc: "فایروال، محافظت در برابر DDoS، محافظ SSH و سخت‌سازی سرور در یک جا. هر تغییر ۶۰ ثانیه آزمایش می‌شود و اگر پنل دیگر جواب ندهد، خودش برمی‌گردد.",
    df_t_overview: "نمای کلی", df_t_firewall: "فایروال", df_t_ddos: "ضد DDoS", df_t_lists: "لیست آی‌پی‌ها", df_t_ssh: "محافظ SSH", df_t_hardening: "سخت‌سازی",
    df_missing_title: "سرویس دیفندر اجرا نمی‌شود", df_missing_sub: "بخشی از استک مانیتورینگ است. install.sh را دوباره اجرا کنید یا روی سرور بزنید:",
    df_off_title: "محافظت خاموش است", df_off_sub: "دیفندر فقط نگاه می‌کند. محافظت را روشن کنید تا فلاد، اسکن و حمله‌ی رمز بسته شود. هیچ پورتی بسته نمی‌شود و هر چیزی که الان کار می‌کند، کار می‌کند.",
    df_on_title: "سرور شما محافظت می‌شود", df_on_sub: "فلاد، اسکن و حمله‌ی رمز خودکار بسته می‌شوند. ترافیک عادی دست نمی‌خورد.",
    df_attack_title: "زیر حمله: در حال دفع", df_attack_sub: "شروع: {since}. اوج {pps} بسته در ثانیه، {drop} مسدود در ثانیه.",
    df_esc_title: "محافظت تشدیدشده", df_esc_sub: "محدودیت‌های «زیر حمله» بعد از حمله فعال‌اند و ۱۰ دقیقه بعد از پایان آن خودکار برمی‌گردند.",
    df_enable: "روشن کردن محافظت", df_disable: "خاموش", df_enable_confirm: "دیفندر روشن شود؟ در حالت باز شروع می‌کند: هیچ پورتی بسته نمی‌شود و فقط ترافیک مخرب مسدود می‌شود. اگر پنل جواب ندهد، تغییر بعد از ۶۰ ثانیه برمی‌گردد.",
    df_disable_confirm: "محافظت خاموش شود؟ همه‌ی قوانین دیفندر حذف و مسدودی‌ها برداشته می‌شوند؛ مانیتورینگ ادامه دارد.",
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
    df_e_sysctl: "تنظیمات کرنل: {action}", df_e_started: "دیفندر شروع به کار کرد",
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
    df_admins: "با SSH از {ips} وارد شده‌اید: این آدرس‌ها همیشه مجازند.", df_bans: "مسدودهای فعلی", df_filter: "جستجو…", df_source: "مسدودکننده", df_left: "پایان تا",
    df_s_auto: "فلاد", df_s_ssh: "محافظ SSH", df_s_manual: "دستی", df_s_fail2ban: "fail2ban", df_blocklist: "لیست سیاه", df_allowlist: "لیست سفید", df_added: "افزوده‌شده",
    df_f2b_note: "مسدودی‌های fail2ban فقط برای اطلاع نمایش داده می‌شوند؛ با fail2ban-client مدیریتشان کنید.",
    df_ssh_title: "محافظ حمله‌ی رمز SSH", df_ssh_sub: "لاگ ورود SSH را می‌خواند و آدرس‌هایی که مدام ورود ناموفق دارند را مسدود می‌کند. کاربرهای واردشده و آدرس‌هایی که امروز موفق وارد شده‌اند هرگز مسدود نمی‌شوند.",
    df_ssh_on: "مسدود کردن آدرس‌های با ورود ناموفق", df_ssh_l4: "محدود کردن اتصال‌های جدید SSH (۱۲ در دقیقه برای هر آدرس)", df_ssh_private: "شبکه‌های خصوصی هرگز مسدود نشوند",
    df_ssh_failures: "ورود ناموفق قبل از مسدودی", df_ssh_window: "در مدت (دقیقه)", df_ssh_ban: "مدت مسدودی (دقیقه)",
    df_ssh_24h: "ورودهای ناموفق (از شروع سرویس)", df_ssh_top: "بیشترین ورود ناموفق", df_ssh_nolog: "لاگ SSH (/var/log/auth.log) خوانا نیست، پس فقط محدودیت اتصال فعال است.",
    df_f2b_present: "fail2ban هم نصب است. هر دو با هم کار می‌کنند؛ محافظ دیفندر سرورهای بدون آن را هم پوشش می‌دهد.", df_attempts: "تلاش‌ها",
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
    df_c_fw_enabled: ["محافظت دیفندر خاموش است", "محافظت دیفندر روشن است"], df_f_fw_enabled: "از تب نمای کلی محافظت را روشن کنید.",
    df_c_internal_exposed: ["{name} (پورت {port}) از اینترنت در دسترس است", "هیچ دیتابیس یا سرویس داخلی‌ای باز نیست"], df_f_internal_exposed: "آن را روی 127.0.0.1 ببندید، یا فایروال را سخت‌گیر کنید و پورت را فقط برای آی‌پی‌های مورد اعتماد باز بگذارید.",
    df_c_open_ports: ["{n} پورت TCP به اینترنت باز است", "{n} پورت TCP عمومی"], df_f_open_ports: "حالت سخت‌گیر هر چیزی که اجازه نداده‌اید را می‌بندد.",
    df_c_reboot: ["برای تمام شدن نصب آپدیت‌ها ری‌بوت لازم است", "ری‌بوتی لازم نیست"], df_f_reboot: "در زمان خلوت سرور را ری‌بوت کنید؛ کل استک خودش بالا می‌آید.",
    df_c_auto_updates: ["آپدیت امنیتی خودکار خاموش است", "آپدیت امنیتی خودکار روشن است"], df_f_auto_updates: "apt install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades",
    df_c_conntrack: ["جدول اتصال‌ها {pct} درصد پر است", "{pct} درصد از جدول اتصال‌ها استفاده شده"], df_f_conntrack: "سخت‌سازی کرنل پایین را اعمال کنید؛ ظرفیت را بالا می‌برد.",
    df_c_kernel: ["{n} تنظیم شبکه‌ی کرنل سخت‌سازی نشده", "تنظیمات شبکه‌ی کرنل سخت‌سازی شده"], df_f_kernel: "از دکمه‌ی «اعمال پیشنهادها» پایین استفاده کنید.",
    df_c_syncookies: ["SYN cookie خاموش است", "SYN cookie روشن است"], df_f_syncookies: "سخت‌سازی کرنل پایین را اعمال کنید.",
    df_c_fail2ban: ["fail2ban نصب نیست", "fail2ban نصب است"], df_f_fail2ban: "اختیاری: محافظ SSH دیفندر همین کار را می‌کند.",
    sc_syncookies: "بدون پر شدن صف، به SYN فلاد جواب می‌دهد", sc_synack: "اتصال‌های نیمه‌باز را زودتر رها می‌کند", sc_backlog: "صف بلندتر برای اتصال‌های در حال باز شدن",
    sc_rfc1337: "محافظت در برابر حمله‌ی TIME-WAIT", sc_bcast: "پینگ به آدرس broadcast را نادیده می‌گیرد (حمله‌ی smurf)", sc_bogus: "پاسخ‌های خطای جعلی ICMP را نادیده می‌گیرد",
    sc_redirects: "ICMP redirect را نادیده می‌گیرد (ربودن مسیر)", sc_send_redirects: "ICMP redirect نمی‌فرستد", sc_source_route: "بسته‌های source-routed را رد می‌کند",
    sc_conntrack: "جای بیشتر برای اتصال‌ها هنگام فلاد", sc_ct_timeout: "اتصال‌های بی‌کار را بعد از یک روز فراموش می‌کند نه پنج روز",
  };
  P.addStrings(EN, FA);
  const tt = (k, i, vars) => { const v = t(k); const s = Array.isArray(v) ? v[i] : v; return vars ? Object.entries(vars).reduce((a, [x, y]) => a.replace(`{${x}}`, y), s) : s; };

  // ---------------------------------------------------------------- state
  const TABS = [["overview", "grid"], ["firewall", "lock"], ["ddos", "zap"], ["lists", "list"], ["ssh", "terminal"], ["hardening", "shield"]];
  const store = { get(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } }, set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* ignore */ } } };
  const D = { tab: store.get("df_tab", "overview"), st: null, err: "", samples: [], lastT: 0, timer: null, ticks: 0, fw: null, talkers: [], events: [], root: null, heroKey: "" };
  if (!TABS.some(([id]) => id === D.tab)) D.tab = "overview";
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const sev = (n) => pill(["ok", "", "warn", "bad"][n], t(`df_sev${n}`));
  const KEEP = 300;

  // ---------------------------------------------------------------- shell
  async function build() {
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
    root.addEventListener("input", (e) => { if (e.target.id === "df-ban-filter") filterBans(e.target.value); });
    if (D.st) { paintPending(D.st.pending); showTab(D.tab); }
    clearInterval(D.timer);
    D.timer = setInterval(loop, 2000);
    loop();
  }

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

  const EVENT_IC = { attack_start: "flame", attack_end: "okmark", escalate: "alert", deescalate: "shield", ban: "ban", ssh_ban: "terminal", unban: "unlock", block: "ban", allow: "check", rollback: "refresh", applied: "sliders", confirmed: "okmark", sysctl: "gear", started: "power" };
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
    for (const s of S) for (const [k, v] of Object.entries(s.drops || {})) totals[k] = (totals[k] || 0) + v;
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
      { h: "df_source", cell: (r) => pill(r.source === "manual" ? "" : r.source === "fail2ban" ? "" : "warn", t(`df_s_${r.source}`)) },
      { h: "df_left", cell: (r) => num(esc(left(r.left))) },
      { h: "actions", cell: (r) => (r.source === "fail2ban" ? "–" : `<button type="button" class="btn small" data-a="unban" data-ip="${esc(r.ip)}">${esc(t("df_unban"))}</button>`) },
    ], b.rows, (r) => `data-ip="${esc(r.ip)}"`);
    const listTable = (rows, kind) => table([
      { h: "df_ip", cls: "strong", cell: (r) => num(esc(r.ip)) },
      { h: "df_note", cell: (r) => esc(r.note || "") },
      { h: "df_added", cell: (r) => (r.added ? esc(ago(r.added)) : "–") },
      { h: "actions", cell: (r) => btnIcon("trash", `${t("df_remove")} ${r.ip}`, `data-a="un${kind}" data-ip="${esc(r.ip)}"`, "danger") },
    ], rows);
    const f2b = b.rows.some((r) => r.source === "fail2ban") ? `<p class="muted">${esc(t("df_f2b_note"))}</p>` : "";
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
      <section class="sec"><div class="sec-head"><h3>${icon("send")}${esc(t("df_notify"))}</h3></div><form class="subcard" data-f="notify">${sw("attacks", n.attacks, t("df_notify_attacks"))}${sw("bans", n.bans, t("df_notify_bans"))}</form></section>`;
  }

  const RENDER = { overview: renderOverview, firewall: renderFirewall, ddos: renderDdos, lists: renderLists, ssh: renderSsh, hardening: renderHardening };
  const rerender = () => showTab(D.tab);

  // ---------------------------------------------------------------- events
  async function onClick(e) {
    const b = e.target.closest("[data-a]");
    if (!b || b.disabled) return;
    const a = b.dataset.a;
    if (a === "tab") return showTab(b.dataset.tab);
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
    if (a === "sysctl") {
      const r = await act(b, () => post("/api/defender/sysctl", { action: b.dataset.act }), t("saved"));
      if (r) rerender();
    }
  }

  async function onChange(e) {
    const form = e.target.closest("form[data-f]");
    if (!form || e.target.type !== "checkbox") return;
    const f = form.dataset.f, on = e.target.checked, name = e.target.name;
    if (f === "esc") { if (!(await apply(e.target, "config", { auto_escalate: on, _rollback: false }, t("saved")))) e.target.checked = !on; }
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
