import SwiftUI

extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension View {
    /// Use at every window root so native scenes and the launcher stay in sync.
    func appAppearance(_ appearance: AppAppearance) -> some View {
        preferredColorScheme(appearance.colorScheme)
    }
}
