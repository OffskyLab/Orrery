import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SingleSelect: Sendable {
    public let title: String
    public let options: [String]
    private let preSelected: Int

    private static let viewportSize = 15

    public init(title: String, options: [String], selected: Int = 0) {
        self.title = title
        self.options = options
        self.preSelected = selected
    }

    /// Run interactive single-select. Returns the selected index, or preSelected on cancel.
    public func run() -> Int {
        runOrNil() ?? preSelected
    }

    /// Run interactive single-select via /dev/tty (leaves stdin/stdout untouched).
    /// Returns the selected index, or `nil` on cancel or if /dev/tty is unavailable.
    public func runOrNil() -> Int? {
        // Open /dev/tty directly — picker I/O is completely separate from stdin/stdout.
        let tty = ttyOpen()
        guard tty >= 0 else { return nil }
        defer { close(tty) }

        var cursor = preSelected

        var oldTermios = termios()
        tcgetattr(tty, &oldTermios)
        var raw = oldTermios
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        tcsetattr(tty, TCSANOW, &raw)
        defer { tcsetattr(tty, TCSANOW, &oldTermios) }

        let (termWidth, _) = terminalSize(tty: tty)
        let viewSize = min(options.count, Self.viewportSize)
        let maxOptionCols = max(20, termWidth - 10)

        var top = computeViewTop(cursor: cursor, viewSize: viewSize)

        ttyWrite(tty, title + "\n")
        ttyWrite(tty, "\u{1B}[?25l")
        render(tty: tty, cursor: cursor, top: top, viewSize: viewSize, maxCols: maxOptionCols)

        loop: while true {
            switch readKey(tty) {
            case .up:
                cursor = cursor > 0 ? cursor - 1 : options.count - 1
                top = computeViewTop(cursor: cursor, viewSize: viewSize)
            case .down:
                cursor = cursor < options.count - 1 ? cursor + 1 : 0
                top = computeViewTop(cursor: cursor, viewSize: viewSize)
            case .space, .enter:
                break loop
            case .ctrlC:
                clearLines(tty, viewSize + 1)
                ttyWrite(tty, "\u{1B}[?25h")
                return nil
            case .other:
                break
            }
            clearLines(tty, viewSize)
            render(tty: tty, cursor: cursor, top: top, viewSize: viewSize, maxCols: maxOptionCols)
        }

        clearLines(tty, viewSize + 1)
        ttyWrite(tty, "\u{1B}[?25h")
        return cursor
    }

    // MARK: - Viewport

    private func computeViewTop(cursor: Int, viewSize: Int) -> Int {
        let maxTop = max(0, options.count - viewSize)
        return min(maxTop, max(0, cursor - viewSize / 2))
    }

    // MARK: - Rendering

    private func render(tty: Int32, cursor: Int, top: Int, viewSize: Int, maxCols: Int) {
        var buf = ""
        for i in top..<(top + viewSize) {
            let option = truncate(options[i], to: maxCols)
            let radio = i == cursor ? "\u{1B}[32m(*)\u{1B}[0m" : "( )"
            if i == cursor {
                buf += "  \u{1B}[1m> \(radio) \(option)\u{1B}[0m\n"
            } else {
                buf += "    \(radio) \(option)\n"
            }
        }
        ttyWrite(tty, buf)
    }

    private func clearLines(_ tty: Int32, _ count: Int) {
        var buf = ""
        for _ in 0..<count { buf += "\u{1B}[1A\u{1B}[2K" }
        ttyWrite(tty, buf)
    }

    private func ttyWrite(_ fd: Int32, _ str: String) {
        var data = Array(str.utf8)
        _ = Darwin.write(fd, &data, data.count)
    }

    // MARK: - Input

    private enum Key { case up, down, space, enter, ctrlC, other }

    private func readKey(_ fd: Int32) -> Key {
        var c: UInt8 = 0
        _ = posixRead(fd, &c, 1)

        if c == 27 {
            // Temporarily non-blocking to distinguish bare ESC from arrow sequences.
            let savedFlags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, savedFlags | O_NONBLOCK)
            var a: UInt8 = 0, b: UInt8 = 0
            let na = posixRead(fd, &a, 1)
            let nb = na > 0 ? posixRead(fd, &b, 1) : 0
            _ = fcntl(fd, F_SETFL, savedFlags)

            if na <= 0 { return .ctrlC }   // bare ESC → cancel
            if a == 91 && nb > 0 {
                switch b {
                case 65: return .up
                case 66: return .down
                default: return .other
                }
            }
            return .other
        }

        switch c {
        case 32:      return .space
        case 13, 10:  return .enter
        case 3:       return .ctrlC
        default:      return .other
        }
    }

    // MARK: - Terminal utilities

    private func terminalSize(tty: Int32) -> (width: Int, height: Int) {
        var ws = winsize()
        if ioctl(tty, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    private func colWidth(_ scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        let isWide =
            (v >= 0x1100 && v <= 0x115F) ||
            (v >= 0x2E80 && v <= 0x303E) ||
            (v >= 0x3040 && v <= 0x33FF) ||
            (v >= 0x3400 && v <= 0x4DBF) ||
            (v >= 0x4E00 && v <= 0xA4CF) ||
            (v >= 0xA960 && v <= 0xA97F) ||
            (v >= 0xAC00 && v <= 0xD7FF) ||
            (v >= 0xF900 && v <= 0xFAFF) ||
            (v >= 0xFE10 && v <= 0xFE19) ||
            (v >= 0xFE30 && v <= 0xFE4F) ||
            (v >= 0xFF01 && v <= 0xFF60) ||
            (v >= 0xFFE0 && v <= 0xFFE6)
        return isWide ? 2 : 1
    }

    private func truncate(_ s: String, to maxCols: Int) -> String {
        var cols = 0
        var result = ""
        var scalars = s.unicodeScalars.makeIterator()
        while let sc = scalars.next() {
            if sc.value == 0x0A || sc.value == 0x0D {
                if !result.isEmpty { result += "…" }
                break
            }
            if sc.value == 0x1B {
                result.unicodeScalars.append(sc)
                if let next = scalars.next() {
                    result.unicodeScalars.append(next)
                    if next.value == 0x5B {
                        while let c = scalars.next() {
                            result.unicodeScalars.append(c)
                            if c.value >= 0x40 && c.value <= 0x7E { break }
                        }
                    }
                }
                continue
            }
            let w = colWidth(sc)
            if cols + w > maxCols { result += "…"; break }
            cols += w
            result.unicodeScalars.append(sc)
        }
        return result
    }
}

@inline(__always)
private func ttyOpen() -> Int32 {
    Darwin.open("/dev/tty", O_RDWR)
}

@inline(__always)
private func posixRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, buf, count)
    #else
    Glibc.read(fd, buf, count)
    #endif
}
