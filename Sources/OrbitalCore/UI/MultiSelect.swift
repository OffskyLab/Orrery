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
        hideCursor()
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
                clearLines(options.count)
                showCursor()
                return preSelected
            case .other:
                break
            }
            clearLines(options.count)
            render(cursor: cursor, selected: selected)
        }

        clearLines(options.count)
        showCursor()
        return selected
    }

    private func render(cursor: Int, selected: IndexSet) {
        for (i, option) in options.enumerated() {
            let check = selected.contains(i) ? "\u{1B}[32m[*]\u{1B}[0m" : "[ ]"
            if i == cursor {
                print("  \u{1B}[1m> \(check) \(option)\u{1B}[0m")
            } else {
                print("    \(check) \(option)")
            }
        }
        fflush(stdout)
    }

    private func clearLines(_ count: Int) {
        for _ in 0..<count {
            print("\u{1B}[1A\u{1B}[2K", terminator: "")
        }
        fflush(stdout)
    }

    private func hideCursor() { print("\u{1B}[?25l", terminator: ""); fflush(stdout) }
    private func showCursor() { print("\u{1B}[?25h", terminator: ""); fflush(stdout) }

    private enum Key { case up, down, space, enter, ctrlC, other }

    private func readKey() -> Key {
        var c: UInt8 = 0
        _ = read(STDIN_FILENO, &c, 1)

        if c == 27 {  // ESC sequence
            var a: UInt8 = 0, b: UInt8 = 0
            _ = read(STDIN_FILENO, &a, 1)
            _ = read(STDIN_FILENO, &b, 1)
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
