// Panel security: two-factor sign-in, active sessions, login protection and the security log.
(() => {
  "use strict";
  const P = window.Panel;
  if (!P) return;
  const { t, esc, num, ago, icon, api, post, act, toast, openDialog, confirmBox, table, pill, field } = P;

  P.addIcons({ key: '<circle cx="7.5" cy="15.5" r="4.5"/><path d="m10.7 12.3 8.8-8.8M16 6l3 3M14 8l2 2"/>', device: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>' });
  P.addStrings({
    sec_nav: "Panel security", sec_desc: "Who can sign in to this panel, from where, and what happened. Turn on two-factor sign-in for the strongest protection.",
    sec_score_good: "The panel is well protected", sec_score_warn: "The panel can be protected better",
    sec_2fa: "Two-factor sign-in", sec_2fa_on: "On: a code from your phone is needed at every sign-in.", sec_2fa_off: "Off: anyone who learns the password can sign in.",
    sec_2fa_enable: "Turn on", sec_2fa_disable: "Turn off", sec_2fa_step1: "Confirm with your password to start.", sec_2fa_step2: "Add this key to an authenticator app (Google Authenticator, Microsoft Authenticator, Authy, 2FAS …): choose \"Enter a setup key\", or open the link on your phone.",
    sec_2fa_key: "Setup key", sec_2fa_link: "Open in authenticator app", sec_2fa_code: "6-digit code from the app", sec_2fa_done: "Two-factor sign-in is on. Other devices were signed out.", sec_2fa_off_done: "Two-factor sign-in is off",
    sec_2fa_lost: "Lost the phone? On the server delete data/panel/totp.json to turn it off.", sec_password: "Password", sec_next: "Next", sec_confirm_disable: "Turn off two-factor sign-in",
    sec_sessions: "Signed-in devices", sec_sessions_sub: "Every browser that is signed in. A session ends after a day without use or after two weeks.", sec_device: "Device", sec_address: "Address",
    sec_started: "Signed in", sec_last: "Last active", sec_this: "this device", sec_revoke: "Sign out", sec_revoke_others: "Sign out all other devices", sec_revoked: "Signed out",
    sec_login: "Login protection", sec_login_sub: "{n} wrong attempts within 15 minutes lock the address (15 minutes, doubling up to a day). After {f} wrong attempts the firewall bans it for an hour.",
    sec_locked: "Locked addresses", sec_none_locked: "No address is locked.", sec_left: "Unlocks in", sec_attempts: "Wrong attempts", sec_unlock: "Unlock",
    sec_notify: "Telegram messages", sec_notify_login: "Sign-in from a new address", sec_notify_lock: "An address got locked out",
    sec_log: "Security log", sec_log_none: "Nothing yet.",
    sec_e_login: "Signed in", sec_e_login_failed: "Wrong password ({user})", sec_e_locked: "Locked out for {minutes} min", sec_e_logout: "Signed out", sec_e_password: "Password changed",
    sec_e_2fa_on: "Two-factor sign-in turned on", sec_e_2fa_off: "Two-factor sign-in turned off", sec_e_session_revoked: "A device was signed out", sec_e_sessions_revoked: "Other devices signed out",
    sec_e_unlocked: "{target} unlocked", sec_e_firewall_ban: "Banned by the firewall (login brute force)",
    sec_tips: "More protection", sec_tip_https: "Put HTTPS in front of the panel (Caddy or Nginx) so the password never travels in plain text.",
    sec_tip_ip: "Allow only your own addresses to open the panel: Firewall → Advanced → Who can open the panel.", sec_tip_pw: "Use a long password (12+ characters) that you use nowhere else: Settings → Change login.",
    sec_open_fw: "Open", sec_your_ip: "Your address now: {ip}",
  }, {
    sec_nav: "امنیت پنل", sec_desc: "چه کسی، از کجا وارد این پنل می‌شود و چه اتفاقی افتاده. برای قوی‌ترین محافظت ورود دومرحله‌ای را روشن کنید.",
    sec_score_good: "پنل خوب محافظت می‌شود", sec_score_warn: "پنل را می‌شود بهتر محافظت کرد",
    sec_2fa: "ورود دومرحله‌ای", sec_2fa_on: "روشن: در هر ورود کد گوشی لازم است.", sec_2fa_off: "خاموش: هر کس رمز را بداند می‌تواند وارد شود.",
    sec_2fa_enable: "روشن کردن", sec_2fa_disable: "خاموش کردن", sec_2fa_step1: "برای شروع رمز عبور را وارد کنید.", sec_2fa_step2: "این کلید را در یک برنامه‌ی احراز هویت (Google Authenticator، Microsoft Authenticator، Authy، 2FAS …) اضافه کنید: گزینه‌ی «وارد کردن کلید» را بزنید، یا لینک را روی گوشی باز کنید.",
    sec_2fa_key: "کلید راه‌اندازی", sec_2fa_link: "باز کردن در برنامه‌ی احراز هویت", sec_2fa_code: "کد ۶ رقمی برنامه", sec_2fa_done: "ورود دومرحله‌ای روشن شد. دستگاه‌های دیگر خارج شدند.", sec_2fa_off_done: "ورود دومرحله‌ای خاموش شد",
    sec_2fa_lost: "گوشی را گم کردید؟ روی سرور فایل data/panel/totp.json را پاک کنید تا خاموش شود.", sec_password: "رمز عبور", sec_next: "بعدی", sec_confirm_disable: "خاموش کردن ورود دومرحله‌ای",
    sec_sessions: "دستگاه‌های واردشده", sec_sessions_sub: "هر مرورگری که وارد شده. نشست بعد از یک روز بی‌استفاده یا بعد از دو هفته تمام می‌شود.", sec_device: "دستگاه", sec_address: "آدرس",
    sec_started: "ورود", sec_last: "آخرین فعالیت", sec_this: "همین دستگاه", sec_revoke: "خروج", sec_revoke_others: "خروج همه‌ی دستگاه‌های دیگر", sec_revoked: "خارج شد",
    sec_login: "محافظت ورود", sec_login_sub: "{n} تلاش اشتباه در ۱۵ دقیقه آدرس را قفل می‌کند (۱۵ دقیقه، هر بار دو برابر تا یک روز). بعد از {f} تلاش اشتباه، فایروال آن را یک ساعت مسدود می‌کند.",
    sec_locked: "آدرس‌های قفل‌شده", sec_none_locked: "هیچ آدرسی قفل نیست.", sec_left: "باز شدن تا", sec_attempts: "تلاش اشتباه", sec_unlock: "باز کردن",
    sec_notify: "پیام تلگرام", sec_notify_login: "ورود از آدرس جدید", sec_notify_lock: "قفل شدن یک آدرس",
    sec_log: "گزارش امنیتی", sec_log_none: "هنوز چیزی نیست.",
    sec_e_login: "ورود", sec_e_login_failed: "رمز اشتباه ({user})", sec_e_locked: "{minutes} دقیقه قفل شد", sec_e_logout: "خروج", sec_e_password: "رمز عوض شد",
    sec_e_2fa_on: "ورود دومرحله‌ای روشن شد", sec_e_2fa_off: "ورود دومرحله‌ای خاموش شد", sec_e_session_revoked: "یک دستگاه خارج شد", sec_e_sessions_revoked: "دستگاه‌های دیگر خارج شدند",
    sec_e_unlocked: "قفل {target} باز شد", sec_e_firewall_ban: "توسط فایروال مسدود شد (حمله به ورود)",
    sec_tips: "محافظت بیشتر", sec_tip_https: "جلوی پنل HTTPS بگذارید (Caddy یا Nginx) تا رمز هیچ‌وقت بدون رمزنگاری منتقل نشود.",
    sec_tip_ip: "فقط آدرس‌های خودتان اجازه‌ی باز کردن پنل را داشته باشند: فایروال ← پیشرفته ← چه کسی پنل را باز کند.", sec_tip_pw: "رمز طولانی (۱۲+ کاراکتر) که جای دیگری استفاده نمی‌کنید: تنظیمات ← تغییر اطلاعات ورود.",
    sec_open_fw: "باز کردن", sec_your_ip: "آدرس فعلی شما: {ip}",
  });

  let S = null, root = null;
  const device = (ua) => {
    ua = ua || "";
    const b = /Edg\//.test(ua) ? "Edge" : /OPR\//.test(ua) ? "Opera" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : /curl|python|Go-http/i.test(ua) ? "Script" : "Browser";
    const o = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS" : /Windows/.test(ua) ? "Windows" : /Mac OS/.test(ua) ? "macOS" : /Linux/.test(ua) ? "Linux" : "";
    return o ? `${b} · ${o}` : b;
  };
  const left = (s) => (s > 3600 ? `${(s / 3600).toFixed(1)}h` : `${Math.ceil(s / 60)}m`);
  const sw = (name, on, label) => `<label class="df-switch"><span class="switch"><input type="checkbox" name="${name}" ${on ? "checked" : ""}><span></span></span><span><b>${esc(label)}</b></span></label>`;

  function html() {
    const good = S.totp;
    const sessions = table([
      { h: "sec_device", cls: "strong", cell: (r) => `${icon("device")} ${esc(device(r.ua))}${r.current ? `<span class="tag">${esc(t("sec_this"))}</span>` : ""}` },
      { h: "sec_address", cell: (r) => num(esc(r.ip)) },
      { h: "sec_started", cell: (r) => esc(ago(r.created)) },
      { h: "sec_last", cell: (r) => esc(ago(r.last)) },
      { h: "actions", cell: (r) => (r.current ? "–" : `<button type="button" class="btn small" data-a="revoke" data-id="${esc(r.id)}">${esc(t("sec_revoke"))}</button>`) },
    ], S.sessions);
    const locks = S.locks.length ? table([
      { h: "sec_address", cls: "strong", cell: (r) => num(esc(r.ip)) },
      { h: "sec_attempts", cell: (r) => num(r.failures) },
      { h: "sec_left", cell: (r) => num(esc(left(r.left))) },
      { h: "actions", cell: (r) => `<button type="button" class="btn small" data-a="unlock" data-ip="${esc(r.ip)}">${esc(t("sec_unlock"))}</button>` },
    ], S.locks) : `<div class="empty">${esc(t("sec_none_locked"))}</div>`;
    const logRows = S.log.length ? `<ol class="df-events">${S.log.slice(0, 40).map((e) => {
      const ic = { login: "okmark", login_failed: "alert", locked: "lock", logout: "logout", password: "key", "2fa_on": "shield", "2fa_off": "alert", firewall_ban: "ban" }[e.kind] || "bell";
      const bad = ["login_failed", "locked", "firewall_ban", "2fa_off"].includes(e.kind);
      return `<li class="${bad ? "ev-attack_start" : e.kind === "login" ? "ev-allow" : ""}"><span class="ev-ic">${icon(ic)}</span><span class="ev-t">${esc(t(`sec_e_${e.kind}`, e))} <span class="muted" dir="ltr">${esc(e.ip || "")}</span></span><time>${esc(ago(e.t))}</time></li>`;
    }).join("")}</ol>` : `<div class="empty">${esc(t("sec_log_none"))}</div>`;
    return `<section class="card hero df-hero ${good ? "" : "warn"}"><div class="hero-icon">${icon(good ? "shield" : "alert")}</div>
        <div class="hero-text"><h2>${esc(t(good ? "sec_score_good" : "sec_score_warn"))}</h2><p>${esc(t(good ? "sec_2fa_on" : "sec_2fa_off"))}</p>
        <div class="hero-meta"><span class="chip">${icon("key")}${esc(t("sec_2fa"))} <b>${esc(good ? "✓" : "–")}</b></span><span class="chip">${icon("device")}${esc(t("sec_sessions"))} <b>${num(S.sessions.length)}</b></span>
          <span class="chip">${esc(t("sec_your_ip", { ip: S.ip }))}</span></div></div>
        <div class="df-hero-act"><button type="button" class="btn ${good ? "ghost danger small" : "primary df-cta"}" data-a="${good ? "2fa-off" : "2fa-on"}">${icon("key")}<span>${esc(t(good ? "sec_2fa_disable" : "sec_2fa_enable"))}</span></button></div></section>
      <section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("device")}${esc(t("sec_sessions"))}</h3><p class="muted">${esc(t("sec_sessions_sub"))}</p></div>
        ${S.sessions.length > 1 ? `<button type="button" class="btn small" data-a="revoke-others">${esc(t("sec_revoke_others"))}</button>` : ""}</div>${sessions}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("lock")}${esc(t("sec_login"))}</h3><p class="muted">${esc(t("sec_login_sub", { n: S.limits.lock_after, f: S.limits.firewall_after }))}</p></div>
        <h4 class="df-h4">${esc(t("sec_locked"))}</h4>${locks}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("send")}${esc(t("sec_notify"))}</h3></div><form class="subcard" data-f="sec-notify">${sw("notify_login", S.settings.notify_login, t("sec_notify_login"))}${sw("notify_lock", S.settings.notify_lock, t("sec_notify_lock"))}</form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("shield")}${esc(t("sec_tips"))}</h3></div><ul class="df-covers">
        <li>${icon("okmark")}<span>${esc(t("sec_tip_ip"))} <a href="#defender" data-a="open-fw">${esc(t("sec_open_fw"))}</a></span></li><li>${icon("okmark")}<span>${esc(t("sec_tip_pw"))}</span></li><li>${icon("okmark")}<span>${esc(t("sec_tip_https"))}</span></li></ul></section>
      <section class="sec"><div class="sec-head"><h3>${icon("clock")}${esc(t("sec_log"))}</h3></div>${logRows}</section>`;
  }

  async function build() {
    S = await api("/api/security");
    return { html: html(), tools: "" };
  }
  const repaint = () => { if (root) root.innerHTML = html(); };

  function enable2fa() {
    openDialog({
      title: t("sec_2fa"), submit: t("sec_next"),
      body: `<p>${esc(t("sec_2fa_step1"))}</p>${field(t("sec_password"), '<input type="password" name="password" required autocomplete="current-password">')}`,
      onSubmit: async (form) => {
        const r = await post("/api/security/2fa/setup", { password: form.elements.password.value });
        setTimeout(() => step2(r), 50);
      },
    });
  }
  function step2(r) {
    const key = r.secret.match(/.{1,4}/g).join(" ");
    openDialog({
      title: t("sec_2fa"), submit: t("sec_2fa_enable"),
      body: `<p>${esc(t("sec_2fa_step2"))}</p>
        <div class="field"><label>${esc(t("sec_2fa_key"))}</label><div class="sec-key" dir="ltr">${esc(key)}</div>
        <p class="row-actions"><button type="button" class="btn small" data-copy="${esc(r.secret)}">${icon("copy")}<span>${esc(t("copy"))}</span></button>
          <a class="btn small" href="${esc(r.uri)}">${icon("key")}<span>${esc(t("sec_2fa_link"))}</span></a></p></div>
        ${field(t("sec_2fa_code"), '<input name="code" inputmode="numeric" autocomplete="one-time-code" required pattern="[0-9 ]{6,7}" maxlength="7" dir="ltr">')}
        <p class="muted">${esc(t("sec_2fa_lost"))}</p>`,
      onSubmit: async (form) => {
        S = await post("/api/security/2fa/enable", { code: form.elements.code.value });
        toast(t("sec_2fa_done"));
        repaint();
      },
    });
  }
  function disable2fa() {
    openDialog({
      title: t("sec_confirm_disable"), submit: t("sec_2fa_disable"), danger: true,
      body: `${field(t("sec_password"), '<input type="password" name="password" required autocomplete="current-password">')}${field(t("sec_2fa_code"), '<input name="code" inputmode="numeric" required maxlength="7" dir="ltr">')}`,
      onSubmit: async (form) => {
        S = await post("/api/security/2fa/disable", { password: form.elements.password.value, code: form.elements.code.value });
        toast(t("sec_2fa_off_done"));
        repaint();
      },
    });
  }

  function bind(r) {
    root = r;
    r.addEventListener("click", async (e) => {
      const b = e.target.closest("[data-a]");
      if (!b) return;
      const a = b.dataset.a;
      if (a === "open-fw") { try { localStorage.setItem("df_tab", "advanced"); } catch (x) { /* ignore */ } return; }
      e.preventDefault();
      if (a === "2fa-on") return enable2fa();
      if (a === "2fa-off") return disable2fa();
      if (a === "revoke") { const x = await act(b, () => post("/api/security/revoke", { id: b.dataset.id }), t("sec_revoked")); if (x) { S = x; repaint(); } }
      if (a === "revoke-others") {
        if (!(await confirmBox({ message: t("sec_revoke_others"), label: t("sec_revoke") }))) return;
        const x = await act(b, () => post("/api/security/revoke-others", {}), t("sec_revoked")); if (x) { S = x; repaint(); }
      }
      if (a === "unlock") { const x = await act(b, () => post("/api/security/unlock", { ip: b.dataset.ip }), t("sec_unlock")); if (x) { S = x; repaint(); } }
    });
    r.addEventListener("change", async (e) => {
      if (!e.target.closest('form[data-f="sec-notify"]')) return;
      const x = await act(e.target, () => post("/api/security/settings", { [e.target.name]: e.target.checked }), t("saved"));
      if (x) S = x; else e.target.checked = !e.target.checked;
    });
  }

  P.registerView({ id: "security", icon: "key", label: "sec_nav", desc: "sec_desc", group: "manage", static: true }, { build, bind }, "settings");
})();
