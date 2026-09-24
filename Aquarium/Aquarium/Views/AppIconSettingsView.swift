//  Settings → App Icon: the icon on the Home Screen, picked from a shelf.
//
//  Every icon is an Icon Composer document in `App Icons/` — Liquid Glass on
//  iOS 26 and later, with the light, dark and tinted looks the system asks for,
//  flattened by Xcode for earlier releases — and each alternate is listed in
//  ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES for the iPhone SDKs. The tiles
//  here are pictures of them from `App Icon Previews` in the asset catalog,
//  because an app icon can't be loaded as an image by name.
//  Tools/IconGenerator/app_icons.py writes both.
//
//  iOS says so itself, with an alert, whenever the icon changes; there is no
//  sanctioned way round that and nothing here tries.

import SwiftUI

#if os(iOS)
struct AppIconChoice: Identifiable, Hashable {
    /// The alternate icon's name, or nil for the primary.
    let iconName: String?
    let title: String
    let blurb: String

    var id: String { iconName ?? "AppIcon" }
    var preview: String { (iconName ?? "AppIcon").replacingOccurrences(of: "AppIcon", with: "IconPreview") }

    static let classic = AppIconChoice(iconName: nil, title: "Aquarium", blurb: "The original")

    static let shelves: [(title: String, icons: [AppIconChoice])] = [
        ("Aquarium", [
            classic,
            .init(iconName: "AppIcon-Ink", title: "Ink", blurb: "Just the mark"),
            .init(iconName: "AppIcon-Gold", title: "Gold", blurb: "The premiere edition"),
        ]),
        ("Colourful", [
            .init(iconName: "AppIcon-Prism", title: "Prism", blurb: "Every colour at once"),
            .init(iconName: "AppIcon-Sherbet", title: "Sherbet", blurb: "Three scoops"),
            .init(iconName: "AppIcon-Neon", title: "Neon", blurb: "Open all night"),
        ]),
        ("Throwbacks", [
            .init(iconName: "AppIcon-RabbitEars", title: "Rabbit Ears", blurb: "Don't touch that dial"),
            .init(iconName: "AppIcon-Glitch", title: "Glitch", blurb: "Signal lost, show found"),
            .init(iconName: "AppIcon-8Bit", title: "8-Bit", blurb: "Press start"),
        ]),
        ("After dark", [
            .init(iconName: "AppIcon-Midnight", title: "Midnight", blurb: "For the 2 a.m. episode"),
            .init(iconName: "AppIcon-SunsetDrive", title: "Sunset Drive", blurb: "Outrun the end credits"),
        ]),
        ("Wildcards", [
            .init(iconName: "AppIcon-Jelly", title: "Jelly", blurb: "Say hi to the locals"),
            .init(iconName: "AppIcon-Popcorn", title: "Popcorn", blurb: "Extra butter"),
        ]),
    ]

    static var all: [AppIconChoice] { shelves.flatMap(\.icons) }

    /// The icon the Home Screen shows now.
    @MainActor static var current: AppIconChoice {
        let name = UIApplication.shared.alternateIconName
        return all.first { $0.iconName == name } ?? classic
    }
}

struct AppIconSettingsView: View {
    @State private var current = AppIconChoice.current
    @State private var failure: String?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(AppIconChoice.shelves, id: \.title) { shelf in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(shelf.title)
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(shelf.icons) { icon in
                                tile(icon)
                            }
                        }
                    }
                }
                Text("Each icon has a dark look and follows the tint you choose for the Home Screen.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Theme.background)
        .screenTitle("App Icon")
        .paletteBar()
        .alert("Couldn't change the icon", isPresented: .init(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func tile(_ icon: AppIconChoice) -> some View {
        let isCurrent = icon == current
        return Button {
            choose(icon)
        } label: {
            VStack(spacing: 8) {
                Image(icon.preview)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Theme.accent)
                                .offset(x: 6, y: 6)
                        }
                    }
                VStack(spacing: 2) {
                    Text(icon.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(Theme.text)
                    Text(icon.blurb)
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                }
                .multilineTextAlignment(.center)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(icon.title), \(icon.blurb)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func choose(_ icon: AppIconChoice) {
        guard icon != current, UIApplication.shared.supportsAlternateIcons else { return }
        let previous = current
        current = icon
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(icon.iconName)
            } catch {
                current = previous
                failure = error.localizedDescription
            }
        }
    }
}
#endif
