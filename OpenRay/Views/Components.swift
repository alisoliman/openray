import SwiftUI

enum RayStyle {
    static let accent = Color(red: 1, green: 0.38, blue: 0.36)
    static let subtleFill = Color.primary.opacity(0.045)
}

struct OpenRayMark: View {
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(
                    LinearGradient(
                        colors: [RayStyle.accent, Color(red: 0.88, green: 0.23, blue: 0.38)], startPoint: .topLeading,
                        endPoint: .bottomTrailing))
            Image(systemName: "command").font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct Keycap: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).frame(minWidth: 19, minHeight: 20)
            .background(.primary.opacity(0.06), in: .rect(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.06)) }
            .accessibilityHidden(true)
    }
}

struct ItemIcon: View {
    var item: LauncherItem
    var body: some View {
        Group {
            if let image = item.clipboardImage {
                ClipboardImageView(resource: image, maxPixelSize: 72, showsFailureText: false)
                    .clipShape(.rect(cornerRadius: 5))
            } else if let url = item.iconURL {
                Image(nsImage: FileIconCache.shared.icon(for: url)).resizable().scaledToFit()
            } else {
                Image(systemName: item.symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color.opacity(0.12), in: .rect(cornerRadius: 8))
            }
        }.frame(width: 32, height: 32).accessibilityHidden(true)
    }

    private var color: Color {
        switch item.tint {
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .purple: .purple
        case .coral: RayStyle.accent
        case .neutral: .secondary
        }
    }
}

struct StatusBanner: View {
    var message: String
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: message == "Copied to clipboard" ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(message == "Copied to clipboard" ? Color.green : Color.orange)
            Text(message).font(.system(size: 12)).textSelection(.enabled).frame(
                maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button("Dismiss message", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }.padding(12).background(.primary.opacity(0.045)).accessibilityElement(children: .combine)
    }
}

struct BackButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28).background(.primary.opacity(0.06), in: .rect(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel("Back to launcher").help("Back (Esc)")
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                .frame(width: 62, height: 62).background(.primary.opacity(0.035), in: .rect(cornerRadius: 17))
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 390)
        }.padding(24)
    }
}
