import XCTest
@testable import Cove

final class ResumeDirectStreamTests: XCTestCase {
    func testResumeKeepsVideoCopy() {
        XCTAssertFalse(ResumeStrategy.reencode(resuming: true, forceTranscode: false))
        XCTAssertFalse(ResumeStrategy.reencode(resuming: false, forceTranscode: false))
    }

    func testDecisionTable() {
        // mid-file + external/extracted (Cove-drawn) subtitle -> re-encode
        XCTAssertTrue(ResumeStrategy.reencode(resuming: true, forceTranscode: false, coveDrawnSub: true))
        // mid-file + no subtitle, or an in-stream one (not Cove-drawn) -> copy
        XCTAssertFalse(ResumeStrategy.reencode(resuming: true, forceTranscode: false, coveDrawnSub: false))
        // from 0 -> copy regardless
        XCTAssertFalse(ResumeStrategy.reencode(resuming: false, forceTranscode: false, coveDrawnSub: true))
        XCTAssertEqual(ResumeStrategy.logLine(reencode: true, forceTranscode: false, coveDrawnSub: true),
                       "re-encode (Cove-drawn subtitle on)")
        XCTAssertEqual(ResumeStrategy.logLine(reencode: false, forceTranscode: false, coveDrawnSub: false),
                       "video copy (no Cove-drawn subtitle)")
    }

    func testBurnInIsNotCoveDrawn() {
        // burn-in: start() passes coveDrawnSub false (the server converts for the burn-in anyway, as before)
        XCTAssertFalse(ResumeStrategy.reencode(resuming: true, forceTranscode: false, coveDrawnSub: false))
    }

    func testSwitchLogic() {
        // already re-encoding (or started from 0): no restart, just load cues
        XCTAssertEqual(ResumeStrategy.coveDrawnSwitch(streamCopiedMidFile: false), .loadCues)
        // turning a Cove-drawn subtitle on in a mid-file copy stream: restart once
        XCTAssertEqual(ResumeStrategy.coveDrawnSwitch(streamCopiedMidFile: true), .restartReencode)
        // after that restart the stream is re-encoded, so a further switch doesn't restart again
        let after = ResumeStrategy.reencode(resuming: true, forceTranscode: false, coveDrawnSub: true)
        XCTAssertEqual(ResumeStrategy.coveDrawnSwitch(streamCopiedMidFile: !after), .loadCues)
    }

    func testSubsOffNeedsNoRestart() throws {
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/ResumeDirectStreamTests.swift",
                                                                          with: "Sources/PlayerModel.swift"), encoding: .utf8)
        // subtitles off restarts only when they were burned in
        XCTAssertTrue(src.contains("if wasBurned { await restart(emby) { $0.sub = nil; $0.noSub = true; $0.burnIn = false } }"))
        XCTAssertTrue(src.contains("coveDrawnSub: coveDrawn"))
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
