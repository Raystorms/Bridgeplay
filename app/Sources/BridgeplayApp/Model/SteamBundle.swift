// Steam app bundle patching component

import AppKit
import Foundation

enum SteamDeployment: Sendable, Equatable {
    case steamMissing
    case notInstalled
    case installed(version: String?)
    case outdated(deployed: String, bundled: String)
    // If the user has something else installed, maybe let's not deploy?
    case foreign(insert: String)
}

// Reading and writing the injection
enum SteamBundle {

    static let insertKey = "DYLD_INSERT_LIBRARIES"
    static let controllerBlockKey = "SDL_JOYSTICK_BLACKLIST_DEVICES"
    static let controllerBlockValue = "0x05ac/0x0004"

    static let plistBackupName = "Info.plist.before-bridgeplay"
    // The backup's name before 3.0. It is the same unmodified Info.plist, so either counts.
    static let legacyPlistBackupName = "Info.plist.before-notproton"
    static let environmentKey = "LSEnvironment"

    static var isPresent: Bool {
        FileManager.default.fileExists(atPath: SupportPaths.Steam.app.path(percentEncoded: false))
    }

    // Any account's Steam: they all run the same Steam.app, so one open in another account
    // still holds the bundle Bridgeplay re-signs.
    static var isRunning: Bool {
        Shell.processIsRunning(named: "steam_osx", allUsers: true)
    }

    // This account's Steam, the only one that writes this account's config.vdf and the
    // only one steam://exit reaches.
    static var isRunningForThisUser: Bool {
        Shell.processIsRunning(named: "steam_osx")
    }

    static func deployment(
        bundledVersion: String,
        app: URL = SupportPaths.Steam.app,
        versionFile: URL = SupportPaths.deployedVersion
    ) -> SteamDeployment {
        let files = FileManager.default
        guard files.fileExists(atPath: app.path(percentEncoded: false)) else { return .steamMissing }

        let plist = SupportPaths.Steam.infoPlist(inBundle: app)
        guard let insert = currentInsert(at: plist), !insert.isEmpty else { return .notInstalled }

        let deployedDylib = SupportPaths.Steam.deployedDylib(inBundle: app)
            .path(percentEncoded: false)
        let components = insert.split(separator: ":").map(String.init)
        guard components.contains(deployedDylib) else { return .foreign(insert: insert) }

        guard files.fileExists(atPath: deployedDylib) else { return .notInstalled }

        guard currentControllerBlock(at: plist) == controllerBlockValue else {
            return .outdated(deployed: deployedVersion(at: versionFile) ?? "", bundled: bundledVersion)
        }

        guard let deployed = deployedVersion(at: versionFile) else { return .installed(version: nil) }
        if deployed == bundledVersion { return .installed(version: deployed) }
        return .outdated(deployed: deployed, bundled: bundledVersion)
    }

    static func currentInsert(at url: URL = SupportPaths.Steam.infoPlist) -> String? {
        guard let dict = readInfoPlist(at: url),
              let environment = dict[environmentKey] as? [String: Any]
        else { return nil }
        return environment[insertKey] as? String
    }

    static func currentControllerBlock(at url: URL = SupportPaths.Steam.infoPlist) -> String? {
        guard let dict = readInfoPlist(at: url),
              let environment = dict[environmentKey] as? [String: Any]
        else { return nil }
        return environment[controllerBlockKey] as? String
    }

    static func deployedVersion(at url: URL = SupportPaths.deployedVersion) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // What stopClient looks at and does, so tests can stand in for Steam.
    struct Client: Sendable {
        var runningAnywhere: @Sendable () -> Bool = { SteamBundle.isRunning }
        var runningHere: @Sendable () -> Bool = { SteamBundle.isRunningForThisUser }
        var askToQuit: @Sendable () -> Void = { _ = try? Shell.run("/usr/bin/open", ["-g", "steam://exit"]) }
        // The quit the Dock sends. NSWorkspace lists only this account's apps.
        var requestQuit: @Sendable () -> Void = {
            for steam in NSWorkspace.shared.runningApplications
            where steam.executableURL?.lastPathComponent == "steam_osx" {
                steam.terminate()
            }
        }
        var sweep: @Sendable (String) -> Void = { _ = try? Shell.run("/usr/bin/pkill", ["-f", $0]) }
        var pause: @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.5) }
        var attempts = 40
        var escalationAttempts = 20
    }

    // Asks this account's Steam to quit with steam://exit, which Steam can ignore on its
    // login or update screen, then with a macOS quit. Steam is never killed: it may be
    // writing its config or an update. Steam ignores SIGTERM, so none is sent. A Steam
    // another account runs is out of reach and reported as such.
    static func stopClient(
        app: URL = SupportPaths.Steam.app,
        helpers: [URL] = [SupportPaths.Steam.innerApp],
        step: String,
        client: Client = Client(),
        onStopping: () -> Void = {}
    ) throws -> Bool {
        guard client.runningAnywhere() else { return false }
        guard client.runningHere() else { throw OpenInAnotherAccount(step: step) }
        onStopping()

        func quits(within attempts: Int) -> Bool {
            for _ in 0..<attempts where client.runningHere() {
                client.pause()
            }
            return !client.runningHere()
        }
        client.askToQuit()
        var quit = quits(within: client.attempts)
        if !quit {
            AppLog.note("stop: Steam ignored steam://exit, asking macOS to quit it")
            client.requestQuit()
            quit = quits(within: client.escalationAttempts)
        }

        guard quit else {
            throw StepFailure(
                step: step,
                detail: String(localized: "Steam did not quit. Choose Steam > Quit Steam, then try again. If Steam does not respond, quit it in Activity Monitor.")
            )
        }
        guard !client.runningAnywhere() else { throw OpenInAnotherAccount(step: step) }

        for pattern in sweepPatterns(app: app, helpers: helpers) {
            client.sweep(pattern)
        }
        return true
    }

    // Its own type, so a caller that only touches this account's files can carry on.
    struct OpenInAnotherAccount: LocalizedError {
        let step: String
        var errorDescription: String? {
            StepFailure(
                step: step,
                detail: String(localized: "Steam is open in another account on this Mac. Quit Steam in that account, then try again.")
            ).errorDescription
        }
    }

    static func sweepPatterns(app: URL, helpers: [URL]) -> [String] {
        ([app] + helpers).map { url in
            (url.path(percentEncoded: false) + "/").reduce(into: "") { pattern, character in
                if "\\.^$|?*+()[]{}".contains(character) { pattern.append("\\") }
                pattern.append(character)
            }
        }
    }

    static func register(_ app: URL = SupportPaths.Steam.app) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = try? Shell.run(lsregister, ["-f", app.path(percentEncoded: false)])
    }

    static func readInfoPlist(at url: URL = SupportPaths.Steam.infoPlist) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    static func writeInfoPlist(_ dict: [String: Any], at url: URL = SupportPaths.Steam.infoPlist) throws {
        var format = PropertyListSerialization.PropertyListFormat.xml
        if let data = try? Data(contentsOf: url) {
            _ = try? PropertyListSerialization.propertyList(from: data, format: &format)
        }

        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
        try WriteRefused.catching(url) { try data.write(to: url, options: .atomic) }
    }
}
