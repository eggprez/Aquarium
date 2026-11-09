import * as api from "../api";
import { el, clear, toast } from "../ui";

export interface LoginOptions {
  /** Signing in to another account while one is still in use (Settings →
   *  Add Account). The current account isn't offered, and Cancel goes back. */
  adding?: boolean;
  onCancel?: () => void;
}

/** "123456" → "123 456": easier to read out and type in. */
function spaced(code: string): string {
  return code.length === 6 ? `${code.slice(0, 3)} ${code.slice(3)}` : code;
}

function hostLabel(server: string): string {
  return server.replace(/^https?:\/\//, "");
}

/** A round picture of the user, with their initial behind it for when the
 *  server has none (it answers 404 and the image is dropped). */
function avatar(server: string, userId: string, name: string, size = 32): HTMLElement {
  const box = el("span", { class: "login-avatar", style: `width:${size}px;height:${size}px` }, [
    (name.trim()[0] ?? "?").toUpperCase(),
  ]);
  const img = el("img", { src: api.avatarUrl(server, userId, size * 2), alt: "", loading: "lazy" });
  img.addEventListener("error", () => img.remove());
  box.append(img);
  return box;
}

export function renderLogin(root: HTMLElement, onSuccess: () => void, opts: LoginOptions = {}): void {
  clear(root);
  const cfg = api.getConfig();
  /** Bumped whenever the screen is redrawn or left: any poll or probe started
   *  for an earlier generation stops when it sees the number move on. */
  let generation = 0;
  const live = (g: number) => g === generation && document.contains(card);

  const card = el("div", { class: "login-card" });
  root.append(card);

  const brand = (): HTMLElement =>
    el("div", { class: "login-brand" }, [
      el("img", { src: "/aquarium-logo.svg", alt: "", width: "56", height: "56" }),
      el("span", { class: "wordmark" }, [el("span", {}, ["Aqua"]), el("b", {}, ["rium"])]),
    ]);

  const hint = (): HTMLElement =>
    el("div", { class: "login-hint" }, [
      "Your credentials are sent only to your own Jellyfin server, over HTTPS when it offers it.",
    ]);

  // ---------- Step 1: which server ----------

  function addressStep(prefill: string): void {
    generation++;
    const g = generation;
    clear(card);
    card.classList.remove("wide");

    const serverInput = el("input", {
      class: "control lg",
      type: "text",
      placeholder: "jellyfin.example.com",
      value: prefill,
      autocapitalize: "off",
      spellcheck: "false",
    }) as HTMLInputElement;
    const errorBox = el("div", { class: "login-error" });
    // Shown only when the server that answered has no TLS. Nothing proceeds
    // until the user has read it and clicked again.
    const insecureBox = el("div", { class: "login-warning", hidden: "" });
    const submit = el("button", { class: "btn primary", type: "submit" }, ["Connect"]) as HTMLButtonElement;
    const accountsBox = el("div", { class: "login-section", hidden: "" });
    const serversBox = el("div", { class: "login-section" });

    const form = el("form", { class: "login-form" }, [
      el("label", {}, ["Server address"]),
      serverInput,
      el("div", { class: "login-hint" }, [
        "The address you open Jellyfin at in a browser — for example http://192.168.1.10:8096 or https://jellyfin.example.com.",
      ]),
      serversBox,
      insecureBox,
      errorBox,
      el("div", { class: "login-buttons" }, [
        opts.adding
          ? el("button", { class: "btn", type: "button", onClick: () => opts.onCancel?.() }, ["Cancel"])
          : null,
        submit,
      ]),
    ]);

    card.append(
      brand(),
      el("h1", {}, [opts.adding ? "Add an Account" : "Connect to Jellyfin"]),
      opts.adding
        ? el("div", { class: "login-hint center" }, [
            "Sign in to another user on this server, or to a different server, without signing this one out.",
          ])
        : "",
      accountsBox,
      form,
      hint()
    );

    // Accounts still signed in here: a click continues as them, no password.
    void api.listAccounts().then((list) => {
      if (!live(g)) return;
      const offered = list.filter((a) => !a.current || !opts.adding);
      if (!offered.length) return;
      accountsBox.removeAttribute("hidden");
      accountsBox.append(
        el("div", { class: "login-section-title" }, ["Accounts on this device"]),
        el("div", { class: "login-list" }, offered.map((a) =>
          el("button", {
            class: "login-row",
            type: "button",
            title: a.server,
            onClick: async (ev: Event) => {
              const btn = ev.currentTarget as HTMLButtonElement;
              btn.disabled = true;
              try {
                await api.switchAccount(a.key);
                onSuccess();
              } catch (e: any) {
                btn.disabled = false;
                errorBox.textContent = e.message ?? String(e);
              }
            },
          }, [
            avatar(a.server, a.user_id, a.user_name || "?", 28),
            el("span", { class: "login-row-name" }, [a.user_name || "Unnamed user"]),
            el("span", { class: "login-row-detail" }, [a.server_name || hostLabel(a.server)]),
          ])
        )),
        el("div", { class: "login-hint" }, ["Click an account to continue as them, or sign in below."])
      );
    });

    // Servers to pick from: signed in to before, then whatever answers the
    // broadcast. A click puts the address in the field and connects.
    const known = api.knownServers();
    let found: api.DiscoveredServer[] = [];
    let looking = true;
    const drawServers = () => {
      clear(serversBox);
      const pick = (address: string) => {
        serverInput.value = address;
        form.requestSubmit();
      };
      const row = (name: string, detail: string, address: string) =>
        el("button", { class: "login-row", type: "button", title: address, onClick: () => pick(address) }, [
          el("span", { class: "login-row-name" }, [name]),
          el("span", { class: "login-row-detail" }, [detail]),
        ]);
      if (known.length) {
        serversBox.append(
          el("div", { class: "login-section-title" }, ["Signed in to before"]),
          el("div", { class: "login-list" }, known.map((k) => row(k.name || hostLabel(k.server), hostLabel(k.server), k.server)))
        );
      }
      const fresh = found.filter((f) => !known.some((k) => k.server === f.address));
      if (fresh.length) {
        serversBox.append(
          el("div", { class: "login-section-title" }, ["On your network"]),
          el("div", { class: "login-list" }, fresh.map((f) => row(f.name, hostLabel(f.address), f.address)))
        );
      }
      if (looking) {
        serversBox.append(el("div", { class: "login-hint" }, [fresh.length ? "Still looking on your network…" : "Looking on your network…"]));
      }
    };
    drawServers();
    void api.discoverServers().then((list) => {
      if (!live(g)) return;
      found = list;
      looking = false;
      drawServers();
    });

    let acceptedInsecure: string | null = null;
    let acceptedTyped: string | null = null;

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
        submit.textContent = "Connect";
      }
      submit.disabled = true;
      submit.textContent = "Connecting…";
      try {
        const probe = await api.probeServer(typed);
        if (!live(g)) return;
        if (!probe.secure && acceptedInsecure !== probe.server) {
          acceptedInsecure = probe.server;
          acceptedTyped = typed;
          clear(insecureBox);
          insecureBox.append(
            el("strong", {}, ["This server isn't encrypted."]),
            el("span", {}, [
              ` ${probe.server} answered over plain HTTP, so your password and everything you watch would be readable by anything between you and it. Safe enough on a home network you trust; not over the internet.`,
            ])
          );
          insecureBox.removeAttribute("hidden");
          submit.textContent = "Connect anyway";
          return;
        }
        await credentialsStep(probe);
      } catch (e: any) {
        errorBox.textContent = e.message ?? String(e);
      } finally {
        submit.disabled = false;
        if (submit.textContent === "Connecting…") submit.textContent = acceptedInsecure ? "Connect anyway" : "Connect";
      }
    });

    if (!prefill) serverInput.focus();
  }

  // ---------- Step 2: who, with a password or a code ----------

  async function credentialsStep(probe: api.ServerProbe): Promise<void> {
    const [users, qcOn, accounts] = await Promise.all([
      api.publicUsers(probe.server),
      api.quickConnectEnabled(probe.server),
      api.listAccounts(),
    ]);
    generation++;
    const g = generation;
    clear(card);
    card.classList.toggle("wide", qcOn);

    // People already signed in here aren't offered again.
    const here = new Set(accounts.filter((a) => a.server === probe.server).map((a) => a.user_id));
    const people = users.filter((u) => !here.has(u.Id));

    const userInput = el("input", {
      class: "control lg",
      type: "text",
      placeholder: "Username",
      autocapitalize: "off",
      autocomplete: "username",
    }) as HTMLInputElement;
    const passInput = el("input", {
      class: "control lg",
      type: "password",
      placeholder: "Password",
      autocomplete: "current-password",
    }) as HTMLInputElement;
    const errorBox = el("div", { class: "login-error" });
    const submit = el("button", { class: "btn primary", type: "submit" }, ["Sign in"]) as HTMLButtonElement;

    // "Who's signing in?" — the server's public users. Typing narrows it; a
    // click fills the name in and moves on to the password.
    const peopleBox = el("div", { class: "login-people" });
    const drawPeople = () => {
      clear(peopleBox);
      const typed = userInput.value.trim().toLowerCase();
      const shown = typed ? people.filter((u) => u.Name.toLowerCase().includes(typed)) : people;
      if (!people.length) return;
      peopleBox.append(
        el("div", { class: "login-section-title" }, ["Who's signing in?"]),
        el("div", { class: "login-chips" }, shown.map((u) =>
          el("button", {
            class: `login-chip${u.Name.toLowerCase() === typed ? " on" : ""}`,
            type: "button",
            onClick: () => {
              errorBox.textContent = "";
              userInput.value = u.Name;
              passInput.value = "";
              drawPeople();
              passInput.focus();
            },
          }, [
            avatar(probe.server, u.Id, u.Name, 24),
            el("span", {}, [u.Name]),
            u.HasPassword === false ? el("span", { class: "login-row-detail" }, ["No password"]) : null,
          ])
        ))
      );
    };
    userInput.addEventListener("input", drawPeople);
    drawPeople();

    const form = el("form", { class: "login-form" }, [
      peopleBox,
      el("label", {}, ["Username"]),
      userInput,
      el("label", {}, ["Password"]),
      passInput,
      errorBox,
      el("div", { class: "login-buttons" }, [
        opts.adding
          ? el("button", { class: "btn", type: "button", onClick: () => opts.onCancel?.() }, ["Cancel"])
          : null,
        submit,
      ]),
    ]);

    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      errorBox.textContent = "";
      if (!userInput.value.trim()) {
        errorBox.textContent = "Enter your username.";
        userInput.focus();
        return;
      }
      submit.disabled = true;
      submit.textContent = "Signing in…";
      try {
        await api.login(probe.server, userInput.value.trim(), passInput.value);
        // Don't leave the password sitting in the DOM for the life of the
        // window; the session is established and it is not needed again.
        passInput.value = "";
        generation++;
        onSuccess();
      } catch (e: any) {
        errorBox.textContent = e.message ?? String(e);
      } finally {
        submit.disabled = false;
        submit.textContent = "Sign in";
      }
    });

    const banner = el("div", { class: "login-banner" }, [
      el("div", { class: "login-banner-name" }, [
        el("strong", {}, [probe.server_name ?? hostLabel(probe.server)]),
        el("span", { class: `sync-pill${probe.secure ? " ok" : " warn"}` }, [probe.secure ? "Encrypted" : "Not encrypted"]),
      ]),
      el("div", { class: "login-hint" }, [probe.version ? `Jellyfin ${probe.version} · ${probe.server}` : probe.server]),
      probe.secure
        ? null
        : el("div", { class: "login-hint warn" }, [
            "This connection isn't encrypted. Anything on the network path can read your access token and what you watch — fine on a home network, worth fixing if the server is reachable from outside it.",
          ]),
      el("button", { class: "btn small", type: "button", onClick: () => addressStep(probe.server) }, [
        "Use a Different Server…",
      ]),
    ]);

    const columns = el("div", { class: "login-columns" }, [form, qcOn ? quickConnectPanel(probe, g) : null]);
    card.append(brand(), banner, columns, hint());
    userInput.focus();
  }

  /** The code, beside the password form: approve it on a device already
   *  signed in and this screen signs in by itself. */
  function quickConnectPanel(probe: api.ServerProbe, g: number): HTMLElement {
    const panel = el("div", { class: "login-qc" });
    let current: api.QuickConnectStart | null = null;
    let expired = false;
    let busy = false;
    let error = "";
    let goodUntil = 0;

    const draw = () => {
      clear(panel);
      panel.append(el("div", { class: "login-section-title" }, ["Quick Connect"]));
      if (current) {
        panel.append(
          el("div", { class: `login-qc-code${expired ? " expired" : ""}`, "aria-label": `Quick Connect code ${current.code.split("").join(" ")}` }, [
            spaced(current.code),
          ])
        );
      } else {
        panel.append(el("div", { class: "login-qc-code pending" }, [busy ? "Getting a code…" : "—"]));
      }
      const buttons = el("div", { class: "login-buttons start" });
      if (current && !expired) {
        buttons.append(el("button", {
          class: "btn small",
          type: "button",
          onClick: () => {
            navigator.clipboard.writeText(current!.code).then(
              () => toast("Code copied", "ok"),
              () => toast("Couldn't copy the code", "error")
            );
          },
        }, ["Copy Code"]));
      }
      buttons.append(el("button", { class: "btn small", type: "button", disabled: busy ? "" : null, onClick: () => void start() }, ["Get New Code"]));
      panel.append(buttons);
      if (error) panel.append(el("div", { class: "login-error" }, [error]));
      else if (expired) panel.append(el("div", { class: "login-hint warn" }, ["That code has expired."]));
      else if (current) {
        const until = new Date(goodUntil).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
        panel.append(
          el("div", { class: "login-hint" }, ["Waiting for the code to be approved…"]),
          el("div", { class: "login-hint" }, [`Expires around ${until}.`])
        );
      }
      panel.append(el("div", { class: "login-hint" }, [
        `On a phone or computer that is already signed in to ${probe.server_name ?? "this server"}, enter this code under Settings → Quick Connect in Aquarium, or on the Quick Connect page of Jellyfin's own web app. This screen signs in by itself the moment it is approved.`,
      ]));
    };

    async function start(): Promise<void> {
      if (busy) return;
      busy = true;
      error = "";
      expired = false;
      draw();
      try {
        current = await api.quickConnectInitiate(probe.server);
        // Jellyfin forgets a request after ten minutes.
        goodUntil = Date.now() + 10 * 60_000;
      } catch (e: any) {
        current = null;
        error = e.message ?? String(e);
      }
      busy = false;
      if (!live(g)) return;
      draw();
      if (current) void poll(current.secret);
    }

    /** Every 3 s until approved, expired, replaced or off the screen. */
    async function poll(secret: string): Promise<void> {
      while (live(g) && current?.secret === secret) {
        await new Promise((r) => setTimeout(r, 3000));
        if (!live(g) || current?.secret !== secret) return;
        let approved: boolean | null;
        try {
          approved = await api.quickConnectState(probe.server, secret);
        } catch {
          // One failed poll is not the end of the request; the next one says.
          continue;
        }
        if (!live(g) || current?.secret !== secret) return;
        if (approved === null || Date.now() > goodUntil + 30_000) {
          expired = true;
          draw();
          return;
        }
        if (!approved) continue;
        try {
          await api.loginWithQuickConnect(probe.server, secret);
          generation++;
          onSuccess();
        } catch (e: any) {
          // An approved code is spent; a new one is the way forward.
          error = e.message ?? String(e);
          expired = true;
          draw();
        }
        return;
      }
    }

    draw();
    void start();
    return panel;
  }

  addressStep(cfg.server ?? "");
}
