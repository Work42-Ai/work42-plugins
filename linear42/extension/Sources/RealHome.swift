import Darwin
import Foundation

/// The person's real home folder. A sandboxed extension's `NSHomeDirectory()` is its own container, but the `file_access`
/// grants in plugin.yaml are relative to the real home, so every home-relative path starts here.
nonisolated enum RealHome {
    static var url: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
