import SwiftUI

/// The walk-through: shown the first time the window opens, and again from
/// the ? button or the Help menu. It says what the app is for and what each
/// part of the window does, in the order a person meets them.
struct Intro: View {
    @EnvironmentObject var model: Model

    struct Page {
        var symbol: String
        var tint: Color
        var title: String
        var lead: String
        var points: [(String, String)] = []
    }

    static let pages: [Page] = [
        Page(symbol: "checkmark.seal.fill", tint: .accentColor,
             title: "Welcome to Aquarium Tests",
             lead: "This app checks that Aquarium still works. It builds the app, opens it on practice devices inside this Mac, and uses it the way a person would: signing in, browsing, playing video, changing settings. You don't need to know anything about the code.",
             points: [
                ("clock", "This takes about a minute to read. You can open it again any time from the ? button at the top left, or the Help menu."),
             ]),
        Page(symbol: "checklist", tint: .blue,
             title: "1. Choose what to test",
             lead: "The list on the left is everything that can be tested. Each row is a device or a part of the app.",
             points: [
                ("circle", "Click the circle on a row to tick it. Ticked rows are what will be tested."),
                ("hand.point.up.left", "Click the row itself to read what it checks, in plain words, on the right."),
                ("hare.fill", "Not sure? Press Quick check. It ticks the fast checks, which take a few minutes. Full check ticks everything and takes a few hours."),
                ("nosign", "A greyed-out row is turned off for now or can't run on this Mac. Click it to see why."),
             ]),
        Page(symbol: "play.circle.fill", tint: .green,
             title: "2. Press Start Testing",
             lead: "The big button at the bottom left starts everything you ticked, one after another.",
             points: [
                ("server.rack", "The checks use a practice media server on this Mac, filled with sample films and shows. Start Testing turns it on for you if it is off."),
                ("iphone", "Practice iPhones, iPads, Apple TVs and Watches may open in windows and move by themselves. That is the testing. Leave those windows alone."),
                ("desktopcomputer", "You can keep using your Mac for other things. Keep it awake and plugged in for long runs."),
                ("stop.fill", "Stop Testing ends the run early. What has finished so far is kept."),
             ]),
        Page(symbol: "list.bullet.clipboard.fill", tint: .orange,
             title: "3. Read the result",
             lead: "The Summary page shows progress while it runs and the outcome when it ends. It will say one of three things.",
             points: [
                ("checkmark.seal.fill", "Everything passed: nothing to do."),
                ("xmark.octagon.fill", "Problems found: some checks did not go as expected. Each one is listed in plain words, with a picture of the screen when there is one."),
                ("exclamationmark.triangle.fill", "Couldn't run: a part never got started. That is usually a set-up hiccup, not a fault in Aquarium. Trying that part again often clears it."),
             ]),
        Page(symbol: "doc.on.clipboard.fill", tint: .purple,
             title: "4. Give the report to Claude",
             lead: "You never have to work out what went wrong yourself. Every run writes a full report.",
             points: [
                ("doc.on.clipboard", "Press Copy Report for Claude on the Summary page."),
                ("bubble.left.and.text.bubble.right", "Paste it into a chat with Claude and ask it to take a look. The report says what ran, what went wrong and where the screenshots are."),
                ("arrow.counterclockwise", "The last run's results are still here the next time you open the app."),
             ]),
    ]

    var body: some View {
        let pages = Self.pages
        let index = min(max(model.introPage, 0), pages.count - 1)
        let page = pages[index]
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 16) {
                        IconTile(symbol: page.symbol, tint: page.tint, size: 56)
                        Text(page.title).font(.largeTitle.weight(.bold))
                    }
                    Text(page.lead).font(.title3).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(page.points, id: \.1) { symbol, text in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: symbol).foregroundStyle(page.tint).frame(width: 22)
                                Text(text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(28)
                .frame(height: 400, alignment: .top)
                Divider()
                HStack {
                    Button("Skip") { close() }
                        .buttonStyle(.link)
                        .opacity(index == pages.count - 1 ? 0 : 1)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(pages.indices, id: \.self) { dot in
                            Circle().fill(dot == index ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .accessibilityLabel("Page \(index + 1) of \(pages.count)")
                    Spacer()
                    Button("Back") { model.introPage = index - 1 }
                        .controlSize(.large)
                        .disabled(index == 0)
                    if index == pages.count - 1 {
                        Button("Get Started") { close() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Next") { model.introPage = index + 1 }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
            }
            .frame(width: 640)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
            .shadow(radius: 30, y: 10)
        }
        .onExitCommand { close() }
    }

    private func close() {
        UserDefaults.standard.set(true, forKey: "seenIntro")
        model.introShowing = false
        model.introPage = 0
    }
}
