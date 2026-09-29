// Apply the last resolved theme before first paint; src/theme.ts writes this
// cache. Without it, light-mode users see a dark flash while the config is
// fetched over IPC.
//
// This lives in its own file rather than inline in index.html so the app can
// run under a Content-Security-Policy without `script-src 'unsafe-inline'`.
// The app used to be called FellyJin, and its localStorage keys were named
// after it. Carry them over once so preferences survive the rename. This runs
// before any module script, so everything else only ever sees the new keys.
try {
  for (var i = localStorage.length - 1; i >= 0; i--) {
    var k = localStorage.key(i);
    if (k && k.indexOf("fellyjin") === 0) {
      var nk = "aquarium" + k.slice("fellyjin".length);
      if (localStorage.getItem(nk) === null) localStorage.setItem(nk, localStorage.getItem(k));
      localStorage.removeItem(k);
    }
  }
} catch (e) {}

try {
  var t = localStorage.getItem("aquarium.theme.resolved");
  document.documentElement.dataset.theme = t === "light" ? "light" : "dark";
} catch (e) {
  document.documentElement.dataset.theme = "dark";
}
