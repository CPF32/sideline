import SwiftUI
import UIKit

/// Host mark for MFL / Sleeper / ESPN in league switchers and connect rows.
struct ProviderLogoView: View {
    let provider: LeagueProvider
    var size: CGFloat = 22
    var cornerRadius: CGFloat? = nil

    private var resolvedCorner: CGFloat {
        cornerRadius ?? Self.defaultCornerRadius(for: size)
    }

    static func defaultCornerRadius(for size: CGFloat) -> CGFloat {
        max(4, size * 0.22)
    }

    /// Pre-rounded bitmap for `Menu` / `UIMenu` icons (SwiftUI `clipShape` is ignored there).
    static func menuImage(for provider: LeagueProvider, size: CGFloat = 22) -> Image {
        Image(uiImage: roundedUIImage(named: provider.logoAssetName, size: size) ?? UIImage())
            .renderingMode(.original)
    }

    private static func roundedUIImage(named name: String, size: CGFloat) -> UIImage? {
        guard let source = UIImage(named: name) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            UIBezierPath(roundedRect: rect, cornerRadius: defaultCornerRadius(for: size)).addClip()
            source.draw(in: rect)
        }
    }

    var body: some View {
        Image(provider.logoAssetName)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: resolvedCorner, style: .continuous))
            .accessibilityLabel(provider.displayName)
    }
}
