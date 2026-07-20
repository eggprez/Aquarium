import * as api from "../api";
import { el, clear } from "../ui";

export function renderLogin(root: HTMLElement, onSuccess: () => void): void {
  clear(root);
  const cfg = api.getConfig();

  const serverInput = el("input", {
    type: "text",
    placeholder: "http://192.168.1.10:8096",
    value: cfg.server ?? "",
    autocapitalize: "off",
    spellcheck: "false",
  });
  const userInput = el("input", { type: "text", placeholder: "Username", autocapitalize: "off" });
  const passInput = el("input", { type: "password", placeholder: "Password" });
  const errorBox = el("div", { class: "login-error" });
  const submit = el("button", { class: "btn primary", type: "submit" }, ["Sign in"]) as HTMLButtonElement;

  const form = el("form", { class: "login-card" }, [
    el("h1", {}, [
      el("div", { class: "brand-mark" }, ["▶"]),
      "Connect to Jellyfin",
    ]),
    el("label", {}, ["Server address"]),
    serverInput,
    el("label", {}, ["Username"]),
    userInput,
    el("label", {}, ["Password"]),
    passInput,
    errorBox,
    submit,
    el("div", { class: "login-hint" }, [
      "Your credentials are sent only to your own Jellyfin server.",
    ]),
  ]);

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    errorBox.textContent = "";
    let server = serverInput.value.trim();
    if (!server) {
      errorBox.textContent = "Enter your server address.";
      return;
    }
    if (!/^https?:\/\//i.test(server)) server = "http://" + server;
    submit.disabled = true;
    submit.textContent = "Connecting…";
    try {
      await api.checkServer(server);
      submit.textContent = "Signing in…";
      await api.login(server, userInput.value.trim(), passInput.value);
      onSuccess();
    } catch (e: any) {
      errorBox.textContent = e.message ?? String(e);
    } finally {
      submit.disabled = false;
      submit.textContent = "Sign in";
    }
  });

  root.append(form);
}
