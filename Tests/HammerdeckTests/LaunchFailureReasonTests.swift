import XCTest
@testable import HammerdeckKit

// The reason app_launcher shows when macOS refuses a launch. NSWorkspace wraps
// LaunchServices' real cause in a generic NSCocoaErrorDomain 256 ("a miscellaneous
// error occurred"), so the reason has to come from the error under that wrapper.
// The chain below is the shape macOS 27 returns for an Xcode flagged version-too-low.
final class LaunchFailureReasonTests: XCTestCase {

    private func refusedXcode() -> NSError {
        let inner = NSError(domain: NSOSStatusErrorDomain, code: -10664, userInfo: [
            NSLocalizedDescriptionKey:
                "kLSIncompatibleApplicationVersionErr: The app is incompatible with the current OS",
        ])
        return NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [
            NSLocalizedDescriptionKey: "The application “Xcode.app” could not be launched "
                + "because a miscellaneous error occurred.",
            NSUnderlyingErrorKey: inner,
        ])
    }

    func testReasonComesFromUnderTheGenericWrapperWithoutTheConstantName() {
        XCTAssertEqual(Native.launchFailureReason(refusedXcode()),
                       "The app is incompatible with the current OS")
    }

    func testChainIsOutermostFirst() {
        XCTAssertEqual(Native.errorChain(refusedXcode()).map(\.code), [256, -10664])
    }

    // Only the generic 256 wrapper is skipped: an outer error with a specific
    // code already says what happened, better than the POSIX errno under it.
    func testASpecificOuterErrorIsNotDescendedPast() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: nil)
        let outer = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [
            NSLocalizedDescriptionKey: "The file “Foo.app” couldn’t be opened because there is no such file.",
            NSUnderlyingErrorKey: posix,
        ])
        XCTAssertEqual(Native.launchFailureReason(outer),
                       "The file “Foo.app” couldn’t be opened because there is no such file.")
    }

    func testAnErrorWithNoUnderlyingCauseKeepsItsOwnWords() {
        let plain = NSError(domain: NSCocoaErrorDomain, code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "The file doesn’t exist."])
        XCTAssertEqual(Native.launchFailureReason(plain), "The file doesn’t exist.")
    }
}
