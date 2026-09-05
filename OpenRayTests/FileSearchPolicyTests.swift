import Foundation
import Testing

@testable import OpenRay

struct FileSearchPolicyTests {
    private let home = URL(fileURLWithPath: "/Users/tester")

    @Test(arguments: [
        "/Users/tester/Library/Application Support/calculator.js",
        "/Users/tester/Library", "/Users/tester/Dev/app/node_modules/calculator.js",
        "/Users/tester/Dev/app/.git/config", "/Users/tester/.ssh/config",
        "/Users/tester/Apps/Something.app/Contents/config.json",
        "/Users/tester/Dev/DerivedData/file.swift", "/Users/tester-other/Documents/note.txt",
        "/System/Library/file.txt", "/Users/tester/../other/file.txt",
    ])
    func excludesPrivateAndNoisyPathsEvenWhenSpotlightReturnsThem(_ path: String) {
        #expect(!FileSearchPolicy.accepts(URL(fileURLWithPath: path), home: home))
    }

    @Test(arguments: [
        "/Users/tester/Documents/Meeting notes.txt", "/Users/tester/Desktop/Invoice.pdf",
        "/Users/tester/Dev/OpenRay/Calculator.swift", "/Users/tester/Documents/Library book.txt",
    ])
    func permitsOrdinaryHomeFiles(_ path: String) {
        #expect(FileSearchPolicy.accepts(URL(fileURLWithPath: path), home: home))
    }
}
