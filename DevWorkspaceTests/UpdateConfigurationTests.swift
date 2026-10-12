import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class UpdateConfigurationTests: XCTestCase {
    private let publicKey = Data(repeating: 7, count: 32).base64EncodedString()

    func test_configuration_whenFeedAndKeyAreValid_shouldAcceptHTTPS() {
        let configuration = UpdateConfiguration(
            feedURLString: "https://updates.example.com/devworkspace/appcast.xml",
            publicKey: publicKey
        )

        XCTAssertEqual(
            configuration?.feedURL.absoluteString,
            "https://updates.example.com/devworkspace/appcast.xml"
        )
        XCTAssertEqual(configuration?.publicKey, publicKey)
    }

    func test_configuration_whenFeedIsUnsafeOrKeyIsMissing_shouldStayDisabled() {
        let unsafeFeeds = [
            "http://updates.example.com/appcast.xml",
            "https://user:password@updates.example.com/appcast.xml",
            "https://updates.example.com/appcast.xml?token=secret",
            "https://updates.example.com/appcast.xml#fragment",
            "file:///private/tmp/appcast.xml"
        ]

        for feed in unsafeFeeds {
            XCTAssertNil(UpdateConfiguration(feedURLString: feed, publicKey: publicKey))
        }
        XCTAssertNil(UpdateConfiguration(feedURLString: "https://updates.example.com/appcast.xml", publicKey: nil))
        XCTAssertNil(UpdateConfiguration(feedURLString: "https://updates.example.com/appcast.xml", publicKey: "bad"))
    }

    func test_updater_whenReleaseFeedIsMissing_shouldNotStartOrCheck() {
        let updater = WorkspaceUpdateController(configuration: nil)

        updater.start()
        updater.checkForUpdates()
        updater.setAutomaticallyChecksForUpdates(true)

        XCTAssertFalse(updater.isConfigured)
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
    }
}
