import Foundation
import IOKit.pwr_mgt
import BrimCore

/// Keep-awake through IOKit's power assertions: "prevent idle display sleep" keeps the display on, and with it the
/// Mac awake (what Amphetamine and `caffeinate -d` do). No permission; macOS releases it when Brim quits.
public final class PowerAssertionKeepAwake: KeepAwakeService {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    public init() {}

    @discardableResult
    public func setAwake(_ on: Bool) -> Bool {
        if on {
            guard !held else { return true }
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Brim: keep awake (you turned it on)" as CFString, &assertion)
            held = result == kIOReturnSuccess
            return held
        }
        if held {
            IOPMAssertionRelease(assertion)
            held = false
        }
        return true
    }
}
