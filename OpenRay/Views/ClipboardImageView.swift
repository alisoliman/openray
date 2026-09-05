import SwiftUI

struct ClipboardImageView: View {
    let resource: ClipboardImageResource
    var maxPixelSize = 600
    var showsFailureText = true
    @State private var thumbnail: NSImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit()
                    .accessibilityLabel(
                        "Clipboard image, \(resource.image.pixelWidth) by \(resource.image.pixelHeight) pixels")
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    if showsFailureText {
                        Text("This saved image is missing or damaged.").font(.system(size: 11)).foregroundStyle(
                            .secondary
                        )
                        .multilineTextAlignment(.center)
                    }
                }
            }
        }
        .task(id: resource.image.id) {
            thumbnail = nil
            isLoading = true
            let data = await ClipboardImageProcessor.shared.thumbnail(resource, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            thumbnail = data.flatMap(NSImage.init(data:))
            isLoading = false
        }
    }
}
