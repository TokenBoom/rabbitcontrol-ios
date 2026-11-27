import Foundation
import SwiftUI

/// 轻量 VT100 / ANSI 终端屏幕缓冲器（支持主/备双屏切换、光标寻址、行/屏擦除与 SGR 16/256/RGB 色彩）。
///
/// 解决纯字符串拼接在运行 `clear`、`vim`、`htop`、进度条 `\r` 回写及彩色提示符时的乱码问题，
/// 同时零 WebView/innerHTML 依赖，严格满足基线 §7.2 无 XSS 终端渲染要求。
nonisolated struct TerminalScreenBuffer: Equatable, Sendable {
    struct CellStyle: Equatable, Hashable, Sendable {
        var fgRGB: UInt32? = nil
        var bold: Bool = false
    }

    struct Cell: Equatable, Sendable {
        var char: Character = " "
        var style: CellStyle = CellStyle()
    }

    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var oscTitle: String?

    private var primaryGrid: [[Cell]]
    private var altGrid: [[Cell]]
    private var scrollback: [[Cell]] = []
    private let maxScrollbackLines = 800

    private struct CursorPos: Equatable, Sendable {
        var row = 0
        var col = 0
    }

    private(set) var usingAltScreen = false
    private var cursorRow = 0
    private var cursorCol = 0
    private var savedPrimaryCursor = CursorPos()
    private var currentStyle = CellStyle()

    private enum ParseState: Equatable, Sendable {
        case ground
        case escape
        case csi(String)
        case osc(String)
    }
    private var parseState: ParseState = .ground

    init(cols: Int = 80, rows: Int = 24) {
        let c = max(20, min(240, cols))
        let r = max(8, min(100, rows))
        self.cols = c
        self.rows = r
        let blankRow = Array(repeating: Cell(), count: c)
        self.primaryGrid = Array(repeating: blankRow, count: r)
        self.altGrid = Array(repeating: blankRow, count: r)
    }

    mutating func resize(cols newCols: Int, rows newRows: Int) {
        let c = max(20, min(240, newCols))
        let r = max(8, min(100, newRows))
        guard c != cols || r != rows else { return }
        primaryGrid = Self.resizedGrid(primaryGrid, cols: c, rows: r)
        altGrid = Self.resizedGrid(altGrid, cols: c, rows: r)
        cols = c
        rows = r
        cursorRow = min(cursorRow, r - 1)
        cursorCol = min(cursorCol, c - 1)
    }

    private static func resizedGrid(_ old: [[Cell]], cols: Int, rows: Int) -> [[Cell]] {
        var next: [[Cell]] = []
        next.reserveCapacity(rows)
        for r in 0..<rows {
            if r < old.count {
                let row = old[r]
                if row.count >= cols {
                    next.append(Array(row.prefix(cols)))
                } else {
                    next.append(row + Array(repeating: Cell(), count: cols - row.count))
                }
            } else {
                next.append(Array(repeating: Cell(), count: cols))
            }
        }
        return next
    }

    /// 喂入新收到的 UTF-8 终端输出流。
    mutating func feed(_ text: String) {
        for scalar in text.unicodeScalars {
            processScalar(scalar)
        }
    }

    private mutating func processScalar(_ scalar: UnicodeScalar) {
        let v = scalar.value
        switch parseState {
        case .ground:
            switch v {
            case 0x1B: // ESC
                parseState = .escape
            case 0x0D: // CR
                cursorCol = 0
            case 0x0A, 0x0B, 0x0C: // LF / VT / FF
                lineFeed()
            case 0x08: // BS
                if cursorCol > 0 { cursorCol -= 1 }
            case 0x09: // TAB
                cursorCol = min(cols - 1, ((cursorCol / 8) + 1) * 8)
            case 0x07: // BEL
                break
            default:
                if v >= 0x20 {
                    putCharacter(Character(scalar))
                }
            }

        case .escape:
            switch scalar {
            case "[":
                parseState = .csi("")
            case "]":
                parseState = .osc("")
            case "c": // RIS full reset
                resetScreen()
                parseState = .ground
            case "7":
                savedPrimaryCursor = CursorPos(row: cursorRow, col: cursorCol)
                parseState = .ground
            case "8":
                cursorRow = min(rows - 1, max(0, savedPrimaryCursor.row))
                cursorCol = min(cols - 1, max(0, savedPrimaryCursor.col))
                parseState = .ground
            default:
                parseState = .ground
            }

        case .csi(var buf):
            if v >= 0x40 && v <= 0x7E {
                parseState = .ground
                handleCSI(params: buf, finalByte: Character(scalar))
            } else if buf.count < 64 {
                buf.unicodeScalars.append(scalar)
                parseState = .csi(buf)
            } else {
                parseState = .ground
            }

        case .osc(var buf):
            if v == 0x07 { // BEL terminates OSC
                parseState = .ground
                handleOSC(buf)
            } else if buf.hasSuffix("\u{1B}") && scalar == "\\" { // ST terminates OSC
                buf.removeLast()
                parseState = .ground
                handleOSC(buf)
            } else if buf.count < 256 {
                buf.unicodeScalars.append(scalar)
                parseState = .osc(buf)
            } else {
                parseState = .ground
            }
        }
    }

    private mutating func putCharacter(_ ch: Character) {
        if cursorCol >= cols {
            cursorCol = 0
            lineFeed()
        }
        setCell(row: cursorRow, col: cursorCol, Cell(char: ch, style: currentStyle))
        cursorCol += 1
    }

    private mutating func lineFeed() {
        if cursorRow + 1 < rows {
            cursorRow += 1
        } else {
            if !usingAltScreen {
                scrollback.append(primaryGrid[0])
                if scrollback.count > maxScrollbackLines {
                    scrollback.removeFirst(scrollback.count - maxScrollbackLines)
                }
                primaryGrid.removeFirst()
                primaryGrid.append(Array(repeating: Cell(), count: cols))
            } else {
                altGrid.removeFirst()
                altGrid.append(Array(repeating: Cell(), count: cols))
            }
        }
    }

    private mutating func setCell(row: Int, col: Int, _ cell: Cell) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        if usingAltScreen {
            altGrid[row][col] = cell
        } else {
            primaryGrid[row][col] = cell
        }
    }

    private mutating func resetScreen() {
        let blankRow = Array(repeating: Cell(), count: cols)
        primaryGrid = Array(repeating: blankRow, count: rows)
        altGrid = Array(repeating: blankRow, count: rows)
        usingAltScreen = false
        cursorRow = 0
        cursorCol = 0
        currentStyle = CellStyle()
    }

    private mutating func handleOSC(_ content: String) {
        // OSC 0;title 或 2;title
        guard let semi = content.firstIndex(of: ";") else { return }
        let code = content[..<semi]
        if code == "0" || code == "2" {
            let title = String(content[content.index(after: semi)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { oscTitle = title }
        }
    }

    private mutating func handleCSI(params: String, finalByte: Character) {
        let isPrivate = params.hasPrefix("?")
        let cleanParams = isPrivate ? String(params.dropFirst()) : params
        let nums = cleanParams.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let first = nums.first ?? 0

        if isPrivate {
            if finalByte == "h" && (nums.contains(1049) || nums.contains(47) || nums.contains(1047)) {
                savedPrimaryCursor = CursorPos(row: cursorRow, col: cursorCol)
                usingAltScreen = true
                altGrid = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
                cursorRow = 0
                cursorCol = 0
            } else if finalByte == "l" && (nums.contains(1049) || nums.contains(47) || nums.contains(1047)) {
                usingAltScreen = false
                cursorRow = min(rows - 1, max(0, savedPrimaryCursor.row))
                cursorCol = min(cols - 1, max(0, savedPrimaryCursor.col))
            }
            return
        }

        switch finalByte {
        case "A": // CUU up
            cursorRow = max(0, cursorRow - max(1, first))
        case "B": // CUD down
            cursorRow = min(rows - 1, cursorRow + max(1, first))
        case "C": // CUF forward
            cursorCol = min(cols - 1, cursorCol + max(1, first))
        case "D": // CUB back
            cursorCol = max(0, cursorCol - max(1, first))
        case "E": // CNL
            cursorRow = min(rows - 1, cursorRow + max(1, first))
            cursorCol = 0
        case "F": // CPL
            cursorRow = max(0, cursorRow - max(1, first))
            cursorCol = 0
        case "G": // CHA col
            cursorCol = min(cols - 1, max(0, max(1, first) - 1))
        case "H", "f": // CUP row;col
            let r = (nums.count >= 1 && nums[0] > 0) ? nums[0] - 1 : 0
            let c = (nums.count >= 2 && nums[1] > 0) ? nums[1] - 1 : 0
            cursorRow = min(rows - 1, max(0, r))
            cursorCol = min(cols - 1, max(0, c))
        case "J": // ED erase display
            eraseInDisplay(mode: first)
        case "K": // EL erase line
            eraseInLine(mode: first)
        case "m": // SGR
            applySGR(nums.isEmpty ? [0] : nums)
        default:
            break
        }
    }

    private mutating func eraseInDisplay(mode: Int) {
        let blank = Cell()
        switch mode {
        case 0: // cursor to end
            eraseInLine(mode: 0)
            for r in (cursorRow + 1)..<rows {
                for c in 0..<cols { setCell(row: r, col: c, blank) }
            }
        case 1: // start to cursor
            for r in 0..<cursorRow {
                for c in 0..<cols { setCell(row: r, col: c, blank) }
            }
            eraseInLine(mode: 1)
        case 2, 3: // entire screen
            for r in 0..<rows {
                for c in 0..<cols { setCell(row: r, col: c, blank) }
            }
            if mode == 3 && !usingAltScreen { scrollback.removeAll() }
        default:
            break
        }
    }

    private mutating func eraseInLine(mode: Int) {
        let blank = Cell()
        let limitCol = min(cursorCol, cols - 1)
        switch mode {
        case 0:
            for c in max(0, limitCol)..<cols { setCell(row: cursorRow, col: c, blank) }
        case 1:
            for c in 0...max(0, limitCol) { setCell(row: cursorRow, col: c, blank) }
        case 2:
            for c in 0..<cols { setCell(row: cursorRow, col: c, blank) }
        default:
            break
        }
    }

    private mutating func applySGR(_ codes: [Int]) {
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0:
                currentStyle = CellStyle()
            case 1:
                currentStyle.bold = true
            case 22:
                currentStyle.bold = false
            case 39:
                currentStyle.fgRGB = nil
            case 30...37:
                currentStyle.fgRGB = Self.ansi16Palette[code - 30]
            case 90...97:
                currentStyle.fgRGB = Self.ansi16Palette[code - 90 + 8]
            case 38:
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    currentStyle.fgRGB = Self.color256(codes[i + 2])
                    i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    let r = UInt32(clamping: max(0, min(255, codes[i + 2])))
                    let g = UInt32(clamping: max(0, min(255, codes[i + 3])))
                    let b = UInt32(clamping: max(0, min(255, codes[i + 4])))
                    currentStyle.fgRGB = (r << 16) | (g << 8) | b
                    i += 4
                }
            default:
                break
            }
            i += 1
        }
    }

    /// 渲染为带 ANSI 色彩的 `AttributedString`（自动裁剪尾部空白列与底部未使用的空行）。
    func renderAttributedString() -> AttributedString {
        let activeGrid = usingAltScreen ? altGrid : (scrollback + primaryGrid)
        var lastNonEmptyRow = activeGrid.count - 1
        while lastNonEmptyRow >= 0 {
            let hasContent = activeGrid[lastNonEmptyRow].contains { $0.char != " " }
            let isCursorLine = !usingAltScreen
                ? (lastNonEmptyRow == scrollback.count + cursorRow)
                : (lastNonEmptyRow == cursorRow)
            if hasContent || isCursorLine { break }
            lastNonEmptyRow -= 1
        }
        guard lastNonEmptyRow >= 0 else { return AttributedString("") }

        var result = AttributedString()
        for rowIdx in 0...lastNonEmptyRow {
            let row = activeGrid[rowIdx]
            var lastCol = row.count - 1
            while lastCol >= 0 && row[lastCol].char == " " {
                lastCol -= 1
            }
            if lastCol >= 0 {
                var runText = ""
                var runStyle = row[0].style
                for colIdx in 0...lastCol {
                    let cell = row[colIdx]
                    if cell.style == runStyle {
                        runText.append(cell.char)
                    } else {
                        result.append(Self.styledSegment(runText, style: runStyle))
                        runText = String(cell.char)
                        runStyle = cell.style
                    }
                }
                if !runText.isEmpty {
                    result.append(Self.styledSegment(runText, style: runStyle))
                }
            }
            if rowIdx < lastNonEmptyRow {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    private static func styledSegment(_ text: String, style: CellStyle) -> AttributedString {
        var seg = AttributedString(text)
        if let rgb = style.fgRGB {
            seg.foregroundColor = Color(hex: rgb)
        } else {
            seg.foregroundColor = Color(hex: 0xF2F3F5)
        }
        return seg
    }

    private static let ansi16Palette: [UInt32] = [
        0x4E5969, // black (readable on dark bg)
        0xF53F3F, // red
        0x23C343, // green
        0xFF9A2E, // yellow
        0x57A9FB, // blue
        0xD97BFF, // magenta
        0x37D4CF, // cyan
        0xE5E6EB, // white
        0x86909C, // bright black
        0xFF7875, // bright red
        0x55E070, // bright green
        0xFADC19, // bright yellow
        0x8AB4FF, // bright blue
        0xF799FF, // bright magenta
        0x6FE7E2, // bright cyan
        0xFFFFFF, // bright white
    ]

    private static func color256(_ idx: Int) -> UInt32 {
        let n = max(0, min(255, idx))
        if n < 16 { return ansi16Palette[n] }
        if n < 232 {
            let v = n - 16
            let r = (v / 36) % 6
            let g = (v / 6) % 6
            let b = v % 6
            let comp: (Int) -> UInt32 = { $0 == 0 ? 0 : UInt32(55 + $0 * 40) }
            return (comp(r) << 16) | (comp(g) << 8) | comp(b)
        }
        let gray = UInt32(8 + (n - 232) * 10)
        return (gray << 16) | (gray << 8) | gray
    }
}
