// Connecting a Seerr server, and the rows in Settings that say it is
// connected.
//
// One address is typed. Everything after that is the app's: it checks what
// answers there, says so if the connection isn't encrypted, and signs in with
// the Jellyfin account already in use (see `seerr.rs`). The password form only
// appears when the server has no Quick Connect to sign in with.
import * as api from "../api";
import * as seerr from "../seerr";
import type { SeerrProbe } from "../seerr";
import { el, clear, toast, openDialog } from "../ui";

function row(label: string, explain: string, control: Node | null): HTMLElement {
  return el("div", { class: "settings-row" }, [
    el("div", {}, [
      el("div", { class: "lbl" }, [label]),
      explain ? el("div", { class: "sub" }, [explain]) : null,
    ]),
    control,
  ]);
}

type Step = { at: "address" } | { at: "insecure"; probe: SeerrProbe } | { at: "password"; probe: SeerrProbe };

/**
 * The connect dialog: address, then (only over plain http) a confirmation,
 * then (only with no Quick Connect) the Jellyfin user name and password.
 * `onDone` runs once a connection has been made.
 */
export function openSeerrConnect(onDone: () => void): void {
  let step: Step = { at: "address" };
  let busy = false;
  let address = "";
  let username = api.getSession()?.userName ?? "";

  const body = el("div", { class: "seerr-connect" });
  const errorLine = el("div", { class: "seerr-connect-error", role: "alert", hidden: "" });
  const say = (message: string | null): void => {
    errorLine.textContent = message ?? "";
    errorLine.toggleAttribute("hidden", !message);
  };

  const close = openDialog({ title: "Connect to Seerr", body: [body, errorLine] });

  /** The two buttons every step ends in. `run` is the step's own action. */
  const buttons = (primary: string, working: string, run: () => Promise<void>, disabled = false): HTMLElement => {
    const go = el("button", { class: "btn primary seerr-connect-go", type: "button" }, [busy ? working : primary]) as HTMLButtonElement;
    go.disabled = busy || disabled;
    go.addEventListener("click", () => void run());
    const cancel = el("button", { class: "btn seerr-connect-cancel", type: "button" }, ["Cancel"]) as HTMLButtonElement;
    cancel.disabled = busy;
    cancel.addEventListener("click", () => close());
    return el("div", { class: "dialog-actions" }, [go, cancel]);
  };

  const finish = (probe: SeerrProbe): void => {
    toast(`Connected to ${probe.name}. Requests is in the sidebar.`, "ok");
    close();
    onDone();
  };

  /** Sign in with the Jellyfin account in use; the password form is next
   *  when there is no Quick Connect to do it with. */
  const signIn = async (probe: SeerrProbe): Promise<void> => {
    say(null);
    try {
      await seerr.connect(probe.server);
      busy = false;
      finish(probe);
    } catch (e) {
      busy = false;
      const err = seerr.seerrError(e);
      if (err.kind === "quickconnect") step = { at: "password", probe };
      else say(err.message);
      draw();
    }
  };

  const look = async (): Promise<void> => {
    if (busy || !address.trim()) return;
    busy = true;
    say(null);
    draw();
    let probe: SeerrProbe;
    try {
      probe = await seerr.probe(address);
    } catch (e) {
      busy = false;
      say(seerr.seerrError(e).message);
      draw();
      return;
    }
    if (probe.secure) {
      await signIn(probe);
    } else {
      // The server answered over plain http: say so before going on.
      busy = false;
      step = { at: "insecure", probe };
      draw();
    }
  };

  const signInAnyway = async (probe: SeerrProbe): Promise<void> => {
    if (busy) return;
    busy = true;
    draw();
    await signIn(probe);
  };

  const draw = (): void => {
    clear(body);
    if (step.at === "address") {
      const input = el("input", {
        class: "control lg seerr-connect-address",
        type: "text",
        placeholder: "requests.example.com",
        autocomplete: "off",
        autocapitalize: "off",
        spellcheck: "false",
        "aria-label": "Seerr server address",
      }) as HTMLInputElement;
      input.value = address;
      input.disabled = busy;
      const actions = buttons("Connect", "Connecting…", look, !address.trim());
      input.addEventListener("input", () => {
        address = input.value;
        const go = actions.querySelector<HTMLButtonElement>(".seerr-connect-go");
        if (go) go.disabled = busy || !address.trim();
      });
      input.addEventListener("keydown", (ev) => {
        if (ev.key === "Enter") void look();
      });
      body.append(
        el("p", {}, [
          "Seerr takes requests for films and shows your Jellyfin server doesn't have yet. Enter its address, and Aquarium signs in with the Jellyfin account you're already using. No password is typed or kept.",
        ]),
        input,
        actions
      );
      if (!busy) input.focus();
      return;
    }
    const probe = step.probe;
    if (step.at === "insecure") {
      body.append(
        el("div", { class: "login-warning seerr-connect-insecure" }, ["This connection isn't encrypted"]),
        el("p", {}, [
          `${probe.name} answered at ${probe.server} over plain http. Anyone on the network between this device and that server could read what is sent, including the session Aquarium signs in with. That is fine on a home network you trust, and not anywhere else.`,
        ]),
        buttons("Connect Anyway", "Connecting…", () => signInAnyway(probe))
      );
      return;
    }
    const user = el("input", {
      class: "control lg seerr-connect-username",
      type: "text",
      placeholder: "Jellyfin user name",
      autocomplete: "off",
      autocapitalize: "off",
      spellcheck: "false",
      "aria-label": "Jellyfin user name",
    }) as HTMLInputElement;
    user.value = username;
    const pass = el("input", {
      class: "control lg seerr-connect-password",
      type: "password",
      placeholder: "Password",
      autocomplete: "off",
      "aria-label": "Password",
    }) as HTMLInputElement;
    user.disabled = busy;
    pass.disabled = busy;
    const withPassword = async (): Promise<void> => {
      if (busy || !username) return;
      // Read once and handed straight on; nothing here keeps it.
      const typed = pass.value;
      busy = true;
      say(null);
      draw();
      try {
        await seerr.connectWithPassword(probe.server, username, typed);
        busy = false;
        finish(probe);
      } catch (e) {
        busy = false;
        say(seerr.seerrError(e).message);
        draw();
      }
    };
    const actions = buttons("Sign In", "Signing in…", withPassword, !username);
    user.addEventListener("input", () => {
      username = user.value;
      const go = actions.querySelector<HTMLButtonElement>(".seerr-connect-go");
      if (go) go.disabled = busy || !username;
    });
    pass.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") void withPassword();
    });
    body.append(
      el("p", {}, [
        `${probe.name} can't sign in with Quick Connect, so it needs your Jellyfin user name and password. They are sent to it once${probe.secure ? ", encrypted," : ""} and not kept on this device.`,
      ]),
      user,
      pass,
      actions
    );
    if (!busy) (username ? pass : user).focus();
  };

  draw();
}

/**
 * The "Requests" block of Settings: one button while nothing is connected;
 * the server, the account, how the connection is made and where the session
 * is kept once something is.
 */
export function seerrSettingsBlock(): HTMLElement {
  const block = el("div", { class: "settings-block seerr-settings" });
  let working = false;
  let error: string | null = null;

  const draw = (): void => {
    clear(block);
    block.append(el("h3", {}, ["Requests"]));
    const st = seerr.getStatus();
    if (!st.connected) {
      block.append(
        row(
          "Connect to Seerr…",
          seerr.COPY.offer,
          el("button", { class: "btn small seerr-connect-button", onClick: () => openSeerrConnect(draw) }, ["Connect to Seerr…"])
        )
      );
      return;
    }
    const out = !!st.needs_reconnect;
    const inKeyring = st.storage === "keyring";
    block.append(
      row("Seerr server", "", el("span", { class: "seerr-settings-server" }, [st.host ?? ""])),
      row("Signed in as", "", el("span", { class: "seerr-settings-user" }, [st.user_name ?? ""])),
      row(
        "Connection",
        st.secure
          ? "Encrypted (HTTPS)."
          : "Unencrypted (HTTP). Anything on the network path can read what is sent, including the session Aquarium signs in with.",
        el("span", { class: `sync-pill seerr-settings-connection${st.secure ? " ok" : " warn"}` }, [st.secure ? "HTTPS" : "HTTP"])
      ),
      row(
        "Session",
        out ? "The connection to Seerr has run out." : inKeyring ? seerr.COPY.kept : seerr.COPY.keptInFile,
        el("span", { class: `sync-pill seerr-settings-session${out || !inKeyring ? " warn" : " ok"}` }, [
          out ? "Run out" : inKeyring ? "Keyring" : "Config file",
        ])
      )
    );
    if (out) {
      const again = el("button", { class: "btn small seerr-reconnect-button" }, ["Reconnect"]) as HTMLButtonElement;
      again.disabled = working;
      again.addEventListener("click", async () => {
        working = true;
        draw();
        try {
          await seerr.reconnect();
          error = null;
        } catch (e) {
          error = seerr.seerrError(e).message;
        }
        working = false;
        draw();
      });
      block.append(row("Reconnect", "Sign in to Seerr again with your Jellyfin account.", again));
    }
    const leave = el("button", { class: "btn small danger seerr-disconnect-button" }, ["Disconnect from Seerr…"]) as HTMLButtonElement;
    leave.disabled = working;
    leave.addEventListener("click", () =>
      openDialog({
        title: "Disconnect from Seerr?",
        body: [
          el("p", {}, [
            "Requests you have already made stay on the server. This device stops showing them until you connect again.",
          ]),
        ],
        actions: [
          { label: "Cancel", primary: true },
          {
            label: "Disconnect",
            danger: true,
            run: async () => {
              working = true;
              draw();
              await seerr.disconnect();
              working = false;
              error = null;
              draw();
            },
          },
        ],
      })
    );
    block.append(row("Disconnect", "Sign this device out of Seerr.", leave));
    if (error) block.append(el("div", { class: "sub seerr-settings-error", role: "alert" }, [error]));
  };

  draw();
  // Quietly bring it up to date: a session that ran out, or a connection made
  // from another window of this page.
  void seerr.loadStatus().then(() => {
    if (document.contains(block)) draw();
  });
  return block;
}
