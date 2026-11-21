(() => {
  "use strict";

  // ---------------------------------------------------------------- i18n
  const T = {
    en: {
      title: "Server Monitor", monitors: "Monitors", manage: "Manage", refresh: "Refresh", logout: "Logout",
      lang_switch: "فارسی", host: "Host",
      cpu: "CPU", memory: "Memory", disk: "Disk", load: "Load average",
      net_down: "Network in", net_up: "Network out", targets: "Targets up",
      websites: "Checks up", ssl: "SSL expires in", alerts: "Firing alerts", cores: "cores", of: "of", days: "days", running: "running",
      overview: "Overview", websites_nav: "Websites", disks: "Disks", network: "Network",
      targets_nav: "Targets", alerts_nav: "Alerts", servers_nav: "Servers", notifications_nav: "Notifications",
      rules_nav: "Alert rules", settings_nav: "Settings",
      d_overview: "Live resource usage of the selected server. Charts update automatically.",
      d_websites: "Websites and TCP ports that are checked for uptime, response time and SSL expiry. Add or remove them here.",
      d_disks: "Mounted filesystems and how full they are.",
      d_network: "Traffic on the physical network interfaces (virtual and Docker interfaces are hidden).",
      d_servers: "The servers whose CPU, memory, disk and network are monitored. Add another server to watch it too.",
      d_notifications: "Where alerts are sent. Connect a Telegram bot to get a message when something goes wrong.",
      d_rules: "When an alert fires. Change the thresholds, switch rules off, or restore the defaults.",
      d_settings: "Panel password, Docker access and information about this installation.",
      nx_nodata: "No network interface data yet. Rates need about 30 seconds of samples; if this stays empty, check the Targets tab.",
      nx_nojob: "The node-net exporter is not in Prometheus. Re-run install.sh, or run: docker compose up -d && docker compose restart panel prometheus",
      nx_down: "The node-net exporter is down, so network cards cannot be read. Error:",
      d_targets: "Everything Prometheus scrapes. A target that is down means its metrics are missing.",
      d_alerts: "Alerts that are firing or about to fire. Change when they fire on the Alert rules page.",
      server: "Server", range: "Range", r1h: "Last hour", r6h: "Last 6 hours", r24h: "Last 24 hours", r7d: "Last 7 days", rlive: "Live (last 5 minutes)",
      c_cpu: "CPU usage", c_mem: "Memory usage", c_net: "Network traffic", c_load: "Load average",
      rx: "in", tx: "out", no_data: "No data yet", empty: "Nothing to show yet.",
      name: "Name", cpu_h: "CPU", mem_h: "Memory", uptime_h: "Uptime", status: "Status", target: "Target", type: "Type",
      response: "Response", http: "HTTP", ssl_h: "SSL days left", mount: "Mount", device: "Device", fs: "Filesystem",
      usage: "Usage", used_total: "Used / Total", iface: "Interface", speed: "Link speed", rate_in: "In", rate_out: "Out", total_in: "Total in", total_out: "Total out",
      job: "Job", instance: "Instance", scrape: "Scrape time", error: "Error", severity: "Severity", alert: "Alert", summary: "Summary", state: "State", since: "Since",
      s_running: "Running", s_up: "Up", s_down: "Down", s_firing: "Firing", s_pending: "Pending", s_exited: "Stopped", s_paused: "Paused", s_created: "Created", s_restarting: "Restarting",
      no_alerts: "No active alerts. Everything looks healthy.", host_online: "Host online",
      h_ok: "Everything is healthy", h_ok_sub: "The server and all of your checks are working normally.", h_warn: "Needs your attention", h_bad: "Problems detected",
      i_alerts: "{n} active alert(s)", i_sites: "{n} website/port check(s) failing", i_targets: "{n} monitoring target(s) not responding",
      i_res: "{what} is high ({v}%)", i_pending: "{n} alert(s) about to fire", i_ssl: "an SSL certificate expires in {n} day(s)",
            net_ifaces: "Network interfaces", tr_title: "Traffic usage", tr_sub: "Downloads and uploads of this server's physical network cards, counted exactly from the cards' own byte counters and kept across reboots.",
      tr_day: "Day", tr_today: "Today", tr_yesterday: "Yesterday", tr_7d: "Last 7 days", tr_month: "This month", tr_prev: "Last month", tr_boot: "Since boot", tr_total: "Total", tr_down: "Download", tr_up: "Upload",
      tr_daily: "Daily traffic", tr_peak_in: "Peak download (24h)", tr_peak_out: "Peak upload (24h)", tr_partial: "Only {d} of data collected so far", tr_range: "{a} to {b}", tr_proj: "At this pace about {v} by the end of the month", tr_incomplete: "Incomplete: there is no data for some of its days", tr_nodata_month: "No data for this month (the panel was not running yet)", tr_months: "Monthly totals", tr_alltime: "All time", tr_alltime_since: "Since {d}, when counting started", tr_boot_since: "Last boot: {d}", tr_24h: "24 hours", tr_hour: "Hour", tr_24h_sum: "Last 24 hours: {v} in total ({d} down, {u} up)", tr_counted: "Counted cards", tr_auto: "automatic: physical cards only", tr_manual: "chosen by you", tr_choose: "Choose cards", tr_dev_title: "Which network cards are counted?", tr_dev_help: "Count only the card(s) your provider meters. Tunnels and VPN interfaces (WireGuard, GRE, ...) carry traffic that also passes through the physical card: counting both would count it twice. Changing this also recalculates the history.", tr_dev_auto: "Automatic: physical cards only (recommended)", tr_dev_manual: "Choose by hand", tr_physical: "physical", tr_virtual: "tunnel / virtual", tr_dev_month: "this month", tr_dev_none: "Choose at least one card.", tr_updated: "Exact count from the network cards' counters · updated {ago}", tr_preparing: "Reading this server's traffic history for the first time. It is ready in a few seconds.", tr_syncing: "Catching up on the traffic since the panel was last running...", tr_month_col: "Month", tr_month_sum: "{m}: {v} in total ({d} down, {u} up)",
            diag_btn: "Find out why", dg_title: "Why can't the panel load data?", diag_services: "Services", diag_containers: "Containers of the stack", diag_ok: "Reachable", diag_fail: "Failing",
      diag_dns: "Name not found", diag_http: "No valid answer", diag_detail: "Detail", diag_exit: "Exit code", diag_restarts: "Restarts", diag_logs: "Last log lines of {s}", service: "Service",
      diag_all_ok: "Every service answers now. Close this window and press Refresh.",
      hint_stopped: "{service} is not running: {detail}. Restart it with the button below; its last log lines further down show why it stopped.",
      hint_dns: "The panel cannot even resolve the name \u201c{service}\u201d ({detail}). Docker's internal DNS is not answering.",
      hint_svc: "{service} is reachable but does not answer correctly: {detail}",
      hint_disk: "The disk is {detail} full. Prometheus stops working when there is no free space left.",
      hint_dns_external: "DNS to the internet fails as well ({detail}). The server's resolver (/etc/resolv.conf) is broken or blocked by the firewall, and Docker uses it.",
      lv_ok: "Normal", lv_warn: "High", lv_bad: "Critical", address: "Address", more: "More", tbl_view: "Table view", time: "Time",
      err_api: "Cannot load data", last_update: "Last update", auto: "auto-refresh every 10s", ago: "ago",
      live_on: "Live · updates every", live_every: "How often live numbers update", live_sec: "{n} s", live_wait: "Connecting to live data…", live_waiting: "Waiting for live data…", live_tag: "Live",
      live_off_note: "Live data is not available ({e}), so the last hour is shown instead.", io_r: "read", io_w: "write", swap: "Swap",
      t_dark: "Switch to light theme", t_light: "Switch to dark theme",
      // generic UI
      add: "Add", cancel: "Cancel", close: "Close", save: "Save", saved: "Saved", remove: "Remove", working: "Working…", copy: "Copy", copied: "Copied",
      confirm: "Please confirm", actions: "Actions", minutes: "min", added: "Added", removed: "Removed", reset_defaults: "Restore defaults",
      // stack containers (self-diagnosis)
      a_restart: "Restart", c_done: "Done",
      c_docker_off: "Docker access is off, so the state of the stack's containers cannot be shown. Enable it by mounting the Docker socket (see Settings).",
      // websites + servers
      add_site: "Add website or port", type_http: "Website (HTTP / HTTPS)", type_tcp: "TCP port", f_target: "Address", f_name_opt: "Name (optional)",
      hint_http: "A full address, for example https://example.com", hint_tcp: "host:port, for example 203.0.113.10:22 (SSH) or db.internal:5432",
      probe: "Test now / why?", probe_title: "Check result", probe_running: "Checking now…", probe_ok: "This check passes from the server right now.",
      probe_fail: "This check fails from the server.", probe_reason: "Reason", probe_log: "Technical details", probe_status: "HTTP status",
      probe_k_reset: "The site (or the network in front of it) accepted the connection and then cut it off during the handshake. This is what a firewall or geo-block does: the site works for you but refuses this server's IP address.",
      probe_k_refused: "The server answered but nothing is listening on that port (or a firewall is actively rejecting it).",
      probe_k_dns: "The server cannot resolve this domain name. Check the spelling and the DNS settings of the server.",
      probe_k_timeout: "No answer in time. The host is down, or a firewall silently drops packets from this server.",
      probe_k_tls: "The site's certificate has a problem: expired, issued for another domain, or from an untrusted issuer.",
      probe_k_unreachable: "This server has no network route to the address.",
      probe_k_status: "The site answered but with an error status (4xx or 5xx), so it is not counted as healthy.",
      probe_k_other: "The check failed for another reason; see the technical details below.",
      probe_k_handshake: "The site rejected the secure connection during the TLS handshake. Usual causes: it only supports old TLS versions or ciphers, its certificate/SNI setup is broken, or its firewall refuses this server's IP address. The table below tries the alternatives for you.",
      v_legacy_tls: "Allow old TLS (1.0 / 1.1)", v_no_verify: "Ignore certificate errors", v_legacy_no_verify: "Old TLS and ignore certificate errors",
      v_plain_http: "Plain HTTP (no encryption)", v_tcp: "Only connect to the port (TCP)",
      diag_title: "What works from the server", diag_works: "Works", diag_fails: "Fails", diag_apply: "Monitor this site this way",
      diag_suggest: "The site passes in the mode marked below. Switch the check to it to monitor the site without false alarms.",
      diag_applied: "Check mode changed. The status updates within a minute.", mode_default: "standard",
      mode_legacy_tls: "old TLS", mode_no_verify: "no certificate check", mode_legacy_no_verify: "old TLS, no certificate check",
      diag_blocked: "The port accepts connections but every secure variant is rejected: the site or its firewall refuses this server specifically (typical for IP/geo blocking).",
      diag_plain: "Plain HTTP works, but every secure (HTTPS) attempt is rejected, whatever the TLS mode. The site is up; its HTTPS side refuses this server. You can monitor it over plain HTTP instead (if that address redirects to an HTTPS page, that page's certificate is still checked).",
      diag_use_http: "Monitor over plain HTTP instead", diag_replaced: "Now monitoring the plain HTTP address.",
      diag_closed: "Even a plain TCP connection fails: the address is unreachable from this server (down, wrong port, or blocked).",
      auto_title: "Automatic fixing of failing websites",
      auto_text: "When a website keeps failing, the panel tries other ways to check it (old TLS, ignoring certificate errors, the page its http:// address redirects to, plain http://) and switches to the first one that works. A check that works is never changed. Turn it off to keep your addresses exactly as typed.",
      auto_on: "Fix failing websites automatically", auto_off_saved: "Automatic fixing is off", auto_on_saved: "Automatic fixing is on",
      auto_log: "Automatic adjustments", auto_tag: "auto", auto_was: "was {from}",
      auto_ev_replace: "{from} is now monitored as {to}", auto_ev_mode: "{from} is now checked with: {mode}", auto_ev_merge: "{from} was removed: {to} is already monitored",
      auto_fix_btn: "Fix automatically", auto_done: "Done. The status updates within a minute.",
      auto_none: "Nothing better was found: no other way of checking this address works from the server.",
      added_auto: "Added. The panel is choosing the best way to monitor it automatically.", redirects_to: "redirects to",
      probe_hint: "If the address opens in your browser but fails here, the server's IP is probably blocked by the site or its network (common for sites hosted in Iran when the monitoring server is abroad), or the server has no route to it. Monitoring shows what the server sees, not what you see.",
      s_wait: "Waiting", w_confirm_remove: "Stop monitoring {n}?", w_hint: "New entries show \"Waiting\" until the first check completes (about a minute).",
      add_server: "Add server", f_srv_addr: "Server address", f_srv_hint: "IP or hostname with the node_exporter port, for example 203.0.113.10:9100",
      srv_local: "this server", srv_confirm_remove: "Stop monitoring server {n}?",
      srv_help_title: "How to add another server",
      srv_help_1: "1. On the other server, run node_exporter (needs Docker):",
      srv_help_2: "2. Allow port 9100 only from this monitoring server in that server's firewall, for example:",
      srv_help_3: "3. Click \"Add server\" and enter its address as IP:9100.",
      // notifications
      tg_title: "Telegram", tg_ok: "Connected", tg_no: "Not configured", tg_bot: "Bot",
      tg_s1: "Open Telegram, talk to @BotFather, send /newbot and copy the token it gives you.",
      tg_s2: "Open your new bot and press Start (or add it to a group and write any message).",
      tg_s3: "Paste the token below and press \"Find chat ID\". Pick the chat, then Save.",
      tg_token: "Bot token", tg_token_saved: "Saved: {h} (leave empty to keep it)", tg_chat: "Chat ID", tg_find: "Find chat ID",
      tg_found: "Click a chat to use it:", tg_none: "No chats found yet. Send your bot a message in Telegram, then try again.",
      tg_test: "Send test message", tg_test_ok: "Test message sent. Check Telegram.", tg_saved: "Telegram saved. Alerts will be sent there.",
      tg_remove: "Disconnect", tg_confirm_remove: "Stop sending alerts to Telegram?", tg_removed: "Telegram disconnected",
      at_title: "Test the whole alert pipeline", at_text: "Fires a harmless test alert through Alertmanager. If Telegram is connected, the message arrives within about 30 seconds.",
      at_btn: "Send test alert", at_ok: "Test alert fired. Telegram gets it in about 30 seconds.",
      // rules
      rl_rule: "Rule", rl_enabled: "On", rl_threshold: "Threshold", rl_for: "Must last", rl_reset_confirm: "Restore every rule to its default threshold and switch all rules on?",
      rl_saved: "Rule saved and applied", rl_reset_ok: "Defaults restored",
      rn_InstanceDown: "Target down", rn_HighCpuUsage: "High CPU", rn_HighMemoryUsage: "High memory", rn_DiskSpaceLow: "Disk almost full",
      rn_DiskWillFillIn24h: "Disk will fill up", rn_HighLoad: "High load", rn_HostRebooted: "Server rebooted", rn_ContainerHighCpu: "Container: high CPU",
      rn_ContainerHighMemory: "Container: high memory", rn_EndpointDown: "Site or port down", rn_SslCertExpiringSoon: "SSL certificate expiring",
      rn_SlowEndpoint: "Slow site", sev_critical: "critical", sev_warning: "warning", sev_info: "info",
      rd_InstanceDown: "A monitored target (server, exporter or checker) stopped responding.",
      rd_HighCpuUsage: "CPU usage stays above the threshold.",
      rd_HighMemoryUsage: "Memory usage stays above the threshold.",
      rd_DiskSpaceLow: "A disk is fuller than the threshold.",
      rd_DiskWillFillIn24h: "At the current rate a disk runs out of space within this many hours.",
      rd_HighLoad: "Load average per CPU core is above the threshold.",
      rd_HostRebooted: "A server restarted within this many seconds.",
      rd_ContainerHighCpu: "A container uses more CPU than the threshold.",
      rd_ContainerHighMemory: "A container uses more of its memory limit than the threshold.",
      rd_EndpointDown: "A website or port check fails.",
      rd_SslCertExpiringSoon: "An SSL certificate expires in fewer days than the threshold.",
      rd_SlowEndpoint: "A website needs longer than this to respond.",
      // settings
      st_pw_title: "Change login", st_user: "Username", st_current: "Current password", st_new: "New password (8+ characters)", st_repeat: "Repeat new password",
      st_change: "Change login", st_mismatch: "The two passwords do not match", st_pw_ok: "Login changed. Other devices are signed out.",
      st_docker_title: "Docker access", st_docker_on: "Enabled", st_docker_off: "Off",
      st_docker_hint_on: "The panel uses the Docker socket only for its own monitoring stack: to show why a service stopped and to restart it from the “Find out why” page. Whoever can reach the socket is root on the server, so keep the password strong and put HTTPS in front of the panel.",
      st_docker_hint_off: "The panel cannot see the state of its own stack. To enable it, make sure the docker.sock mount in docker-compose.yml is present and PANEL_DOCKER_CONTROL is not 0, then run: docker compose up -d",
      st_docker_unavail: "Enabled in settings, but the Docker socket is not reachable.",
      st_about: "About", st_version: "Panel version",
    },
    fa: {
      title: "مانیتورینگ سرور", monitors: "مانیتورها", manage: "مدیریت", refresh: "بروزرسانی", logout: "خروج",
      lang_switch: "English", host: "سرور",
      cpu: "پردازنده", memory: "حافظه (رم)", disk: "دیسک", load: "میانگین بار",
      net_down: "دریافت شبکه", net_up: "ارسال شبکه", targets: "تارگت‌های فعال",
      websites: "چک‌های سالم", ssl: "انقضای SSL", alerts: "هشدارهای فعال", cores: "هسته", of: "از", days: "روز", running: "در حال اجرا",
      overview: "نمای کلی", websites_nav: "سایت‌ها", disks: "دیسک‌ها", network: "شبکه",
      targets_nav: "تارگت‌ها", alerts_nav: "هشدارها", servers_nav: "سرورها", notifications_nav: "اعلان‌ها",
      rules_nav: "قوانین هشدار", settings_nav: "تنظیمات",
      d_overview: "مصرف زنده‌ی منابع سرور انتخاب‌شده. نمودارها خودکار بروز می‌شوند.",
      d_websites: "سایت‌ها و پورت‌های TCP که آپتایم، زمان پاسخ و انقضای SSL‌شان چک می‌شود. از اینجا اضافه یا حذف کنید.",
      d_disks: "فایل‌سیستم‌های مونت‌شده و میزان پر بودن هرکدام.",
      d_network: "ترافیک کارت‌شبکه‌های واقعی (کارت‌های مجازی و داکر پنهان هستند).",
      d_servers: "سرورهایی که پردازنده، رم، دیسک و شبکه‌شان مانیتور می‌شود. برای نظارت بر سرور دیگر، آن را اضافه کنید.",
      d_notifications: "هشدارها کجا فرستاده شوند. یک ربات تلگرام وصل کنید تا هر مشکلی پیام بگیرید.",
      d_rules: "هشدار چه زمانی فعال شود. آستانه‌ها را عوض کنید، قانونی را خاموش کنید یا پیش‌فرض‌ها را برگردانید.",
      d_settings: "رمز پنل، دسترسی داکر و اطلاعات این نصب.",
      nx_nodata: "هنوز داده‌ی کارت شبکه نرسیده. نرخ‌ها حدود ۳۰ ثانیه داده می‌خواهند؛ اگر خالی ماند تب تارگت‌ها را ببینید.",
      nx_nojob: "اکسپورتر node-net در Prometheus نیست. install.sh را دوباره اجرا کنید یا بزنید: ⁦docker compose up -d⁩ && ⁦docker compose restart panel prometheus⁩",
      nx_down: "اکسپورتر node-net قطع است و کارت‌های شبکه خوانده نمی‌شوند. خطا:",
      d_targets: "همه‌ی چیزهایی که Prometheus از آن‌ها متریک می‌گیرد. تارگت قطع یعنی متریکش را نداریم.",
      d_alerts: "هشدارهایی که فعال هستند یا در شرف فعال شدن‌اند. زمان فعال شدنشان را در صفحه‌ی قوانین هشدار عوض کنید.",
      server: "سرور", range: "بازه", r1h: "یک ساعت اخیر", r6h: "۶ ساعت اخیر", r24h: "۲۴ ساعت اخیر", r7d: "۷ روز اخیر", rlive: "زنده (۵ دقیقه‌ی اخیر)",
      c_cpu: "مصرف پردازنده", c_mem: "مصرف حافظه", c_net: "ترافیک شبکه", c_load: "میانگین بار",
      rx: "دریافت", tx: "ارسال", no_data: "هنوز داده‌ای نیست", empty: "هنوز چیزی برای نمایش نیست.",
      name: "نام", cpu_h: "پردازنده", mem_h: "حافظه", uptime_h: "مدت اجرا", status: "وضعیت", target: "مقصد", type: "نوع",
      response: "پاسخ", http: "HTTP", ssl_h: "روز تا انقضای SSL", mount: "مسیر", device: "دستگاه", fs: "فایل‌سیستم",
      usage: "مصرف", used_total: "مصرف / کل", iface: "کارت شبکه", speed: "سرعت لینک", rate_in: "دریافت", rate_out: "ارسال", total_in: "کل دریافت", total_out: "کل ارسال",
      job: "گروه", instance: "نمونه", scrape: "زمان جمع‌آوری", error: "خطا", severity: "شدت", alert: "هشدار", summary: "خلاصه", state: "حالت", since: "از",
      s_running: "در حال اجرا", s_up: "فعال", s_down: "قطع", s_firing: "فعال", s_pending: "در انتظار", s_exited: "متوقف", s_paused: "مکث", s_created: "ساخته‌شده", s_restarting: "در حال ری‌استارت",
      no_alerts: "هشدار فعالی وجود ندارد. همه چیز سالم است.", host_online: "سرور آنلاین است",
      h_ok: "همه چیز سالم است", h_ok_sub: "سرور و تمام بررسی‌های شما عادی کار می‌کنند.", h_warn: "نیاز به توجه دارد", h_bad: "مشکل شناسایی شد",
      i_alerts: "{n} هشدار فعال", i_sites: "{n} بررسی سایت/پورت ناموفق است", i_targets: "{n} هدف مانیتورینگ پاسخ نمی‌دهد",
      i_res: "{what} بالا است ({v}٪)", i_pending: "{n} هشدار در آستانه‌ی فعال شدن", i_ssl: "گواهی SSL تا {n} روز دیگر منقضی می‌شود",
            net_ifaces: "کارت‌های شبکه", tr_title: "مصرف ترافیک", tr_sub: "دانلود و آپلود کارت‌های شبکه‌ی فیزیکی این سرور؛ دقیق از شمارنده‌های خود کارت شبکه و ماندگار (با ریبوت صفر نمی‌شود).",
      tr_day: "روز", tr_today: "امروز", tr_yesterday: "دیروز", tr_7d: "۷ روز اخیر", tr_month: "این ماه", tr_prev: "ماه قبل", tr_boot: "از زمان بوت", tr_total: "مجموع", tr_down: "دانلود", tr_up: "آپلود",
      tr_daily: "ترافیک روزانه", tr_peak_in: "اوج دانلود (۲۴ ساعت)", tr_peak_out: "اوج آپلود (۲۴ ساعت)", tr_partial: "فقط {d} داده جمع‌آوری شده است", tr_range: "از {a} تا {b}", tr_proj: "با همین روند تا آخر ماه حدود {v}", tr_incomplete: "ناقص: برای بعضی روزهایش داده‌ای نیست", tr_nodata_month: "برای این ماه داده‌ای نیست (پنل هنوز نصب نبود)", tr_months: "مجموع ماهانه", tr_alltime: "کل", tr_alltime_since: "از {d}، شروع شمارش", tr_boot_since: "آخرین بوت: {d}", tr_24h: "۲۴ ساعت", tr_hour: "ساعت", tr_24h_sum: "۲۴ ساعت اخیر: در مجموع {v} (دانلود {d}، آپلود {u})", tr_counted: "کارت‌های شمارش‌شده", tr_auto: "خودکار: فقط کارت‌های فیزیکی", tr_manual: "انتخاب خودتان", tr_choose: "انتخاب کارت‌ها", tr_dev_title: "کدام کارت‌های شبکه شمرده شوند؟", tr_dev_help: "فقط کارتی را بشمارید که دیتاسنتر ترافیکش را حساب می‌کند. تانل‌ها و VPN (وایرگارد، GRE و ...) ترافیکی دارند که از کارت فیزیکی هم رد می‌شود؛ شمردن هر دو، آن را دو بار حساب می‌کند. با تغییر این انتخاب، آمار گذشته هم دوباره حساب می‌شود.", tr_dev_auto: "خودکار: فقط کارت‌های فیزیکی (پیشنهادی)", tr_dev_manual: "انتخاب دستی", tr_physical: "فیزیکی", tr_virtual: "تانل / مجازی", tr_dev_month: "این ماه", tr_dev_none: "حداقل یک کارت را انتخاب کنید.", tr_updated: "شمارش دقیق از شمارنده‌های کارت شبکه · به‌روزرسانی {ago}", tr_preparing: "تاریخچه‌ی ترافیک این سرور برای اولین بار خوانده می‌شود؛ چند ثانیه‌ی دیگر آماده است.", tr_syncing: "در حال رسیدن به ترافیکِ زمانی که پنل خاموش بوده...", tr_month_col: "ماه", tr_month_sum: "{m}: در مجموع {v} (دانلود {d}، آپلود {u})",
            diag_btn: "پیدا کردن دلیل", dg_title: "چرا پنل داده‌ای نمی‌گیرد؟", diag_services: "سرویس‌ها", diag_containers: "کانتینرهای استک", diag_ok: "در دسترس", diag_fail: "خراب",
      diag_dns: "نام پیدا نشد", diag_http: "پاسخ درست نمی‌دهد", diag_detail: "جزئیات", diag_exit: "کد خروج", diag_restarts: "تعداد ری‌استارت", diag_logs: "آخرین خط‌های لاگ {s}", service: "سرویس",
      diag_all_ok: "همه‌ی سرویس‌ها الان جواب می‌دهند. این پنجره را ببندید و «بروزرسانی» را بزنید.",
      hint_stopped: "{service} در حال اجرا نیست: {detail}. با دکمه‌ی زیر ری‌استارتش کنید؛ آخرین خط‌های لاگ پایین‌تر دلیل متوقف شدنش را نشان می‌دهد.",
      hint_dns: "پنل اصلاً نام «{service}» را پیدا نمی‌کند ({detail}). DNS داخلی داکر جواب نمی‌دهد.",
      hint_svc: "{service} در دسترس است ولی درست جواب نمی‌دهد: {detail}",
      hint_disk: "دیسک {detail} پر است. وقتی جای خالی نباشد Prometheus از کار می‌افتد.",
      hint_dns_external: "DNS اینترنت هم کار نمی‌کند ({detail}). resolver سرور (⁦/etc/resolv.conf⁩) خراب است یا فایروال جلویش را گرفته و داکر از آن استفاده می‌کند.",
      lv_ok: "عادی", lv_warn: "بالا", lv_bad: "بحرانی", address: "آدرس", more: "بیشتر", tbl_view: "نمایش جدول", time: "زمان",
      err_api: "داده‌ها بارگذاری نشد", last_update: "آخرین بروزرسانی", auto: "بروزرسانی خودکار هر ۱۰ ثانیه", ago: "پیش",
      live_on: "زنده · بروزرسانی هر", live_every: "فاصله‌ی بروزرسانی عددهای زنده", live_sec: "{n} ثانیه", live_wait: "در حال اتصال به داده‌ی زنده…", live_waiting: "در انتظار داده‌ی زنده…", live_tag: "زنده",
      live_off_note: "داده‌ی زنده در دسترس نیست ({e})؛ برای همین یک ساعت اخیر نمایش داده می‌شود.", io_r: "خواندن", io_w: "نوشتن", swap: "Swap",
      t_dark: "تم روشن", t_light: "تم تیره",
      add: "افزودن", cancel: "انصراف", close: "بستن", save: "ذخیره", saved: "ذخیره شد", remove: "حذف", working: "در حال انجام…", copy: "کپی", copied: "کپی شد",
      confirm: "لطفاً تأیید کنید", actions: "عملیات", minutes: "دقیقه", added: "اضافه شد", removed: "حذف شد", reset_defaults: "بازگشت به پیش‌فرض",
      a_restart: "ری‌استارت", c_done: "انجام شد",
      c_docker_off: "دسترسی داکر خاموش است، پس وضعیت کانتینرهای استک را نمی‌شود نشان داد. برای فعال‌سازی سوکت داکر را مونت کنید (تنظیمات را ببینید).",
      add_site: "افزودن سایت یا پورت", type_http: "سایت (⁦HTTP / HTTPS⁩)", type_tcp: "پورت TCP", f_target: "آدرس", f_name_opt: "نام (اختیاری)",
      hint_http: "آدرس کامل، مثلاً https://example.com", hint_tcp: "host:port مثل 203.0.113.10:22 (SSH) یا db.internal:5432",
      probe: "آزمایش الان / چرا؟", probe_title: "نتیجه‌ی چک", probe_running: "در حال چک کردن…", probe_ok: "این چک همین الان از سرور موفق است.",
      probe_fail: "این چک از سرور ناموفق است.", probe_reason: "دلیل", probe_log: "جزئیات فنی", probe_status: "کد HTTP",
      probe_k_reset: "سایت (یا شبکه‌ی جلوی آن) اتصال را پذیرفت و وسط handshake قطعش کرد. این رفتار فایروال یا مسدودسازی جغرافیایی است: سایت برای شما باز می‌شود ولی IP این سرور را رد می‌کند.",
      probe_k_refused: "سرور پاسخ داد ولی روی آن پورت چیزی گوش نمی‌دهد (یا فایروال فعالانه رد می‌کند).",
      probe_k_dns: "سرور نمی‌تواند این نام دامنه را پیدا کند. املا و تنظیمات DNS سرور را بررسی کنید.",
      probe_k_timeout: "در زمان مقرر پاسخی نیامد. میزبان خاموش است یا فایروال بی‌صدا بسته‌های این سرور را دور می‌اندازد.",
      probe_k_tls: "گواهی سایت مشکل دارد: منقضی‌شده، برای دامنه‌ی دیگر یا از مرجع نامعتبر.",
      probe_k_unreachable: "این سرور مسیر شبکه‌ای به این آدرس ندارد.",
      probe_k_status: "سایت پاسخ داد ولی با کد خطا (4xx یا 5xx)، پس سالم حساب نمی‌شود.",
      probe_k_other: "چک به دلیل دیگری ناموفق بود؛ جزئیات فنی پایین را ببینید.",
      probe_k_handshake: "سایت اتصال امن را در مرحله‌ی ⁦TLS handshake⁩ رد کرد. علت‌های معمول: فقط نسخه‌ها یا رمزهای قدیمی TLS را می‌پذیرد، تنظیم گواهی⁦/SNI⁩ خراب است، یا فایروالش IP این سرور را رد می‌کند. جدول پایین گزینه‌های جایگزین را برایتان امتحان می‌کند.",
      v_legacy_tls: "پذیرش TLS قدیمی (۱.۰ / ۱.۱)", v_no_verify: "نادیده گرفتن خطای گواهی", v_legacy_no_verify: "TLS قدیمی و نادیده گرفتن خطای گواهی",
      v_plain_http: "HTTP ساده (بدون رمزنگاری)", v_tcp: "فقط اتصال به پورت (TCP)",
      diag_title: "چه چیزی از سرور کار می‌کند", diag_works: "کار می‌کند", diag_fails: "ناموفق", diag_apply: "مانیتور سایت با این حالت",
      diag_suggest: "سایت در حالتی که پایین علامت خورده موفق است. چک را روی آن بگذارید تا بدون هشدار اشتباه مانیتور شود.",
      diag_applied: "حالت چک عوض شد. وضعیت تا یک دقیقه‌ی دیگر بروز می‌شود.", mode_default: "استاندارد",
      mode_legacy_tls: "TLS قدیمی", mode_no_verify: "بدون بررسی گواهی", mode_legacy_no_verify: "TLS قدیمی، بدون بررسی گواهی",
      diag_blocked: "پورت اتصال را می‌پذیرد ولی همه‌ی حالت‌های امن رد می‌شوند: سایت یا فایروالش مشخصاً این سرور را رد می‌کند (معمول در مسدودسازی IP یا جغرافیایی).",
      diag_plain: "HTTP ساده کار می‌کند ولی هر تلاش امن (HTTPS) با هر حالت TLS رد می‌شود. سایت بالاست؛ بخش HTTPS آن این سرور را رد می‌کند. می‌توانید به‌جای آن روی HTTP ساده مانیتورش کنید (اگر آن آدرس به یک صفحه‌ی HTTPS ریدایرکت شود، گواهی همان صفحه همچنان چک می‌شود).",
      diag_use_http: "مانیتور روی HTTP ساده", diag_replaced: "حالا آدرس HTTP ساده مانیتور می‌شود.",
      diag_closed: "حتی اتصال ساده‌ی TCP هم ناموفق است: آدرس از این سرور در دسترس نیست (خاموش، پورت اشتباه یا مسدود).",
      auto_title: "رفع خودکار سایت‌های خراب",
      auto_text: "وقتی سایتی مدام ناموفق است، پنل راه‌های دیگر چک را امتحان می‌کند (TLS قدیمی، نادیده گرفتن خطای گواهی، صفحه‌ای که آدرس http:// به آن ریدایرکت می‌شود، HTTP ساده) و روی اولین راهی که کار کند می‌رود. چکِ سالم هرگز تغییر نمی‌کند. برای اینکه آدرس‌ها دقیقاً همان‌طور که وارد کردید بمانند، خاموشش کنید.",
      auto_on: "سایت‌های خراب را خودکار درست کن", auto_off_saved: "رفع خودکار خاموش شد", auto_on_saved: "رفع خودکار روشن شد",
      auto_log: "تنظیمات خودکار", auto_tag: "خودکار", auto_was: "قبلاً {from}",
      auto_ev_replace: "{from} حالا به‌صورت {to} مانیتور می‌شود", auto_ev_mode: "{from} حالا با این حالت چک می‌شود: {mode}", auto_ev_merge: "{from} حذف شد: {to} از قبل مانیتور می‌شود",
      auto_fix_btn: "رفع خودکار", auto_done: "انجام شد. وضعیت تا یک دقیقه‌ی دیگر بروز می‌شود.",
      auto_none: "راه بهتری پیدا نشد: هیچ راه دیگری برای چک این آدرس از سرور کار نمی‌کند.",
      added_auto: "اضافه شد. پنل خودکار بهترین راه مانیتور آن را انتخاب می‌کند.", redirects_to: "ریدایرکت می‌شود به",
      probe_hint: "اگر آدرس در مرورگر شما باز می‌شود ولی اینجا ناموفق است، احتمالاً IP سرور توسط سایت یا شبکه‌اش مسدود است (برای سایت‌های میزبانی‌شده در ایران وقتی سرور مانیتورینگ خارج از ایران است رایج است) یا سرور مسیری به آن ندارد. مانیتورینگ همان چیزی را نشان می‌دهد که «سرور» می‌بیند، نه آنچه شما می‌بینید.",
      s_wait: "در انتظار", w_confirm_remove: "نظارت بر {n} متوقف شود؟", w_hint: "موارد جدید تا تکمیل اولین چک (حدود یک دقیقه) «در انتظار» نشان داده می‌شوند.",
      add_server: "افزودن سرور", f_srv_addr: "آدرس سرور", f_srv_hint: "آی‌پی یا نام سرور همراه پورت ⁦node_exporter⁩، مثل 203.0.113.10:9100",
      srv_local: "همین سرور", srv_confirm_remove: "نظارت بر سرور {n} متوقف شود؟",
      srv_help_title: "چطور سرور دیگری را اضافه کنم",
      srv_help_1: "۱. روی سرور دیگر ⁦node_exporter⁩ را اجرا کنید (داکر لازم است):",
      srv_help_2: "۲. پورت 9100 را فقط برای همین سرور مانیتورینگ در فایروال آن سرور باز کنید، مثلاً:",
      srv_help_3: "۳. روی «افزودن سرور» بزنید و آدرسش را به شکل IP:9100 وارد کنید.",
      tg_title: "تلگرام", tg_ok: "متصل", tg_no: "تنظیم نشده", tg_bot: "ربات",
      tg_s1: "تلگرام را باز کنید، با @BotFather صحبت کنید، ⁦/newbot⁩ را بفرستید و توکنی که می‌دهد را کپی کنید.",
      tg_s2: "ربات جدیدتان را باز کنید و Start بزنید (یا آن را به گروه اضافه کنید و یک پیام بنویسید).",
      tg_s3: "توکن را پایین بچسبانید و «پیدا کردن ⁦Chat ID⁩» را بزنید. چت را انتخاب کنید و ذخیره کنید.",
      tg_token: "توکن ربات", tg_token_saved: "ذخیره‌شده: {h} (برای نگه داشتن خالی بگذارید)", tg_chat: "Chat ID", tg_find: "پیدا کردن ⁦Chat ID⁩",
      tg_found: "برای انتخاب روی یک چت بزنید:", tg_none: "هنوز چتی پیدا نشد. در تلگرام به ربات پیام بدهید و دوباره تلاش کنید.",
      tg_test: "ارسال پیام آزمایشی", tg_test_ok: "پیام آزمایشی فرستاده شد. تلگرام را ببینید.", tg_saved: "تلگرام ذخیره شد. هشدارها به آنجا می‌روند.",
      tg_remove: "قطع اتصال", tg_confirm_remove: "ارسال هشدار به تلگرام متوقف شود؟", tg_removed: "اتصال تلگرام قطع شد",
      at_title: "آزمایش کل مسیر هشدار", at_text: "یک هشدار آزمایشی بی‌خطر را از طریق Alertmanager می‌فرستد. اگر تلگرام وصل باشد، پیام تا حدود ۳۰ ثانیه می‌رسد.",
      at_btn: "ارسال هشدار آزمایشی", at_ok: "هشدار آزمایشی ارسال شد. تلگرام تا حدود ۳۰ ثانیه دیگر پیام می‌گیرد.",
      rl_rule: "قانون", rl_enabled: "روشن", rl_threshold: "آستانه", rl_for: "مدت پایداری", rl_reset_confirm: "همه‌ی قانون‌ها به آستانه‌ی پیش‌فرض برگردند و روشن شوند؟",
      rl_saved: "قانون ذخیره و اعمال شد", rl_reset_ok: "پیش‌فرض‌ها برگشتند",
      rn_InstanceDown: "تارگت قطع شده", rn_HighCpuUsage: "پردازنده‌ی بالا", rn_HighMemoryUsage: "حافظه‌ی بالا", rn_DiskSpaceLow: "دیسک تقریباً پر",
      rn_DiskWillFillIn24h: "دیسک به‌زودی پر می‌شود", rn_HighLoad: "بار زیاد", rn_HostRebooted: "سرور ری‌استارت شد", rn_ContainerHighCpu: "کانتینر: پردازنده‌ی بالا",
      rn_ContainerHighMemory: "کانتینر: حافظه‌ی بالا", rn_EndpointDown: "سایت یا پورت قطع", rn_SslCertExpiringSoon: "گواهی SSL رو به انقضا",
      rn_SlowEndpoint: "سایت کند", sev_critical: "بحرانی", sev_warning: "هشدار", sev_info: "اطلاع",
      rd_InstanceDown: "یکی از تارگت‌ها (سرور، اکسپورتر یا چک‌کننده) پاسخ نمی‌دهد.",
      rd_HighCpuUsage: "مصرف پردازنده مدتی بالاتر از آستانه می‌ماند.",
      rd_HighMemoryUsage: "مصرف رم مدتی بالاتر از آستانه می‌ماند.",
      rd_DiskSpaceLow: "یک دیسک بیشتر از آستانه پر شده است.",
      rd_DiskWillFillIn24h: "با روند فعلی، یک دیسک تا این تعداد ساعت دیگر پر می‌شود.",
      rd_HighLoad: "میانگین بار به ازای هر هسته بالاتر از آستانه است.",
      rd_HostRebooted: "یک سرور در این تعداد ثانیه‌ی اخیر ری‌استارت شده است.",
      rd_ContainerHighCpu: "یک کانتینر بیشتر از آستانه پردازنده مصرف می‌کند.",
      rd_ContainerHighMemory: "یک کانتینر بیشتر از آستانه‌ی سقف رم خودش مصرف می‌کند.",
      rd_EndpointDown: "چک یک سایت یا پورت ناموفق است.",
      rd_SslCertExpiringSoon: "گواهی SSL کمتر از این تعداد روز اعتبار دارد.",
      rd_SlowEndpoint: "پاسخ یک سایت بیشتر از این زمان طول می‌کشد.",
      st_pw_title: "تغییر اطلاعات ورود", st_user: "نام کاربری", st_current: "رمز فعلی", st_new: "رمز جدید (حداقل ۸ نویسه)", st_repeat: "تکرار رمز جدید",
      st_change: "تغییر اطلاعات ورود", st_mismatch: "دو رمز یکسان نیستند", st_pw_ok: "اطلاعات ورود عوض شد. دستگاه‌های دیگر خارج شدند.",
      st_docker_title: "دسترسی داکر", st_docker_on: "فعال", st_docker_off: "خاموش",
      st_docker_hint_on: "پنل از سوکت داکر فقط برای استک مانیتورینگ خودش استفاده می‌کند: نشان دادن دلیل متوقف شدن یک سرویس و ری‌استارت آن از صفحه‌ی «پیدا کردن دلیل». هر کسی به این سوکت برسد روی سرور root است؛ پس رمز قوی بگذارید و جلوی پنل HTTPS قرار دهید.",
      st_docker_hint_off: "پنل وضعیت کانتینرهای استک خودش را نمی‌بیند. برای فعال‌سازی، مطمئن شوید مونت docker.sock در docker-compose.yml هست و ⁦PANEL_DOCKER_CONTROL⁩ برابر 0 نیست، سپس بزنید: ⁦docker compose up -d⁩",
      st_docker_unavail: "در تنظیمات فعال است ولی سوکت داکر در دسترس نیست.",
      st_about: "درباره", st_version: "نسخه‌ی پنل",
    },
  };
  // ---------------------------------------------------------------- state
  const store = {
    get(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* storage blocked */ } },
  };
  const state = {
    lang: T[store.get("lang", "en")] ? store.get("lang", "en") : "en",
    theme: document.documentElement.dataset.theme === "light" ? "light" : "dark",   // set by boot.js before the first paint
    range: store.get("range", "live"),
    instance: store.get("instance", ""),
    liveEvery: [1, 3, 5, 10].includes(+store.get("live_every", "1")) ? +store.get("live_every", "1") : 1,
    instances: [],
    names: {},
    view: "overview",
    overview: null,
    settings: null,
    renderId: 0,
  };
  const t = (k, vars) => {
    let s = T[state.lang][k] ?? T.en[k] ?? k;
    if (vars) for (const [a, b] of Object.entries(vars)) s = s.replace(`{${a}}`, b);
    return s;
  };

  // ---------------------------------------------------------------- helpers
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const nf = (n, d = 1) => (n == null ? "–" : Number(n).toLocaleString("en-US", { maximumFractionDigits: d, minimumFractionDigits: 0 }));
  const num = (html) => `<span class="num">${html}</span>`;

  function fmtBytes(n) {
    if (n == null) return "–";
    const u = ["B", "KB", "MB", "GB", "TB", "PB"];
    let i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return `${nf(n, n >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
  }
  const fmtRate = (n) => (n == null ? "–" : `${fmtBytes(n)}/s`);
  function fmtDur(s) {
    if (s == null) return "–";
    s = Math.floor(s);
    const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    if (d) return `${d}d ${h}h`;
    if (h) return `${h}h ${m}m`;
    return m ? `${m}m ${s % 60}s` : `${s % 60}s`;
  }
  const fmtMs = (s) => (s == null ? "–" : s < 1 ? `${nf(s * 1000, 0)} ms` : `${nf(s, 2)} s`);
  const level = (pct) => (pct >= 90 ? "bad" : pct >= 75 ? "warn" : "");
  function ago(unixOrIso) {
    const ts = typeof unixOrIso === "number" ? unixOrIso : Date.parse(unixOrIso) / 1000;
    if (!ts) return "–";
    return `${fmtDur(Date.now() / 1000 - ts)} ${t("ago")}`;
  }

  const P = {
    logo: '<path d="M12 3l8 3v6c0 4.6-3.2 7.9-8 9.8C7.2 19.9 4 16.6 4 12V6l8-3z"/><path d="M8 12h2.5l1.5-3 2 6 1.5-3H17"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    moon: '<path d="M21 13.5A8.5 8.5 0 1110.5 3a6.5 6.5 0 0010.5 10.5z"/>',
    globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.3 3 14.7 0 18M12 3c-3 3.3-3 14.7 0 18"/>',
    refresh: '<path d="M20 11a8 8 0 10-2.3 5.7M20 4v7h-7"/>',
    logout: '<path d="M9 4H5a1 1 0 00-1 1v14a1 1 0 001 1h4M16 8l4 4-4 4M20 12H9"/>',
    cpu: '<rect x="5" y="5" width="14" height="14" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>',
    memory: '<rect x="2" y="7" width="20" height="10" rx="2"/><path d="M6 11v2M10 11v2M14 11v2M18 11v2M6 17v2M10 17v2M14 17v2M18 17v2"/>',
    disk: '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    activity: '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
    down: '<path d="M12 4v12M6 11l6 6 6-6M5 21h14"/>',
    up: '<path d="M12 20V8M6 13l6-6 6 6M5 3h14"/>',
    box: '<path d="M21 8l-9-5-9 5v8l9 5 9-5V8z"/><path d="M3 8l9 5 9-5M12 13v8"/>',
    check: '<circle cx="12" cy="12" r="9"/><path d="M8 12.5l2.7 2.7L16 9.5"/>',
    lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/>',
    bell: '<path d="M18 16v-5a6 6 0 10-12 0v5l-2 2h16l-2-2zM10 21h4"/>',
    server: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    network: '<circle cx="12" cy="5" r="2.2"/><circle cx="5" cy="19" r="2.2"/><circle cx="19" cy="19" r="2.2"/><path d="M12 7.2v4M12 11.2L5.5 16.8M12 11.2l6.5 5.6"/>',
    grid: '<rect x="3" y="3" width="8" height="8" rx="2"/><rect x="13" y="3" width="8" height="5" rx="2"/><rect x="13" y="10" width="8" height="11" rx="2"/><rect x="3" y="13" width="8" height="8" rx="2"/>',
    okmark: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a1 1 0 001 1h8a1 1 0 001-1l1-12M9 7V4h6v3"/>',
    play: '<path d="M7 4.5v15l12-7.5-12-7.5z"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    file: '<path d="M14 3H7a1 1 0 00-1 1v16a1 1 0 001 1h10a1 1 0 001-1V8l-4-5z"/><path d="M14 3v5h5M9 13h6M9 17h6"/>',
    send: '<path d="M21 3L10 14M21 3l-7 18-4-7-7-4 18-7z"/>',
    sliders: '<path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1"/>',
    search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l5 5"/>',
    x: '<path d="M6 6l12 12M18 6L6 18"/>',
    shield: '<path d="M12 3l8 3v6c0 4.6-3.2 7.9-8 9.8C7.2 19.9 4 16.6 4 12V6l8-3z"/><path d="M8.5 12.2l2.4 2.4 4.6-4.8"/>',
    alert: '<path d="M12 3.6l9.4 16.4H2.6L12 3.6z"/><path d="M12 10v4.4M12 17.4h.01"/>',
    octagon: '<path d="M8.2 3h7.6L21 8.2v7.6L15.8 21H8.2L3 15.8V8.2L8.2 3z"/><path d="M9.2 9.2l5.6 5.6M14.8 9.2l-5.6 5.6"/>',
    dots: '<circle cx="5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="19" cy="12" r="1.3"/>',
    table: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M9 4v16"/>',
    copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 00-1-1H5a1 1 0 00-1 1v10a1 1 0 001 1h3"/>',
  };
  const icon = (name) => `<svg class="ico" viewBox="0 0 24 24" aria-hidden="true">${P[name]}</svg>`;

  async function api(path, params = {}) {
    const qs = new URLSearchParams(params).toString();
    const r = await fetch(path + (qs ? `?${qs}` : ""), { credentials: "same-origin", cache: "no-store" });
    if (r.status === 401) { location.replace("/login"); throw new Error("unauthorized"); }
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || `HTTP ${r.status}`);
    return body;
  }
  async function post(path, body = {}) {
    const r = await fetch(path, {
      method: "POST", credentials: "same-origin", cache: "no-store",
      headers: { "Content-Type": "application/json", "X-Panel": "1" }, body: JSON.stringify(body),
    });
    if (r.status === 401) { location.replace("/login"); throw new Error("unauthorized"); }
    const data = await r.json().catch(() => ({}));
    if (!r.ok) { const e = new Error(data.error || `HTTP ${r.status}`); e.saved = !!data.saved; throw e; }
    return data;
  }
  const withInstance = (extra = {}) => (state.instance ? { instance: state.instance, ...extra } : extra);

  // ---------------------------------------------------------------- toasts, dialogs, small UI helpers
  function toast(message, kind = "") {
    const el = document.createElement("div");
    el.className = `toast ${kind}`;
    el.setAttribute("role", kind === "bad" ? "alert" : "status");
    el.textContent = message;
    const box = $("toasts");
    box.appendChild(el);
    while (box.children.length > 4) box.firstChild.remove();   // never pile up a long stack
    setTimeout(() => el.remove(), kind ? 8000 : 4000);
  }

  function openDialog(o) {
    const dlg = document.createElement("dialog");
    dlg.className = `modal${o.wide ? " wide" : ""}`;
    dlg.innerHTML = `<form class="modal-form">
      <header><h3>${esc(o.title)}</h3><button type="button" class="btn small icon ghost" data-close aria-label="${esc(t("close"))}">${icon("x")}</button></header>
      <div class="modal-body">${o.body}</div>
      <div class="form-error" role="alert"></div>
      <footer><button type="button" class="btn" data-close>${esc(o.cancel || t("cancel"))}</button>${o.hideSubmit ? "" : `<button type="submit" class="btn ${o.danger ? "danger solid" : "primary"}">${esc(o.submit || t("save"))}</button>`}</footer>
    </form>`;
    const form = dlg.querySelector("form"), err = dlg.querySelector(".form-error"), submitBtn = dlg.querySelector('[type="submit"]');
    dlg.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", () => dlg.close()));
    dlg.addEventListener("close", () => dlg.remove());
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      err.textContent = "";
      if (!o.onSubmit) { dlg.close(); return; }
      const label = submitBtn.textContent;
      submitBtn.disabled = true;
      submitBtn.textContent = o.busy || t("working");
      try { await o.onSubmit(form, dlg); dlg.close(); }
      catch (x) { if (x.message !== "unauthorized") err.textContent = x.message; }
      finally { submitBtn.disabled = false; submitBtn.textContent = label; }
    });
    document.body.appendChild(dlg);
    dlg.showModal();
    if (o.onOpen) o.onOpen(dlg, form);
    return dlg;
  }

  function confirmBox({ message, label, danger = true }) {
    return new Promise((resolve) => {
      let answered = false;
      const dlg = openDialog({
        title: t("confirm"), body: `<p>${esc(message)}</p>`, submit: label, danger,
        onSubmit: async () => { answered = true; resolve(true); },
      });
      dlg.addEventListener("close", () => { if (!answered) resolve(false); });
    });
  }

  // Runs an action on a button: disables it, reports errors as toasts, optionally confirms success.
  async function act(btn, fn, okMessage) {
    if (btn) btn.disabled = true;
    try {
      const result = await fn();
      if (okMessage) toast(okMessage);
      return result ?? true;
    } catch (e) {
      if (e.message !== "unauthorized") toast(e.message, e.saved ? "warn" : "bad");
      return null;
    } finally { if (btn) btn.disabled = false; }
  }

  function copyText(text) {
    // navigator.clipboard only exists on HTTPS/localhost; the panel is often served over plain HTTP.
    const ta = document.createElement("textarea");
    ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.appendChild(ta); ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { /* ignore */ }
    ta.remove();
    toast(ok ? t("copied") : text, ok ? "" : "warn");
  }

  // ---------------------------------------------------------------- chrome (header, nav)
  const VIEWS = [
    { id: "overview", icon: "grid", label: "overview", desc: "d_overview", group: "monitor" },
    { id: "websites", icon: "globe", label: "websites_nav", desc: "d_websites", group: "monitor" },
    { id: "disks", icon: "disk", label: "disks", desc: "d_disks", group: "monitor" },
    { id: "network", icon: "network", label: "network", desc: "d_network", group: "monitor" },
    { id: "targets", icon: "check", label: "targets_nav", desc: "d_targets", group: "monitor" },
    { id: "alerts", icon: "bell", label: "alerts_nav", desc: "d_alerts", group: "monitor" },
    { id: "servers", icon: "server", label: "servers_nav", desc: "d_servers", group: "manage" },
    { id: "notifications", icon: "send", label: "notifications_nav", desc: "d_notifications", group: "manage", static: true },
    { id: "rules", icon: "sliders", label: "rules_nav", desc: "d_rules", group: "manage", static: true },
    { id: "settings", icon: "gear", label: "settings_nav", desc: "d_settings", group: "manage", static: true },
  ];

  function applyLocale() {
    document.documentElement.lang = state.lang;
    document.documentElement.dir = state.lang === "fa" ? "rtl" : "ltr";
    document.documentElement.dataset.theme = state.theme;
    document.title = t("title");
    document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
    $("logo").innerHTML = icon("logo");
    $("top-logo").innerHTML = icon("logo");
    $("theme").innerHTML = icon(state.theme === "dark" ? "sun" : "moon");
    $("theme").setAttribute("aria-label", state.theme === "dark" ? t("t_dark") : t("t_light"));
    $("theme").title = $("theme").getAttribute("aria-label");
    $("lang").innerHTML = `${icon("globe")}<span class="txt">${esc(t("lang_switch"))}</span>`;
    $("refresh").innerHTML = `${icon("refresh")}<span class="txt">${esc(t("refresh"))}</span>`;
    $("logout").innerHTML = `${icon("logout")}<span class="txt">${esc(t("logout"))}</span>`;
    for (const id of ["lang", "refresh", "logout"]) $(id).title = $(id).textContent.trim();
    document.querySelector('meta[name="theme-color"]').setAttribute("content", state.theme === "dark" ? "#070b12" : "#eef2f8");
    renderNav();
  }

  function badgeFor(id) {
    const o = state.overview, s = state.settings;
    if (id === "notifications") return s && !s.telegram.configured ? '<span class="badge bad">!</span>' : "";
    if (id === "servers") return state.instances.length ? `<span class="badge">${state.instances.length}</span>` : "";
    if (!o) return "";
    if (id === "websites") return o.checks.total ? `<span class="badge${o.checks.up < o.checks.total ? " bad" : ""}">${o.checks.up}/${o.checks.total}</span>` : "";
    if (id === "targets") return `<span class="badge${o.targets.up < o.targets.total ? " bad" : ""}">${o.targets.up}/${o.targets.total}</span>`;
    if (id === "alerts") return o.alerts.firing ? `<span class="badge bad">${o.alerts.firing}</span>` : "";
    return "";
  }
  const TAB_IDS = ["overview", "websites", "network", "alerts"];   // the rest live behind "More" on phones
  function renderNav() {
    const link = (v) => `<a href="#${v.id}" class="${v.id === state.view ? "active" : ""}" ${v.id === state.view ? 'aria-current="page"' : ""} title="${esc(t(v.label))}">${icon(v.icon)}<span class="name">${esc(t(v.label))}</span>${badgeFor(v.id)}</a>`;
    $("nav").innerHTML = VIEWS.filter((v) => v.group === "monitor").map(link).join("");
    $("nav-manage").innerHTML = VIEWS.filter((v) => v.group === "manage").map(link).join("");
    const cur = VIEWS.find((v) => v.id === state.view) || VIEWS[0];
    $("page-title").textContent = t(cur.label);
    const firing = state.overview ? state.overview.alerts.firing : 0;
    const tab = (v) => `<button type="button" data-go="${v.id}" class="${v.id === state.view ? "active" : ""}" ${v.id === state.view ? 'aria-current="page"' : ""}>${icon(v.icon)}<span class="lbl">${esc(t(v.label))}</span>${v.id === "alerts" && firing ? `<span class="dot">${firing}</span>` : ""}</button>`;
    $("tabbar").innerHTML = TAB_IDS.map((id) => tab(VIEWS.find((v) => v.id === id))).join("")
      + `<button type="button" data-more class="${TAB_IDS.includes(cur.id) ? "" : "active"}">${icon("dots")}<span class="lbl">${esc(t("more"))}</span></button>`;
  }

  // Phones: every view that has no tab sits in a bottom sheet.
  function moreSheet() {
    const dlg = document.createElement("dialog");
    dlg.className = "sheet";
    dlg.innerHTML = `<div class="sheet-card"><h3>${esc(t("more"))}</h3><div class="sheet-grid">${VIEWS.filter((v) => !TAB_IDS.includes(v.id)).map((v) =>
      `<button type="button" data-go="${v.id}" class="${v.id === state.view ? "active" : ""}">${icon(v.icon)}<span>${esc(t(v.label))}</span></button>`).join("")}</div></div>`;
    dlg.addEventListener("click", (e) => { if (e.target === dlg || e.target.closest("[data-go]")) dlg.close(); });
    dlg.addEventListener("close", () => dlg.remove());
    document.body.appendChild(dlg);
    dlg.showModal();
  }

  // ---------------------------------------------------------------- live stream (one sample a second, see live.py)
  // Prometheus answers for history and for everything else; the gauges, tiles, network rates and the
  // "Live" chart range come from /api/live, which the panel reads from node_exporter every second.
  const LIVE_KEEP = 300;
  state.live = { status: "off", error: "", samples: [], es: null, instance: null, retry: 0 };
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const liveWanted = () => !document.hidden && ["overview", "network", "defender"].includes(state.view);
  function liveNow() {
    const L = state.live, s = L.samples[L.samples.length - 1];
    return L.status === "live" && s && Date.now() / 1000 - s.t < Math.max(8, state.liveEvery * 2.5) ? s : null;
  }
  function stopLive() {
    const L = state.live;
    clearTimeout(L.retry);
    if (L.es) { L.es.close(); L.es = null; }
    if (L.status !== "error") L.status = "off";
  }
  function startLive() {
    const L = state.live, inst = state.instance || "";
    if (!liveWanted() || !window.EventSource) { stopLive(); paintFoot(); return; }
    if (L.es && L.instance === inst) return;
    stopLive();
    if (L.instance !== inst) L.samples = [];
    L.instance = inst;
    L.status = "wait";
    L.startedAt = Date.now();
    const last = L.samples[L.samples.length - 1];
    const q = new URLSearchParams({ ...(inst ? { instance: inst } : {}), ...(last ? { since: String(last.t) } : {}), every: String(state.liveEvery) });
    const es = new EventSource(`/api/live?${q}`);
    L.es = es;
    es.addEventListener("s", (e) => {
      const batch = JSON.parse(e.data), top = L.samples.length ? L.samples[L.samples.length - 1].t : 0;
      for (const s of batch) if (s.t > top) L.samples.push(s);
      if (L.samples.length > LIVE_KEEP) L.samples.splice(0, L.samples.length - LIVE_KEEP);
      L.status = "live";
      L.error = "";
      beat();
      schedulePaint();
    });
    es.addEventListener("status", (e) => {
      L.error = JSON.parse(e.data).error || "";
      if (L.error) L.status = "error";
      else if (L.status === "error") L.status = "wait";
      schedulePaint();
    });
    es.onerror = () => {
      if (es.readyState === EventSource.CLOSED) {   // refused (unknown server, Prometheus down, logged out)
        if (L.es === es) L.es = null;
        L.status = "error";
        clearTimeout(L.retry);
        L.retry = setTimeout(startLive, 15000);
      } else if (L.status === "live") L.status = "wait";   // dropped; the browser reconnects by itself
      schedulePaint();
    };
    paintFoot();
  }
  let paintQueued = false;
  function schedulePaint() {   // next frame; the timer covers windows where frames are paused (e.g. an embedded, covered view)
    if (paintQueued) return;
    paintQueued = true;
    let done = false;
    const run = () => { if (done) return; done = true; paintQueued = false; paintLive(); };
    requestAnimationFrame(run);
    setTimeout(run, 250);
  }
  function paintLive() {
    paintFoot();
    if (state.view === "overview") {
      paintStats();
      if (state.range === "live") paintLiveCharts();
    } else if (state.view === "network") paintNetLive();
  }
  function beat() {
    const p = document.querySelector(".live .pulse");
    if (!p || reduceMotion.matches) return;
    p.classList.remove("beat");
    void p.offsetWidth;   // restart the animation
    p.classList.add("beat");
  }
  function paintFoot() {
    const L = state.live, box = document.querySelector(".live"), el = $("foot");
    const on = L.status === "live" && liveWanted(), wait = L.status === "wait" && liveWanted();
    box.classList.toggle("is-live", on);
    box.classList.toggle("is-wait", wait);
    const at = state.lastUpdate ? state.lastUpdate.toLocaleTimeString([], { hour12: false }) : "";
    el.textContent = on ? t("live_on") : wait ? t("live_wait") : `${t("last_update")}: ${at} · ${t("auto")}`;
    box.title = L.status === "error" && L.error ? L.error : "";
    const sel = $("live-every");
    sel.hidden = !on;
    const opts = [1, 3, 5, 10].map((n) => `<option value="${n}"${n === state.liveEvery ? " selected" : ""}>${esc(t("live_sec", { n: nf(n, 0) }))}</option>`).join("");
    if (sel._html !== opts) { sel._html = opts; sel.innerHTML = opts; sel.setAttribute("aria-label", t("live_every")); }
  }

  // Numbers jump straight to their new value (2 -> 4, never 2, 3, 4); the HTML is only touched when it changed.
  function tween(el, to, render) {
    if (!el) return;
    const bad = to == null || (Array.isArray(to) && to.some((x) => x == null));
    el._shown = bad ? null : to;
    const html = render(to);
    if (el._html !== html) { el._html = html; el.innerHTML = html; }
  }
  const setHTML = (el, html) => { if (el && el._html !== html) { el._html = html; el.innerHTML = html; } };

  // ---------------------------------------------------------------- overview: health hero, gauges, tiles
  state.hist = {};
  const SPARK_W = 120, SPARK_H = 34, SPARK_LIVE = 120;
  function sparkline(points, color) {
    const pts = (points || []).filter((p) => p[1] != null);
    if (pts.length < 2) return "";
    const xs = pts.map((p) => p[0]), vs = pts.map((p) => p[1]);
    const x0 = Math.min(...xs), x1 = Math.max(...xs), lo = Math.min(...vs), hi = Math.max(...vs), pad = (hi - lo) * 0.18 || 1;
    const X = (ts) => ((ts - x0) / Math.max(1, x1 - x0)) * SPARK_W;
    const Y = (v) => 4 + (1 - (v - (lo - pad * 0.2)) / (hi - lo + pad * 1.2)) * (SPARK_H - 8);
    const d = pts.map((p, i) => `${i ? "L" : "M"}${X(p[0]).toFixed(1)},${Y(p[1]).toFixed(1)}`).join("");
    const last = pts[pts.length - 1];
    return `<svg viewBox="0 0 ${SPARK_W} ${SPARK_H}" preserveAspectRatio="none" aria-hidden="true"><path d="${d}L${SPARK_W},${SPARK_H}L0,${SPARK_H}Z" fill="${color}" opacity=".11"/><path d="${d}" fill="none" stroke="${color}" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round" stroke-linecap="round"/></svg><i class="sd" style="top:${Y(last[1]).toFixed(1)}px;background:${color}"></i>`;
  }
  const memPctOf = (s) => (s.mem && s.mem[1] ? (s.mem[0] / s.mem[1]) * 100 : null);
  const LIVE_PICK = { cpu: [(s) => s.cpu], mem: [memPctOf], net: [(s) => s.rx, (s) => s.tx] };
  function sparkPoints(key, idx) {
    if (liveNow() && state.live.samples.length >= 2) return state.live.samples.slice(-SPARK_LIVE).map((s) => [s.t, LIVE_PICK[key][idx](s)]);
    return ((state.hist[key] || [])[idx] || {}).points;
  }
  const sparkBox = (key, idx, color) => `<div class="spark" data-spark="${key}" data-idx="${idx}" data-color="${color}">${sparkline(sparkPoints(key, idx), `var(${color})`)}</div>`;
  function refreshSparks() {
    document.querySelectorAll("[data-spark]").forEach((el) => setHTML(el, sparkline(sparkPoints(el.dataset.spark, +el.dataset.idx), `var(${el.dataset.color})`)));
  }

  function health(o, memPct) {
    const issues = [];
    let sev = 0;
    const bump = (n, msg) => { issues.push(msg); sev = Math.max(sev, n); };
    if (o.alerts.firing) bump(2, t("i_alerts", { n: o.alerts.firing }));
    if (o.checks.total > o.checks.up) bump(2, t("i_sites", { n: o.checks.total - o.checks.up }));
    if (o.targets.total > o.targets.up) bump(2, t("i_targets", { n: o.targets.total - o.targets.up }));
    for (const [what, v] of [[t("cpu"), o.cpu], [t("memory"), memPct], [t("disk"), o.disk ? o.disk.pct : null]]) {
      if (v == null) continue;
      if (v >= 90) bump(2, t("i_res", { what, v: nf(v, 0) }));
      else if (v >= 75) bump(1, t("i_res", { what, v: nf(v, 0) }));
    }
    if (o.alerts.pending) bump(1, t("i_pending", { n: o.alerts.pending }));
    const ssl = o.checks.min_ssl_days;
    if (ssl != null && ssl < 14) bump(ssl < 7 ? 2 : 1, t("i_ssl", { n: nf(ssl, 0) }));
    return { sev, issues };
  }

  // The overview numbers: Prometheus' snapshot, with this second's live sample on top when there is one.
  function merged() {
    const o = state.overview;
    if (!o) return null;
    const s = liveNow();
    if (!s) return o;
    return {
      ...o,
      cpu: s.cpu ?? o.cpu,
      mem: s.mem ? { used: s.mem[0], total: s.mem[1] } : o.mem,
      load: s.load && s.load[0] != null ? s.load : o.load,
      net: { rx: s.rx ?? o.net.rx, tx: s.tx ?? o.net.tx },
      disk: s.disk ? { ...(o.disk || {}), ...s.disk, pct: (s.disk.used / s.disk.total) * 100 } : o.disk,
      io: s.io,
    };
  }

  const RING_C = 2 * Math.PI * 42;
  const ringSvg = () => `<svg viewBox="0 0 104 104" aria-hidden="true"><circle class="track" cx="52" cy="52" r="42" fill="none" stroke-width="10"/><circle class="fill" cx="52" cy="52" r="42" fill="none" stroke-width="10" stroke-dasharray="0 ${RING_C.toFixed(1)}"/></svg>`;
  const LVL = { "": "lv_ok", warn: "lv_warn", bad: "lv_bad" };
  function gauge({ k, label, ic, go = "", spark = "" }) {
    return `<div class="card stat gauge" data-g="${k}" ${go ? `data-go="${go}" role="link" tabindex="0"` : ""}>
      <div class="ring">${ringSvg()}<div class="center"><span class="value num">–</span></div></div>
      <div class="g-title">${icon(ic)}${esc(label)}</div>
      <div class="g-main"></div>
      <div class="sub"><span class="lvl"></span><span class="g-sub"></span></div>
      ${spark}
    </div>`;
  }
  function tile({ k, label, ic, go = "", tight = false, spark = "" }) {
    return `<div class="card stat" data-t="${k}" ${go ? `data-go="${go}" role="link" tabindex="0"` : ""}><div class="label">${icon(ic)}${esc(label)}</div><div class="value${tight ? " tight" : ""}"></div><div class="sub" hidden></div>${spark}</div>`;
  }
  const pctHTML = (v) => (v == null ? "–" : `${nf(v, 0)}<small>%</small>`);
  function setGauge(k, pct, main, sub) {
    const g = document.querySelector(`[data-g="${k}"]`);
    if (!g) return;
    const lv = pct == null ? "" : level(pct);
    if (g._lv !== lv) {
      g._lv = lv;
      g.classList.remove("warn", "bad");
      g.querySelector(".ring").classList.remove("warn", "bad");
      if (lv) { g.classList.add(lv); g.querySelector(".ring").classList.add(lv); }
      g.querySelector(".lvl").textContent = t(LVL[lv]);
    }
    const v = Math.min(100, Math.max(0, pct || 0));
    g.querySelector(".fill").setAttribute("stroke-dasharray", `${((RING_C * v) / 100).toFixed(1)} ${RING_C.toFixed(1)}`);
    tween(g.querySelector(".value"), pct, pctHTML);
    setHTML(g.querySelector(".g-main"), main);
    setHTML(g.querySelector(".g-sub"), sub ? `<br>${sub}` : "");
  }
  const tileEl = (k) => document.querySelector(`[data-t="${k}"] .value`);

  // Built once per language / theme / server; after that only the values change (paintStats).
  function statsShape(o) {
    const ip = o.public_ip || {};
    return [state.lang, state.theme, state.instance, o.host.name, o.host.os, o.host.cores, o.host.cpu_model, ip.v4, ip.v6, ip.disabled, ip.checked].join("|");
  }
  function buildStats(o) {
    const ip = o.public_ip || {};
    const local = !state.instance || state.instance === "node-exporter:9100";
    const ipChip = (label, v, wait) => `<button type="button" class="chip copy${v ? "" : " off"}" ${v ? `data-copy="${esc(v)}" title="${esc(t("copy"))}"` : "disabled"}><b class="ipl">${label}</b>${num(esc(v || (wait ? "…" : "–")))}</button>`;
    const addr = state.instance ? state.instance.replace(/:\d+$/, "") : "";
    const chips = [
      local ? (ip.disabled ? "" : ipChip("IPv4", ip.v4, !ip.checked) + ipChip("IPv6", ip.v6, !ip.checked))
        : addr ? ipChip(t("address"), addr, false) : "",
      o.host.name ? `<span class="chip">${icon("server")}<b>${num(esc(o.host.name))}</b></span>` : "",
      o.host.os ? `<span class="chip">${num(esc(o.host.os))}</span>` : "",
      o.host.cores != null ? `<span class="chip">${icon("cpu")}<b>${num(nf(o.host.cores, 0))}</b> ${esc(t("cores"))}</span>` : "",
    ].join("");
    const hero = `<section class="card hero"><div class="hero-icon"></div>
      <div class="hero-text"><h2 aria-live="polite"></h2><p></p></div>
      <div class="hero-meta">${chips}</div></section>`;
    const gauges = [
      gauge({ k: "cpu", label: t("cpu"), ic: "cpu", spark: sparkBox("cpu", 0, "--c1") }),
      gauge({ k: "mem", label: t("memory"), ic: "memory", spark: sparkBox("mem", 0, "--c3") }),
      gauge({ k: "disk", label: t("disk"), ic: "disk", go: "disks" }),
    ].join("");
    const tiles = [
      tile({ k: "rx", label: t("net_down"), ic: "down", go: "network", spark: sparkBox("net", 0, "--c1") }),
      tile({ k: "tx", label: t("net_up"), ic: "up", go: "network", spark: sparkBox("net", 1, "--c2") }),
      tile({ k: "load", label: t("load"), ic: "activity", tight: true }),
      tile({ k: "targets", label: t("targets"), ic: "check", go: "targets" }),
      tile({ k: "checks", label: t("websites"), ic: "globe", go: "websites" }),
      tile({ k: "ssl", label: t("ssl"), ic: "lock", go: "websites" }),
      tile({ k: "alerts", label: t("alerts"), ic: "bell", go: "alerts" }),
    ].join("");
    $("stats").innerHTML = `${hero}<div class="gauges">${gauges}</div><div class="tiles">${tiles}</div>`;
  }

  state.statsShape = null;
  function paintStats() {
    const o = merged();
    if (!o || $("stats").hidden) return;
    const shape = statsShape(o);
    if (shape !== state.statsShape) { state.statsShape = shape; buildStats(o); }
    const memPct = o.mem.total ? (o.mem.used / o.mem.total) * 100 : null;
    const d = o.disk;
    const { sev, issues } = health(o, memPct);
    const hero = document.querySelector("#stats .hero");
    if (hero._sev !== sev) {
      hero._sev = sev;
      hero.classList.remove("warn", "bad");
      if (sev) hero.classList.add(["", "warn", "bad"][sev]);
      hero.querySelector(".hero-icon").innerHTML = icon(["shield", "alert", "octagon"][sev]);
    }
    setHTML(hero.querySelector("h2"), esc(t("h_" + ["ok", "warn", "bad"][sev])));
    setHTML(hero.querySelector("p"), esc(issues.length ? issues.join(" · ") : t("h_ok_sub")));

    // only the numbers are left-to-right: the words around them follow the page language
    const io = o.io && o.io[0] != null ? `${esc(t("io_r"))} ${num(esc(fmtRate(o.io[0])))} · ${esc(t("io_w"))} ${num(esc(fmtRate(o.io[1])))}` : "";
    setGauge("cpu", o.cpu, o.host.cores != null ? `${num(nf(o.host.cores, 0))} ${esc(t("cores"))}` : "", o.host.cpu_model ? num(esc(o.host.cpu_model)) : "");
    setGauge("mem", memPct, `${num(fmtBytes(o.mem.used))} ${esc(t("of"))} ${num(fmtBytes(o.mem.total))}`, o.swap && o.swap.total ? `${esc(t("swap"))} ${num(esc(`${fmtBytes(o.swap.used)} / ${fmtBytes(o.swap.total)}`))}` : "");
    setGauge("disk", d ? d.pct : null, d ? `${num(fmtBytes(d.used))} ${esc(t("of"))} ${num(fmtBytes(d.total))}` : "", d ? num(esc(d.mount)) + (io ? `<br>${io}` : "") : "");

    tween(tileEl("rx"), o.net.rx, (v) => num(fmtRate(v)));
    tween(tileEl("tx"), o.net.tx, (v) => num(fmtRate(v)));
    tween(tileEl("load"), o.load, (v) => num(v == null || v.some((x) => x == null) ? "–" : v.map((x) => nf(x, 2)).join(" / ")));
    setHTML(tileEl("targets"), num(`${o.targets.up} / ${o.targets.total}`));
    setHTML(tileEl("checks"), num(`${o.checks.up} / ${o.checks.total}`));
    setHTML(tileEl("ssl"), o.checks.min_ssl_days == null ? "–" : num(`${nf(o.checks.min_ssl_days, 0)} <small>${t("days")}</small>`));
    setHTML(tileEl("alerts"), o.alerts.firing ? num(o.alerts.firing) : `<span class="ok-mark">${icon("okmark")}</span>`);
    document.querySelector('[data-t="alerts"]').classList.toggle("alert-on", !!o.alerts.firing);
    refreshSparks();
    $("hostline").textContent = [o.host.name, o.host.os].filter(Boolean).join(" · ") || " ";
  }
  function renderStats() {   // full rebuild (language or theme changed, new data)
    state.statsShape = null;
    paintStats();
    renderNav();
  }

  // ---------------------------------------------------------------- tables
  function table(cols, rows, rowAttrs) {
    if (!rows.length) return `<div class="table-wrap"><div class="empty">${esc(t("empty"))}</div></div>`;
    const head = cols.map((c) => `<th>${c.raw ? c.h : esc(t(c.h))}</th>`).join("");
    const body = rows.map((r) => `<tr${rowAttrs ? " " + rowAttrs(r) : ""}>${cols.map((c) => `<td class="${c.cls || ""}${c.h === "actions" || c.raw ? " act" : ""}" data-label="${c.raw ? "" : esc(t(c.h))}">${c.cell(r)}</td>`).join("")}</tr>`).join("");
    return `<div class="table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
  }
  const pill = (kind, text, dot = true) => `<span class="pill ${kind}${dot ? " dot" : ""}">${esc(text)}</span>`;
  const miniBar = (pct) => `<div class="mini-bar"><div class="bar ${level(pct)}"><i style="width:${Math.min(100, pct)}%"></i></div>${num(`${nf(pct, 0)}%`)}</div>`;
  const btnIcon = (ic, label, attrs, cls = "") => `<button type="button" class="btn small icon ${cls}" title="${esc(label)}" aria-label="${esc(label)}" ${attrs}>${icon(ic)}</button>`;
  const addButton = (id, label) => `<button type="button" class="btn small primary" id="${id}">${icon("plus")}<span>${esc(label)}</span></button>`;
  const statusPill = (up, known = true) => (!known ? pill("", t("s_wait")) : up ? pill("ok", t("s_up")) : pill("bad", t("s_down")));
  const val = (form, name) => form.elements[name].value;
  const field = (label, control, hint = "") => `<div class="field"><label>${esc(label)}</label>${control}${hint ? `<p class="hint">${esc(hint)}</p>` : ""}</div>`;

  const liveRate = (r, k) => { const s = liveNow(), d = s && s.dev[r.device]; return d && d[k] != null ? d[k] : k ? r.tx : r.rx; };
  function paintNetLive() {
    const s = liveNow();
    document.querySelectorAll("[data-live-only]").forEach((el) => { el.hidden = !s; });
    if (!s) return;
    document.querySelectorAll("[data-live-dev]").forEach((el) => {
      const d = s.dev[el.dataset.liveDev];
      if (d && d[+el.dataset.k] != null) tween(el, d[+el.dataset.k], (v) => num(esc(fmtRate(v))));
    });
  }

  // ---------------------------------------------------------------- views: each has build() and optional bind()
  const CONTAINER_STATE = { running: "ok", restarting: "warn", paused: "warn", created: "warn", exited: "bad", dead: "bad" };
  const stateLabel = (st) => { const k = `s_${st}`; const v = t(k); return v === k ? st : v; };

  const IMPL = {
    // ---- websites + TCP ports
    websites: {
      async build() {
        const checks = await api("/api/checks");
        let metrics = [];
        try { metrics = (await api("/api/websites")).rows; } catch (e) { /* metrics are optional here */ }
        const byTarget = new Map(metrics.map((m) => [m.target, m]));
        const managed = [...checks.http.map((x) => ({ ...x, kind: "http" })), ...checks.tcp.map((x) => ({ ...x, kind: "tcp" }))];
        const known = new Set(managed.map((m) => m.target));
        const extra = metrics.filter((m) => !known.has(m.target)).map((m) => ({ target: m.target, name: "", kind: m.job === "tcp" ? "tcp" : "http", fixed: true }));
        const rows = [...managed, ...extra].map((r) => ({ ...r, m: byTarget.get(r.target) }));
        const cols = [
          { h: "target", cls: "strong", cell: (r) => `${num(esc(r.target))}${r.mode && r.mode !== "default" ? `<span class="tag">${esc(t("mode_" + r.mode))}</span>` : ""}${r.auto_from ? `<span class="tag" title="${esc(t("auto_was", { from: r.auto_from }))}">${esc(t("auto_tag"))}</span>` : ""}${r.name ? `<div class="sub-line">${esc(r.name)}</div>` : ""}` },
          { h: "type", cell: (r) => pill("info", r.kind.toUpperCase(), false) },
          { h: "status", cell: (r) => statusPill(r.m && r.m.up, !!r.m) },
          { h: "response", cell: (r) => num(r.m ? fmtMs(r.m.duration) : "–") },
          { h: "http", cell: (r) => num(r.m && r.m.http ? r.m.http : "–") },
          { h: "ssl_h", cell: (r) => (!r.m || r.m.ssl_days == null ? "–" : pill(r.m.ssl_days < 7 ? "bad" : r.m.ssl_days < 14 ? "warn" : "ok", nf(r.m.ssl_days, 0), false)) },
          { h: "actions", cell: (r) => `<div class="row-actions">${btnIcon("search", t("probe"), `data-act="probe" data-kind="${esc(r.kind)}" data-target="${esc(r.target)}"`)}${r.fixed ? "" : btnIcon("trash", t("remove"), `data-act="del" data-kind="${r.kind}" data-target="${esc(r.target)}"`, "danger")}</div>` },
        ];
        const events = (checks.auto && checks.auto.events) || [];
        const evText = (e) => (e.action === "mode" ? t("auto_ev_mode", { from: e.from, mode: t("mode_" + e.mode) }) : e.action === "merge" ? t("auto_ev_merge", { from: e.from, to: e.to }) : t("auto_ev_replace", { from: e.from, to: e.to }));
        const log = events.length ? `<div class="subcard" style="margin-top:18px"><h3>${icon("check")}${esc(t("auto_log"))}</h3><ul class="steps">${events.slice(0, 5).map((e) => `<li><span class="muted">${esc(new Date(e.t * 1000).toLocaleString())}</span> · ${esc(evText(e))}</li>`).join("")}</ul></div>` : "";
        return { html: table(cols, rows) + `<p class="muted" style="margin-top:12px">${esc(t("w_hint"))}</p>` + log, tools: addButton("btn-add-site", t("add_site")) };
      },
      bind(root) {
        $("btn-add-site")?.addEventListener("click", addSiteDialog);
        root.addEventListener("click", async (e) => {
          const pb = e.target.closest('[data-act="probe"]');
          if (pb) return probeDialog(pb.dataset.kind, pb.dataset.target);
          const b = e.target.closest('[data-act="del"]');
          if (!b) return;
          if (!(await confirmBox({ message: t("w_confirm_remove", { n: b.dataset.target }), label: t("remove") }))) return;
          if (await act(b, () => post("/api/checks/remove", { kind: b.dataset.kind, target: b.dataset.target }), t("removed"))) renderView(false);
        });
      },
    },

    disks: {
      async build() {
        const { rows } = await api("/api/disks", withInstance());
        return table([
          { h: "mount", cls: "strong", cell: (r) => num(esc(r.mount)) },
          { h: "device", cls: "muted", cell: (r) => num(esc(r.device)) },
          { h: "fs", cell: (r) => esc(r.fstype) },
          { h: "usage", cell: (r) => miniBar(r.pct) },
          { h: "used_total", cell: (r) => num(`${fmtBytes(r.used)} / ${fmtBytes(r.total)}`) },
        ], rows);
      },
    },

    network: {
      async build() {
        const { rows, exporter } = await api("/api/network", withInstance());
        if (!rows.length) {
          const why = !exporter ? "nx_nodata" : !exporter.present ? "nx_nojob" : !exporter.up ? "nx_down" : "nx_nodata";
          const detail = exporter && exporter.error ? ` <code>${esc(exporter.error)}</code>` : "";
          return `<div class="notice bad">${icon("bell")}<span>${esc(t(why))}${detail}</span></div>` + table([], []);
        }
        try { state.traffic = await api("/api/traffic", withInstance({ tz: new Date().getTimezoneOffset() })); } catch (e) { state.traffic = null; }   // the totals are optional
        const ifaces = table([
          { h: "iface", cls: "strong", cell: (r) => num(esc(r.device)) },
          { h: "status", cell: (r) => (r.up ? pill("ok", t("s_up")) : pill("bad", t("s_down"))) },
          { h: "speed", cell: (r) => num(r.speed ? `${nf((r.speed * 8) / 1e6, 0)} Mbit/s` : "–") },
          { h: "rate_in", cell: (r) => `<span data-live-dev="${esc(r.device)}" data-k="0">${num(fmtRate(liveRate(r, 0)))}</span>` },
          { h: "rate_out", cell: (r) => `<span data-live-dev="${esc(r.device)}" data-k="1">${num(fmtRate(liveRate(r, 1)))}</span>` },
          { h: "total_in", cell: (r) => num(fmtBytes(r.rx_total)) },
          { h: "total_out", cell: (r) => num(fmtBytes(r.tx_total)) },
        ], rows);
        return `<section class="sec"><div class="sec-head"><h3>${icon("network")}${esc(t("net_ifaces"))}<span class="live-tag" data-live-only hidden><i></i>${esc(t("live_tag"))}</span></h3></div>${ifaces}</section>${state.traffic ? trafficSection(state.traffic) : ""}`;
      },
      bind() { paintBars(); paintNetLive(); },
    },

    targets: {
      async build() {
        const { rows } = await api("/api/targets");
        return table([
          { h: "job", cls: "strong", cell: (r) => esc(r.job) },
          { h: "instance", cell: (r) => num(esc(r.instance)) },
          { h: "status", cell: (r) => (r.up ? pill("ok", t("s_up")) : pill("bad", t("s_down"))) },
          { h: "scrape", cell: (r) => num(fmtMs(r.duration)) },
          { h: "error", cls: "wrap-cell", cell: (r) => (r.error ? `<span style="color:var(--s-bad)">${esc(r.error)}</span>` : "") },
        ], rows);
      },
    },

    alerts: {
      async build() {
        const { rows } = await api("/api/alerts");
        const sev = { critical: "bad", warning: "warn", info: "info" };
        const note = rows.length ? "" : `<div class="notice ok">${icon("okmark")}<span>${esc(t("no_alerts"))}</span></div>`;
        return note + (rows.length ? table([
          { h: "severity", cell: (r) => pill(sev[r.severity] || "", r.severity && T[state.lang]["sev_" + r.severity] ? t("sev_" + r.severity) : r.severity || "–", false) },
          { h: "alert", cls: "strong", cell: (r) => esc(r.name) },
          { h: "instance", cell: (r) => num(esc(r.instance || "–")) },
          { h: "summary", cls: "wrap-cell", cell: (r) => esc(r.summary) },
          { h: "state", cell: (r) => (r.state === "firing" ? pill("bad", t("s_firing")) : pill("warn", t("s_pending"))) },
          { h: "since", cell: (r) => num(ago(r.since)) },
        ], rows) : "");
      },
    },

    // ---- servers (node_exporter targets)
    servers: {
      async build() {
        const checks = await api("/api/checks");
        let targets = [];
        try { targets = (await api("/api/targets")).rows.filter((r) => r.job === "node"); } catch (e) { /* optional */ }
        const byInst = new Map(targets.map((r) => [r.instance, r]));
        const cols = [
          { h: "target", cls: "strong", cell: (r) => `${num(esc(r.target))}${r.locked ? `<span class="tag">${esc(t("srv_local"))}</span>` : ""}` },
          { h: "name", cell: (r) => esc(r.name || "–") },
          { h: "status", cell: (r) => { const m = byInst.get(r.target); return statusPill(m && m.up, !!m); } },
          { h: "actions", cell: (r) => (r.locked ? "" : `<div class="row-actions">${btnIcon("trash", t("remove"), `data-act="del" data-target="${esc(r.target)}"`, "danger")}</div>`) },
        ];
        const cmd = "docker run -d --name node-exporter --restart unless-stopped \\\n  --net host --pid host -v /:/host:ro,rslave \\\n  prom/node-exporter:v1.8.2 --path.rootfs=/host";
        const fw = "ufw allow from <MONITORING-SERVER-IP> to any port 9100 proto tcp";
        const help = `<div class="subcard" style="margin-top:18px"><h3>${esc(t("srv_help_title"))}</h3>
          <p>${esc(t("srv_help_1"))}</p><div class="codebox">${esc(cmd)}</div><button type="button" class="btn small" data-copy="${esc(cmd)}">${icon("copy")}<span>${esc(t("copy"))}</span></button>
          <p>${esc(t("srv_help_2"))}</p><div class="codebox">${esc(fw)}</div><p>${esc(t("srv_help_3"))}</p></div>`;
        return { html: table(cols, checks.nodes) + help, tools: addButton("btn-add-server", t("add_server")) };
      },
      bind(root) {
        $("btn-add-server")?.addEventListener("click", addServerDialog);
        root.addEventListener("click", async (e) => {
          const c = e.target.closest("[data-copy]");
          if (c) return copyText(c.dataset.copy);
          const b = e.target.closest('[data-act="del"]');
          if (!b) return;
          if (!(await confirmBox({ message: t("srv_confirm_remove", { n: b.dataset.target }), label: t("remove") }))) return;
          if (await act(b, () => post("/api/checks/remove", { kind: "nodes", target: b.dataset.target }), t("removed"))) { state.instances = []; renderView(false); }
        });
      },
    },

    // ---- notifications (Telegram)
    notifications: {
      async build() {
        const s = (state.settings = await api("/api/settings"));
        const tg = s.telegram;
        const status = tg.configured ? pill("ok", t("tg_ok")) : pill("", t("tg_no"));
        const bot = tg.configured && tg.bot ? ` <span class="muted">${esc(t("tg_bot"))}: @${esc(tg.bot)}</span>` : "";
        const tokenHint = tg.configured ? t("tg_token_saved", { h: tg.token_hint }) : "";
        const html = `<div class="split">
          <section class="subcard"><h3>${icon("send")}${esc(t("tg_title"))} ${status}${bot}</h3>
            <ol class="steps"><li>${esc(t("tg_s1"))}</li><li>${esc(t("tg_s2"))}</li><li>${esc(t("tg_s3"))}</li></ol>
            <form id="tg-form" autocomplete="off">
              ${field(t("tg_token"), `<input name="token" type="password" dir="ltr" autocomplete="new-password" placeholder="123456789:AA…">`, tokenHint)}
              ${field(t("tg_chat"), `<input name="chat_id" dir="ltr" inputmode="numeric" value="${esc(tg.chat_id)}" placeholder="123456789">`)}
              <div id="tg-chats" class="chips" style="margin:-4px 0 14px"></div>
              <div class="actions-row">
                <button type="submit" class="btn primary">${esc(t("save"))}</button>
                <button type="button" class="btn" id="tg-find">${icon("search")}<span>${esc(t("tg_find"))}</span></button>
                <button type="button" class="btn" id="tg-test">${esc(t("tg_test"))}</button>
                ${tg.configured ? `<button type="button" class="btn danger" id="tg-remove">${esc(t("tg_remove"))}</button>` : ""}
              </div>
            </form></section>
          <section class="subcard"><h3>${icon("bell")}${esc(t("at_title"))}</h3><p>${esc(t("at_text"))}</p>
            <button type="button" class="btn" id="alert-test">${esc(t("at_btn"))}</button></section></div>`;
        return { html, tools: "" };
      },
      bind(root) {
        const form = root.querySelector("#tg-form");
        const creds = () => ({ token: val(form, "token").trim(), chat_id: val(form, "chat_id").trim() });
        form.addEventListener("submit", async (e) => {
          e.preventDefault();
          if (await act(form.querySelector('[type="submit"]'), () => post("/api/telegram/save", creds()), t("tg_saved"))) renderView(true);
        });
        root.querySelector("#tg-find").addEventListener("click", async (e) => {
          const box = root.querySelector("#tg-chats");
          const r = await act(e.currentTarget, () => post("/api/telegram/chats", { token: val(form, "token").trim() }));
          if (!r) return;
          box.innerHTML = r.chats.length
            ? `<span class="muted">${esc(t("tg_found"))}</span>` + r.chats.map((c) => `<button type="button" class="btn small" data-chat="${esc(c.id)}">${esc(c.title)} <code>${esc(c.id)}</code></button>`).join("")
            : `<span class="muted">${esc(t("tg_none"))}</span>`;
        });
        root.querySelector("#tg-chats").addEventListener("click", (e) => {
          const b = e.target.closest("[data-chat]");
          if (b) form.elements.chat_id.value = b.dataset.chat;
        });
        root.querySelector("#tg-test").addEventListener("click", (e) => act(e.currentTarget, () => post("/api/telegram/test", creds()), t("tg_test_ok")));
        root.querySelector("#tg-remove")?.addEventListener("click", async (e) => {
          if (!(await confirmBox({ message: t("tg_confirm_remove"), label: t("tg_remove") }))) return;
          if (await act(e.currentTarget, () => post("/api/telegram/remove"), t("tg_removed"))) renderView(true);
        });
        root.querySelector("#alert-test").addEventListener("click", (e) => act(e.currentTarget, () => post("/api/alerts/test"), t("at_ok")));
      },
    },

    // ---- alert rules
    rules: {
      async build() {
        const { rules } = await api("/api/rules");
        const sev = { critical: "bad", warning: "warn", info: "info" };
        const cols = [
          { h: "rl_rule", cls: "strong", cell: (r) => `${esc(T[state.lang]["rn_" + r.name] ? t("rn_" + r.name) : r.name)} <code class="rule-code" dir="ltr">${esc(r.name)}</code><div class="sub-line">${esc(t("rd_" + r.name))}</div>` },
          { h: "rl_enabled", cell: (r) => `<label class="switch"><input type="checkbox" data-f="enabled" ${r.enabled ? "checked" : ""} aria-label="${esc(r.name)}"><span></span></label>` },
          { h: "severity", cell: (r) => pill(sev[r.severity] || "", T[state.lang]["sev_" + r.severity] ? t("sev_" + r.severity) : r.severity, false) },
          { h: "rl_threshold", cell: (r) => (r.has_threshold ? `<span class="inline-field"><input type="number" data-f="value" step="any" min="${r.min}" max="${r.max}" value="${esc(r.value)}" aria-label="${esc(t("rl_threshold"))}"><small>${esc(r.unit)}</small></span>` : "–") },
          { h: "rl_for", cell: (r) => `<span class="inline-field"><input type="number" data-f="for" step="1" min="0" max="1440" value="${esc(r.for)}" aria-label="${esc(t("rl_for"))}"><small>${esc(t("minutes"))}</small></span>` },
          { h: "", raw: true, cell: () => `<button type="button" class="btn small primary" data-save disabled>${esc(t("save"))}</button>` },
        ];
        const html = table(cols, rules, (r) => `data-rule="${esc(r.name)}"`);
        return { html, tools: `<button type="button" class="btn small" id="btn-reset-rules">${esc(t("reset_defaults"))}</button>` };
      },
      bind(root) {
        root.addEventListener("input", (e) => { const row = e.target.closest("tr[data-rule]"); if (row) row.querySelector("[data-save]").disabled = false; });
        root.addEventListener("change", (e) => { const row = e.target.closest("tr[data-rule]"); if (row) row.querySelector("[data-save]").disabled = false; });
        root.addEventListener("click", async (e) => {
          const b = e.target.closest("[data-save]");
          if (!b) return;
          const row = b.closest("tr[data-rule]");
          const val = row.querySelector('[data-f="value"]');
          const body = { name: row.dataset.rule, enabled: row.querySelector('[data-f="enabled"]').checked, value: val ? val.value : null, for: row.querySelector('[data-f="for"]').value };
          if (await act(b, () => post("/api/rules/set", body), t("rl_saved"))) renderView(true);
        });
        $("btn-reset-rules")?.addEventListener("click", async (e) => {
          if (!(await confirmBox({ message: t("rl_reset_confirm"), label: t("reset_defaults"), danger: false }))) return;
          if (await act(e.currentTarget, () => post("/api/rules/reset"), t("rl_reset_ok"))) renderView(true);
        });
      },
    },

    // ---- settings
    settings: {
      async build() {
        const s = (state.settings = await api("/api/settings"));
        const d = s.docker;
        const dockerPill = d.enabled && d.available ? pill("ok", t("st_docker_on")) : d.enabled ? pill("warn", t("st_docker_unavail"), false) : pill("", t("st_docker_off"));
        const html = `<div class="split">
          <section class="subcard"><h3>${icon("lock")}${esc(t("st_pw_title"))}</h3>
            <form id="pw-form" autocomplete="off">
              ${field(t("st_user"), `<input name="user" dir="ltr" value="${esc(s.user)}" autocomplete="username" required>`)}
              ${field(t("st_current"), `<input name="current" type="password" dir="ltr" autocomplete="current-password" required>`)}
              ${field(t("st_new"), `<input name="new" type="password" dir="ltr" autocomplete="new-password" minlength="8" required>`)}
              ${field(t("st_repeat"), `<input name="repeat" type="password" dir="ltr" autocomplete="new-password" minlength="8" required>`)}
              <div class="actions-row"><button type="submit" class="btn primary">${esc(t("st_change"))}</button></div>
            </form></section>
          <div style="display:grid;gap:16px">
            <section class="subcard"><h3>${icon("box")}${esc(t("st_docker_title"))} ${dockerPill}</h3>
              <p>${esc(d.enabled ? t("st_docker_hint_on") : t("st_docker_hint_off"))}</p></section>
            <section class="subcard"><h3>${icon("check")}${esc(t("auto_title"))}</h3><p>${esc(t("auto_text"))}</p>
              <label style="display:flex;align-items:center;gap:12px;cursor:pointer"><span class="switch"><input type="checkbox" id="auto-toggle" ${s.auto_fix ? "checked" : ""}><span></span></span><b>${esc(t("auto_on"))}</b></label></section>
            <section class="subcard"><h3>${icon("server")}${esc(t("st_about"))}</h3>
              <p>${esc(t("st_version"))}: ${num(esc(s.version))}</p></section></div></div>`;
        return { html, tools: "" };
      },
      bind(root) {
        root.querySelector("#auto-toggle").addEventListener("change", async (e) => {
          const on = e.currentTarget.checked;
          if (await act(e.currentTarget, () => post("/api/settings/auto", { enabled: on }), t(on ? "auto_on_saved" : "auto_off_saved"))) state.settings = { ...state.settings, auto_fix: on };
          else e.currentTarget.checked = !on;
        });
        const form = root.querySelector("#pw-form");
        form.addEventListener("submit", async (e) => {
          e.preventDefault();
          if (val(form, "new") !== val(form, "repeat")) return toast(t("st_mismatch"), "bad");
          const ok = await act(form.querySelector('[type="submit"]'), () => post("/api/password", { user: val(form, "user").trim(), current: val(form, "current"), new: val(form, "new") }), t("st_pw_ok"));
          if (ok) { ["current", "new", "repeat"].forEach((n) => { form.elements[n].value = ""; }); }
        });
      },
    },
  };

  // ---------------------------------------------------------------- dialogs
  function probeDialog(kind, target) {
    openDialog({
      title: `${t("probe_title")}: ${target}`, wide: true, hideSubmit: true, cancel: t("close"),
      body: `<div id="probe-out"><div class="skeleton" style="height:70px"></div><p class="muted">${esc(t("probe_running"))}</p></div>`,
      onOpen: async (dlg) => {
        const out = dlg.querySelector("#probe-out");
        try {
          const r = await post("/api/checks/probe", { kind, target });
          const status = r.http_status ? ` · ${esc(t("probe_status"))}: ${num(r.http_status)}` : "";
          let diag = "";
          if (r.variants && r.variants.length) {
            const by = Object.fromEntries(r.variants.map((v) => [v.id, v]));
            const secureOk = r.variants.some((v) => v.ok && v.id in { legacy_tls: 1, no_verify: 1, legacy_no_verify: 1 });
            const note = secureOk ? t("diag_suggest")
              : by.plain_http && by.plain_http.ok ? t("diag_plain")
              : by.tcp && by.tcp.ok ? t("diag_blocked") : t("diag_closed");
            const rows = r.variants.map((v) => {
              const label = t(v.id === "tcp" ? "v_tcp" : `v_${v.id}`);
              const apply = v.ok && v.id in { legacy_tls: 1, no_verify: 1, legacy_no_verify: 1 }
                ? `<button type="button" class="btn small primary" data-mode="${v.id}">${esc(t("diag_apply"))}</button>` : "";
              return `<tr><td>${v.ok ? pill("ok", t("diag_works")) : pill("bad", t("diag_fails"))}</td><td class="strong" style="white-space:normal">${esc(label)}${apply ? `<div style="margin-top:8px">${apply}</div>` : ""}</td><td class="wrap-cell muted" style="min-width:300px">${v.ok ? (v.final_url ? `${esc(t("redirects_to"))} <code class="reason">${esc(v.final_url)}</code>` : "") : `<code class="reason">${esc(v.reason)}</code>`}</td></tr>`;
            }).join("");
            const httpFix = !secureOk && by.plain_http && by.plain_http.ok && target.startsWith("https://")
              ? `<p><button type="button" class="btn small primary" data-replace="http://${esc(target.slice(8))}">${esc(t("diag_use_http"))}</button></p>` : "";
            const autoBtn = r.variants.some((v) => v.ok && (v.id in { legacy_tls: 1, no_verify: 1, legacy_no_verify: 1 } || v.id === "plain_http"))
              ? `<p><button type="button" class="btn primary" data-autofix>${esc(t("auto_fix_btn"))}</button></p>` : "";
            diag = `<h4 style="margin:18px 0 8px">${esc(t("diag_title"))}</h4>${autoBtn}<p class="muted">${esc(note)}</p>${httpFix}<div class="table-wrap"><table><tbody>${rows}</tbody></table></div>`;
          }
          out.innerHTML = `<div class="notice ${r.ok ? "ok" : "bad"}">${icon(r.ok ? "okmark" : "bell")}<span><b>${esc(t(r.ok ? "probe_ok" : "probe_fail"))}</b>${status}</span></div>
            ${r.ok ? "" : `<p>${esc(t("probe_k_" + (r.kind || "other")))}</p>`}
            ${r.reason ? `<p><b>${esc(t("probe_reason"))}:</b> <code>${esc(r.reason)}</code></p>` : ""}
            ${diag}
            ${r.ok ? "" : `<p class="muted">${esc(t("probe_hint"))}</p>`}
            <details><summary>${esc(t("probe_log"))}</summary><pre class="logs" style="height:280px;margin-top:10px">${esc(r.log)}</pre></details>`;
          out.querySelectorAll("[data-autofix]").forEach((b) => b.addEventListener("click", async () => {
            const res = await act(b, () => post("/api/checks/autofix", { target }));
            if (!res) return;
            toast(res.event ? t("auto_done") : t("auto_none"), res.event ? "" : "warn");
            dlg.close(); renderView(false);
          }));
          out.querySelectorAll("[data-replace]").forEach((b) => b.addEventListener("click", async () => {
            if (await act(b, () => post("/api/checks/replace", { kind, target, new_target: b.dataset.replace }), t("diag_replaced"))) { dlg.close(); renderView(false); }
          }));
          out.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", async () => {
            if (await act(b, () => post("/api/checks/mode", { kind, target, mode: b.dataset.mode }), t("diag_applied"))) { dlg.close(); renderView(false); }
          }));
        } catch (e) { out.innerHTML = `<div class="notice bad">${icon("bell")}<span>${esc(e.message)}</span></div>`; }
      },
    });
  }

  function addSiteDialog() {
    openDialog({
      title: t("add_site"), submit: t("add"),
      body: `${field(t("type"), `<select name="kind"><option value="http">${esc(t("type_http"))}</option><option value="tcp">${esc(t("type_tcp"))}</option></select>`)}
        ${field(t("f_target"), `<input name="target" dir="ltr" required placeholder="https://example.com" autocomplete="off">`, t("hint_http"))}
        ${field(t("f_name_opt"), `<input name="name" maxlength="60" autocomplete="off">`)}`,
      onOpen: (dlg, form) => {
        const hint = dlg.querySelector(".hint");
        form.elements.kind.addEventListener("change", () => {
          const http = val(form, "kind") === "http";
          form.elements.target.placeholder = http ? "https://example.com" : "203.0.113.10:22";
          hint.textContent = t(http ? "hint_http" : "hint_tcp");
        });
        form.elements.target.focus();
      },
      onSubmit: async (form) => {
        let target = val(form, "target").trim();
        const kind = val(form, "kind");
        if (kind === "http" && target && !/^[a-z][a-z0-9+.-]*:\/\//i.test(target)) target = `https://${target}`;  // only when no scheme was typed
        await post("/api/checks/add", { kind, target, name: val(form, "name").trim() });
        toast(kind === "http" && state.settings && state.settings.auto_fix ? t("added_auto") : t("added"));
        renderView(false);
      },
    });
  }

  function addServerDialog() {
    openDialog({
      title: t("add_server"), submit: t("add"),
      body: `${field(t("f_srv_addr"), `<input name="target" dir="ltr" required placeholder="203.0.113.10:9100" autocomplete="off">`, t("f_srv_hint"))}
        ${field(t("f_name_opt"), `<input name="name" maxlength="60" autocomplete="off">`)}`,
      onOpen: (dlg, form) => form.elements.target.focus(),
      onSubmit: async (form) => {
        let target = val(form, "target").trim();
        if (target && !/:\d+$/.test(target)) target += ":9100";
        await post("/api/checks/add", { kind: "nodes", target, name: val(form, "name").trim() });
        toast(t("added"));
        state.instances = [];
        renderView(false);
      },
    });
  }

  // ---------------------------------------------------------------- charts
  // One categorical slot per series, in fixed order (blue, orange, aqua); text never wears a series colour.
  const CHARTS = [
    { m: "cpu", title: "c_cpu", fmt: (v) => `${nf(v)}%`, max: 100, colors: ["--c1"], now: true },
    { m: "mem", title: "c_mem", fmt: (v) => `${nf(v)}%`, max: 100, colors: ["--c3"], now: true },
    { m: "net", title: "c_net", fmt: fmtRate, colors: ["--c1", "--c2"], names: ["rx", "tx"] },
    { m: "load", title: "c_load", fmt: (v) => nf(v, 2), colors: ["--c1", "--c2", "--c3"] },
  ];
  const niceMax = (v) => {
    if (!(v > 0)) return 1;
    const p = 10 ** Math.floor(Math.log10(v));
    return [1, 2, 2.5, 5, 10].map((x) => x * p).find((x) => x >= v);
  };
  const seriesName = (cfg, s, i) => (cfg.names ? t(cfg.names[i]) : s.name);
  const hhmm = (d) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

  function drawChart(box, cfg, series, uid, win) {
    // With a fixed time window only the points inside it count (older samples would be drawn left of the
    // axis, outside the card, and would also stretch the scale); the plot area is clipped as well.
    if (win) series = series.map((s) => ({ ...s, points: s.points.filter((p) => p[0] >= win[0] && p[0] <= win[1]) }));
    const all = series.flatMap((s) => s.points.filter((p) => p[1] != null));
    // A line needs at least two samples at different times; right after startup there is only one.
    if (new Set(all.map((p) => p[0])).size < 2) { box.innerHTML = `<div class="empty">${esc(t(win ? "live_waiting" : "no_data"))}</div>`; return; }
    const bw = Math.round(box.clientWidth) || 600, compact = bw < 420;
    const W = Math.max(240, bw), H = compact ? 170 : 190, L = compact ? 42 : 52, R = 10, TOP = 12, B = 24;
    const x0 = win ? win[0] : Math.min(...all.map((p) => p[0])), x1 = win ? win[1] : Math.max(...all.map((p) => p[0])) || x0 + 1;
    const ymax = cfg.max || niceMax(Math.max(...all.map((p) => p[1])) * 1.1);
    const X = (ts) => L + ((ts - x0) / Math.max(1, x1 - x0)) * (W - L - R);
    const Y = (v) => TOP + (1 - v / ymax) * (H - TOP - B);
    const colors = cfg.colors.map((c) => `var(${c})`);

    let grid = "";
    for (let i = 0; i <= 4; i++) {
      const v = (ymax * i) / 4, y = Y(v);
      grid += `<line x1="${L}" x2="${W - R}" y1="${y}" y2="${y}"/><text x="${L - 8}" y="${y + 4}" text-anchor="end">${esc(cfg.fmt(v).replace(/\.0+(?=\D|$)/, ""))}</text>`;
    }
    const span = x1 - x0, ticks = compact ? 3 : 4;
    for (let i = 0; i <= ticks; i++) {
      const ts = x0 + (span * i) / ticks, d = new Date(ts * 1000);
      const label = span > 2 * 86400 ? `${d.getMonth() + 1}/${d.getDate()}` : span < 900 ? `${hhmm(d)}:${String(d.getSeconds()).padStart(2, "0")}` : hhmm(d);
      grid += `<text x="${X(ts)}" y="${H - 6}" text-anchor="${i === 0 ? "start" : i === ticks ? "end" : "middle"}">${label}</text>`;
    }
    let paths = "", defs = "", dots = "";
    const lastOf = series.map((s) => [...s.points].reverse().find((p) => p[1] != null));
    series.forEach((s, i) => {
      let d = "", pen = false, first = null, last = null;
      s.points.forEach(([ts, v]) => {
        if (v == null) { pen = false; return; }
        d += `${pen ? "L" : "M"}${X(ts).toFixed(1)},${Y(v).toFixed(1)}`;
        if (first == null) first = ts;
        last = ts;
        pen = true;
      });
      if (!d) return;
      if (series.length <= 2) {   // area wash ~10%; with three lines it would only muddy the overlaps
        defs += `<linearGradient id="g${uid}${i}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${colors[i]}" stop-opacity=".2"/><stop offset="1" stop-color="${colors[i]}" stop-opacity=".02"/></linearGradient>`;
        paths += `<path d="${d}L${X(last).toFixed(1)},${Y(0)}L${X(first).toFixed(1)},${Y(0)}Z" fill="url(#g${uid}${i})" stroke="none"/>`;
      }
      paths += `<path d="${d}" fill="none" stroke="${colors[i]}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>`;
      const lp = lastOf[i];
      dots += `<circle r="4.5" fill="${colors[i]}" cx="${X(lp[0]).toFixed(1)}" cy="${Y(lp[1]).toFixed(1)}"/>`;
    });
    defs += `<clipPath id="c${uid}"><rect x="${L}" y="0" width="${W - L - R}" height="${H - B + 6}"/></clipPath>`;
    box.innerHTML = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="${esc(t(cfg.title))}"><defs>${defs}</defs><g class="grid">${grid}</g><g clip-path="url(#c${uid})">${paths}</g><line class="cross" y1="${TOP}" y2="${H - B}" opacity="0"/><g class="dots">${dots}</g><rect class="hit" x="${L}" y="0" width="${W - L - R}" height="${H}" fill="transparent"/></svg><div class="tip" hidden></div>`;

    const svg = box.querySelector("svg"), tip = box.querySelector(".tip"), cross = box.querySelector(".cross");
    const dotEls = [...box.querySelectorAll(".dots circle")];
    const ref = series.reduce((a, b) => (b.points.length > a.points.length ? b : a), series[0]).points;
    const rest = () => {
      box._hover = null;
      tip.hidden = true; cross.setAttribute("opacity", "0");
      dotEls.forEach((c, i) => { const lp = lastOf[i]; c.setAttribute("cx", X(lp[0]).toFixed(1)); c.setAttribute("cy", Y(lp[1]).toFixed(1)); });
    };
    const show = (e) => {
      box._hover = { clientX: e.clientX };   // the live range redraws every second: keep the tooltip where it is
      const rect = svg.getBoundingClientRect();
      const px = ((e.clientX - rect.left) / rect.width) * W;
      const ts = x0 + ((px - L) / (W - L - R)) * (x1 - x0);
      let best = 0;
      ref.forEach((p, i) => { if (Math.abs(p[0] - ts) < Math.abs(ref[best][0] - ts)) best = i; });
      const at = ref[best][0], cx = X(at);
      cross.setAttribute("x1", cx); cross.setAttribute("x2", cx); cross.setAttribute("opacity", "1");
      const rows = series.map((s, i) => {
        const p = s.points.find((q) => q[0] === at);
        if (p && p[1] != null) { dotEls[i].setAttribute("cx", cx.toFixed(1)); dotEls[i].setAttribute("cy", Y(p[1]).toFixed(1)); }
        const name = series.length > 1 ? `<span>${esc(seriesName(cfg, s, i))}</span>` : "";
        return `<div class="r"><i style="background:${colors[i]}"></i><b>${esc(p && p[1] != null ? cfg.fmt(p[1]) : "–")}</b>${name}</div>`;
      }).join("");
      const dt = new Date(at * 1000);
      tip.innerHTML = `<div class="t">${esc(span > 2 * 86400 ? dt.toLocaleString() : dt.toLocaleTimeString([], { hour12: false }))}</div>${rows}`;
      tip.hidden = false;
      const cxPx = (cx / W) * rect.width, w = tip.offsetWidth;
      tip.style.left = `${Math.max(0, Math.min(rect.width - w, cxPx > rect.width / 2 ? cxPx - w - 14 : cxPx + 14))}px`;
      tip.style.top = "4px";
    };
    svg.addEventListener("pointermove", show);
    svg.addEventListener("pointerdown", show);
    svg.addEventListener("pointerleave", rest);
    svg.addEventListener("pointercancel", rest);
    if (box._hover) show(box._hover);
  }

  // Every chart has a table twin: the same numbers, readable without colour or hover.
  function chartTable(cfg, series) {
    const ref = series.reduce((a, b) => (b.points.length > a.points.length ? b : a), series[0]).points.filter((p) => p[1] != null);
    if (!ref.length) return `<div class="empty">${esc(t("no_data"))}</div>`;
    const step = Math.max(1, Math.floor(ref.length / 24));
    const rows = ref.filter((_, i) => (ref.length - 1 - i) % step === 0).reverse();
    const long = ref[ref.length - 1][0] - ref[0][0] > 2 * 86400;
    const head = `<th>${esc(t("time"))}</th>${series.map((s, i) => `<th>${esc(seriesName(cfg, s, i) || t(cfg.title))}</th>`).join("")}`;
    const body = rows.map(([ts]) => {
      const d = new Date(ts * 1000);
      return `<tr><td>${num(esc(long ? `${d.getMonth() + 1}/${d.getDate()} ${hhmm(d)}` : hhmm(d)))}</td>${series.map((s) => { const p = s.points.find((q) => q[0] === ts); return `<td>${num(esc(p && p[1] != null ? cfg.fmt(p[1]) : "–"))}</td>`; }).join("")}</tr>`;
    }).join("");
    return `<div class="chart-table table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
  }
  state.charts = [];
  state.tv = {};

  state.chartWin = null;   // [from, to] while the charts show the live range
  function paintChart(root, i) {
    const c = CHARTS[i], got = state.charts[i];
    const box = root.querySelector(`#plot-${i}`);
    if (!box || !got) return;
    if (state.tv[i]) box.innerHTML = chartTable(c, got);
    else drawChart(box, c, got, i, state.chartWin);
    if (c.now) {
      const last = [...got[0].points].reverse().find((p) => p[1] != null);
      tween(root.querySelector(`#now-${i}`), last ? last[1] : null, (v) => (v == null ? "" : num(esc(c.fmt(v)))));
    }
  }

  function liveSeries(m) {
    const S = state.live.samples, pts = (f) => S.map((s) => [s.t, f(s)]);
    if (m === "cpu") return [{ name: "CPU", points: pts((s) => s.cpu) }];
    if (m === "mem") return [{ name: "Memory", points: pts(memPctOf) }];
    if (m === "net") return [{ name: "rx", points: pts((s) => s.rx) }, { name: "tx", points: pts((s) => s.tx) }];
    return [1, 5, 15].map((p, k) => ({ name: `${p}m`, points: pts((s) => (s.load ? s.load[k] : null)) }));
  }
  let tablesAt = 0;
  function paintLiveCharts() {
    const root = $("panel"), S = state.live.samples;
    if (root.dataset.view !== "overview" || !liveNow() || S.length < 2 || !root.querySelector("#plot-0")) return;
    const note = root.querySelector("#live-note");
    if (note) note.hidden = true;
    const end = S[S.length - 1].t;
    state.chartWin = [end - (LIVE_KEEP - 1), end];
    const tables = Date.now() - tablesAt > 10000;   // a table that rewrites itself every second cannot be read
    if (tables) tablesAt = Date.now();
    CHARTS.forEach((c, i) => {
      state.charts[i] = liveSeries(c.m);
      if (!state.tv[i] || tables) paintChart(root, i);
    });
  }

  async function buildOverview(root, id, rebuild) {
    const live = state.range === "live";
    if (rebuild) {
      state.charts = [];
      tablesAt = 0;
      const tag = live ? `<span class="live-tag"><i></i>${esc(t("live_tag"))}</span>` : "";
      root.querySelector("#body").innerHTML = `<div class="notice warn" id="live-note" hidden></div><div class="charts">${CHARTS.map((c, i) => {
        const names = c.names ? c.names.map((n) => t(n)) : c.colors.length > 1 ? ["1m", "5m", "15m"] : [];
        const legend = names.length > 1 ? `<div class="legend">${names.map((n, k) => `<span><i style="background:var(${c.colors[k]})"></i>${esc(n)}</span>`).join("")}</div>` : "";
        const tv = !!state.tv[i];
        return `<div class="chart"><header><h3>${esc(t(c.title))}${tag}</h3><span class="now" id="now-${i}"></span><button type="button" class="btn small icon ghost view-toggle" data-tv="${i}" aria-pressed="${tv}" title="${esc(t("tbl_view"))}" aria-label="${esc(t("tbl_view"))}">${icon("table")}</button></header>${legend}<div class="plot" id="plot-${i}"><div class="skeleton"></div></div></div>`;
      }).join("")}</div>`;
    }
    const L = state.live;
    // Only fresh samples count: after the source failed, old ones would freeze the charts on stale data.
    if (live && window.EventSource && (liveNow() || (L.status === "wait" && Date.now() - L.startedAt < 8000))) {
      paintLiveCharts();
      refreshSparks();
      return;
    }
    // Live data is not coming (exporter unreachable, old browser): show the last hour from Prometheus.
    state.chartWin = null;
    const note = root.querySelector("#live-note");
    if (note) { note.hidden = !live; note.textContent = live ? t("live_off_note", { e: L.error || t("live_wait") }) : ""; }
    await Promise.all(CHARTS.map(async (c, i) => {
      try {
        const { series } = await api("/api/history", withInstance({ metric: c.m, range: live ? "1h" : state.range }));
        if (id !== state.renderId || state.chartWin) return;   // live data arrived meanwhile
        state.charts[i] = series;
        state.hist[c.m] = series;
        paintChart(root, i);
      } catch (e) {
        if (id === state.renderId && !state.charts[i]) root.querySelector(`#plot-${i}`).innerHTML = `<div class="empty">${esc(e.message)}</div>`;
      }
    }));
    if (id === state.renderId) refreshSparks();
  }

  // ---------------------------------------------------------------- traffic usage (network page)
  state.traffic = null;
  state.trTable = false;
  state.trMonth = "cur";
  // Gregorian month names in the panel's language (Latin digits, like every other number in the panel)
  const monthName = (key, opts = { month: "long", year: "numeric" }) => {
    const [y, m] = key.split("-").map(Number);
    try { return new Intl.DateTimeFormat(state.lang === "fa" ? "fa-IR-u-ca-gregory-nu-latn" : "en-US", { ...opts, timeZone: "UTC" }).format(new Date(Date.UTC(y, m - 1, 1))); }
    catch (e) { return key; }
  };
  const dayName = (key, d, month = "long") => {
    const [y, m] = key.split("-").map(Number);
    try { return new Intl.DateTimeFormat(state.lang === "fa" ? "fa-IR-u-ca-gregory-nu-latn" : "en-US", { day: "numeric", month, timeZone: "UTC" }).format(new Date(Date.UTC(y, m - 1, d))); }
    catch (e) { return `${m}/${d}`; }
  };
  const sumOf = (d) => (d && (d.rx != null || d.tx != null) ? (d.rx || 0) + (d.tx || 0) : null);
  function usageCard(label, d, notes = [], cls = "") {
    const rx = d.rx || 0, tx = d.tx || 0, sum = rx + tx, share = sum ? (rx / sum) * 100 : 0;
    const known = d.rx != null || d.tx != null;
    notes = (Array.isArray(notes) ? notes : [notes]).filter(Boolean);
    return `<div class="usage${cls ? " " + cls : ""}"><div class="u-label">${esc(label)}</div>
      <div class="u-total">${known ? num(esc(fmtBytes(sum))) : "–"}</div>
      <div class="u-split" aria-hidden="true"><i class="rx" style="width:${share.toFixed(1)}%"></i><i class="tx" style="width:${sum ? (100 - share).toFixed(1) : 0}%"></i></div>
      <div class="u-rows"><div><span class="k rx"></span>${icon("down")}<span>${esc(t("tr_down"))}</span><b>${num(esc(known ? fmtBytes(rx) : "–"))}</b></div>
      <div><span class="k tx"></span>${icon("up")}<span>${esc(t("tr_up"))}</span><b>${num(esc(known ? fmtBytes(tx) : "–"))}</b></div></div>
      ${notes.map((n) => `<div class="u-note">${n}</div>`).join("")}</div>`;
  }
  const fullDate = (ts) => {
    try { return new Intl.DateTimeFormat(state.lang === "fa" ? "fa-IR-u-ca-gregory-nu-latn" : "en-US", { day: "numeric", month: "long", year: "numeric" }).format(new Date(ts * 1000)); }
    catch (e) { return new Date(ts * 1000).toLocaleDateString(); }
  };
  function trafficSection(tr) {
    const head = `<div class="sec-head"><h3>${icon("activity")}${esc(t("tr_title"))}</h3><p class="muted">${esc(t("tr_sub"))}</p></div>`;
    if (tr.preparing || tr.empty) return `<section class="sec">${head}<div class="notice">${icon("refresh")}<span>${esc(t("tr_preparing"))}</span></div></section>`;
    const cur = tr.month, prev = tr.prev;
    const dayNow = cur.daily.length;
    // at the pace so far, where the month ends up (from the 2nd day on, when there is a pace to speak of)
    const total = sumOf(cur), proj = total != null && cur.elapsed > 86400 && cur.complete ? (total / cur.elapsed) * cur.seconds : null;
    const curNotes = [esc(t("tr_range", { a: dayName(cur.key, 1), b: dayName(cur.key, dayNow) })),
      proj != null ? t("tr_proj", { v: `<b>${num(esc(fmtBytes(proj)))}</b>` }) : "",
      cur.complete ? "" : esc(t("tr_incomplete"))];
    const prevNotes = [esc(monthName(prev.key)), prev.rx == null && prev.tx == null ? esc(t("tr_nodata_month")) : prev.complete ? "" : esc(t("tr_incomplete"))];
    const cards = [
      usageCard(t("tr_today"), tr.today),
      usageCard(`${t("tr_month")} · ${monthName(cur.key, { month: "long" })}`, cur, curNotes, "u-main"),
      usageCard(t("tr_prev"), prev, prevNotes),
      usageCard(t("tr_7d"), tr.week),
      usageCard(t("tr_alltime"), tr.alltime, esc(t("tr_alltime_since", { d: fullDate(tr.alltime.since) }))),
      usageCard(t("tr_boot"), tr.boot, tr.boot.since ? esc(t("tr_boot_since", { d: fullDate(tr.boot.since) })) : ""),
    ].join("");
    const peak = (label, v) => `<span class="chip">${esc(label)} <b>${num(esc(fmtRate(v)))}</b></span>`;
    if (!["cur", "prev", "24h"].includes(state.trMonth)) state.trMonth = "cur";
    const seg = [["24h", t("tr_24h")], ["cur", monthName(cur.key)], ["prev", monthName(prev.key)]]
      .map(([k, l]) => `<button type="button" data-trmonth="${k}" aria-pressed="${state.trMonth === k}">${esc(l)}</button>`).join("");
    const counted = tr.devices.filter((d) => d.counted).map((d) => `<span class="chip">${num(esc(d.name))}</span>`).join("") || "–";
    const status = tr.syncing ? `<div class="notice">${icon("refresh")}<span>${esc(t("tr_syncing"))}</span></div>` : "";
    return `<section class="sec">${head}${status}
      <div class="tr-devs"><span class="muted">${esc(t("tr_counted"))}:</span>${counted}<span class="muted small">(${esc(t(tr.auto ? "tr_auto" : "tr_manual"))})</span>
        <button type="button" class="btn small ghost" data-trdev>${icon("gear")}${esc(t("tr_choose"))}</button>
        <span class="muted small tr-upd">${esc(t("tr_updated", { ago: ago(tr.updated) }))}</span></div>
      <div class="usage-grid">${cards}</div>
      <div class="chart tr-chart"><header><h3>${esc(t("tr_daily"))}</h3><div class="seg" role="group" aria-label="${esc(t("tr_daily"))}">${seg}</div><button type="button" class="btn small icon ghost view-toggle" data-trtable aria-pressed="${state.trTable}" title="${esc(t("tbl_view"))}" aria-label="${esc(t("tbl_view"))}">${icon("table")}</button></header>
        <div class="legend"><span><i style="background:var(--c1)"></i>${esc(t("tr_down"))}</span><span><i style="background:var(--c2)"></i>${esc(t("tr_up"))}</span>
          ${tr.peak.rx != null ? peak(t("tr_peak_in"), tr.peak.rx) : ""}${tr.peak.tx != null ? peak(t("tr_peak_out"), tr.peak.tx) : ""}</div>
        <div class="plot" id="tr-plot"></div><div class="u-note tr-sum" id="tr-sum"></div></div>
      ${monthsTable(tr.months)}</section>`;
  }

  // which network cards are counted
  function trafficDevices() {
    const tr = state.traffic;
    if (!tr || !tr.devices) return;
    const row = (d) => `<label class="tr-dev"><input type="checkbox" name="dev" value="${esc(d.name)}" ${d.counted ? "checked" : ""}>
      <b>${num(esc(d.name))}</b><span class="pill ${d.physical ? "ok" : ""}">${esc(t(d.physical ? "tr_physical" : "tr_virtual"))}</span>
      <span class="muted">${esc(t("tr_dev_month"))}: ${num(esc(fmtBytes(sumOf(d.month) || 0)))}</span></label>`;
    const body = `<p class="muted">${esc(t("tr_dev_help"))}</p>
      <label class="tr-mode"><input type="radio" name="mode" value="auto" ${tr.auto ? "checked" : ""}> ${esc(t("tr_dev_auto"))}</label>
      <label class="tr-mode"><input type="radio" name="mode" value="manual" ${tr.auto ? "" : "checked"}> ${esc(t("tr_dev_manual"))}</label>
      <div class="tr-dev-list">${tr.devices.filter((d) => d.counted || d.physical || sumOf(d.month) || sumOf(d.prev)).map(row).join("")}</div>`;
    openDialog({
      title: t("tr_dev_title"), body,
      onOpen: (dlg, form) => {
        const sync = () => { const manual = form.mode.value === "manual"; form.querySelectorAll('[name="dev"]').forEach((c) => { c.disabled = !manual; }); };
        form.querySelectorAll('[name="mode"]').forEach((r) => r.addEventListener("change", sync));
        sync();
      },
      onSubmit: async (form) => {
        const manual = form.mode.value === "manual";
        const devices = [...form.querySelectorAll('[name="dev"]:checked')].map((c) => c.value);
        if (manual && !devices.length) throw new Error(t("tr_dev_none"));
        await post("/api/traffic/devices", withInstance({ devices: manual ? devices : null }));
        state.traffic = await api("/api/traffic", withInstance({ tz: new Date().getTimezoneOffset() }));
        route();
      },
    });
  }

  function monthsTable(months) {
    if (!months || !months.length) return "";
    const rows = months.map((m) => `<tr><td class="strong">${esc(monthName(m.key))}${m.complete ? "" : ` <span class="muted" title="${esc(t("tr_incomplete"))}">*</span>`}</td>
      <td data-label="${esc(t("tr_down"))}">${num(esc(fmtBytes(m.rx)))}</td><td data-label="${esc(t("tr_up"))}">${num(esc(fmtBytes(m.tx)))}</td><td data-label="${esc(t("tr_total"))}"><b>${num(esc(fmtBytes(sumOf(m))))}</b></td></tr>`).join("");
    const note = months.some((m) => !m.complete) ? `<div class="u-note">* ${esc(t("tr_incomplete"))}</div>` : "";
    return `<div class="chart tr-months"><header><h3>${esc(t("tr_months"))}</h3></header>
      <div class="table-wrap"><table><thead><tr><th>${esc(t("tr_month_col"))}</th><th>${esc(t("tr_down"))}</th><th>${esc(t("tr_up"))}</th><th>${esc(t("tr_total"))}</th></tr></thead><tbody>${rows}</tbody></table></div>${note}</div>`;
  }

  // the chosen month's days, padded with the days still to come so the month always shows in full
  function monthDays(tr) {
    if (state.trMonth === "24h") {
      const hours = tr.hourly.map((h, i) => {
        const d = new Date(h.start * 1000), hh = String(d.getHours()).padStart(2, "0"), nx = String((d.getHours() + 1) % 24).padStart(2, "0");
        return { ...h, day: i, label: hh, title: `${hh}:00 – ${nx}:00`, short: `${hh}:00`, today: i === tr.hourly.length - 1 };
      });
      const sum = hours.reduce((a, h) => ({ rx: a.rx + (h.rx || 0), tx: a.tx + (h.tx || 0) }), { rx: 0, tx: 0 });
      return { m: { ...sum, hourly: true }, days: hours };
    }
    const m = state.trMonth === "prev" ? tr.prev : tr.month;
    const days = m.daily.map((d) => ({ ...d, label: String(d.day), title: dayName(m.key, d.day), short: dayName(m.key, d.day, "short") }));
    for (let d = days.length + 1; d <= m.days; d++) days.push({ day: d, rx: null, tx: null, future: true, label: String(d), title: dayName(m.key, d) });
    return { m, days };
  }

  function barsTable(m, days) {
    const rows = days.filter((d) => !d.future).slice().reverse().map((d) => `<tr><td>${esc(d.short || d.title)}${d.today && !m.hourly ? ` <span class="muted">(${esc(t("tr_today"))})</span>` : ""}</td><td data-label="${esc(t("tr_down"))}">${num(esc(fmtBytes(d.rx)))}</td><td data-label="${esc(t("tr_up"))}">${num(esc(fmtBytes(d.tx)))}</td><td data-label="${esc(t("tr_total"))}">${num(esc(fmtBytes(sumOf(d))))}</td></tr>`).join("");
    return `<div class="chart-table table-wrap"><table><thead><tr><th>${esc(t(m.hourly ? "tr_hour" : "tr_day"))}</th><th>${esc(t("tr_down"))}</th><th>${esc(t("tr_up"))}</th><th>${esc(t("tr_total"))}</th></tr></thead><tbody>${rows}</tbody>
      <tfoot><tr><th>${esc(t("tr_total"))}</th><th>${num(esc(fmtBytes(m.rx)))}</th><th>${num(esc(fmtBytes(m.tx)))}</th><th>${num(esc(fmtBytes(sumOf(m))))}</th></tr></tfoot></table></div>`;
  }

  function paintBars() {
    const box = $("tr-plot"), tr = state.traffic;
    if (!box || !tr || !tr.month || !tr.hourly) return;
    const { m, days } = monthDays(tr);
    const sumBox = $("tr-sum");
    const parts = { v: `<b>${num(esc(fmtBytes(sumOf(m))))}</b>`, d: num(esc(fmtBytes(m.rx))), u: num(esc(fmtBytes(m.tx))) };
    if (sumBox) sumBox.innerHTML = m.rx == null && m.tx == null ? "" : m.hourly ? t("tr_24h_sum", parts) : t("tr_month_sum", { m: esc(monthName(m.key)), ...parts });
    if (state.trTable) { box.innerHTML = barsTable(m, days); return; }
    const vals = days.flatMap((d) => [d.rx || 0, d.tx || 0]);
    if (!Math.max(...vals)) { box.innerHTML = `<div class="empty">${esc(t(state.trMonth === "prev" ? "tr_nodata_month" : "no_data"))}</div>`; return; }
    const bw = Math.round(box.clientWidth) || 600, compact = bw < 420;
    const W = Math.max(260, bw), H = compact ? 190 : 220, L = compact ? 52 : 62, R = 8, TOP = 12, B = 26;
    const unit = 1024 ** Math.max(0, Math.floor(Math.log(Math.max(...vals)) / Math.log(1024))), ymax = niceMax((Math.max(...vals) * 1.08) / unit) * unit, plotW = W - L - R, gw = plotW / days.length;
    const Y = (v) => TOP + (1 - v / ymax) * (H - TOP - B);
    const barW = Math.max(1.5, Math.min(22, gw * 0.36));
    const every = Math.max(1, Math.ceil(days.length / Math.max(1, Math.floor(plotW / 24))));   // day labels that fit
    const ti = days.findIndex((d) => d.today);
    let grid = "", bars = "", hits = "";
    for (let i = 0; i <= 4; i++) {
      const v = (ymax * i) / 4, y = Y(v);
      grid += `<line x1="${L}" x2="${W - R}" y1="${y}" y2="${y}"/><text x="${L - 8}" y="${y + 4}" text-anchor="end">${esc(fmtBytes(v))}</text>`;
    }
    const topRound = (x, y, w, h, r) => {   // rounded data end, flat on the baseline
      r = Math.min(r, w / 2, h);
      return `M${x},${y + h}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + h}Z`;
    };
    days.forEach((d, i) => {
      const cx = L + gw * i + gw / 2;
      if (d.today || (i % every === 0 && (ti < 0 || Math.abs(i - ti) * gw >= 22))) grid += `<text x="${cx}" y="${H - 7}" text-anchor="middle"${d.today ? ' class="today"' : ""}>${esc(d.label)}</text>`;
      if (d.future) return;
      [["rx", "--c1", -1], ["tx", "--c2", 1]].forEach(([k, col, side]) => {
        const v = d[k] || 0;
        if (v <= 0) return;
        const h = Math.max(2, (H - TOP - B) * (v / ymax)), x = side < 0 ? cx - barW - 0.5 : cx + 0.5;
        bars += `<path d="${topRound(x, Y(0) - h, barW, h, Math.min(4, barW / 2))}" fill="var(${col})"${d.today ? ' opacity=".7"' : ""}/>`;
      });
      hits += `<rect class="hit" data-i="${i}" x="${L + gw * i}" y="0" width="${gw}" height="${H}" fill="transparent"/>`;
    });
    box.innerHTML = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" style="height:${H}px" role="img" aria-label="${esc(`${t("tr_daily")} · ${m.hourly ? t("tr_24h") : monthName(m.key)}`)}"><g class="grid">${grid}</g><rect class="hl" y="${TOP}" height="${H - TOP - B}" width="${gw}" opacity="0"/>${bars}${hits}</svg><div class="tip" hidden></div>`;
    const svg = box.querySelector("svg"), tip = box.querySelector(".tip"), hl = box.querySelector(".hl");
    const show = (e) => {
      const rect = svg.getBoundingClientRect();
      const px = ((e.clientX - rect.left) / rect.width) * W;
      if (px < L) return;
      const i = Math.max(0, Math.min(days.length - 1, Math.floor((px - L) / gw)));
      const d = days[i], cx = L + gw * i;
      if (d.future) { rest(); return; }
      hl.setAttribute("x", cx); hl.setAttribute("opacity", "1");
      tip.innerHTML = `<div class="t">${esc(d.title)}${d.today && !m.hourly ? ` · ${esc(t("tr_today"))}` : ""}</div>
        <div class="r"><i style="background:var(--c1)"></i><b>${num(esc(fmtBytes(d.rx)))}</b><span>${esc(t("tr_down"))}</span></div>
        <div class="r"><i style="background:var(--c2)"></i><b>${num(esc(fmtBytes(d.tx)))}</b><span>${esc(t("tr_up"))}</span></div>
        <div class="r"><i></i><b>${num(esc(fmtBytes(sumOf(d))))}</b><span>${esc(t("tr_total"))}</span></div>`;
      tip.hidden = false;
      const mid = ((cx + gw / 2) / W) * rect.width, w = tip.offsetWidth;
      tip.style.left = `${Math.max(0, Math.min(rect.width - w, mid > rect.width / 2 ? mid - w - 8 : mid + 8))}px`;
      tip.style.top = "4px";
    };
    const rest = () => { tip.hidden = true; hl.setAttribute("opacity", "0"); };
    svg.addEventListener("pointermove", show);
    svg.addEventListener("pointerdown", show);
    svg.addEventListener("pointerleave", rest);
    svg.addEventListener("pointercancel", rest);
  }

  // ---------------------------------------------------------------- self-diagnosis ("why can't the panel load data?")
  function healthDialog() {
    const dlg = openDialog({ title: t("dg_title"), wide: true, hideSubmit: true, cancel: t("close"), body: `<div id="diag"><div class="skeleton"></div></div>` });
    const box = dlg.querySelector("#diag");
    const render = (d) => {
      const hints = d.hints.map((h) => `<div class="notice ${h.kind === "dns_external" || h.kind === "disk" ? "warn" : "bad"}">${icon("bell")}<span>${esc(t("hint_" + h.kind, { service: h.service, detail: h.detail }))}</span></div>`).join("");
      const allOk = d.services.every((x) => x.ok);
      const svc = table([
        { h: "service", cls: "strong", cell: (r) => esc(r.service) },
        { h: "status", cell: (r) => (r.ok ? pill("ok", t("diag_ok")) : pill("bad", t(r.stage === "dns" ? "diag_dns" : "diag_http"))) },
        { h: "diag_detail", cls: "wrap-cell", cell: (r) => (r.error ? `<code class="reason">${esc(r.error)}</code>` : r.ms != null ? num(`${r.ms} ms`) : "") },
      ], d.services);
      const ctn = d.containers ? table([
        { h: "service", cls: "strong", cell: (r) => esc(r.service) },
        { h: "status", cell: (r) => pill(CONTAINER_STATE[r.state] || "", stateLabel(r.state)) },
        { h: "diag_exit", cell: (r) => num(r.state === "running" ? "–" : String(r.exit_code ?? "–")) + (r.oom ? ` <span class="tag">OOM</span>` : "") },
        { h: "diag_restarts", cell: (r) => num(String(r.restarts)) },
        { h: "actions", cell: (r) => (r.state === "running" ? "" : `<div class="row-actions">${btnIcon("refresh", t("a_restart"), `data-diag-restart="${esc(r.id)}"`)}</div>`) },
      ], d.containers) : `<div class="notice">${icon("bell")}<span>${esc(t("c_docker_off"))}</span></div>`;
      const logs = Object.entries(d.logs).map(([name, text]) => `<h4>${esc(t("diag_logs", { s: name }))}</h4><pre class="logs short">${esc(text || "–")}</pre>`).join("");
      const extra = [d.disk ? `<span class="chip">${icon("disk")}${esc(t("disk"))} <b>${num(`${nf(d.disk.pct, 0)}%`)}</b></span>` : "", `<span class="chip">${icon("globe")}DNS <b>${esc(d.dns_external.ok ? t("diag_ok") : t("diag_fail"))}</b></span>`].join("");
      box.innerHTML = `${allOk ? `<div class="notice ok">${icon("okmark")}<span>${esc(t("diag_all_ok"))}</span></div>` : ""}${hints}
        <div class="diag-chips">${extra}</div><h4>${esc(t("diag_services"))}</h4>${svc}<h4>${esc(t("diag_containers"))}</h4>${ctn}${logs}`;
    };
    const load = async () => {
      try { render(await api("/api/health")); } catch (e) { if (e.message !== "unauthorized") box.innerHTML = `<div class="notice bad">${esc(e.message)}</div>`; }
    };
    box.addEventListener("click", async (e) => {
      const b = e.target.closest("[data-diag-restart]");
      if (!b) return;
      if (await act(b, () => post("/api/docker/action", { id: b.dataset.diagRestart, action: "restart" }), t("c_done"))) { box.innerHTML = `<div class="skeleton"></div>`; setTimeout(load, 4000); }
    });
    load();
  }

  // ---------------------------------------------------------------- view rendering
  function overviewTools() {
    const label = (i) => (state.names[i] ? `${state.names[i]} (${i})` : i);
    const inst = state.instances.length > 1
      ? `<label class="muted" for="sel-inst">${esc(t("server"))}</label><select id="sel-inst">${state.instances.map((i) => `<option ${i === state.instance ? "selected" : ""} value="${esc(i)}">${esc(label(i))}</option>`).join("")}</select>` : "";
    const range = `<label class="muted" for="sel-range">${esc(t("range"))}</label><select id="sel-range">${["live", "1h", "6h", "24h", "7d"].map((r) => `<option ${r === state.range ? "selected" : ""} value="${r}">${esc(t("r" + r))}</option>`).join("")}</select>`;
    return inst + range;
  }

  async function renderView(first) {
    const id = ++state.renderId;
    const v = VIEWS.find((x) => x.id === state.view) || VIEWS[0];
    const root = $("panel");
    $("stats").hidden = v.id !== "overview";
    if (v.id === "overview") paintStats();
    const hadShell = root.dataset.view === v.id && root.dataset.lang === state.lang;
    if (v.static && hadShell && !first) return;   // forms must not be wiped by the 10-second refresh
    if (!hadShell || first) {
      root.dataset.view = v.id;
      root.dataset.lang = state.lang;
      root.innerHTML = `<div class="panel-head"><h2>${icon(v.icon)}${esc(t(v.label))}</h2><div class="tools" id="tools">${v.id === "overview" ? overviewTools() : ""}</div></div><p class="desc">${esc(t(v.desc))}</p><hr><div id="body"><div class="skeleton"></div></div>`;
      const si = $("sel-inst"), sr = $("sel-range");
      if (si) si.onchange = () => { state.instance = si.value; store.set("instance", si.value); startLive(); tick(true); };
      if (sr) sr.onchange = () => { state.range = sr.value; store.set("range", sr.value); renderView(true); };
    }
    try {
      if (v.id === "overview") { await buildOverview(root, id, !hadShell || first); return; }
      const impl = IMPL[v.id];
      const res = await impl.build();
      if (id !== state.renderId) return;
      const html = typeof res === "string" ? res : res.html;
      const body = root.querySelector("#body");
      const fresh = body.cloneNode(false);              // drop handlers bound to the previous render
      fresh.innerHTML = html;
      body.replaceWith(fresh);
      if (typeof res !== "string") $("tools").innerHTML = res.tools || "";
      if (impl.bind) impl.bind(fresh);
    } catch (e) {
      if (id === state.renderId && e.message !== "unauthorized") root.querySelector("#body").innerHTML = `<div class="notice bad">${esc(t("err_api"))}: ${esc(e.message)}</div>`;
    }
  }

  async function loadStats() {
    try {
      const inst = await api("/api/instances");
      state.instances = inst.instances;
      state.names = inst.names || {};
      if (!state.instances.includes(state.instance)) state.instance = state.instances[0] || "";
      state.overview = await api("/api/overview", withInstance());
      $("banner").innerHTML = "";
      paintStats();
      renderNav();
    } catch (e) {
      if (e.message !== "unauthorized") $("banner").innerHTML = `<div class="notice bad">${icon("bell")}<span>${esc(t("err_api"))}: ${esc(e.message)}</span><button type="button" class="btn small" data-diag>${icon("search")}<span>${esc(t("diag_btn"))}</span></button></div>`;
    }
    try { state.settings = await api("/api/settings"); renderNav(); } catch (e) { /* the badge is optional */ }
    state.lastUpdate = new Date();
    paintFoot();
  }

  let ticking = false;
  async function tick(full) {
    if (ticking) return;
    ticking = true;
    try {
      await loadStats();
      startLive();   // no-op while already streaming the selected server
      await renderView(full === true);
    } finally { ticking = false; }
  }

  function route() {
    const id = location.hash.slice(1);
    state.view = VIEWS.some((v) => v.id === id) ? id : "overview";
    renderNav();
    window.scrollTo(0, 0);
    startLive();
    renderView(true);
  }

  // ---------------------------------------------------------------- boot
  $("theme").onclick = () => {
    // No transitions while the colours swap, so the two themes never blend for a moment.
    document.documentElement.classList.add("no-anim");
    state.theme = state.theme === "dark" ? "light" : "dark";
    store.set("theme", state.theme);
    applyLocale(); renderStats(); renderView(true);
    const done = () => document.documentElement.classList.remove("no-anim");
    requestAnimationFrame(() => requestAnimationFrame(done));
    setTimeout(done, 120);   // frames can be paused (hidden window): never leave transitions switched off
  };
  $("lang").onclick = () => { state.lang = state.lang === "en" ? "fa" : "en"; store.set("lang", state.lang); applyLocale(); renderStats(); renderView(true); };
  $("refresh").onclick = () => tick(true);
  $("logout").onclick = async () => { try { await fetch("/logout", { method: "POST" }); } catch (e) { /* ignore */ } location.replace("/login"); };
  window.addEventListener("hashchange", route);
  document.addEventListener("click", (e) => {
    const go = e.target.closest("[data-go]");
    if (go) { location.hash = go.dataset.go; return; }
    if (e.target.closest("[data-more]")) { moreSheet(); return; }
    if (e.target.closest("[data-trdev]")) { trafficDevices(); return; }
    const trm = e.target.closest("[data-trmonth]");
    if (trm) {
      state.trMonth = trm.dataset.trmonth;
      document.querySelectorAll("[data-trmonth]").forEach((b) => b.setAttribute("aria-pressed", String(b === trm)));
      paintBars();
      return;
    }
    if (e.target.closest("[data-trtable]")) {
      state.trTable = !state.trTable;
      e.target.closest("[data-trtable]").setAttribute("aria-pressed", String(state.trTable));
      paintBars();
      return;
    }
    if (e.target.closest("[data-diag]")) { healthDialog(); return; }
    const cp = e.target.closest("[data-copy]");
    if (cp) { copyText(cp.dataset.copy); return; }
    const tv = e.target.closest("[data-tv]");
    if (tv) {
      const i = +tv.dataset.tv;
      state.tv[i] = !state.tv[i];
      tv.setAttribute("aria-pressed", String(!!state.tv[i]));
      paintChart($("panel"), i);
    }
  });
  document.addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ") && e.target.matches && e.target.matches('[data-go][role="link"]')) { e.preventDefault(); location.hash = e.target.dataset.go; }
  });
  $("live-every").addEventListener("change", (e) => {   // a new pace: reconnect the stream at once
    state.liveEvery = +e.target.value;
    store.set("live_every", String(state.liveEvery));
    stopLive();
    startLive();
    window.dispatchEvent(new CustomEvent("live-every", { detail: state.liveEvery }));
  });
  document.addEventListener("visibilitychange", () => {   // no stream (and no server work) for a hidden tab
    if (document.hidden) { stopLive(); paintFoot(); } else { startLive(); tick(false); }
  });
  let resizeTimer;
  window.addEventListener("resize", () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(() => { if (state.view === "overview" || state.view === "network") renderView(false); }, 300); });

  // ---------------------------------------------------------------- country flags
  // One file of small SVG flags (country-flag-icons, MIT), fetched the first time a page shows a country;
  // each flag becomes an image of its own (a blob: URL), so a long list stays light. Until the file is
  // there flagImg() returns "" and the page shows its own fallback; "panel:flags" tells it to repaint.
  const FLAGS = { urls: null, at: 0 };
  function loadFlags() {
    if (FLAGS.urls || Date.now() - FLAGS.at < 60000) return;      // loaded, loading, or failed a minute ago
    FLAGS.at = Date.now();
    fetch("/flags.json", { credentials: "same-origin" })            // the browser keeps it (ETag)
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((m) => {
        const urls = {};
        for (const [cc, svg] of Object.entries(m)) {
          if (/^[A-Z]{2}$/.test(cc) && typeof svg === "string" && svg.startsWith("<svg")) urls[cc] = URL.createObjectURL(new Blob([svg], { type: "image/svg+xml" }));
        }
        FLAGS.urls = urls;
        window.dispatchEvent(new Event("panel:flags"));
      })
      .catch(() => { /* the pages keep their fallback; tried again later */ });
  }
  function flagImg(cc, cls = "") {
    const u = FLAGS.urls && FLAGS.urls[String(cc || "").toUpperCase()];
    if (!FLAGS.urls) loadFlags();
    return u ? `<img class="flag-img${cls ? ` ${cls}` : ""}" src="${u}" alt="" aria-hidden="true" decoding="async" draggable="false">` : "";
  }

  // ---------------------------------------------------------------- extension point (defender.js and future pages)
  window.Panel = {
    t, esc, nf, num, fmtBytes, fmtRate, fmtDur, ago, level, icon, api, post, act, toast, openDialog, confirmBox,
    table, pill, field, btnIcon, addButton, drawChart, sparkline, tween, setHTML, renderView, state, flagImg, loadFlags,
    registerView(view, impl, after) {
      const i = VIEWS.findIndex((v) => v.id === after);
      VIEWS.splice(i < 0 ? VIEWS.length : i + 1, 0, view);
      IMPL[view.id] = impl;
    },
    addStrings(en, fa) { Object.assign(T.en, en); Object.assign(T.fa, fa); },
    addIcons(map) { Object.assign(P, map); },
    setTabs(ids) { TAB_IDS.splice(0, TAB_IDS.length, ...ids); },
  };

  // Boot once every deferred script (the extra pages) has registered itself.
  document.addEventListener("DOMContentLoaded", () => {
    applyLocale();
    state.view = VIEWS.some((v) => v.id === location.hash.slice(1)) ? location.hash.slice(1) : "overview";
    renderNav();
    tick(true);
    setInterval(() => { if (!document.hidden) tick(false); }, 10000);
  });
})();
