import SwiftUI

// Glass dropdown lists for the Classic theme (audio, subtitles, quality…), drawn by the app so they match the glass
// pills: the standard macOS menu always uses the system's blue highlight. Like the tooltips, the list is drawn in a
// layer over the whole window (`dropdownLayer()` on the root view), so nothing on the page covers or clips it.

final class DropdownCenter: ObservableObject {
    struct List {
        let id = UUID()
        let anchor: CGRect          // the pill's frame in the layer's coordinates
        let options: [String]
        let selected: Int
        let pick: (Int) -> Void
    }
    @Published var list: List?
    func close() { list = nil }
}

private struct DropdownCenterKey: EnvironmentKey { static let defaultValue: DropdownCenter? = nil }
extension EnvironmentValues {
    var dropdownCenter: DropdownCenter? {
        get { self[DropdownCenterKey.self] }
        set { self[DropdownCenterKey.self] = newValue }
    }
}

/// The open list: a dark glass panel under its pill; the chosen line carries a check, the line under the pointer
/// lights up in the accent color. Clicking outside (or Esc) closes it.
private struct DropdownLayer: View {
    @ObservedObject var center: DropdownCenter
    @AppStorage("accent") private var accentName = "red"
    @Environment(\.appBG) private var bg
    @State private var hover: Int?

    var body: some View {
        GeometryReader { g in
            if let l = center.list {
                ZStack(alignment: .topLeading) {
                    // Click anywhere else: close
                    Color.black.opacity(0.001).onTapGesture { center.close() }
                    // As wide as the longest choice (at least the pill), so names are not cut
                    let longest = l.options.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width }.max() ?? 0
                    let width = min(max(l.anchor.width, longest + 84), 560)
                    let rowH: CGFloat = 30
                    let h = CGFloat(l.options.count) * rowH + 12
                    let below = l.anchor.maxY + 6 + h <= g.size.height
                    list(l, width: width, rowH: rowH)
                        .frame(width: width)
                        .offset(x: min(l.anchor.minX, g.size.width - width - 8),
                                y: below ? l.anchor.maxY + 6 : max(8, l.anchor.minY - 6 - h))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: center.list?.id)
        .onExitCommand { center.close() }
    }

    func list(_ l: DropdownCenter.List, width: CGFloat, rowH: CGFloat) -> some View {
        let accent = Theme.accent(accentName)
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(l.options.indices, id: \.self) { i in
                    Button { l.pick(i); center.close() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                .opacity(i == l.selected ? 1 : 0)
                            Text(l.options[i]).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).frame(height: rowH)
                        .background {
                            if hover == i { Capsule().fill(accent.opacity(0.55)) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: min(CGFloat(l.options.count) * rowH + 12, 360))
        .scrollIndicators(.never)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(bg.opacity(0.75)))
        .modifier(ClassicClearGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }
}

private struct DropdownLayerModifier: ViewModifier {
    @StateObject private var center = DropdownCenter()
    func body(content: Content) -> some View {
        content
            .environment(\.dropdownCenter, center)
            .coordinateSpace(name: "dropdownLayer")
            .overlay { DropdownLayer(center: center) }
    }
}

extension View {
    /// Root of a window: glass dropdown lists opened inside it are drawn over everything else.
    func dropdownLayer() -> some View { modifier(DropdownLayerModifier()) }
}

/// A choice (audio, subtitles, quality…) as a glass pill showing the current value; clicking opens the glass list.
struct GlassPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var maxWidth: CGFloat = 260
    @Environment(\.dropdownCenter) private var center
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            guard let center else { return }
            if center.list != nil { center.close(); return }
            let sel = options.firstIndex { $0.0 == selection } ?? 0
            center.list = .init(anchor: frame, options: options.map(\.1), selected: sel) { i in
                selection = options[i].0
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == selection }?.1 ?? "—").lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: maxWidth - 44, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: 32)
            .classicGlassPill()
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { frame = g.frame(in: .named("dropdownLayer")) }
                .onChange(of: g.frame(in: .named("dropdownLayer"))) { _, f in frame = f }
        })
    }
}
