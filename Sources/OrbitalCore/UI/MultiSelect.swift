import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct MultiSelect: Sendable {
    public let title: String
    public let options: [String]
    private let preSelected: IndexSet

    private static let out = FileHandle.standardOutput

    public init(title: String, options: [String], selected: IndexSet = IndexSet()) {
        self.title = title
        self.options = options
        self.preSelected = selected
    }

    /// Run interactive multi-select. Returns indices of selected options.
    public func run() -> IndexSet {
        guard isatty(STDIN_FILENO) != 0 else { return preSelected }

        var selected = preSelected
        var cursor = 0

        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)
        var raw = oldTermios
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios) }

        print(title)
        write("\u{1B}[?25l") // hide cursor
        render(cursor: cursor, selected: selected)

        loop: while true {
            switch readKey() {
            case .up:    cursor = cursor > 0 ? cursor - 1 : options.count - 1
            case .down:  cursor = cursor < options.count - 1 ? cursor + 1 : 0
            case .space:
                if selected.contains(cursor) { selected.remove(cursor) }
                else { selected.insert(cursor) }
            case .enter:
                break loop
            case .ctrlC:
                clearLines(options.count + 1)
                write("\u{1B}[?25h") // show cursor
                return preSelected
            case .other:
                break
            }
            clearLines(options.count)
            render(cursor: cursor, selected: selected)
        }

        clearLines(options.count + 1)
        write("\u{1B}[?25h") // show cursor
        return selected
    }

    private func render(cursor: Int, selected: IndexSet) {
        var buf = ""
        for (i, option) in options.enumerated() {
            let check = selected.contains(i) ? "\u{1B}[32m[*]\u{1B}[0m" : "[ ]"
            if i == cursor {
                buf += "  \u{1B}[1m> \(check) \(option)\u{1B}[0m\n"
            } else {
                buf += "    \(check) \(option)\n"
            }
        }
        write(buf)
    }

    private func clearLines(_ count: Int) {
        var buf = ""
        for _ in 0..<count {
            buf += "\u{1B}[1A\u{1B}[2K"
        }
        write(buf)
    }

    /// Write directly to stdout (unbuffered, no flush needed).
    private func write(_ str: String) {
        Self.out.write(Data(str.utf8))
    }

    private enum Key { case up, down, space, enter, ctrlC, other }

    private func readKey() -> Key {
        var c: UInt8 = 0
        let fd = STDIN_FILENO
        _ = Glibc_read(fd, &c, 1)

        if c == 27 {  // ESC sequence
            var a: UInt8 = 0, b: UInt8 = 0
            _ = Glibc_read(fd, &a, 1)
            _ = Glibc_read(fd, &b, 1)
            if a == 91 {  // [
                switch b {
                case 65: return .up    // ↑
                case 66: return .down  // ↓
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
}

// POSIX read() conflicts with Swift's read on some platforms.
// Wrap it to avoid ambiguity.
@inline(__always)
private func Glibc_read(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, buf, count)
    #else
    Glibc.read(fd, buf, count)
    #endif
}
