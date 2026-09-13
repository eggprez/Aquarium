// Apply the last resolved theme before first paint; src/theme.ts writes this
// cache. Without it, light-mode users see a dark flash while the config is
// fetched over IPC.
//
// This lives in its own file rather than inline in index.html so the app can
// run under a Content-Security-Policy without `script-src 'unsafe-inline'`.
try {
  var t = localStorage.getItem("fellyjin.theme.resolved");
  document.documentElement.dataset.theme = t === "light" ? "light" : "dark";
} catch (e) {
  document.documentElement.dataset.theme = "dark";
}
