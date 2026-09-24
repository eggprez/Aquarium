//  Approving a Quick Connect code from a device that is already signed in.
//
//  The other half of the exchange on the sign-in screen: an Apple TV shows a
//  six-digit code, and whoever is holding a phone with this app on it types
//  it here. Jellyfin's web app has the same page under the user menu; this
//  saves opening a browser for it.

#if !os(tvOS)
import SwiftUI

struct QuickConnectApproveSection: View {
    @Environment(JellyfinClient.self) private var client

    @State private var code = ""
    @State private var isApproving = false
    @State private var isConfirming = false
    @State private var outcome: (text: String, tone: StatusPill.Tone)?

    var body: some View {
        Section {
            HStack(spacing: 12) {
                TextField("6-digit code", text: $code)
                    .font(.body.monospacedDigit())
                    // A number pad and nothing more. Marked as a one-time
                    // code, the keyboard offered whatever six digits had last
                    // arrived by text message — and this code signs someone
                    // else's device in as you, so it is the one code that must
                    // not come from whoever sent a message.
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: code) { _, new in
                        // Digits only, and the six of them — the field is not
                        // the place to find out a letter went in.
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { code = digits }
                        if outcome != nil { outcome = nil }
                    }
                    .onSubmit { if code.count == 6 { isConfirming = true } }
                Button {
                    isConfirming = true
                } label: {
                    if isApproving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Approve")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentStrong)
                .disabled(code.count != 6 || isApproving || client.isOffline)
            }
            .confirmationDialog(
                "Sign another device in as \(client.session?.userName ?? "you")?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Approve \(code)") { Task { await approve() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only approve a code you can see on your own device's screen right now. Whoever holds the device showing it gets full access to your account.")
            }
            if let outcome {
                HStack(spacing: 8) {
                    StatusPill(text: outcome.tone == .ok ? "Approved" : "Not approved", tone: outcome.tone)
                    Text(outcome.text)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
            }
        } header: {
            Text("Quick Connect")
        } footer: {
            Text("Another device signing in to this server — an Apple TV, say — can show a code instead of asking for a password. Enter the code here and it is signed in as you.")
        }
    }

    private func approve() async {
        guard code.count == 6, !isApproving else { return }
        isApproving = true
        defer { isApproving = false }
        do {
            if try await client.authorizeQuickConnect(code: code) {
                // The field is emptied first: its change handler clears any
                // verdict on screen, and this one is meant to stay.
                code = ""
                outcome = ("The other device is signing in now.", .ok)
            } else {
                outcome = ("The server doesn't know that code. Check the digits, or ask for a new code — they expire after ten minutes.", .warn)
            }
        } catch {
            outcome = (error.localizedDescription, .bad)
        }
    }
}
#endif
