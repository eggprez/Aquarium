//  Focus for a television page whose contents arrive after it does.
//
//  A library, a collection or a person's page opens empty — its contents are
//  still being fetched — and an empty page has nothing for the focus engine
//  to hold. The engine places focus when a screen appears, not when it fills
//  in a moment later, so the page sat with nothing focused until the remote
//  was pressed. The title page solves the same thing with its own focus
//  state (`ItemDetailView.focusTarget`). These pages' first control is a card
//  drawn by a shared grid or shelf, so the page marks itself as wanting
//  focus on arrival (`focusOnArrival()`), and the first card to appear in
//  it takes focus, once (`arrivalFocusCard`).

import SwiftUI

/// One page's "focus on arrival", spent by the first card that takes it.
final class ArrivalFocusClaim {
    var spent = false
}

private struct ArrivalFocusKey: EnvironmentKey {
    static let defaultValue: ArrivalFocusClaim? = nil
}

extension EnvironmentValues {
    var arrivalFocus: ArrivalFocusClaim? {
        get { self[ArrivalFocusKey.self] }
        set { self[ArrivalFocusKey.self] = newValue }
    }
}

extension View {
    /// The first card to appear inside this view takes focus, once: for a
    /// television page that opens before its contents have loaded. Nothing
    /// on other platforms.
    func focusOnArrival() -> some View {
        #if os(tvOS)
        modifier(ArrivalFocusPage())
        #else
        self
        #endif
    }

    /// A card that takes focus on arrival if it is the first of its page's
    /// (`isFirst`) and the page asked for it. Nothing on other platforms.
    func arrivalFocusCard(isFirst: Bool) -> some View {
        #if os(tvOS)
        modifier(ArrivalFocusCard(isFirst: isFirst))
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct ArrivalFocusPage: ViewModifier {
    /// Kept for the page's life: coming back to it leaves the selector where
    /// the viewer left it.
    @State private var claim = ArrivalFocusClaim()

    func body(content: Content) -> some View {
        content.environment(\.arrivalFocus, claim)
    }
}

private struct ArrivalFocusCard: ViewModifier {
    let isFirst: Bool
    @Environment(\.arrivalFocus) private var claim
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onAppear {
                guard isFirst, let claim, !claim.spent else { return }
                claim.spent = true
                // After this pass, once the card is in the hierarchy.
                Task { @MainActor in focused = true }
            }
    }
}
#endif
