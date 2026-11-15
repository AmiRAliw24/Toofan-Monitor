// Runs in <head> before the first paint: applies the saved theme and language so the page never
// flashes the wrong theme (or flips direction) while the main script is still loading.
(function () {
  var d = document.documentElement, theme = null, lang = null;
  try { theme = localStorage.getItem("theme"); lang = localStorage.getItem("lang"); } catch (e) { /* storage blocked */ }
  if (theme !== "light" && theme !== "dark") {
    theme = window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  }
  if (lang !== "fa" && lang !== "en") lang = "en";
  d.setAttribute("data-theme", theme);
  d.setAttribute("lang", lang);
  d.setAttribute("dir", lang === "fa" ? "rtl" : "ltr");
  var meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute("content", theme === "dark" ? "#070b12" : "#eef2f8");
})();
