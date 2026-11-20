import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

/// Search box floating at the bottom of the window (top bar layout), above the toast spot.
struct SearchDock: View {
    @Binding var query: String
    @Binding var open: Bool
    let focusTick: Int
    @FocusState private var focused: Bool
    var body: some View {
        VStack {
            Spacer()
            if open {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").coveFont(size: 15, weight: .semibold).foregroundColor(.secondary)
                    // Typing counts only while the box is open: after closing, the field could hold on to the
                    // keyboard while sliding away, and typing then opened search results
                    TextField("Search movies, shows, people", text: Binding(get: { query }, set: { if open { query = $0 } }))
                        .textFieldStyle(.plain)
                        .coveFont(size: 15).frame(width: 320)
                        .focused($focused)
                        .onExitCommand { close() }   // Esc closes it
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                            .buttonStyle(.plainHand)
                    }
                }
                .padding(.horizontal, 18).frame(height: 44)
                .searchGlass()
                .padding(.bottom, 24)
                .transition(.coveGlassPopIn)
                .onAppear { DispatchQueue.main.async { focused = true } }
            }
        }
        .frame(maxWidth: .infinity)
        .coveGlassPopIn(value: open)
        .onChange(of: focusTick) { focused = true }
        // However it closes (Esc, the search button): let go of the keyboard. The text field kept it while
        // sliding away, so typing afterwards still went into the search and opened results.
        .onChange(of: open) { _, on in if !on { release() } }
    }

    func close() {
        query = ""
        open = false
        release()
    }

    func release() {
        focused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        // Again once the slide-away animation is over, in case the field took the keyboard back meanwhile
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !open, let w = NSApp.keyWindow, w.firstResponder is NSText else { return }
            w.makeFirstResponder(nil)
        }
    }
}
