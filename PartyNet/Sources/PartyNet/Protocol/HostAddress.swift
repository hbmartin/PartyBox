public struct HostAddress: Equatable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init?(parsing value: String) {
        if value.hasPrefix("[") {
            guard let closingBracket = value.firstIndex(of: "]"),
                  closingBracket > value.startIndex,
                  value.index(after: closingBracket) < value.endIndex,
                  value[value.index(after: closingBracket)] == ":" else { return nil }
            let portStart = value.index(closingBracket, offsetBy: 2)
            guard let port = UInt16(value[portStart...]), port != 0 else { return nil }
            host = String(value[value.index(after: value.startIndex)..<closingBracket])
            self.port = port
            return
        }

        guard value.filter({ $0 == ":" }).count == 1,
              let separator = value.lastIndex(of: ":"),
              separator > value.startIndex,
              let port = UInt16(value[value.index(after: separator)...]),
              port != 0 else { return nil }
        host = String(value[..<separator])
        self.port = port
    }
}
