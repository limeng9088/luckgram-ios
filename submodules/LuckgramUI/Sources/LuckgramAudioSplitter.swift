import Foundation

/// Splits an audio file that is larger than the server's single-request limit (`ai.transcribe_max_mb`)
/// into segments that are each a valid file of the same format (docs/api-server.md §3.1 item 6).
/// Same algorithm as Android `org.telegram.luckgram.LuckgramAudioSplitter`:
///
/// - OGG (Opus / Vorbis, Telegram voice notes): cut at page boundaries; every segment starts with the
///   stream's header pages (the leading pages with granule position 0).
/// - WAV: cut the PCM data at frame boundaries and write a fresh RIFF header per segment.
/// - MP3 / ADTS AAC: cut at a frame sync word.
/// - Other containers (MP4/M4A, WebM, FLAC) cannot be cut without remuxing: returns nil.
public enum LuckgramAudioSplitter {
    /// - Returns: the segments in order (one element if `audio` already fits), or nil if it can't be split.
    public static func split(_ audio: Data, mimeType: String, maxBytes: Int) -> [Data]? {
        if audio.count <= maxBytes {
            return [audio]
        }
        let bytes = [UInt8](audio)
        let mime = mimeType.lowercased().components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
        switch mime {
        case "audio/ogg", "audio/opus":
            return splitOgg(bytes, maxBytes)
        case "audio/wav", "audio/x-wav", "audio/wave":
            return splitWav(bytes, maxBytes)
        case "audio/mpeg", "audio/mp3":
            return splitAtSync(bytes, maxBytes, mask: 0xE0)
        case "audio/aac":
            return splitAtSync(bytes, maxBytes, mask: 0xF0)
        default:
            return nil
        }
    }

    // MARK: - OGG

    private static func splitOgg(_ a: [UInt8], _ maxBytes: Int) -> [Data]? {
        var pages: [(offset: Int, length: Int)] = []
        var pos = 0
        while pos < a.count {
            guard pos + 27 <= a.count, a[pos] == 0x4F, a[pos + 1] == 0x67, a[pos + 2] == 0x67, a[pos + 3] == 0x53 else {
                return nil
            }
            let segments = Int(a[pos + 26])
            guard pos + 27 + segments <= a.count else {
                return nil
            }
            var length = 27 + segments
            for i in 0 ..< segments {
                length += Int(a[pos + 27 + i])
            }
            guard pos + length <= a.count else {
                return nil
            }
            pages.append((pos, length))
            pos += length
        }
        var headerPages = 0
        var headerBytes = 0
        while headerPages < pages.count && granule(a, pages[headerPages].offset) == 0 {
            headerBytes += pages[headerPages].length
            headerPages += 1
        }
        if headerPages == 0 || headerPages == pages.count {
            return nil
        }
        let header = Data(a[0 ..< headerBytes])
        var result: [Data] = []
        var current: Data?
        for page in pages[headerPages...] {
            if headerBytes + page.length > maxBytes {
                return nil
            }
            if let c = current, c.count + page.length > maxBytes {
                result.append(c)
                current = nil
            }
            if current == nil {
                current = header
            }
            current!.append(contentsOf: a[page.offset ..< page.offset + page.length])
        }
        if let current {
            result.append(current)
        }
        return result
    }

    private static func granule(_ a: [UInt8], _ offset: Int) -> UInt64 {
        var g: UInt64 = 0
        for i in (0 ..< 8).reversed() {
            g = (g << 8) | UInt64(a[offset + 6 + i])
        }
        return g
    }

    // MARK: - WAV

    private static func splitWav(_ a: [UInt8], _ maxBytes: Int) -> [Data]? {
        guard a.count >= 12, tag(a, 0, "RIFF"), tag(a, 8, "WAVE") else {
            return nil
        }
        var pos = 12
        var fmtOffset = -1
        var fmtLength = 0
        var dataOffset = -1
        var dataLength = 0
        while pos + 8 <= a.count {
            let length = Int(le32(a, pos + 4))
            if tag(a, pos, "fmt ") {
                fmtOffset = pos
                fmtLength = length
            } else if tag(a, pos, "data") {
                dataOffset = pos + 8
                dataLength = min(length, a.count - dataOffset)
                break
            }
            pos += 8 + length + (length & 1)
        }
        guard fmtOffset >= 0, dataOffset >= 0, fmtLength >= 16, fmtOffset + 8 + fmtLength <= a.count else {
            return nil
        }
        let blockAlign = Int(a[fmtOffset + 8 + 12]) | (Int(a[fmtOffset + 8 + 13]) << 8)
        guard blockAlign > 0 else {
            return nil
        }
        let headerLength = 12 + 8 + fmtLength + 8
        let perSegment = (maxBytes - headerLength) / blockAlign * blockAlign
        guard perSegment > 0 else {
            return nil
        }
        var result: [Data] = []
        var start = 0
        while start < dataLength {
            let n = min(perSegment, dataLength - start)
            var segment = Data()
            segment.append(contentsOf: Array("RIFF".utf8))
            appendLE32(&segment, UInt32(headerLength + n - 8))
            segment.append(contentsOf: Array("WAVE".utf8))
            segment.append(contentsOf: a[fmtOffset ..< fmtOffset + 8 + fmtLength])
            segment.append(contentsOf: Array("data".utf8))
            appendLE32(&segment, UInt32(n))
            segment.append(contentsOf: a[dataOffset + start ..< dataOffset + start + n])
            result.append(segment)
            start += n
        }
        return result
    }

    private static func tag(_ a: [UInt8], _ offset: Int, _ t: String) -> Bool {
        return Array(a[offset ..< offset + 4]) == Array(t.utf8)
    }

    private static func le32(_ a: [UInt8], _ offset: Int) -> UInt32 {
        return UInt32(a[offset]) | (UInt32(a[offset + 1]) << 8) | (UInt32(a[offset + 2]) << 16) | (UInt32(a[offset + 3]) << 24)
    }

    private static func appendLE32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    // MARK: - MP3 / ADTS

    /// Cuts at the last frame sync (0xFF, next byte & mask == mask) at or before each limit.
    private static func splitAtSync(_ a: [UInt8], _ maxBytes: Int, mask: UInt8) -> [Data] {
        var result: [Data] = []
        var start = 0
        while start < a.count {
            var end = min(a.count, start + maxBytes)
            if end < a.count {
                let floor = max(start + 1, end - 64 * 1024)
                var i = end - 1
                while i >= floor {
                    if a[i] == 0xFF && i + 1 < a.count && (a[i + 1] & mask) == mask {
                        end = i
                        break
                    }
                    i -= 1
                }
            }
            result.append(Data(a[start ..< end]))
            start = end
        }
        return result
    }
}
