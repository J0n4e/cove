import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Crop math (pure)

/// The round crop: the picture fills a square viewport at zoom 1 (shorter side = viewport side), the user zooms
/// (1…4) and drags it. Output: the visible square, as 512×512 JPEG (quality 0.9). The circle is only shown; the
/// upload is the full square (servers crop round themselves).
enum ProfileCrop {
    static let outputSide = 512
    static let jpegQuality: CGFloat = 0.9
    static let zoomRange: ClosedRange<CGFloat> = 1...4

    /// Points per image pixel.
    nonisolated static func scale(image: CGSize, viewport: CGFloat, zoom: CGFloat) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return viewport / min(image.width, image.height) * zoom
    }

    /// Keeps the picture covering the whole viewport.
    nonisolated static func clamp(_ o: CGSize, image: CGSize, viewport: CGFloat, zoom: CGFloat) -> CGSize {
        let s = scale(image: image, viewport: viewport, zoom: zoom)
        let mx = max(0, (image.width * s - viewport) / 2), my = max(0, (image.height * s - viewport) / 2)
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }

    /// The visible square in image pixels (origin top left).
    nonisolated static func rect(image: CGSize, viewport: CGFloat, zoom: CGFloat, offset: CGSize) -> CGRect {
        let s = scale(image: image, viewport: viewport, zoom: zoom)
        let o = clamp(offset, image: image, viewport: viewport, zoom: zoom)
        let side = viewport / s
        let x = (image.width * s / 2 - viewport / 2 - o.width) / s
        let y = (image.height * s / 2 - viewport / 2 - o.height) / s
        return CGRect(x: x, y: y, width: side, height: side).integral.intersection(CGRect(origin: .zero, size: image))
    }

    /// 512×512 JPEG of the crop.
    static func jpeg(_ cg: CGImage, crop: CGRect) -> Data? {
        guard let part = cg.cropping(to: crop),
              let ctx = CGContext(data: nil, width: outputSide, height: outputSide, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }
}

// MARK: - Server calls

@MainActor
enum ProfilePictureService {
    /// Sends one request to a saved server; nil = done, else the sentence for the window. Tokens are never logged.
    static func send(_ shape: ProfileImageAPI.Shape, server: String, name: String, token: String, emby: Emby) async -> String? {
        guard let u = URL(string: server + shape.path) else { return "\(name) has an address Cove can't use." }
        var r = URLRequest(url: u, timeoutInterval: 30)
        r.httpMethod = shape.method
        emby.authorize(&r, token: token)
        if let ct = shape.contentType { r.setValue(ct, forHTTPHeaderField: "Content-Type") }
        r.httpBody = shape.body
        do {
            let (_, resp) = try await Net.session.data(for: r)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            coveLog.info("Profile picture \(shape.method, privacy: .public): HTTP \(status)")
            return ProfileImageAPI.message(status: status, server: name)
        } catch {
            coveLog.error("Profile picture \(shape.method, privacy: .public) failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            let m = Emby.describe(error, server: name)
            return m.isEmpty ? "Cancelled." : m
        }
    }

    struct Target { let url: String; let name: String; let token: String; let userId: String; let jellyfin: Bool; let version: String? }

    static func target(_ s: SavedServer) -> Target? {
        guard let t = s.token, let u = s.userId, !t.isEmpty, !u.isEmpty else { return nil }
        let d = UserDefaults.standard
        return Target(url: s.url, name: ServerPill.title(name: s.name, address: s.url), token: t, userId: u,
                      jellyfin: d.bool(forKey: "jellyfin-" + s.id), version: d.string(forKey: "serverVersion-" + s.id))
    }

    static func current(_ emby: Emby) -> Target {
        Target(url: emby.server, name: emby.currentServerName, token: emby.token, userId: emby.userId,
               jellyfin: emby.isJellyfin, version: UserDefaults.standard.string(forKey: "serverVersion-" + emby.server.lowercased()))
    }

    static func upload(_ jpeg: Data, to t: Target, emby: Emby) async -> String? {
        await send(ProfileImageAPI.upload(userId: t.userId, jpeg: jpeg, jellyfin: t.jellyfin, version: t.version),
                   server: t.url, name: t.name, token: t.token, emby: emby)
    }
}

// MARK: - Window

/// "Change picture…": a fixed-size glass window with a drop zone, Choose image…, the round crop and Save.
@MainActor
enum ProfilePictureWindow {
    private static var window: NSWindow?
    static let size = NSSize(width: 420, height: 560)

    static func show(emby: Emby) {
        if window == nil {
            let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Change Picture"
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible {
            let host = NSHostingView(rootView: ProfilePictureView(close: { window?.close() }).environmentObject(emby))
            host.sizingOptions = []
            CoveWindowLook.applyGlass(w, content: host, size: size)
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// "Remove picture": DELETE on the current server, then every avatar refreshes.
    static func remove(emby: Emby) {
        let t = ProfilePictureService.current(emby)
        Task { @MainActor in
            let err = await ProfilePictureService.send(ProfileImageAPI.remove(userId: t.userId, jellyfin: t.jellyfin, version: t.version),
                                                       server: t.url, name: t.name, token: t.token, emby: emby)
            if let err {
                let a = NSAlert(); a.messageText = "Couldn't remove the picture"; a.informativeText = err; a.runModal()
            } else { await ProfileModel.shared.pictureChanged(emby) }
        }
    }
}

struct ProfilePictureView: View {
    let close: () -> Void
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var image: CGImage?
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var dropHover = false
    @State private var allServers = false
    @State private var busy = false
    @State private var error = ""
    @State private var results: [String] = []
    private let viewport: CGFloat = 240

    var imageSize: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    var otherTargets: [SavedServer] {
        emby.servers.filter { $0.id != emby.server.lowercased() && ProfilePictureService.target($0) != nil }
    }

    var body: some View {
        VStack(spacing: Glass3DTokens.Space.l) {
            Text("Change Picture").cvFont(18, weight: .bold).padding(.top, Glass3DTokens.Space.page)
            cropArea
            if image != nil {
                HStack(spacing: Glass3DTokens.Space.s) {
                    Image(systemName: "minus.magnifyingglass").cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
                    Slider(value: $zoom, in: ProfileCrop.zoomRange).frame(width: 200)
                    Image(systemName: "plus.magnifyingglass").cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
                }
                .onChange(of: zoom) { offset = ProfileCrop.clamp(offset, image: imageSize, viewport: viewport, zoom: zoom) }
            }
            Button("Choose image…") { choose() }.buttonStyle(AboutButton(accentName: accentName))
            if !otherTargets.isEmpty {
                Toggle(isOn: $allServers) { Text("Use for all my servers").cvFont(12) }.toggleStyle(.checkbox)
            }
            if !error.isEmpty { Text(error).cvFont(11).foregroundColor(Glass3DTokens.Status.warning).multilineTextAlignment(.center) }
            ForEach(results, id: \.self) { Text($0).cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary) }
            Spacer(minLength: 0)
            HStack {
                if busy { Spinner().controlSize(.small) }
                Spacer()
                Button("Save") { save() }.buttonStyle(AboutButton(primary: true, accentName: accentName))
                    .disabled(image == nil || busy).opacity(image == nil || busy ? 0.5 : 1)
            }
        }
        .padding(.horizontal, Glass3DTokens.Space.xxl).padding(.bottom, Glass3DTokens.Space.xl)
        .frame(width: ProfilePictureWindow.size.width, height: ProfilePictureWindow.size.height)
        .foregroundColor(.white)
        .keepsWindowOpen(busy || image != nil)
    }

    /// Drop zone before a picture is chosen; then the picture, draggable (on the picture only), under a round mask.
    @ViewBuilder var cropArea: some View {
        ZStack {
            if let image {
                let s = ProfileCrop.scale(image: imageSize, viewport: viewport, zoom: zoom)
                Image(decorative: image, scale: 1)
                    .resizable().interpolation(.high)
                    .frame(width: imageSize.width * s, height: imageSize.height * s)
                    .offset(offset)
                    .frame(width: viewport, height: viewport).clipped()
                    .overlay {   // dim outside the circle
                        Rectangle().fill(Color.black.opacity(0.55))
                            .mask(Rectangle().overlay(Circle().blendMode(.destinationOut)).compositingGroup())
                            .allowsHitTesting(false)
                    }
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5).allowsHitTesting(false))
                    .contentShape(Rectangle())
                    .gesture(DragGesture()
                        .onChanged { v in
                            let start = dragStart ?? offset
                            if dragStart == nil { dragStart = offset }
                            offset = ProfileCrop.clamp(CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height),
                                                       image: imageSize, viewport: viewport, zoom: zoom)
                        }
                        .onEnded { _ in dragStart = nil })
                    .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous)
                    .strokeBorder(Color.white.opacity(dropHover ? 0.8 : 0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous).fill(Color.black.opacity(dropHover ? 0.35 : 0.2)))
                    .frame(width: viewport, height: viewport)
                    .overlay(VStack(spacing: Glass3DTokens.Space.s) {
                        Image(systemName: "photo.on.rectangle").cvFont(30, weight: .light)
                        Text("Drop a picture here").cvFont(12).foregroundColor(Glass3DTokens.Grey.secondary)
                    })
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in load(url) } }
            }
            return true
        }
    }

    func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .heic]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        if p.runModal() == .OK, let u = p.url { load(u) }
    }

    func load(_ url: URL) {
        error = ""; results = []
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // camera photos the right way up
                kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary)
        else { error = "Cove can't read that file. Choose a PNG, JPEG or HEIC picture."; return }
        image = cg; zoom = 1; offset = .zero
    }

    func save() {
        guard let image, let jpeg = ProfileCrop.jpeg(image, crop: ProfileCrop.rect(image: imageSize, viewport: viewport, zoom: zoom, offset: offset))
        else { error = "The picture couldn't be prepared."; return }
        busy = true; error = ""; results = []
        let others = allServers ? otherTargets.compactMap(ProfilePictureService.target) : []
        Task { @MainActor in
            let cur = ProfilePictureService.current(emby)
            let err = await ProfilePictureService.upload(jpeg, to: cur, emby: emby)
            var lines: [String] = []
            for t in others {
                let e = await ProfilePictureService.upload(jpeg, to: t, emby: emby)
                lines.append("\(t.name): " + (e ?? "updated"))
            }
            busy = false
            if err == nil { await ProfileModel.shared.pictureChanged(emby) }
            if let err { error = err; results = lines }
            else if lines.isEmpty { close() }
            else { results = ["\(cur.name): updated"] + lines }
        }
    }
}
