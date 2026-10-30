import Foundation

/// A running process as Part B sees it (from `NSRunningApplication`,
/// `proc_pidpath`, `proc_pidinfo` and the responsible-process lookup).
public struct ProcessRecord: Codable, Hashable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    /// The process macOS holds responsible (e.g. the .app that launched a
    /// Java helper). Optional.
    public var responsiblePID: Int32?
    public var executablePath: String?
    public var bundleIdentifier: String?
    /// `NSRunningApplication.localizedName`, if any.
    public var localizedName: String?
    /// Command-line arguments, if Part B can read them. Java launchers often
    /// pass a path inside the .app here.
    public var arguments: [String]

    public init(pid: Int32, parentPID: Int32 = 1, responsiblePID: Int32? = nil, executablePath: String? = nil, bundleIdentifier: String? = nil, localizedName: String? = nil, arguments: [String] = []) {
        self.pid = pid
        self.parentPID = parentPID
        self.responsiblePID = responsiblePID
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.arguments = arguments
    }
}

/// A user-editable fix for an app that still shows the wrong name.
public struct AppNameOverride: Codable, Hashable, Sendable {
    public enum Match: Codable, Hashable, Sendable {
        case bundleIdentifier(String)
        /// Last path component of the executable, e.g. "java".
        case executableName(String)
        /// Any part of the executable path or arguments.
        case pathContains(String)
    }

    public var match: Match
    public var displayName: String

    public init(_ match: Match, displayName: String) {
        self.match = match
        self.displayName = displayName
    }

    func matches(_ p: ProcessRecord) -> Bool {
        switch match {
        case .bundleIdentifier(let id):
            return p.bundleIdentifier?.caseInsensitiveCompare(id) == .orderedSame
        case .executableName(let name):
            guard let exe = p.executablePath else { return false }
            return PathUtils.lastComponent(exe).caseInsensitiveCompare(name) == .orderedSame
        case .pathContains(let fragment):
            if let exe = p.executablePath, exe.contains(fragment) { return true }
            return p.arguments.contains { $0.contains(fragment) }
        }
    }
}

/// Turns processes into the names people recognise: ExoCharts rather than
/// "java", Slack rather than "Slack Helper (Renderer)".
public struct AppNameResolver: Sendable {
    public var overrides: [AppNameOverride]

    /// Runtimes and wrappers whose own name means nothing to the user.
    public static let genericNames: Set<String> = [
        "java", "javaw", "jspawnhelper", "python", "python3", "node", "electron", "ruby", "perl",
        "wine", "wine64", "wineserver", "mono", "dotnet", "bash", "zsh", "sh", "osascript",
        "applet", "universalaccessauthwarn",
    ]

    /// Folders inside an .app where helper apps live. An .app found inside
    /// one of these belongs to the outer app.
    static let helperFolders: Set<String> = ["Frameworks", "Helpers", "XPCServices", "LoginItems", "Library", "MacOS", "Resources", "PlugIns", "SharedSupport"]

    public init(overrides: [AppNameOverride] = []) {
        self.overrides = overrides
    }

    public func resolve(pid: Int32, processes: [Int32: ProcessRecord]) -> String {
        guard let record = processes[pid] else { return "Unknown" }

        // The process itself, then whoever is responsible for it, then its parents.
        var chain: [ProcessRecord] = [record]
        var visited: Set<Int32> = [record.pid]
        if let rp = record.responsiblePID, rp != record.pid, let r = processes[rp] {
            chain.append(r)
            visited.insert(rp)
        }
        var parent = record.parentPID
        while parent > 1, chain.count < 12, !visited.contains(parent), let p = processes[parent] {
            chain.append(p)
            visited.insert(parent)
            parent = p.parentPID
        }

        for candidate in chain {
            if let name = override(for: candidate) { return name }
            if let name = Self.appName(fromPath: candidate.executablePath) { return name }
            for arg in candidate.arguments {
                if let name = Self.appName(fromPath: arg) { return name }
            }
            if let name = candidate.localizedName, !Self.isGeneric(name) { return name }
        }
        return record.localizedName
            ?? record.executablePath.map(PathUtils.lastComponent)
            ?? "Unknown"
    }

    private func override(for p: ProcessRecord) -> String? {
        overrides.first { $0.matches(p) }?.displayName
    }

    static func isGeneric(_ name: String) -> Bool {
        genericNames.contains(name.lowercased())
    }

    /// The app a path belongs to: the innermost .app that isn't a helper
    /// tucked inside another app. "/Applications/Slack.app/Contents/Frameworks/
    /// Slack Helper (Renderer).app/..." -> "Slack";
    /// "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/..." -> "Simulator".
    public static func appName(fromPath path: String?) -> String? {
        guard let path, path.contains(".app") else { return nil }
        let parts = PathUtils.components(path)
        let appIndices = parts.indices.filter { parts[$0].hasSuffix(".app") && parts[$0].count > 4 }
        guard var chosen = appIndices.last else { return nil }
        var k = appIndices.count - 1
        while k > 0 {
            let outer = appIndices[k - 1]
            let between = parts[(outer + 1)..<chosen]
            let name = parts[chosen]
            let isHelper = name.localizedCaseInsensitiveContains("helper")
                || between.contains(where: { helperFolders.contains($0) })
            guard isHelper else { break }
            chosen = outer
            k -= 1
        }
        return String(parts[chosen].dropLast(4))
    }
}
