import CryptoKit
import Foundation
import libzstd

struct ClaudeResetGrants: Equatable, Sendable {
    let resetsLeft: Int
    let nextExpiration: Date?
}

/// Reads Claude limit resets from the response the Claude desktop app cached the last
/// time its usage settings were open. Only Claude's own clients are told about resets,
/// so the app reuses that response instead of requesting it. The cache can be days old.
enum ClaudeResetCache {
    nonisolated static func read(organizationUUID: String, now: Date) -> ClaudeResetGrants? {
        let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data")
        // The settings page has requested the usage both with and without spend details.
        let entries = ["?cedar_ember=1&skip_spend=1", "?cedar_ember=1"].compactMap { query -> (Date, Data)? in
            let url = "https://claude.ai/api/organizations/\(organizationUUID)/usage\(query)"
            let file = cacheDirectory.appendingPathComponent(entryFileName(forKey: "1/0/\(url)"))
            guard let data = try? Data(contentsOf: file),
                  let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate else { return nil }
            return (modified, data)
        }
        guard let newest = entries.max(by: { $0.0 < $1.0 }),
              let body = responseBody(fromCacheEntry: newest.1) else { return nil }
        return grants(fromUsage: body, now: now)
    }

    /// Chromium's simple cache names each entry after the first 8 bytes of the key's
    /// SHA-1, read as a little-endian integer.
    nonisolated static func entryFileName(forKey key: String) -> String {
        let digest = Array(Insecure.SHA1.hash(data: Data(key.utf8)))
        let hash = digest[..<8].reversed().map { String(format: "%02x", $0) }.joined()
        return "\(hash)_0"
    }

    /// An entry holds a 24-byte header, the key, the body, then the response headers,
    /// with each stream followed by a 20-byte record ending in the stream's size.
    nonisolated static func responseBody(fromCacheEntry entry: Data) -> Data? {
        let bytes = [UInt8](entry)
        let endMagic: [UInt8] = [0xd8, 0x41, 0x0d, 0x97, 0x45, 0x6f, 0xfa, 0xf4]
        guard bytes.count > 24 else { return nil }
        let keyLength = Int(littleEndianUInt32(bytes, at: 12))
        let bodyStart = 24 + keyLength
        guard bodyStart <= bytes.count,
              let bodyEnd = firstIndex(of: endMagic, in: bytes, from: bodyStart),
              bodyEnd + 20 <= bytes.count else { return nil }
        let body = Data(bytes[bodyStart ..< bodyEnd])
        let headers = String(decoding: bytes[(bodyEnd + 20)...], as: UTF8.self).lowercased()
        if headers.contains("content-encoding:zstd") {
            return zstdDecompressed(body)
        }
        return headers.contains("content-encoding:") ? nil : body
    }

    nonisolated static func grants(fromUsage data: Data, now: Date) -> ClaudeResetGrants? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["cedar_ember"] as? [String: Any],
              let grants = status["grants"] as? [[String: Any]] else { return nil }
        let usable = grants.compactMap { grant -> (left: Int, endsAt: Date?)? in
            guard let left = (grant["resets_left"] as? NSNumber)?.intValue, left > 0 else { return nil }
            let endsAt = (grant["ends_at"] as? String).flatMap(ClaudeClient.date)
            if let endsAt, endsAt <= now { return nil }
            return (left, endsAt)
        }
        return ClaudeResetGrants(
            resetsLeft: usable.reduce(0) { $0 + $1.left },
            nextExpiration: usable.compactMap(\.endsAt).min()
        )
    }

    nonisolated private static func zstdDecompressed(_ data: Data) -> Data? {
        guard let stream = ZSTD_createDStream() else { return nil }
        defer { ZSTD_freeDStream(stream) }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        let finished = data.withUnsafeBytes { source -> Bool in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            while true {
                let (result, produced) = chunk.withUnsafeMutableBytes { buffer -> (Int, Int) in
                    var out = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                    let result = ZSTD_decompressStream(stream, &out, &input)
                    return (result, out.pos)
                }
                if ZSTD_isError(result) != 0 { return false }
                output.append(contentsOf: chunk[..<produced])
                if result == 0 { return true }
                if input.pos == input.size && produced < chunk.count { return false }
            }
        }
        return finished ? output : nil
    }

    nonisolated private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0 ..< 4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    nonisolated private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        return (start ... bytes.count - pattern.count).first {
            bytes[$0 ..< $0 + pattern.count].elementsEqual(pattern)
        }
    }
}
