import AppKit
import CoreServices
import XCTest
@testable import Adapta_PE

final class LoginLaunchTests: XCTestCase {
    @MainActor
    func testOnlyLoginLaunchHidesSettings() {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: kCoreEventClass,
            eventID: kAEOpenApplication, targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(AppModel.isLoginLaunch(nil))
        XCTAssertFalse(AppModel.isLoginLaunch(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(AppModel.isLoginLaunch(event))
    }
}
