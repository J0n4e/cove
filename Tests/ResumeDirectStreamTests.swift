import XCTest
@testable import Cove

final class ResumeDirectStreamTests: XCTestCase {
    func testResumeKeepsVideoCopy() {
        XCTAssertFalse(ResumeStrategy.reencode(resuming: true, forceTranscode: false))
        XCTAssertFalse(ResumeStrategy.reencode(resuming: false, forceTranscode: false))
    }

    func testRetryStillReencodes() {
        XCTAssertTrue(ResumeStrategy.reencode(resuming: true, forceTranscode: true))
        XCTAssertTrue(ResumeStrategy.reencode(resuming: false, forceTranscode: true))
    }

    func testOffset() {
        XCTAssertEqual(ResumeStrategy.offset(requested: 600, playerAt: 600), 0)
        XCTAssertEqual(ResumeStrategy.offset(requested: 600, playerAt: 597.5), -2.5, accuracy: 0.001)
    }

    func testResumeURLHasNoCopyOverrideOrStartTicks() throws {
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/ResumeDirectStreamTests.swift",
                                                                          with: "Sources/PlayerModel.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("reencode: midFile"))
        XCTAssertTrue(src.contains("reencode: resumeReencode"))
        XCTAssertFalse(src.contains("StartTimeTicks="))
    }

    @MainActor func testWithoutVideoCopyOnlyWhenAsked() {
        let u = "https://s/Videos/1/master.m3u8?AllowVideoStreamCopy=true"
        XCTAssertTrue(Emby.withoutVideoCopy(u).contains("AllowVideoStreamCopy=false"))
    }
}
