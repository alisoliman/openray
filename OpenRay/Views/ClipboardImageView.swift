import SwiftUI

struct ClipboardImageView: View {
    let resource: ClipboardImageResource
    var maxPixelSize = 600
    var showsFailureText = true
    /// Thumbnails fill their square; previews fit inside it.
    var fills = false
    @State private var thumbnail: NSImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: fills ? .fill : .fit)
                    .accessibilityLabel(
                        "Clipboard image, \(resource.image.pixelWidth) by \(resource.image.pixelHeight) pixels")
            } else if isLoading {
                if showsFailureText { Spinner() } else { OR.Color.fill2 }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(OR.Color.text2)
                    if showsFailureText {
                        Text("This saved image is missing or damaged.").font(OR.Font.callout)
                            .foregroundStyle(OR.Color.text2)
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
