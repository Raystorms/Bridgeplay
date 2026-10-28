// The Chinese, Japanese and Korean fonts the run script links into every prefix

import Foundation

// About 85 MB, so the app doesn't carry them (Makefile CJK_FONTS): they come from their own
// release, checked against these pins, once Bridgeplay's fonts folder exists. The run script
// links whatever is in that folder, so a game started before they arrive shows boxes for CJK
// text until the next refresh brings them. Packed by scripts/package-fonts.sh, which prints
// these pins.
enum CJKFonts {
    static let step = String(localized: "Adding fonts for Chinese, Japanese and Korean")

    static let archive = "fonts-cjk-29ba44d27134.tar.xz"
    static let sha256 = "2520655a6752299ecb025e5b23fff7181c96e634269e27b74ec16d36558aaaf7"
    static let bases = [URL(string: "https://github.com/raymondchins/Bridgeplay/releases/download/fonts-cjk-29ba44d27134")!]

    static let files: [String: String] = [
        "malgun.ttf": "e006f28630a8142a929fdab0097d4d267c4003dcdac0ec3ec51ffecc8d1afcd5",
        "msgothic.ttc": "75704a3efa6b2e1c2c5af586192cb65b945e27e89bf5fc9076c31328a726dba0",
        "msyh.ttf": "955e1e0dc1f8d8fdbb3cfb22a395a27b1dd24b8108930c94e2bcda216b560a6b",
        "msyhbd.ttf": "cef037b3f0e00ab8cab78355aa339aedd426581160b30f27879803a24c988bee",
        "simsun.ttc": "59e540ec2eacb2d8417add67eceb2efdc8bd978aa2a0a93195db5b2805a43e6a",
    ]
    // Their licences, beside them in the archive and in the fonts folder.
    static let licences = ["source-han-sans/LICENSE.txt", "ume/license.html"]

    typealias Obtain = @Sendable (_ downloads: URL) async throws -> URL

    static let liveObtain: Obtain = { downloads in
        try await PinnedDownload.obtain(file: archive, sha256: sha256, bases: bases, into: downloads,
                                        step: step, from: "GitHub")
    }

    // Fonts that are absent or differ from their pin. Installs from before the split already
    // have them from the app, so nothing is downloaded there.
    static func missing(in fonts: URL = SupportPaths.fonts, pins: [String: String] = files) -> [String] {
        pins.filter { name, hash in Digest.sha256IfPresent(fonts.appending(path: name)) != hash }.keys.sorted()
    }

    // Downloads and lays the fonts in when the folder exists (Bridgeplay is set up) and any is
    // missing. Each font is checked against its pin before it replaces anything.
    static func install(into fonts: URL = SupportPaths.fonts, downloads: URL = FreeEngine.downloads,
                        pins: [String: String] = files, obtain: Obtain = liveObtain) async throws {
        let files = FileManager.default
        guard files.fileExists(atPath: fonts.path(percentEncoded: false)), !missing(in: fonts, pins: pins).isEmpty else { return }
        try files.createDirectory(at: downloads, withIntermediateDirectories: true)
        let archive = try await obtain(downloads)

        let work = fonts.deletingLastPathComponent()
            .appending(path: ".fonts-cjk-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work) }
        let unpacked = try Shell.run("/usr/bin/tar", ["-xJf", archive.path(percentEncoded: false),
                                                      "-C", work.path(percentEncoded: false)])
        guard unpacked.succeeded else {
            throw StepFailure(step: step, detail: String(localized: "The font download could not be unpacked."))
        }
        for (name, hash) in pins {
            guard Digest.sha256IfPresent(work.appending(path: name)) == hash else {
                AppLog.note("fonts: \(name) in \(archive.lastPathComponent) does not match its pin")
                throw StepFailure(step: step, detail: String(localized: "The font download is damaged."))
            }
        }
        for name in pins.keys.sorted() + licences {
            let source = work.appending(path: name), destination = fonts.appending(path: name)
            guard files.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try files.replaceItemAt(destination, withItemAt: source)
        }
        AppLog.note("fonts: added \(pins.count) CJK fonts from \(archive.lastPathComponent)")
    }

    // One background attempt at a time; a failure waits for the next refresh.
    @MainActor private static var running = false

    @MainActor static func fetchIfNeeded() {
        guard !running else { return }
        running = true
        Task.detached(priority: .utility) {
            do { try await install() } catch { AppLog.note("fonts: CJK fonts not added: \(error.localizedDescription)") }
            await MainActor.run { running = false }
        }
    }
}
