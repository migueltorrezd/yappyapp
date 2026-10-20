import AppKit
import IOKit

/// YA-61: names the app holding system-wide secure input, so a withheld
/// dictation can say who to blame instead of a generic "secure input is on".
enum SecureInputOwner {
    static let secureInputPIDKey = "kCGSSessionSecureInputPID"

    /// Pure: the first positive secure-input pid in the IOConsoleUsers list.
    static func pid(fromConsoleUsers users: [[String: Any]]) -> pid_t? {
        for user in users {
            if let number = user[secureInputPIDKey] as? NSNumber, number.int32Value > 0 {
                return number.int32Value
            }
        }
        return nil
    }

    /// Reads the console session list from the IORegistry (the same data
    /// `ioreg -l -d 1` prints) and resolves the pid to an app name.
    static func currentOwnerName() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        guard let property = IORegistryEntryCreateCFProperty(
            root,
            "IOConsoleUsers" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue(),
              let users = property as? [[String: Any]],
              let pid = pid(fromConsoleUsers: users) else {
            return nil
        }

        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
