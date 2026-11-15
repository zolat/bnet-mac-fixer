import Foundation
import IOKit

/// A snapshot of the system power state, read from IOPMrootDomain.
public struct WakeState: Equatable {
    /// IOPMSystemCapability bits (CPU=0x1, Graphics=0x2, Audio=0x4, Network=0x8).
    public var capabilities: UInt32
    public var clamshellClosed: Bool
    /// True when closing the lid puts the Mac to sleep (no external display / clamshell mode).
    public var clamshellCausesSleep: Bool

    public static let graphicsBit: UInt32 = 0x02

    public init(capabilities: UInt32, clamshellClosed: Bool, clamshellCausesSleep: Bool) {
        self.capabilities = capabilities
        self.clamshellClosed = clamshellClosed
        self.clamshellCausesSleep = clamshellCausesSleep
    }

    /// A full, user-facing wake: graphics are up, and the Mac isn't lid-closed-and-about-to-sleep.
    /// DarkWakes (Power Nap / maintenance) have no graphics capability, so they return false.
    /// Lid-closed full wakes for notifications return false as well, since they go straight back to sleep.
    public var isUserAwake: Bool {
        guard capabilities & Self.graphicsBit != 0 else { return false }
        return !(clamshellClosed && clamshellCausesSleep)
    }

    /// Reads the live state. Returns nil if IOPMrootDomain can't be queried.
    public static func current() -> WakeState? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let caps = property("System Capabilities") as? NSNumber else { return nil }
        return WakeState(
            capabilities: caps.uint32Value,
            clamshellClosed: (property("AppleClamshellState") as? Bool) ?? false,
            clamshellCausesSleep: (property("AppleClamshellCausesSleep") as? Bool) ?? false
        )
    }

    public var description: String {
        "caps=0x\(String(capabilities, radix: 16)) lidClosed=\(clamshellClosed) lidCausesSleep=\(clamshellCausesSleep) userAwake=\(isUserAwake)"
    }
}
