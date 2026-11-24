import XCTest
@testable import Cove
import SwiftUI

/// UI polish round 3: one menu look, one toast look, the remaining screens on the shared tokens / components, and
/// the FINAL guard: no raw font, radius, padding / spacing, status colour, animation duration or shadow outside the
/// explicit allowlist (Tests/UIGuardAllowlist.swift, with a reason per file).
final class UIPolishRound3Tests: XCTestCase {
    typealias T = Glass3DTokens

    // MARK: Menus and toasts
    func testMenusShareOneLookFromExistingTokens() {
        XCTAssertEqual(T.Menu.radius, T.Radius.window)
        XCTAssertEqual(T.Menu.level, 3)
        XCTAssertEqual(T.Menu.shadow, T.elevation(3).shadow)
        XCTAssertEqual(T.Menu.shadow, T.shadowLarge)   // the value the dropdowns always had
        XCTAssertEqual(T.elevation(T.Menu.level).backgroundFill, 0.75)
    }

    func testToastSizesStayAsTheyWere() {
        XCTAssertEqual(T.Toast.height, 44)          // main window toast
        XCTAssertEqual(T.Toast.compactHeight, 40)   // SyncPlay toasts in the player
        XCTAssertEqual(T.shadowCard, T.elevation(2).shadow)
    }

    func testMenusAndToastsAreWired() throws {
        let menus = ["Sources/GlassDropdown.swift", "Sources/Classic/Glass3DProfileMenu.swift"]
        for f in menus { XCTAssertTrue(try source(f).contains(".glassMenuSurface()"), f) }
        XCTAssertTrue(try source("Sources/Classic/Glass3DProfileCircle.swift").contains("Glass3DTokens.Menu.animation"))
        XCTAssertTrue(try source("Sources/GlassDropdown.swift").contains("Glass3DTokens.Menu.animation"))
        let toasts = ["Sources/Shared/MainKeys.swift", "Sources/SyncPlay/SyncPlayViews.swift",
                      "Sources/SyncPlay/RemoteControl.swift", "Sources/Classic/Glass3DServerWindow.swift"]
        for f in toasts {
            let s = try source(f)
            XCTAssertTrue(s.contains(".toastStyle("), f)
            XCTAssertTrue(s.contains("Glass3DTokens.Toast.animation"), f)
        }
    }

    func testSettingsButtonsUseTheFamily() throws {
        XCTAssertTrue(try source("Sources/Settings.swift").contains(".buttonStyle(GlassButtonStyle(.secondary))"))
        for (name, text) in try sources() {
            for bad in [".buttonStyle(.link)", ".buttonStyle(.borderless)", ".buttonStyle(.borderedProminent)",
                        ".buttonStyle(.bordered)"] {
                XCTAssertFalse(text.contains(bad), "\(name): \(bad) → GlassButtonStyle / .plainHand")
            }
        }
    }

    // MARK: Final guard
    static let patterns: [UIGuardKind: String] = [
        .font: #"\.font\("#,
        .padding: #"\.padding\((?:(?:\[[^\]]*\]|\.[a-zA-Z]+)\s*,\s*)?(?:[3-9]|[1-9][0-9])"#,
        .spacing: #"\bspacing:\s*(?:[3-9]|[1-9][0-9])"#,
        .statusColour: #"(?:Color\.|[:(?,]\s*\.)(?:red|green|orange|yellow)\b"#,
        .animation: #"(?:easeInOut|easeOut|easeIn|linear|spring)\((?:duration|response):\s*[0-9]"#,
        .shadow: #"\.shadow\("#,
    ]

    static func count(_ kind: UIGuardKind, in text: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: patterns[kind]!) else { return -1 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func testGuardPatternsCatchRawValues() {
        XCTAssertEqual(Self.count(.padding, in: ".padding(12) .padding(.horizontal, 8) .padding([.top, .bottom], 20)"), 3)
        XCTAssertEqual(Self.count(.padding, in: ".padding(Glass3DTokens.Space.m) .padding(.top, 2) .padding(0)"), 0)
        XCTAssertEqual(Self.count(.spacing, in: "VStack(spacing: 8) HStack(spacing: 0) .lineSpacing(4) spacing: 2"), 1)
        XCTAssertEqual(Self.count(.statusColour, in: ".foregroundColor(.red) x ? .green : .orange Color.yellow"), 4)
        XCTAssertEqual(Self.count(.statusColour, in: "Glass3DTokens.Status.danger .redacted"), 0)
        XCTAssertEqual(Self.count(.animation, in: ".easeOut(duration: 0.2) .spring(response: 0.3) Glass3DTokens.Motion.fast"), 2)
        XCTAssertEqual(Self.count(.shadow, in: ".shadow(radius: 2) .g3Shadow(Glass3DTokens.shadowLarge)"), 1)
        XCTAssertEqual(Self.count(.font, in: ".font(.callout) .cvFont(12)"), 1)
    }

    /// CI fails on any raw value of a guarded kind outside the allowlist, or more of them than allowed in a file.
    func testNoRawUIValuesOutsideTheAllowlist() throws {
        for (path, text) in try sources() {
            let allowed = UIGuardAllowlist.files[path]?.max ?? [:]
            for kind in UIGuardKind.allCases {
                let n = Self.count(kind, in: text)
                XCTAssertLessThanOrEqual(n, allowed[kind] ?? 0,
                                         "\(path): \(n) raw \(kind.rawValue) value(s) — use Glass3DTokens (Space / Motion / Status / g3Shadow, elevation) or cvFont; only add to Tests/UIGuardAllowlist.swift with a reason")
            }
            let radius = try NSRegularExpression(pattern: #"cornerRadius(: *|\()[0-9]"#)
            XCTAssertEqual(radius.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)), 0,
                           "\(path): use Glass3DTokens.Radius")
        }
    }

    func testAllowlistIsHonest() throws {
        let all = Dictionary(uniqueKeysWithValues: try sources())
        for (path, entry) in UIGuardAllowlist.files {
            XCTAssertNotNil(all[path], "\(path): listed in UIGuardAllowlist but missing — remove the entry")
            XCTAssertFalse(entry.reason.trimmingCharacters(in: .whitespaces).isEmpty, "\(path): give a reason")
            XCTAssertFalse(entry.max.isEmpty, path)
            for (_, n) in entry.max { XCTAssertGreaterThan(n, 0, path) }
        }
    }

    // MARK: Helpers
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every Swift file under Sources/, keyed by its path below Sources/.
    private func sources() throws -> [(String, String)] {
        let base = root.appendingPathComponent("Sources").resolvingSymlinksInPath().standardizedFileURL
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let u = e?.nextObject() as? URL {
            guard u.pathExtension == "swift" else { continue }
            let full = u.resolvingSymlinksInPath().standardizedFileURL.path
            let rel = full.hasPrefix(base.path + "/") ? String(full.dropFirst(base.path.count + 1)) : u.lastPathComponent
            out.append((rel, try String(contentsOf: u, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 50)
        return out
    }
}
