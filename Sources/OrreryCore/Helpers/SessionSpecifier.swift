import ArgumentParser

public enum SessionSpecifier {
    case last
    case index(Int)
    case id(String)

    public init(_ raw: String) throws {
        if raw == "last" {
            self = .last
        } else if let n = Int(raw) {
            guard n > 0 else {
                throw ValidationError("session index must be > 0")
            }
            self = .index(n)
        } else {
            self = .id(raw)
        }
    }
}
