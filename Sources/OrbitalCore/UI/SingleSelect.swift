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

    private static let out = FileHandle.standardOutput

    public init(title: String, options: [String], selected: Int = 0) {
        self.title = title
        self.options = options
        self.preSelected = selected
    }

    /// Run interactive single-select. Returns the selected index, or preSelected on cancel.
    public func run() -> Int {
        guard isatty(STDIN_FILENO) != 0 else { return preSelected }

        var cursor = preSelected

        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)
        var raw = oldTermios
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios) }

        print(title)
        write("\u{1B}[?25l")
        render(cursor: cursor)

        loop: while true {
            switch readKey() {
            case .up:    cursor = cursor > 0 ? cursor - 1 : options.count - 1
            case .down:  cursor = cursor < options.count - 1 ? cursor + 1 : 0
            case .space, .enter:
                break loop
            case .ctrlC:
                clearLines(options.count + 1)
                write("\u{1B}[?25h")
                return preSelected
            case .other:
                break
            }
            clearLines(options.count)
            render(cursor: cursor)
        }

        clearLines(options.count + 1)
        write("\u{1B}[?25h")
        return cursor
    }

    private func render(cursor: Int) {
        var buf = ""
        for (i, option) in options.enumerated() {
            let radio = i == cursor ? "\u{1B}[32m(*)\u{1B}[0m" : "( )"
            if i == cursor {
                buf += "  \u{1B}[1m> \(radio) \(option)\u{1B}[0m\n"
            } else {
                buf += "    \(radio) \(option)\n"
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

    private func write(_ str: String) {
        Self.out.write(Data(str.utf8))
    }

    private enum Key { case up, down, space, enter, ctrlC, other }

    private func readKey() -> Key {
        var c: UInt8 = 0
        let fd = STDIN_FILENO
        _ = posixRead(fd, &c, 1)

        if c == 27 {
            var a: UInt8 = 0, b: UInt8 = 0
            _ = posixRead(fd, &a, 1)
            _ = posixRead(fd, &b, 1)
            if a == 91 {
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
}

@inline(__always)
private func posixRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, buf, count)
    #else
    Glibc.read(fd, buf, count)
    #endif
}
