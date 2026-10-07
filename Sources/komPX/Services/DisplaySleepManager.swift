import Combine
import IOKit.pwr_mgt

final class DisplaySleepManager: ObservableObject {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    func start() {
        guard assertionID == IOPMAssertionID(kIOPMNullAssertionID) else { return }
        let reason = "komPX is processing media" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result != kIOReturnSuccess {
            assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }

    func stop() {
        guard assertionID != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
    }

    deinit {
        stop()
    }
}
