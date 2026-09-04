import SwiftUI

struct ContentView: View {
    private let content = WelcomeContent.default

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(content.title)
                .font(.largeTitle.bold())

            Text(content.subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(minWidth: 520, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
