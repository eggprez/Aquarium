//  Sign-in.
//
//  The address is probed before any credential is sent to it, and what came
//  back is shown — the server's name, its version, and whether the connection
//  is encrypted. A LAN-only server over plain HTTP is a defensible choice;
//  not knowing which one you have is not.
//
//  Two things spare the typing, which on an Apple TV is the whole cost of
//  signing in. Servers on the local network are listed under the address
//  field as they answer (see ServerDiscovery), so the address is a press
//  rather than a URL pecked out on a remote. And a server with Quick Connect
//  turned on offers a six-digit code instead of a password: the code is
//  approved from a phone or a browser that is already signed in, and the
//  session arrives here by itself. A television defaults to the code; a
//  phone or a Mac, where a password manager fills the form in one tap, keeps
//  the password first and offers the code beside it. And the people the server
//  is willing to name before anyone signs in are listed over the form, so a
//  username is a press too — and typing part of one narrows the list.
//
//  On an Apple TV with more than one user, each of them gets this screen the
//  first time, with nothing of their own signed in. What the others have is
//  offered: the accounts, to be taken up as they are, and the servers, to
//  sign in to as somebody else.

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    /// Up as a sheet over the shell, to add an account beside the one in use
    /// — rather than being the whole window because nobody is signed in.
    var addingAccount = false

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var probe: ServerProbe?
    /// A server that only answered over plain http after https was tried, out
    /// on the internet, waiting for the person to say that's acceptable.
    @State private var unencryptedOffer: ServerProbe?
    @State private var isProbing = false
    @State private var isSigningIn = false
    @State private var error: String?

    /// Who the server says can sign in to it. See `JellyfinClient.publicUsers`.
    @State private var users: [JellyfinClient.PublicUser] = []

    @State private var discovered: [DiscoveredServer] = []
    @State private var isDiscovering = false

    /// Which way in, once a server has answered.
    private enum Mode { case password, quickConnect }
    @State private var mode: Mode = .password
    @State private var quickConnectOffered = false
    @State private var quick: QuickConnectStart?
    @State private var quickExpired = false
    @State private var isStartingQuick = false

    /// Which field the keyboard is in, so return moves to the next one and the
    /// last one submits — the sign-in screen was three taps and a manual
    /// keyboard dismissal before.
    private enum Field: Hashable { case address, username, password, modeSwitch }
    @FocusState private var focused: Field?

    var body: some View {
        platformBody
            .task {
                // Someone else in the house, on the same server, is what adding
                // an account nearly always is: start from the address in use.
                if addingAccount, address.isEmpty, probe == nil, let server = client.session?.server {
                    address = server
                    await connect()
                }
                await discover()
            }
            // The code is polled for as long as it is on screen. Changing the
            // secret — a fresh code after an expiry — restarts the loop.
            .task(id: quick?.secret) { await waitForApproval() }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(macOS)
        macBody
        #else
        touchBody
        #endif
    }

    #if !os(macOS)
    private var touchBody: some View {
        // Centred rather than pinned to the top: on a phone the card is about a
        // third of the screen and everything under it was air.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 22) {
                    header
                    if probe == nil || addingAccount { savedAccounts }
                    card
                    if addingAccount {
                        Button("Cancel") { app.isAddingAccount = false }
                            #if os(tvOS)
                            .appButtonStyle()
                            #else
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            #endif
                    }
                    Text("Aquarium talks to your own Jellyfin server and nothing else. Your access token is kept in the keychain and is never logged.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: Self.cardWidth)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .padding(.horizontal, Metrics.gutter)
                // Centres what fits and scrolls what doesn't — which is what
                // happens the moment a keyboard takes half the screen.
                .frame(minHeight: proxy.size.height)
            }
        }
        .background(Theme.background)
        .scrollDismissesKeyboard(.interactively)
    }
    #endif

    #if os(macOS)
    // MARK: - The Mac's layout

    /// A Mac signs in the way a Mac dialog does: a column of labelled fields,
    /// the lists that spare the typing as tables under them, and the buttons
    /// bottom-right with Return and Escape wired to them. No cards, no
    /// scrolling, nothing sized for a thumb.
    ///
    /// As the add-account sheet the same content shrinks to a fixed width and
    /// takes exactly the height it needs, whatever minimum the caller asks
    /// for; as the whole window it sits centred in whatever space there is.
    private var macBody: some View {
        Group {
            if addingAccount {
                macContent
                    .padding(20)
                    .frame(width: 460)
                    .fixedSize()
            } else {
                macContent
                    .frame(width: 480)
                    .padding(Metrics.gutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            }
        }
    }

    private var macContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            macHeader
            if probe == nil { macSavedAccounts }
            macForm
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            macButtons
            if !addingAccount {
                Text("Aquarium talks to your own Jellyfin server and nothing else. Your access token is kept in the keychain and is never logged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Landing in the field you are meant to fill in next.
        .onChange(of: probe == nil) { _, noServer in
            focused = noServer ? .address : (mode == .password ? .username : nil)
        }
        // The segmented control changes `mode` directly; what the footnote
        // link used to do on the way is done here. Not while the server is
        // being forgotten — that change of focus belongs to the address.
        .onChange(of: mode) { _, now in
            guard probe != nil else { return }
            error = nil
            switch now {
            case .quickConnect:
                focused = nil
                if quick == nil || quickExpired { Task { await startQuickConnect() } }
            case .password:
                focused = .username
            }
        }
        // Typing over an address that a table put there: the table's
        // selection no longer describes the field.
        .onChange(of: address) { _, now in
            if selectedServer != nil, selectedServer != now { selectedServer = nil }
        }
        .alert(
            "No Secure Connection",
            isPresented: Binding(get: { unencryptedOffer != nil }, set: { if !$0 { unencryptedOffer = nil } }),
            presenting: unencryptedOffer
        ) { found in
            Button("Connect Without Encryption", role: .destructive) {
                Task { await adopt(found) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { found in
            Text("\(found.server) didn't answer over https, only over plain http. Your password and everything you watch would cross the internet unencrypted — and a network that blocks secure connections looks exactly like this. Only continue if you know this server has no https.")
        }
    }

    /// The mark and the name, at window size; in the sheet, a line that says
    /// what the sheet is for, because the window behind it already has the
    /// name on it.
    @ViewBuilder
    private var macHeader: some View {
        if addingAccount {
            HStack(alignment: .top, spacing: 12) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add an Account")
                        .font(.headline)
                    Text("Sign in to another user on this server, or to a different server, without signing this one out.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(spacing: 6) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                HStack(spacing: 0) {
                    Text("Aqua").fontWeight(.semibold)
                    Text("rium").fontWeight(.heavy).foregroundStyle(Theme.accent)
                }
                .font(.title2)
                Text("A Jellyfin client")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Accounts already on this Mac

    @State private var selectedAccount: String?

    /// Who is still signed in here, as a table: select and Continue, or
    /// double-click. In the sheet the accounts are in Settings behind it,
    /// and a Mac has no household of users to offer, so nothing is listed.
    @ViewBuilder
    private var macSavedAccounts: some View {
        let offered = (addingAccount ? [] : client.accounts) + client.householdAccounts
        if !offered.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Accounts on this Mac")
                    .font(.headline)
                List(offered, id: \.accountKey, selection: $selectedAccount) { account in
                    MacHoverRow(isSelected: selectedAccount == account.accountKey) {
                        HStack(spacing: 8) {
                            AccountAvatar(account: account, size: 24)
                            Text(account.userName.isEmpty ? "Unnamed user" : account.userName)
                            Text(account.serverLabel)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .listStyle(.bordered)
                .frame(height: Self.macListHeight(rows: offered.count))
                .contextMenu(forSelectionType: String.self) { keys in
                    if let account = offered.first(where: { keys.contains($0.accountKey) }) {
                        Button("Continue as \(account.userName)") { takeUp(account) }
                    }
                } primaryAction: { keys in
                    if let account = offered.first(where: { keys.contains($0.accountKey) }) { takeUp(account) }
                }
                .disabled(app.switchingTo != nil)
                HStack {
                    Text("Double-click an account to continue as them, or sign in below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Continue") {
                        if let account = offered.first(where: { $0.accountKey == selectedAccount }) { takeUp(account) }
                    }
                    .disabled(selectedAccount == nil || app.switchingTo != nil)
                }
            }
        }
    }

    private func takeUp(_ account: SavedSession) {
        Task {
            await app.switchAccount(to: account)
            if addingAccount, client.session?.accountKey == account.accountKey { app.isAddingAccount = false }
        }
    }

    /// A bordered table's height for this many rows — enough that nothing
    /// scrolls until the list is long, and no taller than the rows need.
    private static func macListHeight(rows: Int) -> CGFloat {
        CGFloat(min(max(rows, 1), 5)) * 30 + 2
    }

    // MARK: The form

    private var macForm: some View {
        Form {
            TextField("Server Address:", text: $address, prompt: Text("jellyfin.example.com"))
                .textFieldStyle(.roundedBorder)
                .disabled(probe != nil)
                .focused($focused, equals: .address)
                .onSubmit { Task { await connect() } }

            if probe == nil {
                Text("The address you open Jellyfin at in a browser — for example http://192.168.1.10:8096 or https://jellyfin.example.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                macServerList
            }

            if let probe {
                LabeledContent("Server:") { macBanner(probe) }

                if quickConnectOffered {
                    Picker("Sign In With:", selection: $mode) {
                        Text("Password").tag(Mode.password)
                        Text("Quick Connect").tag(Mode.quickConnect)
                    }
                    .pickerStyle(.segmented)
                }

                switch mode {
                case .password:
                    macUserList(probe)
                    TextField("Username:", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .username)
                        .onSubmit { focused = .password }
                        // The pair of them, so a password manager sees a
                        // sign-in form and offers to fill it — and to save it
                        // afterwards.
                        .textContentType(.username)
                    SecureField("Password:", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .password)
                        .onSubmit { Task { await signIn() } }
                        .textContentType(.password)
                case .quickConnect:
                    macQuickConnect(probe)
                }
            }
        }
        .formStyle(.columns)
        .defaultFocus($focused, .address)
    }

    // MARK: Servers, as a table

    /// One row of the servers table: signed in to before, or found on the
    /// network — the address is what both come down to.
    private struct MacServerChoice: Identifiable, Hashable {
        var name: String
        var address: String
        var detail: String
        var symbol: String
        var id: String { address }
    }

    @State private var selectedServer: String?

    private var macServerChoices: [MacServerChoice] {
        let known = knownServerAddresses.map { server in
            MacServerChoice(
                name: server.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""),
                address: server, detail: "Signed in to before", symbol: "person.badge.plus")
        }
        let found = discovered
            .filter { server in !known.contains { $0.address == server.address } }
            .map { MacServerChoice(name: $0.name, address: $0.address, detail: "On your network", symbol: "server.rack") }
        return known + found
    }

    /// Selecting a server puts its address in the field, so Connect — or
    /// Return — takes it from there; a double-click connects outright.
    @ViewBuilder
    private var macServerList: some View {
        let choices = macServerChoices
        if isDiscovering || !choices.isEmpty {
            LabeledContent {
                VStack(alignment: .leading, spacing: 6) {
                    if !choices.isEmpty {
                        List(choices, selection: $selectedServer) { choice in
                            MacHoverRow(isSelected: selectedServer == choice.address) {
                                HStack(spacing: 8) {
                                    Image(systemName: choice.symbol)
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 18)
                                    Text(choice.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(choice.detail)
                                        .foregroundStyle(.secondary)
                                }
                                .help(choice.address)
                            }
                        }
                        .listStyle(.bordered)
                        .frame(height: Self.macListHeight(rows: choices.count))
                        .contextMenu(forSelectionType: String.self) { keys in
                            if let server = keys.first {
                                Button("Connect") { connect(to: server) }
                            }
                        } primaryAction: { keys in
                            if let server = keys.first { connect(to: server) }
                        }
                        .onChange(of: selectedServer) { _, server in
                            if let server { address = server }
                        }
                        .disabled(isProbing)
                    }
                    HStack(spacing: 6) {
                        if isDiscovering {
                            ProgressView().controlSize(.mini)
                            Text(choices.isEmpty ? "Looking on your network…" : "Still looking on your network…")
                        } else {
                            Text("Double-click a server to connect to it.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } label: {
                Text("Servers:")
            }
        }
    }

    private func connect(to server: String) {
        address = server
        Task { await connect() }
    }

    // MARK: People on the server, as a table

    /// The server's users less the ones already signed in here — all of
    /// them, not narrowed by the field: a table that shrank to one row the
    /// moment a row was clicked would look like the others had gone.
    private var macOpenUsers: [JellyfinClient.PublicUser] {
        guard let probe else { return [] }
        let here = Set(client.accounts.filter { $0.server == probe.server }.map(\.userId))
        return users.filter { !here.contains($0.Id) }
    }

    /// The selection follows the field: whoever's name is typed is the row
    /// that is highlighted, and clicking a row types their name.
    private var macUserSelection: Binding<String?> {
        Binding(
            get: { macOpenUsers.first { $0.name.caseInsensitiveCompare(username) == .orderedSame }?.Id },
            set: { id in
                guard let user = macOpenUsers.first(where: { $0.Id == id }) else { return }
                error = nil
                username = user.name
                password = ""
                focused = .password
            }
        )
    }

    @ViewBuilder
    private func macUserList(_ probe: ServerProbe) -> some View {
        let people = macOpenUsers
        if !people.isEmpty {
            LabeledContent {
                VStack(alignment: .leading, spacing: 6) {
                    List(people, selection: macUserSelection) { user in
                        MacHoverRow(isSelected: user.name.caseInsensitiveCompare(username) == .orderedSame) {
                            HStack(spacing: 8) {
                                AccountAvatar(account: SavedSession(server: probe.server, userId: user.Id, userName: user.name, deviceId: ""), size: 22)
                                Text(user.name)
                                if user.HasPassword == false {
                                    Text("No password")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.bordered)
                    .frame(height: Self.macListHeight(rows: people.count))
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let user = people.first(where: { ids.contains($0.Id) }) {
                            Button("Sign In as \(user.name)") { choose(user) }
                        }
                    } primaryAction: { ids in
                        if let user = people.first(where: { ids.contains($0.Id) }) { choose(user) }
                    }
                    .disabled(isSigningIn)
                    Text("Click a name to fill it in; double-click to sign in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Text("Users:")
            }
        }
    }

    // MARK: Quick Connect

    private func macQuickConnect(_ probe: ServerProbe) -> some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    if let quick {
                        Text(Self.spaced(quick.code))
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(quickExpired ? .secondary : .primary)
                            .textSelection(.enabled)
                            .contentTransition(.numericText())
                            .animation(.default, value: quick.code)
                            .accessibilityLabel("Quick Connect code \(quick.code.map(String.init).joined(separator: " "))")
                        Button("Copy Code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(quick.code, forType: .string)
                        }
                        .disabled(quickExpired)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(height: 40)
                    }
                }
                if quickExpired {
                    Text("That code has expired.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if quick != nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for the code to be approved…")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Text("On a phone or computer that is already signed in to \(probe.serverName ?? "this server"), enter this code under Settings → Quick Connect in Aquarium, or on the Quick Connect page of Jellyfin's own web app. This window signs in by itself the moment it is approved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            Text("Code:")
        }
    }

    // MARK: Banner and buttons

    /// What the probe found, as facts rather than a pill: the name, the
    /// version and address under it, and whether the link is encrypted.
    private func macBanner(_ probe: ServerProbe) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(probe.serverName ?? probe.server)
                    .fontWeight(.semibold)
                Label(probe.secure ? "Encrypted" : "Not Encrypted", systemImage: probe.secure ? "lock.fill" : "lock.open")
                    .font(.caption)
                    .foregroundStyle(probe.secure ? .green : .orange)
                    .help(probe.secure
                          ? "Your password and access token are never sent in the clear."
                          : "Anything on the network path can read your access token and what you watch.")
            }
            Text(probe.version.map { "Jellyfin \($0) · \(probe.server)" } ?? probe.server)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !probe.secure {
                Text("This connection isn't encrypted. Anything on the network path can read your access token and what you watch — fine on a home network, worth fixing if the server is reachable from outside it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Use a Different Server…") { useDifferentServer() }
                .controlSize(.small)
                .padding(.top, 2)
        }
    }

    /// Bottom-right, the Mac way: Cancel with Escape, the one thing to do
    /// next with Return, and the spinner beside them so nothing changes width.
    private var macButtons: some View {
        HStack(spacing: 12) {
            Spacer()
            if isProbing || isSigningIn || isStartingQuick {
                ProgressView().controlSize(.small)
            }
            if addingAccount {
                Button("Cancel") { app.isAddingAccount = false }
                    .keyboardShortcut(.cancelAction)
            }
            if probe == nil {
                Button("Connect") { Task { await connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isProbing)
            } else if mode == .quickConnect {
                // The code signs in by itself; the only thing to press is for
                // a fresh one once the server has forgotten the last.
                if quickExpired || (quick == nil && !isStartingQuick) {
                    Button("Get New Code") { Task { await startQuickConnect() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isStartingQuick)
                }
            } else {
                Button("Sign In") {
                    // Return in the username field is the default button as
                    // well as the field's submit: with no password typed yet
                    // it means "next field", not "try with none".
                    if focused == .username, password.isEmpty {
                        focused = .password
                        return
                    }
                    Task { await signIn() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty || isSigningIn)
            }
        }
        .buttonStyle(.bordered)
    }
    #endif

    #if !os(macOS)
    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Server address", text: $address, placeholder: "jellyfin.example.com", isSecure: false)
                .disabled(probe != nil)
                .focused($focused, equals: .address)
                .submitLabel(.go)
                .onSubmit { Task { await connect() } }
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                #endif

            if probe == nil {
                Text("The address you open Jellyfin at in a browser — for example http://192.168.1.10:8096 or https://jellyfin.example.com.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                knownServers
                discoveredList
            }

            if let probe {
                connectedBanner(probe)
                userPicker(probe)
                switch mode {
                case .password:
                    field("Username", text: $username, placeholder: "", isSecure: false)
                        .focused($focused, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        // The pair of them, so a password manager sees a sign-in
                        // form and offers to fill it — and to save it afterwards.
                        .textContentType(.username)
                    field("Password", text: $password, placeholder: "", isSecure: true)
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                        .textContentType(.password)
                case .quickConnect:
                    quickConnectPanel(probe)
                }
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actionButton

            if probe != nil, quickConnectOffered {
                modeSwitch
            }
        }
        .frame(maxWidth: Self.cardWidth)
        .padding(Metrics.gutter)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        // Landing in the field you are meant to fill in next.
        .onChange(of: probe == nil) { _, noServer in
            focused = noServer ? .address : (mode == .password ? .username : nil)
        }
        .alert(
            "No secure connection",
            isPresented: Binding(get: { unencryptedOffer != nil }, set: { if !$0 { unencryptedOffer = nil } }),
            presenting: unencryptedOffer
        ) { found in
            Button("Connect without encryption", role: .destructive) {
                Task { await adopt(found) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { found in
            Text("\(found.server) didn't answer over https, only over plain http. Your password and everything you watch would cross the internet unencrypted — and a network that blocks secure connections looks exactly like this. Only continue if you know this server has no https.")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            // The application's own mark, the one the Linux build and the app
            // icon carry, rather than a system glyph standing in for it.
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 76, height: 76)
                .padding(.bottom, 2)
            HStack(spacing: 0) {
                Text("Aqua").fontWeight(.semibold)
                Text("rium").fontWeight(.heavy).foregroundStyle(Theme.accent)
            }
            .font(.largeTitle)
            Text("A Jellyfin client")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
        }
    }

    // MARK: - Accounts already on this device

    /// Who is still signed in here. After a sign-out, or a token one server
    /// stopped honouring, the others are a press away instead of a password.
    ///
    /// Adding an account, the ones already on this device's list are in
    /// Settings behind the sheet, so only the household's are worth showing:
    /// signed in under another of the Apple TV's users, and not yet here.
    @ViewBuilder
    private var savedAccounts: some View {
        let offered = (addingAccount ? [] : client.accounts) + client.householdAccounts
        if !offered.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(addingAccount ? "Already on this Apple TV" : "Who's watching?")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                ForEach(offered, id: \.accountKey) { account in
                    Button {
                        Task {
                            await app.switchAccount(to: account)
                            if addingAccount, client.session?.accountKey == account.accountKey { app.isAddingAccount = false }
                        }
                    } label: {
                        AccountRow(account: account, isCurrent: false)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .rowButtonStyle()
                }
                Text("Or sign in to another account below.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: Self.cardWidth)
            .padding(Metrics.gutter)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
        }
    }

    #endif

    // MARK: - Servers signed in to before

    /// The servers this device — or, on an Apple TV, anyone using it — is
    /// signed in to. A second person in the house nearly always wants the
    /// same one, and it may not be on the local network to be discovered.
    private var knownServerAddresses: [String] {
        var seen = Set<String>()
        return (client.accounts + client.householdAccounts).map(\.server).filter { seen.insert($0).inserted }
    }

    #if !os(macOS)
    @ViewBuilder
    private var knownServers: some View {
        let servers = knownServerAddresses
        if !servers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Signed in to before")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textDim)
                ForEach(servers, id: \.self) { server in
                    Button {
                        address = server
                        Task { await connect() }
                    } label: {
                        serverRow(name: server.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""),
                                  detail: "Sign in as somebody else", symbol: "person.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .disabled(isProbing)
                }
            }
        }
    }

    private func serverRow(name: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - People on the server

    /// How many names are listed at once. More than this and the list is a
    /// page of its own between the server and the form.
    /// A phone has a keyboard under the list, and a name is quick to type.
    private static var userRows: Int {
        #if os(tvOS)
        6
        #else
        4
        #endif
    }

    /// The server's users, less the ones already signed in here, narrowed by
    /// whatever has been typed. A whole name — typed, or put there by a press
    /// — leaves that one person, ticked; clearing the field brings the rest
    /// back.
    private var matchingUsers: [JellyfinClient.PublicUser] {
        guard let probe else { return [] }
        let here = Set(client.accounts.filter { $0.server == probe.server }.map(\.userId))
        let open = users.filter { !here.contains($0.Id) }
        let typed = username.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty { return open }
        if let exact = open.first(where: { $0.name.caseInsensitiveCompare(typed) == .orderedSame }) { return [exact] }
        return open.filter { $0.name.localizedCaseInsensitiveContains(typed) }
    }

    @ViewBuilder
    private func userPicker(_ probe: ServerProbe) -> some View {
        let matches = matchingUsers
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Who's signing in?")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textDim)
                ForEach(matches.prefix(Self.userRows)) { user in
                    Button {
                        choose(user)
                    } label: {
                        AccountRow(
                            account: SavedSession(server: probe.server, userId: user.Id, userName: user.name, deviceId: ""),
                            isCurrent: user.name.caseInsensitiveCompare(username) == .orderedSame,
                            detail: user.HasPassword == false ? "No password" : ""
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .rowButtonStyle()
                    .disabled(isSigningIn)
                }
                if matches.count > Self.userRows {
                    // The code panel has no username field to type in.
                    Text(mode == .quickConnect
                         ? "And \(matches.count - Self.userRows) more — sign in with a password instead to type a name."
                         : "And \(matches.count - Self.userRows) more — type part of a username to find them.")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    #endif

    /// A name from the list: into the form, and straight in where the server
    /// says there is no password to ask for.
    private func choose(_ user: JellyfinClient.PublicUser) {
        error = nil
        username = user.name
        password = ""
        mode = .password
        if user.HasPassword == false {
            Task { await signIn() }
        } else {
            focused = .password
        }
    }

    #if !os(macOS)
    // MARK: - Servers on the network

    @ViewBuilder
    private var discoveredList: some View {
        if isDiscovering || !discovered.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(discovered.isEmpty ? "Looking on your network…" : "On your network")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textDim)
                    if isDiscovering { ProgressView().controlSize(.mini) }
                }
                ForEach(discovered) { server in
                    Button {
                        address = server.address
                        Task { await connect() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.text)
                                Text(server.address)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textDim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textDim)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isProbing)
                }
            }
            .animation(.easeOut(duration: 0.2), value: discovered)
        }
    }

    #endif

    private func discover() async {
        guard probe == nil, !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        let found = await ServerDiscovery.find()
        // A server that answered while the user was already typing a
        // different address, or after they pressed Connect, is still worth
        // listing — but never worth replacing what they typed.
        if probe == nil { discovered = found }
    }

    #if !os(macOS)
    // MARK: - Quick Connect

    private func quickConnectPanel(_ probe: ServerProbe) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Connect")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textDim)
            VStack(spacing: 10) {
                if let quick {
                    Text(Self.spaced(quick.code))
                        .font(.system(size: codePointSize, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(quickExpired ? Theme.textDim : Theme.text)
                        .contentTransition(.numericText())
                        .animation(.default, value: quick.code)
                        .accessibilityLabel("Quick Connect code \(quick.code.map(String.init).joined(separator: " "))")
                } else {
                    ProgressView()
                        .frame(height: codePointSize)
                }
                if quickExpired {
                    Text("That code has expired.")
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                } else if quick != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the code to be approved…")
                            .font(.footnote)
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("On a phone or computer that is already signed in to \(probe.serverName ?? "this server"), enter this code under Settings → Quick Connect in Aquarium, or on the Quick Connect page of Jellyfin's own web app. This screen signs in by itself the moment it is approved.")
                .font(.caption)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A phone's card is a column; a television's is wider, so that the
    /// banner's warning and the address wrap in two lines rather than six
    /// and the code is on screen without scrolling. A tvOS scroll view only
    /// moves to bring focus into view, and the code itself takes no focus.
    private static var cardWidth: CGFloat {
        #if os(tvOS)
        780
        #else
        460
        #endif
    }

    private var codePointSize: CGFloat {
        #if os(tvOS)
        64
        #else
        44
        #endif
    }

    #endif

    /// "123456" as "123 456" — the way the Jellyfin web app shows it.
    private static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let chars = Array(code)
        return String(chars[0..<3]) + " " + String(chars[3...])
    }

    #if !os(macOS)
    private var modeSwitch: some View {
        Button {
            error = nil
            switch mode {
            case .password:
                mode = .quickConnect
                focused = nil
                if quick == nil || quickExpired { Task { await startQuickConnect() } }
            case .quickConnect:
                mode = .password
                focused = .username
            }
        } label: {
            Text(mode == .password ? "Sign in with a Quick Connect code instead" : "Sign in with a password instead")
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .focused($focused, equals: .modeSwitch)
    }

    #endif

    private func startQuickConnect() async {
        guard let probe, !isStartingQuick else { return }
        isStartingQuick = true
        defer { isStartingQuick = false }
        error = nil
        quickExpired = false
        do {
            quick = try await client.quickConnectInitiate(server: probe.server)
        } catch {
            self.error = error.localizedDescription
            quick = nil
        }
    }

    /// Poll until the code is approved, expires, or leaves the screen.
    private func waitForApproval() async {
        guard let quick, let probe, mode == .quickConnect else { return }
        // Local, not `isSigningIn`: the `defer` below clears that at the end
        // of the `do` block — before the `catch` gets to read it.
        var signingIn = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self.quick?.secret == quick.secret else { return }
            do {
                guard let approved = try await client.quickConnectState(server: probe.server, secret: quick.secret) else {
                    quickExpired = true
                    return
                }
                guard approved else { continue }
                isSigningIn = true
                signingIn = true
                defer { isSigningIn = false }
                let replacing = client.isSignedIn
                let session = try await client.loginWithQuickConnect(server: probe.server, secret: quick.secret)
                self.quick = nil
                if replacing { app.accountChanged() }
                await app.loadLibraries()
                app.toast("Signed in to \(probe.serverName ?? probe.server) as \(session.userName)", tone: .ok)
                return
            } catch {
                // One failed poll is not the end of the request; the next
                // one, three seconds on, will say. Only the sign-in itself,
                // which the server has by then agreed to, is worth reporting —
                // and an approved code is spent, so it is marked as done with
                // and the button for a new one comes back.
                if error is CancellationError || Task.isCancelled { return }
                if signingIn {
                    self.error = error.localizedDescription
                    quickExpired = true
                    return
                }
            }
        }
    }

    #if !os(macOS)
    // MARK: - Banner, fields, buttons

    private func connectedBanner(_ probe: ServerProbe) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(probe.serverName ?? probe.server)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                StatusPill(text: probe.secure ? "HTTPS" : "HTTP", tone: probe.secure ? .ok : .warn)
            }
            Text(probe.version.map { "Jellyfin \($0) · \(probe.server)" } ?? probe.server)
                .font(.caption)
                .foregroundStyle(Theme.textDim)
            if !probe.secure {
                Text("This connection isn't encrypted. Anything on the network path can read your access token and what you watch — fine on a home network, worth fixing if the server is reachable from outside it.")
                    .font(.caption)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Use a different server") { useDifferentServer() }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String, isSecure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textDim)
            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if probe == nil {
            Button {
                Task { await connect() }
            } label: {
                busyLabel(isProbing ? "Looking…" : "Connect", busy: isProbing)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentStrong)
            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isProbing)
        } else if mode == .quickConnect {
            // The code signs in by itself; the only thing to press is for a
            // fresh one once the server has forgotten the last.
            if quickExpired || (quick == nil && !isStartingQuick) {
                Button {
                    Task { await startQuickConnect() }
                } label: {
                    busyLabel(isStartingQuick ? "Asking…" : "Get a new code", busy: isStartingQuick)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentStrong)
                .disabled(isStartingQuick)
            }
        } else {
            Button {
                Task { await signIn() }
            } label: {
                busyLabel(isSigningIn ? "Signing in…" : "Sign in", busy: isSigningIn)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentStrong)
            .disabled(username.isEmpty || isSigningIn)
        }
    }

    /// A button's title, centred in the button, with the spinner beside it
    /// rather than in the middle of it.
    ///
    /// The two used to sit in an `HStack` that was itself centred, so the
    /// spinner appearing pushed the words off to the right by half its width
    /// — which on a television, where the button is the width of the card, is
    /// the whole label visibly sliding sideways the moment it is pressed. The
    /// text now takes the full width and centres in it whatever else is drawn;
    /// the spinner is an overlay pinned to the leading edge and takes no part
    /// in the layout at all.
    private func busyLabel(_ title: String, busy: Bool) -> some View {
        Text(title)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if busy { ProgressView().controlSize(.small) }
            }
    }
    #endif

    /// Back to the address field, with everything the last server told us
    /// forgotten.
    private func useDifferentServer() {
        probe = nil
        users = []
        quick = nil
        quickExpired = false
        quickConnectOffered = false
        mode = .password
        error = nil
        Task { await discover() }
    }

    private func connect() async {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty, !isProbing else { return }
        focused = nil
        error = nil
        isProbing = true
        defer { isProbing = false }
        do {
            let found = try await client.probe(server: address)
            // https was tried and didn't answer. At home that is simply a
            // server without TLS; anywhere else it is also what blocking port
            // 443 looks like, and the password is about to follow.
            if found.fellBackToHTTP, !Self.isLocalAddress(found.server) {
                unencryptedOffer = found
                return
            }
            await adopt(found)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// An address that doesn't leave the building: a private or link-local IP
    /// literal, or a `.local`/single-label name.
    private static func isLocalAddress(_ server: String) -> Bool {
        guard let host = URL(string: server)?.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        if !host.contains(".") && !host.contains(":") { return true }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4, host.split(separator: ".").count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        guard host.contains(":") else { return false }
        return host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") || host == "::1"
    }

    private func adopt(_ found: ServerProbe) async {
        isProbing = true
        defer { isProbing = false }
        async let people = client.publicUsers(server: found.server)
        let offersQuickConnect = await client.quickConnectEnabled(server: found.server)
        users = await people
        probe = found
        quickConnectOffered = offersQuickConnect
        #if os(tvOS)
        // A remote is the reason the code exists. Where the server has
        // it, the television starts there and keeps the password behind
        // a link.
        mode = offersQuickConnect ? .quickConnect : .password
        #else
        mode = .password
        #endif
        if mode == .quickConnect {
            await startQuickConnect()
            #if os(tvOS)
            // Focus decides what a television scrolls to. Left on the
            // banner's link above the code, the code could sit below the
            // fold; on the link beneath it, the whole panel is in view.
            // Asked for a moment after the panel has been laid out — a
            // request made while the code is still arriving is dropped.
            try? await Task.sleep(for: .milliseconds(250))
            focused = .modeSwitch
            #endif
        }
    }

    private func signIn() async {
        guard let probe, !username.isEmpty, !isSigningIn else { return }
        focused = nil
        error = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let replacing = client.isSignedIn
            _ = try await client.login(server: probe.server, username: username, password: password)
            password = ""
            if replacing { app.accountChanged() }
            await app.loadLibraries()
            app.toast(replacing ? "Signed in as \(client.session?.userName ?? username)" : "Signed in to \(probe.serverName ?? probe.server)", tone: .ok)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - One account, as a row

/// A user's picture, name and server: the row the sign-in screen and both
/// Settings pages list accounts with.
struct AccountRow: View {
    let account: SavedSession
    let isCurrent: Bool
    /// For a television's Settings rows, which turn white under the selector:
    /// light text on that is no text at all.
    var invertsWhenFocused = false
    /// The line under the name, where the server is not what needs saying —
    /// a list of one server's users. Empty for no line at all.
    var detail: String?

    @Environment(\.isFocused) private var isFocused

    private var inverted: Bool { invertsWhenFocused && isFocused }

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatar(account: account, size: avatarSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.userName.isEmpty ? "Unnamed user" : account.userName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(inverted ? Color(hex: 0x16161F) : Theme.text)
                if detail != "" {
                    Text(detail ?? account.serverLabel)
                        .font(.caption)
                        .foregroundStyle(inverted ? Color(hex: 0x55556A) : Theme.textDim)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Signed in")
            }
        }
        .contentShape(Rectangle())
    }

    private var avatarSize: CGFloat {
        #if os(tvOS)
        56
        #else
        36
        #endif
    }
}

/// The user's own picture from their server, over their initial for the many
/// who never set one.
struct AccountAvatar: View {
    let account: SavedSession
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(Theme.accentSoft)
            Text(String(account.userName.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
            RemoteImage(url: JellyfinClient.avatarURL(for: account, width: Int(size * 3)), placeholderFill: Self.clear)
                .clipShape(Circle())
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static let clear = LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom)
}

#if os(macOS)
/// A row of one of the sign-in screen's tables, tinted under the pointer.
/// The system draws the selection; this only adds the hover, and stays out
/// of the way of the selected row so the two never fight.
private struct MacHoverRow<Content: View>: View {
    var isSelected: Bool
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .listRowBackground(hovering && !isSelected ? Color.primary.opacity(0.06) : nil)
    }
}
#endif
