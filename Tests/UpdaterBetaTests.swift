import XCTest
@testable import Cove

final class UpdaterBetaTests: XCTestCase {
    func testBetaTagsAreValid() {
        for ok in ["v1.19.9-beta.1", "v1.19.9-beta.12", "v1.20-beta.3", "v1.19.9"] {
            XCTAssertTrue(Updater.isValidReleaseTag(ok), ok)
        }
        for bad in ["v1.19.9-beta", "v1.19.9-beta.", "v1.19.9-Beta.1", "v1.19.9-beta.1x", "v1.19.9-rc.1",
                    "v1.19.9-beta.1-5-gabc1234", "1.19.9-beta.1"] {
            XCTAssertFalse(Updater.isValidReleaseTag(bad), bad)
        }
    }

    func testOrdering() {
        let order = ["v1.19.9", "v1.19.9-beta.10", "v1.19.9-beta.2", "v1.19.9-beta.1", "v1.19.8"]
        for i in 0..<order.count {
            for j in 0..<order.count where i != j {
                XCTAssertEqual(Updater.isNewer(order[i], than: order[j]), i < j, "\(order[i]) vs \(order[j])")
            }
        }
        XCTAssertFalse(Updater.isNewer("v1.19.9-beta.2", than: "v1.19.9-beta.2"))
        XCTAssertTrue(Updater.isNewer("v1.19.10-beta.1", than: "v1.19.9"))
        // Old forms keep working
        XCTAssertTrue(Updater.isNewer("v1.0", than: "v0.10Beta"))
        XCTAssertTrue(Updater.isNewer("v1.2", than: "v1.2Beta"))
    }

    func testNoDowngradeWhenSwitchingOff() {
        // On a beta with the channel off, releases/latest is still the previous official one: not offered
        XCTAssertFalse(Updater.isNewer("v1.19.8", than: "v1.19.9-beta.2"))
        XCTAssertTrue(Updater.isNewer("v1.19.9", than: "v1.19.9-beta.2"))
        let id = "eu.jonae.cove"
        XCTAssertNotNil(Updater.verifyBundle(info: ["CFBundleIdentifier": id, "CoveVersion": "v1.19.8"],
                                             expectedId: id, tag: "v1.19.8", current: "v1.19.9-beta.1"))
    }

    func testVerifyBundleAcceptsBeta() {
        let id = "eu.jonae.cove"
        func info(_ v: String) -> [String: Any] { ["CFBundleIdentifier": id, "CoveVersion": v] }
        XCTAssertNil(Updater.verifyBundle(info: info("v1.19.9-beta.1"), expectedId: id, tag: "v1.19.9-beta.1", current: "v1.19.8"))
        XCTAssertNil(Updater.verifyBundle(info: info("v1.19.9-beta.2"), expectedId: id, tag: "v1.19.9-beta.2", current: "v1.19.9-beta.1"))
        XCTAssertNil(Updater.verifyBundle(info: info("v1.19.9"), expectedId: id, tag: "v1.19.9", current: "v1.19.9-beta.2"))
        XCTAssertNotNil(Updater.verifyBundle(info: info("v1.19.9-beta.1"), expectedId: id, tag: "v1.19.9-beta.2", current: "v1.19.8"))
        XCTAssertNotNil(Updater.verifyBundle(info: info("v1.19.9-beta.1"), expectedId: id, tag: "v1.19.9-beta.1", current: "v1.19.9-beta.1"))
    }

    let sample = #"""
    [{"tag_name":"v1.19.10-beta.1","draft":true,"prerelease":true,"body":"","html_url":"x","assets":[]},
     {"tag_name":"v1.19.9-beta.2","draft":false,"prerelease":true,"body":"b2","html_url":"x","assets":[]},
     {"tag_name":"nightly","draft":false,"prerelease":true,"body":"","html_url":"x","assets":[]},
     {"tag_name":"v1.19.9-beta.1","draft":false,"prerelease":true,"body":"b1","html_url":"x","assets":[]},
     {"tag_name":"v1.19.8","draft":false,"prerelease":false,"body":"r","html_url":"x","assets":[]}]
    """#

    func testChannelPick() throws {
        let list = try XCTUnwrap(Updater.decodeList(Data(sample.utf8)))
        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(Updater.pick(list, beta: true)?.tag_name, "v1.19.9-beta.2")   // draft ignored
        XCTAssertEqual(Updater.pick(list, beta: false)?.tag_name, "v1.19.8")
        XCTAssertEqual(Updater.pick(Array(list.reversed()), beta: true)?.tag_name, "v1.19.9-beta.2")
        // Once the official release is out, it wins on the beta channel too
        let rel = #"[{"tag_name":"v1.19.9","draft":false,"prerelease":false,"body":"","html_url":"x","assets":[]}]"#
        let more = try XCTUnwrap(Updater.decodeList(Data(rel.utf8))) + list
        XCTAssertEqual(Updater.pick(more, beta: true)?.tag_name, "v1.19.9")
        XCTAssertNil(Updater.pick([], beta: true))
    }

    func testPrettyNames() {
        XCTAssertEqual(AppVersion.pretty("v1.19.9-beta.2"), "1.19.9 beta 2")
        XCTAssertEqual(AppVersion.pretty("v1.19.9"), "v1.19.9")
        XCTAssertEqual(AppVersion.pretty("v0.4Beta"), "v0.4 Beta")
        XCTAssertEqual(UpdateRow.onBetaText("v1.19.9-beta.2"), "You're on beta 2 of 1.19.9")
        XCTAssertNil(UpdateRow.onBetaText("v1.19.8"))
        XCTAssertNil(UpdateRow.onBetaText(nil))
    }

    func testDevBuildDetectionUnaffected() {
        XCTAssertTrue(Updater.isDevVersion("v1.16.0-5-gc5f529b"))
        XCTAssertTrue(Updater.isDevVersion("v1.19.9-beta.2-3-gabc1234"))
        XCTAssertFalse(Updater.isDevVersion("v1.19.9-beta.2"))
        XCTAssertFalse(Updater.isDevVersion("v1.19.9"))
        // A dev build on top of a beta is that beta, so the same beta isn't offered and the next one is
        XCTAssertFalse(Updater.isNewer("v1.19.9-beta.2", than: "v1.19.9-beta.2-3-gabc1234"))
        XCTAssertTrue(Updater.isNewer("v1.19.9-beta.3", than: "v1.19.9-beta.2-3-gabc1234"))
        XCTAssertTrue(Updater.isNewer("v1.16.0", than: "v1.16.0-5-gc5f529b"))
    }

    // MARK: Leaving the beta

    func testLeaveBetaDecision() {
        XCTAssertEqual(Updater.leaveBetaDecision(current: "v1.20.1-beta.3", official: "v1.20.0", betaChannel: false), .offerSwitch)
        XCTAssertEqual(Updater.leaveBetaDecision(current: "v1.20.0", official: "v1.20.0", betaChannel: false), .none)
        XCTAssertEqual(Updater.leaveBetaDecision(current: "v1.20.1", official: "v1.20.0", betaChannel: false), .none)
        XCTAssertEqual(Updater.leaveBetaDecision(current: "v1.20.1-beta.3", official: "v1.20.1", betaChannel: false), .normalUpdate)
        XCTAssertEqual(Updater.leaveBetaDecision(current: "v1.20.1-beta.3", official: "v1.20.0", betaChannel: true), .none)
        XCTAssertEqual(Updater.leaveBetaDecision(current: "v1.20.1-beta.3", official: "v1.20.0-beta.9", betaChannel: false), .none)
        XCTAssertEqual(Updater.leaveBetaDecision(current: "v1.20.1-beta.3", official: "1.20.0", betaChannel: false), .none)
        XCTAssertEqual(Updater.leaveBetaText(official: "v1.20.0", current: "v1.20.1-beta.3"),
                       "You're leaving the beta. Cove 1.20.0 replaces 1.20.1 beta 3. Your settings stay.")
        XCTAssertEqual(Updater.plain("v1.20.0"), "1.20.0")
    }

    func testVerifyBundleDowngradeOnlyWithFlag() {
        let id = "eu.jonae.cove"
        func info(_ v: String) -> [String: Any] { ["CFBundleIdentifier": id, "CoveVersion": v] }
        let beta = "v1.20.1-beta.3"
        XCTAssertNil(Updater.verifyBundle(info: info("v1.20.0"), expectedId: id, tag: "v1.20.0", current: beta, allowDowngradeTo: "v1.20.0"))
        XCTAssertNotNil(Updater.verifyBundle(info: info("v1.20.0"), expectedId: id, tag: "v1.20.0", current: beta))
        XCTAssertNotNil(Updater.verifyBundle(info: info("v1.20.0"), expectedId: id, tag: "v1.20.0", current: beta, allowDowngradeTo: "v1.19.9"))
        XCTAssertNotNil(Updater.verifyBundle(info: info("v1.19.9"), expectedId: id, tag: "v1.20.0", current: beta, allowDowngradeTo: "v1.20.0"))
        XCTAssertNotNil(Updater.verifyBundle(info: ["CFBundleIdentifier": "x.other", "CoveVersion": "v1.20.0"], expectedId: id,
                                             tag: "v1.20.0", current: beta, allowDowngradeTo: "v1.20.0"))
        // Never from an official version, never to a beta
        XCTAssertNotNil(Updater.verifyBundle(info: info("v1.20.0"), expectedId: id, tag: "v1.20.0", current: "v1.20.1", allowDowngradeTo: "v1.20.0"))
        XCTAssertNotNil(Updater.verifyBundle(info: info("v1.20.1-beta.2"), expectedId: id, tag: "v1.20.1-beta.2", current: beta,
                                             allowDowngradeTo: "v1.20.1-beta.2"))
        // A normal upgrade is unaffected by the flag
        XCTAssertNil(Updater.verifyBundle(info: info("v1.20.1"), expectedId: id, tag: "v1.20.1", current: beta, allowDowngradeTo: "v1.20.0"))
    }

    func testWhatsNewSkippedForDowngradeWithoutPendingNotes() {
        XCTAssertFalse(WhatsNew.shouldShow(lastSeen: "v1.20.1-beta.3", current: "v1.20.0"))
    }
}
