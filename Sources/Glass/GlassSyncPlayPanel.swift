import SwiftUI

/// SyncPlay panel of the Glass player, in the Episodes panel's style: the group, who's watching, the group's
/// state and Leave group. Opened by the person.2 button, which only shows while in a group.
struct GlassSyncPlayPanel: View {
    @ObservedObject var group: SyncPlayGroup
    var classic: Bool { false }
    let close: () -> Void
    @AppStorage("accent") private var accentName = "red"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Watch together").spFont(classic, 18, weight: .bold)
                Spacer()
            }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 2)
            if let i = group.info {
                Text(i.name).spFont(classic, 13, weight: .medium).foregroundColor(.secondary).lineLimit(1)
                    .padding(.horizontal, 18)
                HStack(spacing: 8) {
                    if i.state == "Waiting" { ProgressView().controlSize(.small) }
                    Text(SyncPlayGroup.stateText(i.state)).spFont(classic, 13)
                        .foregroundColor(i.state == "Waiting" ? Theme.accent(accentName) : .white.opacity(0.8))
                }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 6)
                SyncPlayIgnoreWaitRow(group: group, classic: classic)
                Divider().padding(.horizontal, 18).padding(.vertical, 6)
                Text(SyncPlayGroup.watchingText(i.participants.count).uppercased()).spFont(classic, 10, weight: .semibold)
                    .foregroundColor(.secondary).kerning(0.6).padding(.horizontal, 18).padding(.bottom, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(i.participants.enumerated()), id: \.offset) { _, name in
                            HStack(spacing: 12) {
                                Image(systemName: "person.fill").spFont(classic, 14).frame(width: 20)
                                Text(name).spFont(classic, 14, weight: .medium).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 18).padding(.vertical, 7)
                        }
                    }
                }
                .frame(maxHeight: 260)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Joining…").spFont(classic, 13).foregroundColor(.secondary)
                }.padding(.horizontal, 18).padding(.vertical, 10)
            }
            HStack {
                Spacer()
                Button { close(); Task { await group.leave() } } label: {
                    Label("Leave group", systemImage: "rectangle.portrait.and.arrow.right").spFont(classic, 13, weight: .semibold)
                        .foregroundColor(.white)
                        .modifier(SyncPlayPill(classic: classic))
                }.buttonStyle(HoverButton()).helpLabel("Leave the group (the video keeps playing here)")
            }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14)
        }
        .frame(width: 320)
        .background(.ultraThinMaterial.opacity(0.95))
        .background(Color(white: 0.15).opacity(0.85))
        .cornerRadius(14)
        .environment(\.colorScheme, .dark)
        .onTapGesture {}   // keep taps inside the panel
    }
}
