import Foundation

struct WelcomeContent: Equatable {
    let title: String
    let subtitle: String

    static let `default` = WelcomeContent(
        title: "OpenRay",
        subtitle: "A fast, private launcher for macOS."
    )
}
