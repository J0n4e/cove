import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

/// A teardrop lying on its side: round on the left, its point at the middle of the right edge. The point is a
/// right angle (the sides meet at 90°), as a classic drop.
struct Teardrop: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.height / 2
        let c = CGPoint(x: rect.minX + r, y: rect.midY)
        let d = min(rect.maxX - c.x, r * 2.squareRoot())   // r·√2 from the middle gives the 90° point
        let tip = CGPoint(x: c.x + d, y: rect.midY)
        guard d > r else { return Path(ellipseIn: rect) }
        // Where the straight sides touch the circle
        let a = acos(r / d)
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: c.x + r * cos(a), y: c.y - r * sin(a)))
        p.addArc(center: c, radius: r, startAngle: .radians(-a), endAngle: .radians(a), clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// The A–Z letter preview's drop, in the watched check's finish: glossy white (light on top, shade at the
/// bottom) with a thin black outline and a soft shadow.
struct TeardropGlass: View {
    var body: some View {
        ZStack {
            Teardrop().fill(Color.white)
            Teardrop().fill(LinearGradient(stops: [.init(color: .white.opacity(0.55), location: 0),
                                                   .init(color: .white.opacity(0.1), location: 0.45),
                                                   .init(color: .black.opacity(0.35), location: 1)],
                                           startPoint: .top, endPoint: .bottom))
            Teardrop().stroke(Color.black.opacity(0.85), lineWidth: 0.9)
        }
        .shadow(color: .black.opacity(0.65), radius: 1.5, y: 1.5)
    }
}
