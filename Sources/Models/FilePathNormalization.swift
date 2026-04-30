import Foundation

enum FilePathNormalization {
    /// Stable POSIX paths for index keys, manual edits, and prefix checks (`.` / `..` collapsed, trailing slashes removed).
    static func canonical(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    static func pathsMatch(_ a: String, _ b: String) -> Bool {
        canonical(a) == canonical(b)
    }

    /// Whether `filePath` lies under `libraryRoot`. Root comparison is case-insensitive so enumerator paths still match the folder the user picked on a default APFS/HFS+ install.
    static func isUnderLibraryRoot(_ filePath: String, libraryRoot: String) -> Bool {
        let f = canonical(filePath).lowercased()
        let r = canonical(libraryRoot).lowercased()
        if f == r { return true }
        return f.hasPrefix(r + "/")
    }
}
