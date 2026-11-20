import Foundation

/// Cove has one look since the Glass theme (key "apple") was retired. At the very start of launch every stored
/// theme becomes "classic" (Glass3D); someone who was on Glass sees a one-time note once the window is up.
/// Settings that only the Glass theme used go too: its player controls and the separate player window.
enum ThemeMigration {
    static let themeKey = "theme"
    static let theme = "classic"
    /// Set when a Glass user was migrated; cleared once the note has been shown.
    static let notePendingKey = "glassRetiredNotePending"
    static let noteTitle = "One look"
    static let noteText = "The Glass theme was retired — Cove now has one look."
    /// Keys of settings that only applied to the Glass theme.
    static let retiredKeys = ["playerControls", "separatePlayer"]

    /// Pure decision: the stored theme value → the value to store and whether to show the note.
    /// `existingUser`: Cove ran before. A missing value then means the old default, Glass; on a fresh install
    /// there is nothing to tell.
    static func migrate(_ value: String?, existingUser: Bool) -> (theme: String, showNote: Bool) {
        if value == theme { return (theme, false) }
        if value == nil { return (theme, existingUser) }
        return (theme, true)   // "apple" or anything unknown: they were on Glass
    }

    /// Runs once per launch before any window; does nothing once everything is migrated.
    static func run(_ d: UserDefaults = .standard) {
        let existing = d.object(forKey: "importedEmbyFlix") != nil || d.object(forKey: "LastSeenVersion") != nil
        let stored = d.string(forKey: themeKey)
        let r = migrate(stored, existingUser: existing)
        if stored != r.theme { d.set(r.theme, forKey: themeKey) }
        if r.showNote { d.set(true, forKey: notePendingKey) }
        for k in retiredKeys where d.object(forKey: k) != nil { d.removeObject(forKey: k) }
    }

    /// True once: the note is due (and is marked as shown).
    static func takeNote(_ d: UserDefaults = .standard) -> Bool {
        guard d.bool(forKey: notePendingKey) else { return false }
        d.removeObject(forKey: notePendingKey)
        return true
    }
}
