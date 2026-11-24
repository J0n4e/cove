import SwiftUI

/// SyncPlay panel of the Glass3D (and Classic-layout) player, in the Episodes panel's style: the group, who's watching, the group's
/// state and Leave group. Opened by the person.2 button, which only shows while in a group.
struct ClassicSyncPlayPanel: View {
    @ObservedObject var group: SyncPlayGroup
    let classic: Bool
    let close: () -> Void
    @AppStorage("accent") private var accentName = "red"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Watch together").spFont(classic, 18, weight: .bold)
                Spacer()
            }.padding(.horizontal, Glass3DTokens.Space.xl).padding(.top, Glass3DTokens.Space.l).padding(.bottom, 2)
            if let i = group.info {
                Text(i.name).spFont(classic, 13, weight: .medium).foregroundColor(.secondary).lineLimit(1)
                    .padding(.horizontal, Glass3DTokens.Space.xl)
                HStack(spacing: Glass3DTokens.Space.s) {
                    if i.state == "Waiting" { ProgressView().controlSize(.small) }
                    Text(SyncPlayGroup.stateText(i.state)).spFont(classic, 13)
                        .foregroundColor(i.state == "Waiting" ? Theme.accent(accentName) : .white.opacity(0.8))
                }.padding(.horizontal, Glass3DTokens.Space.xl).padding(.top, Glass3DTokens.Space.m).padding(.bottom, Glass3DTokens.Space.s)
                SyncPlayIgnoreWaitRow(group: group, classic: classic)
                Divider().padding(.horizontal, Glass3DTokens.Space.xl).padding(.vertical, Glass3DTokens.Space.s)
                Text(SyncPlayGroup.watchingText(i.participants.count).uppercased()).spFont(classic, 10, weight: .semibold)
                    .foregroundColor(.secondary).kerning(0.6).padding(.horizontal, Glass3DTokens.Space.xl).padding(.bottom, Glass3DTokens.Space.xs)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(i.participants.enumerated()), id: \.offset) { _, name in
                            HStack(spacing: Glass3DTokens.Space.m) {
                                Image(systemName: "person.fill").spFont(classic, 14).frame(width: 20)
                                Text(name).spFont(classic, 14, weight: .medium).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, Glass3DTokens.Space.xl).padding(.vertical, Glass3DTokens.Space.s)
                        }
                    }
                }
                .classicScrollBars()   // thin overlay bars, only while scrolling
                .frame(maxHeight: 260)
            } else {
                HStack(spacing: Glass3DTokens.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Joining…").spFont(classic, 13).foregroundColor(.secondary)
                }.padding(.horizontal, Glass3DTokens.Space.xl).padding(.vertical, Glass3DTokens.Space.m)
            }
            HStack {
                Spacer()
                Button { close(); Task { await group.leave() } } label: {
                    Label("Leave group", systemImage: "rectangle.portrait.and.arrow.right").spFont(classic, 13, weight: .semibold)
                        .foregroundColor(.white)
                        .modifier(SyncPlayPill(classic: classic))
                }.buttonStyle(HoverButton()).helpLabel("Leave the group (the video keeps playing here)")
            }.padding(.horizontal, Glass3DTokens.Space.xl).padding(.top, Glass3DTokens.Space.m).padding(.bottom, Glass3DTokens.Space.l)
        }
        .frame(width: 320)
        .modifier(PanelSurface(classic: classic))
        .environment(\.colorScheme, .dark)
        .onTapGesture {}   // keep taps inside the panel
    }
}
