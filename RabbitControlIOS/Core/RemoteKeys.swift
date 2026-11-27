/// Physical Windows Set-1 keys, as required by rc-input.
enum RemoteKeys {
    struct Stroke: Equatable {
        var key: UInt16
        var shift: Bool
    }

    /// 将 iOS 软键盘默认开启的智能引号/破折号/省略号归一化为标准美式 ASCII 字符。
    static func normalizeSmartPunctuation(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\u{2018}", "\u{2019}", "\u{201B}", "\u{FF07}":
                out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201F}", "\u{FF02}":
                out.append("\"")
            case "\u{2013}", "\u{2014}", "\u{2212}":
                out.append("-")
            case "\u{2026}":
                out.append("...")
            case "\u{00A0}":
                out.append(" ")
            default:
                out.append(ch)
            }
        }
        return out
    }

    static func strokes(for text: String) -> [Stroke]? {
        let normalized = normalizeSmartPunctuation(text)
        let rows: [(String, String, UInt16)] = [
            ("1234567890-=", "!@#$%^&*()_+", 0x02),
            ("qwertyuiop[]", "QWERTYUIOP{}", 0x10),
            ("asdfghjkl;'`", "ASDFGHJKL:\"~", 0x1e),
            ("zxcvbnm,./", "ZXCVBNM<>?", 0x2c),
            ("\\", "|", 0x2b)
        ]
        var result: [Stroke] = []
        for c in normalized {
            if let special = ([" ": 0x39, "\n": 0x1c, "\r": 0x1c, "\t": 0x0f] as [Character: UInt16])[c] {
                result.append(Stroke(key: special, shift: false))
            } else {
                guard let row = rows.first(where: { $0.0.contains(c) || $0.1.contains(c) }) else { return nil }
                let shift = row.1.contains(c)
                guard let index = Array(shift ? row.1 : row.0).firstIndex(of: c) else { return nil }
                result.append(Stroke(key: row.2 + UInt16(index), shift: shift))
            }
        }
        return result
    }
}
