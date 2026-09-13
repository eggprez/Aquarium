import * as api from "../api";
import { el, clear } from "../ui";

export function renderLogin(root: HTMLElement, onSuccess: () => void): void {
  clear(root);
  const cfg = api.getConfig();

  const serverInput = el("input", {
    class: "control lg",
    type: "text",
    placeholder: "jellyfin.example.com",
    value: cfg.server ?? "",
    autocapitalize: "off",
    spellcheck: "false",
  });
  const userInput = el("input", {
    class: "control lg",
    type: "text",
    placeholder: "Username",
    autocapitalize: "off",
    autocomplete: "username",
  });
  const passInput = el("input", {
    class: "control lg",
    type: "password",
    placeholder: "Password",
    autocomplete: "current-password",
  }) as HTMLInputElement;
  const errorBox = el("div", { class: "login-error" });
  // Shown only when the server that answered has no TLS. Sign-in doesn't
  // proceed until the user has read it and clicked again.
  const insecureBox = el("div", { class: "login-warning", hidden: "" });
  const submit = el("button", { class: "btn primary", type: "submit" }, ["Sign in"]) as HTMLButtonElement;

  const form = el("form", { class: "login-card" }, [
    el("div", { class: "login-brand" }, [
      el("img", { src: "/fellyjin-logo.png", alt: "", width: "56", height: "56" }),
      el("span", { class: "wordmark" }, [el("span", {}, ["Felly"]), el("b", {}, ["Jin"])]),
    ]),
    el("h1", {}, ["Connect to Jellyfin"]),
    el("label", {}, ["Server address"]),
    serverInput,
    el("label", {}, ["Username"]),
    userInput,
    el("label", {}, ["Password"]),
    passInput,
    insecureBox,
    errorBox,
    submit,
    el("div", { class: "login-hint" }, [
      "Your credentials are sent only to your own Jellyfin server, over HTTPS when it offers it.",
    ]),
  ]);

  /**
   * The address the user has agreed to use unencrypted. A bare hostname is
   * resolved over https first; when only plaintext answers, the password and
   * every later request would go over the wire readable by anything on the
   * path, so that gets said out loud instead of silently prefixing "http://".
   */
  let acceptedInsecure: string | null = null;
  /** The address text the warning was raised for; editing it withdraws consent. */
  let acceptedTyped: string | null = null;

  function warnInsecure(typed: string, server: string): void {
    acceptedInsecure = server;
    acceptedTyped = typed;
    clear(insecureBox);
    insecureBox.append(
      el("strong", {}, ["This server isn't encrypted."]),
      el("span", {}, [
        ` ${server} answered over plain HTTP, so your password and everything you watch would be readable by anything between you and it. Safe enough on a home network you trust; not over the internet.`,
      ])
    );
    insecureBox.removeAttribute("hidden");
    submit.textContent = "Connect anyway";
  }

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    errorBox.textContent = "";
    const typed = serverInput.value.trim();
    if (!typed) {
      errorBox.textContent = "Enter your server address.";
      return;
    }
    // Editing the address withdraws any agreement to use it unencrypted.
    if (acceptedTyped !== null && typed !== acceptedTyped) {
      acceptedInsecure = null;
      acceptedTyped = null;
      insecureBox.setAttribute("hidden", "");
    }

    submit.disabled = true;
    submit.textContent = "Connecting…";
    try {
      const probe = await api.probeServer(typed);
      if (!probe.secure && acceptedInsecure !== probe.server) {
        warnInsecure(typed, probe.server);
        return;
      }
      submit.textContent = "Signing in…";
      await api.login(probe.server, userInput.value.trim(), passInput.value);
      // Don't leave the password sitting in the DOM for the life of the
      // window; the session is established and it is not needed again.
      passInput.value = "";
      form.reset();
      onSuccess();
    } catch (e: any) {
      errorBox.textContent = e.message ?? String(e);
    } finally {
      submit.disabled = false;
      if (submit.textContent === "Connecting…" || submit.textContent === "Signing in…") {
        submit.textContent = acceptedInsecure ? "Connect anyway" : "Sign in";
      }
    }
  });

  root.append(form);
}
