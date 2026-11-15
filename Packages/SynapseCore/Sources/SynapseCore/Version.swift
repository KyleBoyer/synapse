import Foundation

public enum Synapse {
    /// The app's marketing version (set from the release tag in CI); "dev" when running outside the app bundle.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
