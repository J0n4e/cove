import Foundation

// Google Cast (CASTV2) wire format, hand-written so Cove needs no dependency.
// One message = a 4-byte big-endian length, then a protobuf `CastMessage`:
//   1 protocol_version (varint, 0 = CASTV2_1_0)   2 source_id (string)   3 destination_id (string)
//   4 namespace (string)   5 payload_type (varint, 0 = STRING, 1 = BINARY)   6 payload_utf8 (string)
//   7 payload_binary (bytes, unused by Cove; skipped when read)

struct CastMessage: Equatable {
    var source = "sender-0"
    var destination = "receiver-0"
    var namespace: String
    var payload: String

    // MARK: Namespaces
    static let nsConnection = "urn:x-cast:com.google.cast.tp.connection"
    static let nsHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let nsReceiver = "urn:x-cast:com.google.cast.receiver"
    static let nsMedia = "urn:x-cast:com.google.cast.media"

    /// The protobuf bytes (without the length prefix).
    func encoded() -> Data {
        var d = Data()
        CastProto.varintField(1, 0, into: &d)
        CastProto.stringField(2, source, into: &d)
        CastProto.stringField(3, destination, into: &d)
        CastProto.stringField(4, namespace, into: &d)
        CastProto.varintField(5, 0, into: &d)
        CastProto.stringField(6, payload, into: &d)
        return d
    }

    /// Length-prefixed, ready to write to the socket.
    func framed() -> Data {
        let body = encoded()
        var d = Data()
        let n = UInt32(body.count)
        d.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        d.append(body)
        return d
    }

    /// Reads one protobuf `CastMessage`. Nil for malformed data.
    static func decode(_ data: Data) -> CastMessage? {
        let b = [UInt8](data)
        var i = 0
        var m = CastMessage(namespace: "", payload: "")
        var src: String?, dst: String?, ns: String?, pl: String?
        while i < b.count {
            guard let key = CastProto.readVarint(b, &i) else { return nil }
            let field = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0:
                guard CastProto.readVarint(b, &i) != nil else { return nil }
            case 2:
                guard let len = CastProto.readVarint(b, &i), len <= UInt64(b.count - i) else { return nil }
                let bytes = Array(b[i..<(i + Int(len))])
                i += Int(len)
                let s = String(decoding: bytes, as: UTF8.self)
                switch field {
                case 2: src = s
                case 3: dst = s
                case 4: ns = s
                case 6: pl = s
                default: break   // 7 payload_binary: not used
                }
            case 5: i += 4
            case 1: i += 8
            default: return nil
            }
            if i > b.count { return nil }
        }
        guard let ns else { return nil }
        m.source = src ?? ""; m.destination = dst ?? ""; m.namespace = ns; m.payload = pl ?? ""
        return m
    }

    /// The payload as a JSON object.
    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
    }
    var type: String? { json?["type"] as? String }

    static func make(_ ns: String, _ body: [String: Any], to dst: String = "receiver-0", from src: String = "sender-0") -> CastMessage {
        let d = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        return CastMessage(source: src, destination: dst, namespace: ns, payload: String(decoding: d, as: UTF8.self))
    }
}

enum CastProto {
    static func varint(_ v: UInt64, into d: inout Data) {
        var v = v
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            d.append(byte)
        } while v != 0
    }
    static func varintField(_ f: Int, _ v: UInt64, into d: inout Data) {
        varint(UInt64(f << 3 | 0), into: &d); varint(v, into: &d)
    }
    static func stringField(_ f: Int, _ s: String, into d: inout Data) {
        let u = Data(s.utf8)
        varint(UInt64(f << 3 | 2), into: &d); varint(UInt64(u.count), into: &d); d.append(u)
    }
    static func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var r: UInt64 = 0, shift: UInt64 = 0
        while i < b.count && shift < 64 {
            let byte = b[i]; i += 1
            r |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return r }
            shift += 7
        }
        return nil
    }
}

/// Collects socket reads (which can split or join messages anywhere) and hands out whole messages.
struct CastFramer {
    private(set) var buffer = Data()
    /// Refuse absurd lengths (a corrupt stream): the receiver never sends more than 64 KB.
    static let maxMessage = 1 << 20
    var broken = false

    mutating func append(_ d: Data) -> [CastMessage] {
        buffer.append(d)
        var out: [CastMessage] = []
        while buffer.count >= 4 {
            let b = [UInt8](buffer.prefix(4))
            let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            if n > Self.maxMessage { broken = true; buffer.removeAll(); break }
            guard buffer.count >= 4 + n else { break }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + n)
            buffer = Data(buffer.dropFirst(4 + n))
            if let m = CastMessage.decode(body) { out.append(m) }
        }
        return out
    }
}
