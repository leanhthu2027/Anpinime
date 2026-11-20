import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Normalize PNG-wrapped media and StreamC encrypted HLS playlists.
enum FilmMediaTransform {
    static func qualities(_ text: String) -> [PlaybackQuality] {
        var values: [String: PlaybackQuality] = [:]
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-STREAM-INF:") {
            func attribute(_ name: String) -> String? {
                guard let range = line.range(of: "(?:[:,])\(name)=([^,]+)", options: .regularExpression) else { return nil }
                return String(line[range]).components(separatedBy: "=").last
            }
            guard let raw = attribute("RESOLUTION") else { continue }
            let dimensions = raw.split(separator: "x").compactMap { Double($0) }
            guard dimensions.count == 2, dimensions.allSatisfy({ $0 > 0 && $0.isFinite }) else { continue }
            let bandwidth = Double(attribute("BANDWIDTH") ?? "") ?? 0
            let height = dimensions[1], key = "height-\(Int(height))"
            let quality = PlaybackQuality(id: key, title: "\(Int(height))p", bandwidth: bandwidth, width: dimensions[0], height: height)
            if (values[key]?.bandwidth ?? -1) < bandwidth { values[key] = quality }
        }
        return [.automatic] + values.values.sorted { $0.height > $1.height }
    }

    static func unwrap(_ data: Data) -> Data {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.starts(with: signature) else { return data }
        var offset = 8
        while offset + 12 <= data.count {
            let length = (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
            guard length <= data.count - offset - 12 else { return data }
            let end = offset + 12 + length
            let kind = data.subdata(in: offset + 4..<offset + 8)
            // Rock wraps MPEG-TS in a PNG ancillary tsDa chunk, not after IEND.
            // Require packet boundaries so an ordinary image remains untouched.
            if kind == Data("tsDa".utf8), length >= 188 * 3, length % 188 == 0 {
                let start = offset + 8
                if stride(from: start, to: start + length, by: 188).allSatisfy({ data[$0] == 0x47 }) {
                    return data.subdata(in: start..<start + length)
                }
            }
            if kind == Data("IEND".utf8) {
                return end < data.count ? data.subdata(in: end..<data.count) : data
            }
            offset = end
        }
        return data
    }

    static func playlist(_ text: String, base: URL, map: (URL) -> URL) -> String {
        let expression = try! NSRegularExpression(pattern: #"URI="([^"]+)""#)
        return text.components(separatedBy: .newlines).map { line in
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, !clean.hasPrefix("#"), let url = MovieCatalog.url(clean, base: base) {
                return map(url).absoluteString
            }
            var result = line
            for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let range = Range(match.range(at: 1), in: result),
                      let url = MovieCatalog.url(String(result[range]), base: base) else { continue }
                result.replaceSubrange(range, with: map(url).absoluteString)
            }
            return result
        }.joined(separator: "\n")
    }

    static func byteRange(_ header: String, count: Int) -> Range<Int>? {
        guard count > 0, header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 { return max(0, count - suffix)..<count }
        guard let start = Int(parts[0]), start >= 0, start < count else { return nil }
        let last: Int
        if parts[1].isEmpty { last = count - 1 }
        else if let parsed = Int(parts[1]), parsed >= start { last = min(parsed, count - 1) }
        else { return nil }
        return start..<(last + 1)
    }

    static func hexData(_ hex: String) -> Data? {
        let chars = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        guard chars.count >= 2, chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(chars[i..<(i + 2)]), radix: 16) else { return nil }
            bytes.append(byte)
            i += 2
        }
        return Data(bytes)
    }

    /// Decrypt StreamC `#ENC-AESGCM;iv=<24hex>` HLS playlist wrapper using HMAC-SHA256 derived AES-128-GCM key.
    static func unwrapEncryptedM3U8(_ rawText: String, videoHash: String?) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("#enc-aesgcm;iv=") else { return rawText }
        #if canImport(CryptoKit)
        guard let videoHash = videoHash?.trimmingCharacters(in: .whitespacesAndNewlines), !videoHash.isEmpty else { return rawText }
        let lines = trimmed.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.count >= 2,
              let ivRange = lines[0].range(of: #"iv=([0-9a-fA-F]{24})"#, options: [.regularExpression, .caseInsensitive]) else { return rawText }
        let ivHex = String(lines[0][ivRange].dropFirst(3))
        let payloadB64 = lines.dropFirst().joined().replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        guard let iv = hexData(ivHex), iv.count == 12,
              let cipherWithTag = Data(base64Encoded: payloadB64), cipherWithTag.count > 16 else { return rawText }
        let hmacKey = SymmetricKey(data: Data("stream-derive-v1".utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(videoHash.utf8), using: hmacKey)
        let aesKey = SymmetricKey(data: Data(mac).prefix(16))
        let ciphertext = cipherWithTag.prefix(cipherWithTag.count - 16)
        let tag = cipherWithTag.suffix(16)
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plain = try? AES.GCM.open(sealed, using: aesKey),
              let text = String(data: plain, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return rawText }
        return text
        #else
        return rawText
        #endif
    }
}
