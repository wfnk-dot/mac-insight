import Foundation

/// What the user should do about a bucket.
public enum ClearAdvice: String, Codable, Sendable {
    /// Fine to move to the Trash from here.
    case safeToClear
    /// Clean it up inside its own app, not in Finder.
    case useItsOwnApp
    /// Look through it first; it's your own stuff.
    case reviewFirst
    /// Managed by macOS; leave it alone.
    case leaveAlone
}

/// The named buckets in "Explain my storage".
public enum StorageBucket: String, Codable, CaseIterable, Sendable {
    case timeMachineSnapshots
    case purgeable
    case caches
    case logs
    case iosBackups
    case iMovie
    case photos
    case mail
    case messages
    case obsRecordings
    case downloads
    case developer
    case homebrewCache
    case nodeModules
    case docker
    case appContainers
    case virtualMemory
    case trash
    case applications
    case macOS
    case everythingElse
    /// Space macOS says is used but the scan could not see.
    case notFound

    public var title: String {
        switch self {
        case .timeMachineSnapshots: return "Time Machine local snapshots"
        case .purgeable: return "Purgeable space"
        case .caches: return "Caches"
        case .logs: return "Logs"
        case .iosBackups: return "iPhone and iPad backups"
        case .iMovie: return "iMovie libraries"
        case .photos: return "Photos library"
        case .mail: return "Mail and attachments"
        case .messages: return "Messages attachments"
        case .obsRecordings: return "OBS recordings"
        case .downloads: return "Downloads"
        case .developer: return "Xcode and developer files"
        case .homebrewCache: return "Homebrew cache"
        case .nodeModules: return "node_modules folders"
        case .docker: return "Docker"
        case .appContainers: return "App containers"
        case .virtualMemory: return "Virtual memory and sleep image"
        case .trash: return "Trash"
        case .applications: return "Applications"
        case .macOS: return "macOS itself"
        case .everythingElse: return "Everything else"
        case .notFound: return "Not found by the scan"
        }
    }

    /// One plain-English line: what it is and how to clear it.
    public var note: String {
        switch self {
        case .timeMachineSnapshots:
            return "Hourly safety copies Time Machine keeps on this disk. macOS deletes them by itself when space runs low."
        case .purgeable:
            return "Space macOS can free on its own (snapshots, iCloud copies, caches). Nothing to do here."
        case .caches:
            return "Temporary files apps can rebuild. Generally safe to clear, but apps may be slower the first time afterwards."
        case .logs:
            return "Diagnostic records. Safe to clear; macOS keeps its own logs trimmed."
        case .iosBackups:
            return "Old iPhone and iPad backups. Delete old ones in Finder: select the device in the sidebar, then Manage Backups."
        case .iMovie:
            return "iMovie library: delete old events and projects inside iMovie, not here."
        case .photos:
            return "Your Photos library: delete photos inside the Photos app, not here."
        case .mail:
            return "Mail messages and their attachments. Delete old mail inside the Mail app."
        case .messages:
            return "Photos and files sent in Messages. Remove them in Messages, or in System Settings > General > Storage > Messages."
        case .obsRecordings:
            return "Screen recordings from OBS. Your own files: review and keep what you want."
        case .downloads:
            return "Things you downloaded. Your own files: review before trashing."
        case .developer:
            return "Xcode build files, simulators and tools. DerivedData and old simulators are safe to clear; Xcode rebuilds them."
        case .homebrewCache:
            return "Old Homebrew downloads. Safe to clear (or run 'brew cleanup')."
        case .nodeModules:
            return "JavaScript packages for projects. Safe to clear; they're reinstalled with 'npm install'."
        case .docker:
            return "Docker images and containers. Clear them inside Docker Desktop (Troubleshoot > Clean / Purge data)."
        case .appContainers:
            return "Private storage for App Store apps. Clear it from inside each app, or by uninstalling the app."
        case .virtualMemory:
            return "Swap and sleep image used by macOS. Managed automatically; leave it alone."
        case .trash:
            return "Things already in the Trash. They still use space until you empty the Trash yourself."
        case .applications:
            return "Installed apps. Remove unused ones with AppCleaner."
        case .macOS:
            return "The operating system. Leave it alone."
        case .everythingElse:
            return "Everything else, broken down by its biggest folders."
        case .notFound:
            return "Used space the scan couldn't see: usually local snapshots, purgeable space, or folders blocked without Full Disk Access."
        }
    }

    public var advice: ClearAdvice {
        switch self {
        case .caches, .logs, .homebrewCache, .nodeModules: return .safeToClear
        case .developer: return .safeToClear
        case .iosBackups, .iMovie, .photos, .mail, .messages, .docker, .appContainers, .applications: return .useItsOwnApp
        case .obsRecordings, .downloads, .trash, .everythingElse: return .reviewFirst
        case .timeMachineSnapshots, .purgeable, .virtualMemory, .macOS, .notFound: return .leaveAlone
        }
    }
}

/// Decides which bucket a file belongs to. Rules are checked in order, most
/// specific first (e.g. Homebrew's cache before general caches, Docker before
/// app containers, node_modules wherever it is).
public struct BucketClassifier: Sendable {
    public var home: String
    /// Folders OBS records into. Also, files named like OBS's default
    /// "2026-10-30 14-05-33.mkv" directly in ~/Movies count as OBS recordings.
    public var obsFolders: [String]

    private let rules: [(prefix: String, bucket: StorageBucket)]

    public init(home: String, obsFolders: [String]? = nil) {
        let home = PathUtils.normalize(home)
        self.home = home
        let obs = (obsFolders ?? [home + "/Movies/OBS"]).map(PathUtils.normalize)
        self.obsFolders = obs
        let h = home
        var rules: [(prefix: String, bucket: StorageBucket)] = [
            (h + "/.Trash", .trash),
            ("/.Trashes", .trash),
            ("/private/var/vm", .virtualMemory),
            (h + "/Library/Application Support/MobileSync", .iosBackups),
            (h + "/Library/Mail", .mail),
            (h + "/Library/Containers/com.apple.mail", .mail),
            (h + "/Library/Messages", .messages),
            (h + "/Library/Containers/com.docker.docker", .docker),
            (h + "/Library/Group Containers/group.com.docker", .docker),
            (h + "/.docker", .docker),
            (h + "/Library/Caches/Homebrew", .homebrewCache),
            (h + "/Library/Caches/com.apple.dt.Xcode", .developer),
            (h + "/Library/Developer", .developer),
            ("/Library/Developer", .developer),
            ("/opt/homebrew", .developer),
            ("/usr/local/Homebrew", .developer),
            (h + "/.npm", .developer),
            (h + "/.gradle", .developer),
            (h + "/.cargo", .developer),
            (h + "/.cache", .caches),
            (h + "/Library/Caches", .caches),
            ("/Library/Caches", .caches),
            ("/System/Library/Caches", .caches),
            ("/private/var/folders", .caches),
            (h + "/Library/Logs", .logs),
            ("/Library/Logs", .logs),
            ("/private/var/log", .logs),
            ("/private/var/logs", .logs),
        ]
        for folder in obs { rules.append((folder, .obsRecordings)) }
        rules += [
            (h + "/Downloads", .downloads),
            (h + "/Library/Containers", .appContainers),
            (h + "/Library/Group Containers", .appContainers),
            ("/Applications", .applications),
            (h + "/Applications", .applications),
            ("/System", .macOS),
            ("/usr", .macOS),
            ("/bin", .macOS),
            ("/sbin", .macOS),
            ("/Library/Apple", .macOS),
        ]
        self.rules = rules
    }

    /// `path` should already be normalised (see `PathUtils.normalize`).
    public func classify(_ path: String) -> StorageBucket {
        if path.contains("/node_modules/") || path.hasSuffix("/node_modules") { return .nodeModules }
        if path.contains(".photoslibrary/") || path.hasSuffix(".photoslibrary") { return .photos }
        if path.contains(".imovielibrary/") || path.hasSuffix(".imovielibrary")
            || path.contains(".theater/") || path.hasSuffix(".theater") {
            return .iMovie
        }
        if path.hasPrefix("/Volumes/"), path.contains("/.Trashes/") { return .trash }
        if path.contains("/Xcode.app/") || path.contains("/Xcode-beta.app/") { return .developer }
        for rule in rules where PathUtils.isInside(path, rule.prefix) {
            return rule.bucket
        }
        if PathUtils.parent(path) == home + "/Movies", Self.looksLikeOBSRecording(PathUtils.lastComponent(path)) {
            return .obsRecordings
        }
        return .everythingElse
    }

    /// OBS's default file name: "YYYY-MM-DD HH-MM-SS.ext".
    public static func looksLikeOBSRecording(_ name: String) -> Bool {
        let chars = Array(name)
        guard chars.count > 20, chars[19] == "." else { return false }
        let pattern = Array("dddd-dd-dd dd-dd-dd")
        for (i, p) in pattern.enumerated() {
            if p == "d" {
                guard chars[i].isASCII, chars[i].isNumber else { return false }
            } else if chars[i] != p {
                return false
            }
        }
        let ext = String(chars[20...]).lowercased()
        return ["mkv", "mp4", "mov", "flv", "ts", "m3u8"].contains(ext)
    }

    /// Key for the "Everything else, by top folders" breakdown: the folder
    /// under the home folder (e.g. ~/Documents), else the top-level folder.
    public func topFolder(for path: String) -> String {
        if PathUtils.isInside(path, home) && path != home {
            let rest = PathUtils.components(String(path.dropFirst(home.count)))
            if rest.count >= 2 { return home + "/" + rest[0] }
            return home + " (loose files)"
        }
        let parts = PathUtils.components(path)
        if parts.count >= 2 { return "/" + parts[0] }
        return "/ (loose files)"
    }
}
