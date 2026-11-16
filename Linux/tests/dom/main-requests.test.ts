// src/main.ts and Seerr: the Requests entry in the sidebar (there only while a
// Seerr server is connected), the two routes, and what the shell does when the
// connection comes or goes.
import { afterEach, describe, expect, it } from "vitest";
import { onInvoke } from "../helpers/tauri";
import { bootShell, page, settle, teardownShell } from "../helpers/main-shell";

afterEach(teardownShell);

const CONNECTED = {
  connected: true,
  server: "https://seerr.test",
  host: "seerr.test",
  secure: true,
  user_id: 7,
  user_name: "Ann",
  permissions: 32,
  settings: {},
  needs_reconnect: false,
  storage: "keyring",
};

function navRoutes(): string[] {
  return [...document.querySelectorAll("#nav .nav-item")].map((n) => `${n.textContent} ${n.getAttribute("data-route")}`);
}

describe("Requests in the shell", () => {
  it("has no sidebar entry without a Seerr server", async () => {
    await bootShell();
    expect(navRoutes().some((r) => r.includes("Requests"))).toBe(false);
    expect(navRoutes()).toContain("Favorites #/favorites");
  });

  it("has one while a server is connected, after Favorites, and routes to both pages", async () => {
    const shell = await bootShell({ invokes: { seerr_status: { ...CONNECTED } } });
    const routes = navRoutes();
    expect(routes).toContain("Requests #/requests");
    expect(routes.indexOf("Requests #/requests")).toBe(routes.indexOf("Favorites #/favorites") + 1);

    await shell.go("#/requests");
    expect(page()).toBe("requests");
    expect(document.querySelector('.nav-item[data-route="#/requests"]')!.classList.contains("active")).toBe(true);
    await shell.go("#/request/movie/603");
    expect(page()).toBe("request:movie/603");
    await shell.go("#/request/tv/1396");
    expect(page()).toBe("request:tv/1396");
  });

  it("is not offered while the session has run out", async () => {
    await bootShell({ invokes: { seerr_status: { ...CONNECTED, needs_reconnect: true } } });
    expect(navRoutes().some((r) => r.includes("Requests"))).toBe(false);
  });

  it("gains and loses the entry as the connection comes and goes, and redraws a Seerr page", async () => {
    const shell = await bootShell();
    const seerr = await import("../../src/seerr");
    await shell.go("#/requests");
    expect(shell.views.requests).toHaveBeenCalledTimes(1);

    // Connected from Settings.
    onInvoke("seerr_status", { ...CONNECTED });
    await seerr.loadStatus();
    await settle();
    expect(navRoutes()).toContain("Requests #/requests");
    expect(shell.views.requests).toHaveBeenCalledTimes(2);

    // A detail that isn't the connection itself redraws nothing.
    onInvoke("seerr_status", { ...CONNECTED, permissions: 1056 });
    await seerr.loadStatus();
    await settle();
    expect(shell.views.requests).toHaveBeenCalledTimes(2);

    // Disconnected.
    onInvoke("seerr_status", { connected: false });
    await seerr.loadStatus();
    await settle();
    expect(navRoutes().some((r) => r.includes("Requests"))).toBe(false);
    expect(shell.views.requests).toHaveBeenCalledTimes(3);
  });

  it("draws the Requests page again when a request is made or withdrawn elsewhere", async () => {
    const shell = await bootShell({ invokes: { seerr_status: { ...CONNECTED } } });
    const seerr = await import("../../src/seerr");
    await shell.go("#/requests");
    const before = shell.views.requests.mock.calls.length;
    document.dispatchEvent(new CustomEvent(seerr.SEERR_REQUESTS_CHANGED));
    await settle();
    expect(shell.views.requests.mock.calls.length).toBe(before + 1);
    // Not while some other page is up.
    await shell.go("#/home");
    document.dispatchEvent(new CustomEvent(seerr.SEERR_REQUESTS_CHANGED));
    await settle();
    expect(shell.views.requests.mock.calls.length).toBe(before + 1);
  });

  it("shows the offline screen for both pages when the Jellyfin server is unreachable", async () => {
    const shell = await bootShell({ ping: false, invokes: { seerr_status: { ...CONNECTED } } });
    await shell.go("#/requests");
    expect(document.querySelector("#content .offline-screen")).not.toBeNull();
    expect(shell.views.requests).not.toHaveBeenCalled();
    await shell.go("#/request/movie/603");
    expect(shell.views.request).not.toHaveBeenCalled();
  });

  it("forgets the connection on the way to the sign-in screen", async () => {
    await bootShell({ invokes: { seerr_status: { ...CONNECTED } } });
    const seerr = await import("../../src/seerr");
    expect(seerr.isConnected()).toBe(true);
    document.dispatchEvent(new CustomEvent("aquarium-auth-expired"));
    await settle();
    expect(seerr.isConnected()).toBe(false);
  });
});
