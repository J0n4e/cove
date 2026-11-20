import XCTest
@testable import Cove

/// The Glass theme was retired: every stored theme becomes "classic" (Glass3D); Glass users get one note.
final class ThemeMigrationTests: XCTestCase {
    func testMigrateDecision() {
        XCTAssertTrue(ThemeMigration.migrate("apple", existingUser: true) == ("classic", true))
        XCTAssertTrue(ThemeMigration.migrate("apple", existingUser: false) == ("classic", true))
        XCTAssertTrue(ThemeMigration.migrate("classic", existingUser: true) == ("classic", false))
        XCTAssertTrue(ThemeMigration.migrate("something", existingUser: true) == ("classic", true))
        // Never set: the old default was Glass for someone who ran Cove before; a fresh install gets no note
        XCTAssertTrue(ThemeMigration.migrate(nil, existingUser: true) == ("classic", true))
        XCTAssertTrue(ThemeMigration.migrate(nil, existingUser: false) == ("classic", false))
    }

    private func defaults() -> UserDefaults {
        let name = "ThemeMigrationTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testRunFromGlassShowsTheNoteOnce() {
        let d = defaults()
        d.set("apple", forKey: "theme")
        d.set("1.19.1", forKey: "LastSeenVersion")
        d.set("glass", forKey: "playerControls")
        d.set(true, forKey: "separatePlayer")
        ThemeMigration.run(d)
        XCTAssertEqual(d.string(forKey: "theme"), "classic")
        XCTAssertNil(d.object(forKey: "playerControls"))
        XCTAssertNil(d.object(forKey: "separatePlayer"))
        XCTAssertTrue(ThemeMigration.takeNote(d))
        XCTAssertFalse(ThemeMigration.takeNote(d), "shown once")
        ThemeMigration.run(d)   // the next launch: nothing more to do
        XCTAssertFalse(ThemeMigration.takeNote(d))
    }

    func testRunOnGlass3DAndFreshInstallHasNoNote() {
        let g3 = defaults()
        g3.set("classic", forKey: "theme")
        ThemeMigration.run(g3)
        XCTAssertEqual(g3.string(forKey: "theme"), "classic")
        XCTAssertFalse(ThemeMigration.takeNote(g3))

        let fresh = defaults()
        ThemeMigration.run(fresh)
        XCTAssertEqual(fresh.string(forKey: "theme"), "classic")
        XCTAssertFalse(ThemeMigration.takeNote(fresh))
    }

    func testNoteText() {
        XCTAssertEqual(ThemeMigration.noteText, "The Glass theme was retired — Cove now has one look.")
    }
}

/// Esc in the main window leaves full screen only when nothing else takes it.
final class MainKeysEscTests: XCTestCase {
    func testEscLeavesFullScreen() {
        XCTAssertTrue(MainKeys.escLeavesFullScreen(fullScreen: true, typing: false, menuOpen: false, searchOpen: false))
        XCTAssertFalse(MainKeys.escLeavesFullScreen(fullScreen: false, typing: false, menuOpen: false, searchOpen: false))
        XCTAssertFalse(MainKeys.escLeavesFullScreen(fullScreen: true, typing: true, menuOpen: false, searchOpen: false))
        XCTAssertFalse(MainKeys.escLeavesFullScreen(fullScreen: true, typing: false, menuOpen: true, searchOpen: false),
                       "the open menu closes first")
        XCTAssertFalse(MainKeys.escLeavesFullScreen(fullScreen: true, typing: false, menuOpen: false, searchOpen: true),
                       "the search pill closes first")
        XCTAssertFalse(MainKeys.escLeavesFullScreen(fullScreen: true, modifiers: true, typing: false, menuOpen: false,
                                                    searchOpen: false))
        XCTAssertFalse(MainKeys.escLeavesFullScreen(fullScreen: true, typing: false, menuOpen: false, searchOpen: false,
                                                    playing: true))
        XCTAssertEqual(MainKeys.escKeyCode, 53)
    }
}
