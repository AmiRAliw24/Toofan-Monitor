(() => {
  const T = {
    en: { title: "Server Monitor", signin_sub: "Sign in to continue", user: "Username", password: "Password", signin: "Sign in", otp: "Code from your authenticator app",
      otp_need: "Enter the 6-digit code from your authenticator app.", bad: "Wrong username or password", bad_otp: "Wrong username, password or code",
      locked: "Too many wrong attempts from this address. Try again in {m} minutes.", busy: "Too many requests. Wait a moment and try again.", net: "Could not reach the server" },
    fa: { title: "مانیتورینگ سرور", signin_sub: "برای ادامه وارد شوید", user: "نام کاربری", password: "رمز عبور", signin: "ورود", otp: "کد برنامه‌ی احراز هویت",
      otp_need: "کد ۶ رقمی برنامه‌ی احراز هویت (مثل Google Authenticator) را وارد کنید.", bad: "نام کاربری یا رمز عبور اشتباه است", bad_otp: "نام کاربری، رمز یا کد اشتباه است",
      locked: "تلاش اشتباه زیادی از این آدرس شده. {m} دقیقه‌ی دیگر دوباره امتحان کنید.", busy: "درخواست زیاد است. کمی صبر کنید و دوباره امتحان کنید.", net: "ارتباط با سرور برقرار نشد" },
  };
  let lang = "en", theme = "dark";
  try { lang = localStorage.getItem("lang") || lang; theme = localStorage.getItem("theme") || theme; } catch (e) { /* storage blocked */ }
  if (!T[lang]) lang = "en";
  const t = (k, v = {}) => T[lang][k].replace(/\{(\w+)\}/g, (_, x) => v[x]);
  document.documentElement.dataset.theme = theme;
  document.documentElement.lang = lang;
  document.documentElement.dir = lang === "fa" ? "rtl" : "ltr";
  document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = T[lang][el.dataset.i18n]; });
  document.title = T[lang].signin + " - " + T[lang].title;

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
