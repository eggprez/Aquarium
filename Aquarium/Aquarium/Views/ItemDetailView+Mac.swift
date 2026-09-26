//  The detail page's Mac-only pieces that don't need the page's own state:
//  Return opening a focused tile, and the disk-space question as an alert.

import SwiftUI

extension View {
    /// Text the pointer can select and copy — the overview, the facts, the
    /// tagline. Mac only: `textSelection` doesn't exist on tvOS, and on a
    /// phone selectable text changes what a tap on it does.
    @ViewBuilder
    func macSelectable() -> some View {
        #if os(macOS)
        textSelection(.enabled)
        #else
        self
        #endif
    }

    /// Return on a focused tile opens it. A button answers Space on the Mac
    /// and nothing else; a tile you have arrowed to and pressed Return on
    /// expects to open, the way a file in Finder does. Nothing anywhere
    /// else — the television's select button already does this, and a
    /// phone has no keys.
    @ViewBuilder
    func macOpensOnReturn(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onKeyPress(.return) {
            action()
            return .handled
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
extension View {
    /// "That won't fit, and here is what would" — as an alert, with the rungs
    /// that fit as its buttons. The first of them is the default, so Return
    /// takes the best fit and Escape takes nothing; the phone's sheet of
    /// stacked full-width buttons had neither.
    func spaceAlert(
        _ prompt: Binding<SpacePrompt?>,
        onChoose: @escaping (SpacePrompt, DownloadQuality) -> Void
    ) -> some View {
        alert(
            "Not Enough Disk Space",
            isPresented: Binding(
                get: { prompt.wrappedValue != nil },
                set: { if !$0 { prompt.wrappedValue = nil } }
            ),
            presenting: prompt.wrappedValue
        ) { current in
            ForEach(Array(current.verdict.alternatives.enumerated()), id: \.element.id) { index, alternative in
                let size = DownloadManager.estimateTotal(current.items, quality: alternative)
                Button("Use \(alternative.label)" + (size.map { " (about \(Format.bytes($0)))" } ?? "")) {
                    onChoose(current, alternative)
                }
                .keyboardShortcut(index == 0 ? KeyboardShortcut.defaultAction : nil)
            }
            Button("Download Anyway", role: .destructive) { onChoose(current, current.requested) }
            Button("Cancel", role: .cancel) {}
        } message: { current in
            let count = current.items.count
            Text("\(count) item\(count == 1 ? "" : "s") at \(current.requested.label) needs about \(Format.bytes(current.verdict.needed)), and there is \(Format.bytes(current.verdict.free)) free where downloads are kept.")
        }
    }
}
#endif
