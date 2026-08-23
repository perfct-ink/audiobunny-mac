import Foundation

// Identifies this app install to the server. Deliberately NOT IOPlatformUUID
// — that's shared by every user account and every app running on this same
// physical Mac, too coarse for "this AudioBunny install." A Keychain-persisted
// random UUID maps 1:1 to this install and survives an app reinstall.
enum MachineIdentity {
    private static let key = "audiobunny.machineId"

    static var id: String {
        if let existing = KeychainStore.get(key: key) { return existing }
        let generated = UUID().uuidString
        KeychainStore.set(generated, key: key)
        return generated
    }

    static var name: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}
