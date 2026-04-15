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

    public init(title: String, options: [String], selected: IndexSet = IndexSet()) {
        self.title = title
        self.options = options
        self.preSelected = selected
    }

    /// Run interactive multi-select via /dev/tty (leaves stdin/stdout untouched).
    /// Returns indices of selected options, or preSelected on cancel.
    public func run() -> IndexSet {
        let tty = posixOpen("/dev/tty", O_RDWR)
        guard tty >= 0 else { return preSelected }
        defer { posixClose(tty) }

        var selected = preSelected
        var cursor = 0

        var oldTermios = termios()
        tcgetattr(tty, &oldTermios)
        var raw = oldTermios
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        tcsetattr(tty, TCSANOW, &raw)
        defer { tcsetattr(tty, TCSANOW, &oldTermios) }

        ttyWrite(tty, title + "\n")
        ttyWrite(tty, "\u{1B}[?25l")
        render(tty: tty, cursor: cursor, selected: selected)

        loop: while true {
            switch readKey(tty) {
            case .up:    cursor = cursor > 0 ? cursor - 1 : options.count - 1
            case .down:  cursor = cursor < options.count - 1 ? cursor + 1 : 0
            case .space:
                if selected.contains(cursor) { selected.remove(cursor) }
                else { selected.insert(cursor) }
            case .enter:
                break loop
            case .ctrlC:
                clearLines(tty, options.count + 1)
                ttyWrite(tty, "\u{1B}[?25h")
                return preSelected
            case .other:
                break
            }
            clearLines(tty, options.count)
            render(tty: tty, cursor: cursor, selected: selected)
        }

        clearLines(tty, options.count + 1)
        ttyWrite(tty, "\u{1B}[?25h")
        return selected
    }

    private func render(tty: Int32, cursor: Int, selected: IndexSet) {
        var buf = ""
        for (i, option) in options.enumerated() {
            let check = selected.contains(i) ? "\u{1B}[32m[*]\u{1B}[0m" : "[ ]"
            if i == cursor {
                buf += "  \u{1B}[1m> \(check) \(option)\u{1B}[0m\n"
            } else {
                buf += "    \(check) \(option)\n"
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
        _ = posixWrite(fd, &data, data.count)
    }

    private enum Key { case up, down, space, enter, ctrlC, other }

    private func readKey(_ fd: Int32) -> Key {
        var c: UInt8 = 0
        _ = posixRead(fd, &c, 1)

        if c == 27 {
            let savedFlags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, savedFlags | O_NONBLOCK)
            var a: UInt8 = 0, b: UInt8 = 0
            let na = posixRead(fd, &a, 1)
            let nb = na > 0 ? posixRead(fd, &b, 1) : 0
            _ = fcntl(fd, F_SETFL, savedFlags)

            if na <= 0 { return .ctrlC }
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
}

@inline(__always)
private func posixOpen(_ path: String, _ flags: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(path, flags)
    #else
    Glibc.open(path, flags)
    #endif
}

@inline(__always)
private func posixClose(_ fd: Int32) {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}

@inline(__always)
private func posixRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, buf, count)
    #else
    Glibc.read(fd, buf, count)
    #endif
}

@inline(__always)
private func posixWrite(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, buf, count)
    #else
    Glibc.write(fd, buf, count)
    #endif
}
