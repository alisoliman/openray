import AppKit
import CryptoKit
import Foundation

// A private-pasteboard fixture producer for end-to-end UI verification.
// It refuses the General pasteboard and never reads clipboard contents outside
// the dedicated OpenRayVerification namespace.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    fatalError(
        "Usage: clipboard-fixture.swift OpenRayVerification.NAME image PATH | files PATH... | describe | release")
}
let name = arguments[0]
guard name.hasPrefix("OpenRayVerification."), name.count <= 160,
    name.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45
    })
else {
    fatalError("Only a dedicated OpenRayVerification pasteboard may be used.")
}
let board = NSPasteboard(name: .init(name))
switch arguments[1] {
case "image":
    guard arguments.count == 3 else { fatalError("An image file is required.") }
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    board.clearContents()
    guard board.setData(data, forType: .png) else { fatalError("The image fixture could not be written.") }
    print("Wrote an image to the private pasteboard.")
case "files":
    guard arguments.count > 2 else { fatalError("At least one file path is required.") }
    let items = arguments.dropFirst(2).map { path in
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        return item
    }
    board.clearContents()
    guard board.writeObjects(items) else { fatalError("File fixtures could not be written.") }
    print("Wrote \(items.count) file references to the private pasteboard.")
case "describe":
    var result: [String: Any] = [
        "types": (board.types ?? []).map(\.rawValue), "items": board.pasteboardItems?.count ?? 0,
    ]
    if let image = board.data(forType: .png) {
        result["pngBytes"] = image.count
        result["pngSHA256"] = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
    }
    result["fileURLs"] = board.pasteboardItems?.compactMap { $0.string(forType: .fileURL) } ?? []
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
case "release":
    board.releaseGlobally()
    print("Released the private verification pasteboard.")
default: fatalError("Unknown fixture action.")
}
