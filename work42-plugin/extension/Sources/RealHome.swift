import Foundation
#if os(macOS)
import Darwin
#endif

/// The person's real home folder. A sandboxed extension's `NSHomeDirectory()` is its own container, but the `file_access` grant in
/// plugin.yaml is relative to the real home, so every home-relative path starts here. (An iPad draws these widgets without
/// touching those folders; there it is the app's home, which only has to be a valid path.)
nonisolated enum RealHome {
    static var url: URL {
        #if os(macOS)
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        #endif
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static var path: String { url.path }

    /// `~/.work42/meet42`: the folder the plugin declares read-write.
    static var meet42Folder: URL { url.appendingPathComponent(".work42/meet42", isDirectory: true) }
}
