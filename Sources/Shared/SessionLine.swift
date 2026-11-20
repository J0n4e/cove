import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

/// Glass3D Now Playing progress: a slim glass capsule, how far the server converted in faint white, the watched part
/// in see-through accent with a glow.
struct ClassicSessionLine: View {
    let watched: Double
    let converted: Double?
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let accent = Theme.accent(accentName)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.35))
                ClassicGlassBacking(shape: Capsule())
                if let c = converted { Capsule().fill(Color.white.opacity(0.18)).frame(width: max(6, g.size.width * c)) }
                Capsule().fill(accent.opacity(0.5))
                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center)))
                    .frame(width: max(6, g.size.width * watched))
                    .shadow(color: accent.opacity(0.8), radius: 4)
            }
        }
        .frame(height: 6)
    }
}
