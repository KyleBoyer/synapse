import Foundation

public enum PathPolicy {
    public static func isAllowed(_ path: String, roots: [String]) -> Bool {
        func resolve(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }
        let p = resolve(path)
        return roots.contains { r in
            let root = resolve(r)
            return p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }
}
