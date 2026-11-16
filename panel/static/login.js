(() => {
  const T = {
    en: { title: "Server Monitor", signin_sub: "Sign in to continue", user: "Username", password: "Password", signin: "Sign in", otp: "Code from your authenticator app",
      otp_need: "Enter the 6-digit code from your authenticator app.", bad: "Wrong username or password", bad_otp: "Wrong username, password or code",
      locked: "Too many wrong attempts from this address. Try again in {m} minutes.", busy: "Too many requests. Wait a moment and try again.", net: "Could not reach the server",
      other: "فارسی", show: "Show password", hide: "Hide password", dark: "Dark theme (switch to light)", light: "Light theme (switch to dark)" },
    fa: { title: "مانیتورینگ سرور", signin_sub: "برای ادامه وارد شوید", user: "نام کاربری", password: "رمز عبور", signin: "ورود", otp: "کد برنامه‌ی احراز هویت",
      otp_need: "کد ۶ رقمی برنامه‌ی احراز هویت (مثل Google Authenticator) را وارد کنید.", bad: "نام کاربری یا رمز عبور اشتباه است", bad_otp: "نام کاربری، رمز یا کد اشتباه است",
      locked: "تلاش اشتباه زیادی از این آدرس شده. {m} دقیقه‌ی دیگر دوباره امتحان کنید.", busy: "درخواست زیاد است. کمی صبر کنید و دوباره امتحان کنید.", net: "ارتباط با سرور برقرار نشد",
      other: "English", show: "نمایش رمز", hide: "پنهان کردن رمز", dark: "تم تیره (تغییر به روشن)", light: "تم روشن (تغییر به تیره)" },
  };
  const save = (k, v) => { try { localStorage.setItem(k, v); } catch (e) { /* storage blocked */ } };
  let lang = null;
  try { lang = localStorage.getItem("lang"); } catch (e) { /* storage blocked */ }
  if (!T[lang]) lang = (navigator.language || "").toLowerCase().startsWith("fa") ? "fa" : "en";   // first visit: the browser's language
  let theme = document.documentElement.dataset.theme || "dark";   // chosen by boot.js before the first paint
  const t = (k, v = {}) => T[lang][k].replace(/\{(\w+)\}/g, (_, x) => v[x]);
  const SUN = '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>';
  const MOON = '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/></svg>';
  const EYE = '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>';
  const EYE_OFF = '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 3l18 18M10.6 5.1A10.7 10.7 0 0 1 12 5c6.4 0 10 7 10 7a17 17 0 0 1-3.2 4.1M6.6 6.6A17 17 0 0 0 2 12s3.6 7 10 7a9.8 9.8 0 0 0 5.4-1.6"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>';
  const pw = document.getElementById("password"), pwBtn = document.getElementById("pw-toggle");
  function paint() {
    const d = document.documentElement;
    d.dataset.theme = theme;
    d.lang = lang;
    d.dir = lang === "fa" ? "rtl" : "ltr";
    document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = T[lang][el.dataset.i18n]; });
    document.title = T[lang].signin + " - " + T[lang].title;
    document.querySelector("#lang span").textContent = t("other");
    const th = document.getElementById("theme");
    th.innerHTML = theme === "dark" ? SUN : MOON;
    th.setAttribute("aria-label", t(theme));
    th.title = t(theme);
    const shown = pw.type === "text";
    pwBtn.innerHTML = shown ? EYE_OFF : EYE;
    pwBtn.setAttribute("aria-label", t(shown ? "hide" : "show"));
    pwBtn.setAttribute("aria-pressed", String(shown));
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", theme === "dark" ? "#070b12" : "#eef2f8");
  }
  paint();
  document.getElementById("lang").addEventListener("click", () => { lang = lang === "fa" ? "en" : "fa"; save("lang", lang); paint(); });
  document.getElementById("theme").addEventListener("click", () => { theme = theme === "dark" ? "light" : "dark"; save("theme", theme); paint(); });
  pwBtn.addEventListener("click", () => { pw.type = pw.type === "password" ? "text" : "password"; paint(); pw.focus(); });

  const form = document.getElementById("form"), err = document.getElementById("error"), btn = document.getElementById("submit");
  const otpBox = document.getElementById("otp-field"), otp = document.getElementById("otp");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    err.textContent = "";
    btn.disabled = true;
    try {
      const r = await fetch("/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ user: form.user.value, password: form.password.value, otp: otp.value }),
      });
      if (r.ok) { location.replace("/"); return; }
      const d = await r.json().catch(() => ({}));
      if (d.otp && !otp.value) {             // password was right: now the second factor
        otpBox.hidden = false;
        err.textContent = t("otp_need");
        otp.focus();
      } else if (r.status === 429 && d.locked) {
        err.textContent = t("locked", { m: Math.max(1, Math.ceil(d.locked / 60)) });
      } else if (r.status === 429) {
        err.textContent = t("busy");
      } else {
        err.textContent = otpBox.hidden ? t("bad") : t("bad_otp");
        otp.value = "";
      }
    } catch (x) {
      err.textContent = t("net");
    }
    btn.disabled = false;
    if (otpBox.hidden) form.password.select();
  });
})();
