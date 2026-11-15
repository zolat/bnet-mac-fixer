import Foundation
import IOKit
import IOKit.pwr_mgt

/// Wraps IORegisterForSystemPower. Callbacks are delivered on the main run loop.
final class PowerMonitor {
    // iokit_common_msg(x) = 0xE0000000 | x (the C macros aren't imported into Swift).
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    var onWillSleep: () -> Void = {}
    var onPoweredOn: () -> Void = {}

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    func start() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(messageType, argument)
        }, &notifier)
        guard rootPort != 0, let notifyPort else { return false }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
            .defaultMode
        )
        return true
    }

    private func handle(_ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case Self.systemWillSleep:
            onWillSleep()
            IOAllowPowerChange(rootPort, notificationID)
        case Self.systemHasPoweredOn:
            onPoweredOn()
        default:
            break
        }
    }
}
