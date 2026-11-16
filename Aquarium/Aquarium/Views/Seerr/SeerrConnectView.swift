//  Connecting a Seerr server, and the rows in Settings that say it is
//  connected.
//
//  One address is typed. Everything after that is the app's: it checks what
//  answers there, says so if the connection isn't encrypted, and signs in with
//  the Jellyfin account already in use (see `SeerrClient`). The password form
//  only appears when the server has no Quick Connect to sign in with.

import SwiftUI

struct SeerrConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(JellyfinClient.self) private var client
    @Environment(AppModel.self) private var app

    private enum Step: Equatable {
        case address
        /// The server answered over plain http: say so before going on.
        case insecure(SeerrProbe)
        /// No Quick Connect: the Jellyfin user name and password instead.
        case password(SeerrProbe)
    }

    @State private var step: Step = .address
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var error: String?

    private var seerr: SeerrClient { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect to Seerr")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.text)
                switch step {
                case .address: addressStep
                case .insecure(let probe): insecureStep(probe)
                case .password(let probe): passwordStep(probe)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(TestID.Requests.connectError)
                }
            }
            .padding(panelPadding)
            .frame(maxWidth: panelWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 320)
        #else
        .background(Theme.background)
        #endif
        .interactiveDismissDisabled(isBusy)
        .onAppear { if username.isEmpty { username = client.session?.userName ?? "" } }
        .testAnchor(TestID.Requests.connectRoot)
    }

    private var panelPadding: CGFloat {
        #if os(tvOS)
        80
        #else
        24
        #endif
    }

    private var panelWidth: CGFloat {
        #if os(tvOS)
        1100
        #else
        520
        #endif
    }

    // MARK: - Steps

    @ViewBuilder
    private var addressStep: some View {
        Text("Seerr takes requests for films and shows your Jellyfin server doesn't have yet. Enter its address, and Aquarium signs in with the Jellyfin account you're already using. No password is typed or kept.")
            .font(.subheadline)
            .foregroundStyle(Theme.textBody)
            .fixedSize(horizontal: false, vertical: true)
        TextField("requests.example.com", text: $address)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .textFieldStyle(.roundedBorder)
            #elseif os(macOS)
            .textFieldStyle(.roundedBorder)
            #endif
            .autocorrectionDisabled()
            .onSubmit { Task { await look() } }
            .accessibilityIdentifier(TestID.Requests.connectAddress)
        buttons(primary: "Connect", id: TestID.Requests.connectContinue,
                disabled: address.trimmingCharacters(in: .whitespaces).isEmpty) { await look() }
    }

    @ViewBuilder
    private func insecureStep(_ probe: SeerrProbe) -> some View {
        Label("This connection isn't encrypted", systemImage: "lock.open")
            .font(.headline)
            .foregroundStyle(Theme.warn)
            .accessibilityIdentifier(TestID.Requests.connectInsecure)
        Text("\(probe.name) answered at \(probe.server) over plain http. Anyone on the network between this device and that server could read what is sent, including the session Aquarium signs in with. That is fine on a home network you trust, and not anywhere else.")
            .font(.subheadline)
            .foregroundStyle(Theme.textBody)
            .fixedSize(horizontal: false, vertical: true)
        buttons(primary: "Connect Anyway", id: TestID.Requests.connectAnyway, disabled: false) { await signIn(probe) }
    }

    @ViewBuilder
    private func passwordStep(_ probe: SeerrProbe) -> some View {
        Text("\(probe.name) can't sign in with Quick Connect, so it needs your Jellyfin user name and password. They are sent to it once\(probe.secure ? ", encrypted," : "") and not kept on this device.")
            .font(.subheadline)
            .foregroundStyle(Theme.textBody)
            .fixedSize(horizontal: false, vertical: true)
        TextField("Jellyfin user name", text: $username)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .textFieldStyle(.roundedBorder)
            #elseif os(macOS)
            .textFieldStyle(.roundedBorder)
            #endif
            .autocorrectionDisabled()
            .accessibilityIdentifier(TestID.Requests.connectUsername)
        SecureField("Password", text: $password)
            #if !os(tvOS)
            .textFieldStyle(.roundedBorder)
            #endif
            .onSubmit { Task { await signInWithPassword(probe) } }
            .accessibilityIdentifier(TestID.Requests.connectPassword)
        buttons(primary: "Sign In", id: TestID.Requests.connectSignIn, disabled: username.isEmpty) {
            await signInWithPassword(probe)
        }
    }

    private func buttons(primary: String, id: String, disabled: Bool, action: @escaping () async -> Void) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await action() }
            } label: {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                            .accessibilityIdentifier(TestID.Requests.connectBusy)
                    }
                    Text(primary)
                }
            }
            .appButtonStyle(prominent: true)
            .disabled(isBusy || disabled)
            .accessibilityIdentifier(id)
            Button("Cancel", role: .cancel) { dismiss() }
                .appButtonStyle()
                .disabled(isBusy)
                .accessibilityIdentifier(TestID.Requests.connectCancel)
        }
        .padding(.top, 4)
    }

    // MARK: - Doing it

    private func look() async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let probe = try await seerr.probe(address: address)
            if probe.secure {
                await signIn(probe, alreadyBusy: true)
            } else {
                step = .insecure(probe)
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func signIn(_ probe: SeerrProbe, alreadyBusy: Bool = false) async {
        if !alreadyBusy {
            guard !isBusy else { return }
            isBusy = true
        }
        error = nil
        defer { if !alreadyBusy { isBusy = false } }
        guard await seerr.canQuickConnect() else {
            step = .password(probe)
            return
        }
        do {
            try await seerr.connectWithQuickConnect(to: probe.server)
            await finish(probe)
        } catch SeerrError.quickConnectUnavailable {
            step = .password(probe)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func signInWithPassword(_ probe: SeerrProbe) async {
        guard !isBusy, !username.isEmpty else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await seerr.connectWithPassword(to: probe.server, username: username, password: password)
            password = ""
            await finish(probe)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish(_ probe: SeerrProbe) async {
        await seerr.refreshAccount()
        app.toast("Connected to \(probe.name). Requests is in the \(Self.whereItIs).", tone: .ok)
        dismiss()
    }

    private static var whereItIs: String {
        #if os(tvOS)
        "tabs at the top"
        #elseif os(macOS)
        "sidebar"
        #else
        Metrics.phoneLayout ? "More tab" : "sidebar"
        #endif
    }
}

// MARK: - Settings rows

#if !os(tvOS)
/// The "Requests" section of the Account page (iPhone, iPad) and the Account
/// tab (Mac). The Apple TV draws its own from the same client; see
/// `TVSettingsView`.
struct SeerrSettingsSection: View {
    @State private var isConnecting = false
    @State private var confirmDisconnect = false
    @State private var isWorking = false
    @State private var error: String?

    private var seerr: SeerrClient { .shared }

    var body: some View {
        Section {
            if let connection = seerr.connection {
                LabeledContent("Seerr server") {
                    Text(connection.host)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(TestID.Requests.settingsServer)
                }
                LabeledContent("Signed in as") {
                    Text(connection.userName)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(TestID.Requests.settingsUser)
                }
                LabeledContent("Connection") {
                    StatusPill(text: connection.secure ? "HTTPS" : "HTTP", tone: connection.secure ? .ok : .warn)
                        .accessibilityIdentifier(TestID.Requests.settingsConnection)
                }
                LabeledContent("Session") {
                    StatusPill(text: seerr.needsReconnect ? "Run out" : "Keychain", tone: seerr.needsReconnect ? .warn : .ok)
                        .accessibilityIdentifier(TestID.Requests.settingsSession)
                }
                LabeledContent("Posters") {
                    StatusPill(text: seerr.postersOff ? "Off" : "On", tone: seerr.postersOff ? .warn : .ok)
                        .accessibilityIdentifier(TestID.Requests.settingsPosters)
                }
                if seerr.postersOff {
                    Text(SeerrCopy.postersOff)
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                }
                if seerr.needsReconnect {
                    Button("Reconnect") { Task { await reconnect() } }
                        .disabled(isWorking)
                        .accessibilityIdentifier(TestID.Requests.settingsReconnect)
                }
                // The dialog hangs from its own row. Hung from the section, a
                // form hands it to every row, and none of them presents it.
                Button("Disconnect from Seerr…", role: .destructive) { confirmDisconnect = true }
                    .disabled(isWorking)
                    .accessibilityIdentifier(TestID.Requests.settingsDisconnect)
                    .confirmationDialog("Disconnect from Seerr?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                        Button("Disconnect", role: .destructive) {
                            Task {
                                isWorking = true
                                await seerr.disconnect()
                                isWorking = false
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Requests you have already made stay on the server. This device stops showing them until you connect again.")
                    }
            } else {
                Button("Connect to Seerr…") { isConnecting = true }
                    .accessibilityIdentifier(TestID.Requests.settingsConnect)
                    .sheet(isPresented: $isConnecting) { SeerrConnectView() }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.warn)
            }
        } header: {
            Text("Requests")
        } footer: {
            Text(seerr.connection == nil ? SeerrCopy.offer : SeerrCopy.kept)
        }
    }

    private func reconnect() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await seerr.reconnect()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif

/// The sentences Settings says about Seerr, in one place for every platform.
enum SeerrCopy {
    static let offer = "Seerr takes requests for films and shows the library doesn't have yet. Connect one and they can be asked for from Search and from a Requests page."
    static let postersOffTitle = "No posters from Seerr"
    static let postersOff = "Seerr only shares posters when Cache Images is on. An admin can turn it on in Seerr's Settings, under General. Aquarium doesn't fetch them from the film database directly."
    static let kept = "Aquarium signed in to Seerr with your Jellyfin account. Only Seerr's session is kept, in the keychain beside your Jellyfin sign-in; no password is stored."
}
