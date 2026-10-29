import Foundation
import Testing

@testable import BridgeplayApp

@Suite("CJK fonts")
struct CJKFontsTests {

    private func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "np-cjk-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // A small stand-in for the release archive: two "fonts" and the licences, packed the way
    // scripts/package-fonts.sh packs them.
    private func archive(in dir: URL, contents: [String: String]) throws -> (URL, [String: String]) {
        let stage = dir.appending(path: "stage", directoryHint: .isDirectory)
        var pins: [String: String] = [:]
        for (name, text) in contents {
            let file = stage.appending(path: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            if !name.contains("/") { pins[name] = Digest.sha256(of: Data(text.utf8)) }
        }
        let out = dir.appending(path: "fonts.tar.xz")
        #expect(try Shell.run("/bin/sh", ["-c", "cd '\(stage.path(percentEncoded: false))' && tar -cJf '\(out.path(percentEncoded: false))' ."]).succeeded)
        return (out, pins)
    }

    @Test("The Makefile keeps exactly the pinned fonts out of the app")
    func makefileMatchesPins() throws {
        let makefile = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../Makefile").standardized
        let text = try String(contentsOf: makefile, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("CJK_FONTS := ") })
        let names = line.dropFirst("CJK_FONTS := ".count).split(separator: " ").map(String.init).sorted()
        #expect(names == CJKFonts.files.keys.sorted())
        #expect(CJKFonts.archive.hasPrefix("fonts-cjk-") && CJKFonts.bases.allSatisfy { $0.host() == "github.com" })
    }

    @Test("Missing fonts are downloaded, checked and laid in with their licences")
    func installsMissing() async throws {
        let dir = try directory("install")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (tarball, pins) = try archive(in: dir, contents: [
            "a.ttf": "font a", "b.ttc": "font b",
            "source-han-sans/LICENSE.txt": "OFL", "ume/license.html": "Ume",
        ])
        let fonts = dir.appending(path: "fonts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        #expect(CJKFonts.missing(in: fonts, pins: pins) == ["a.ttf", "b.ttc"])

        try await CJKFonts.install(into: fonts, downloads: dir.appending(path: "dl"), pins: pins) { _ in tarball }
        #expect(CJKFonts.missing(in: fonts, pins: pins).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fonts.appending(path: "source-han-sans/LICENSE.txt").path(percentEncoded: false)))

        // Nothing missing: no download at all.
        try await CJKFonts.install(into: fonts, downloads: dir, pins: pins) { _ in
            Issue.record("downloaded although every font was there"); return tarball
        }
    }

    @Test("A damaged download changes nothing, and nothing happens before setup")
    func refusesDamaged() async throws {
        let dir = try directory("damaged")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (tarball, _) = try archive(in: dir, contents: ["a.ttf": "not the pinned font"])
        let pins = ["a.ttf": Digest.sha256(of: Data("font a".utf8))]
        let fonts = dir.appending(path: "fonts", directoryHint: .isDirectory)

        // No fonts folder yet: Bridgeplay isn't set up, so nothing is fetched.
        try await CJKFonts.install(into: fonts, downloads: dir, pins: pins) { _ in
            Issue.record("downloaded before setup"); return tarball
        }

        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try Data("older".utf8).write(to: fonts.appending(path: "a.ttf"))
        await #expect(throws: StepFailure.self) {
            try await CJKFonts.install(into: fonts, downloads: dir, pins: pins) { _ in tarball }
        }
        #expect(try String(contentsOf: fonts.appending(path: "a.ttf"), encoding: .utf8) == "older")
    }
}
