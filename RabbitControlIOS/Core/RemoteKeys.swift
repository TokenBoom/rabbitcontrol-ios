/// Physical Windows Set-1 keys, as required by rc-input.
enum RemoteKeys {
    struct Stroke: Equatable {
        var key: UInt16
        var shift: Bool
    }

    static func strokes(for text: String) -> [Stroke]? {
        let rows: [(String, String, UInt16)] = [
            ("1234567890-=", "!@#$%^&*()_+", 0x02),
            ("qwertyuiop[]", "QWERTYUIOP{}", 0x10),
            ("asdfghjkl;'`", "ASDFGHJKL:\"~", 0x1e),
            ("zxcvbnm,./", "ZXCVBNM<>?", 0x2c),
            ("\\", "|", 0x2b)
        ]
        var result: [Stroke] = []
        for c in text {
            if let special = ([" ": 0x39, "\n": 0x1c, "\t": 0x0f] as [Character: UInt16])[c] {
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
