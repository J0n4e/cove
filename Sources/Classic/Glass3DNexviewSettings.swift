import SwiftUI

/// Settings → Connect → Nexview: address + API token (sealed on this Mac). Used by Activity → Cleanup only
/// ("Requested by" column, filters, sort). Model: Shared/NexviewRequests.swift, connection: Admin/NexviewService.swift.
struct NexviewSettingsSection: View {
    @ObservedObject private var conn = NexviewConnection.shared
    @State private var addressDraft = NexviewConnection.shared.address
    @State private var keyDraft = ""
    @State private var testing = false

    var body: some View {
        PrefSection(title: "Nexview") {
            PrefRow(label: "Address") {
                TextField("https://nexview.example.com", text: $addressDraft).textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit { conn.saveAddress(addressDraft) }
            }
            PrefRow(label: "API token") {
                HStack(spacing: 8) {
                    SecureField(conn.hasKey ? "Saved \u{2014} paste a new one to replace it" : "nxv_\u{2026}", text: $keyDraft)
                        .textFieldStyle(.roundedBorder).frame(width: 260)
                    Button("Save") {
                        conn.saveAddress(addressDraft); conn.setKey(keyDraft); keyDraft = ""
                        testing = true; Task { await conn.test(); testing = false }
                    }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || NexcrateAPI.normalizedAddress(addressDraft) == nil)
                }
            }
            PrefRow(label: "Status") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(conn.status ?? (conn.configured ? "Connected" : "Not connected"))
                        .foregroundColor(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380, alignment: .leading)
                    if conn.configured {
                        HStack(spacing: 8) {
                            Button(testing ? "Testing\u{2026}" : "Test") {
                                conn.saveAddress(addressDraft)
                                testing = true; Task { await conn.test(); testing = false }
                            }.disabled(testing)
                            Button("Disconnect") { conn.disconnect() }
                        }
                    }
                }
            }
            PrefNote("Admins: Activity \u{2192} Cleanup shows who requested each title in Nexview, and can filter for requests the requester never watched. Make a token in Nexview under Profile \u{2192} Account \u{2192} Security \u{2192} API tokens (\u{201C}may only read\u{201D} is enough); the account must be a Nexview admin or approver. The token is kept sealed on this Mac.")
        }
    }
}
