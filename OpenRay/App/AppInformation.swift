import Foundation

enum AppInformation {
    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    static let documentationURL = URL(string: "https://github.com/alisoliman/openray#readme")!
    static let supportURL = URL(string: "https://github.com/alisoliman/openray/issues")!
}
