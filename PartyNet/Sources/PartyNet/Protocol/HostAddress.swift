import Darwin

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
            guard let port = Self.parsePort(value[portStart...]) else { return nil }
            let literal = String(value[value.index(after: value.startIndex)..<closingBracket])
            guard Self.isValidIPv6Literal(literal) else { return nil }
            host = literal
            self.port = port
            return
        }

        guard value.filter({ $0 == ":" }).count == 1,
              let separator = value.lastIndex(of: ":"),
              separator > value.startIndex,
              let port = Self.parsePort(value[value.index(after: separator)...]) else { return nil }
        host = String(value[..<separator])
        self.port = port
    }

    private static func parsePort(_ value: Substring) -> UInt16? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let port = UInt16(value),
              port != 0 else { return nil }
        return port
    }

    private static func isValidIPv6Literal(_ literal: String) -> Bool {
        guard !literal.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        let separators = literal.indices.filter { literal[$0] == "%" }
        guard separators.count <= 1 else { return false }

        let address: Substring
        if let separator = separators.first {
            address = literal[..<separator]
            let scope = literal[literal.index(after: separator)...]
            guard isValidScopeIdentifier(scope) else { return false }
        } else {
            address = literal[...]
        }

        var binaryAddress = in6_addr()
        return String(address).withCString {
            inet_pton(AF_INET6, $0, &binaryAddress) == 1
        }
    }

    static func isValidScopeIdentifier(
        _ scope: Substring,
        interfaceIndex: (String) -> UInt32 = { name in
            name.withCString { if_nametoindex($0) }
        }
    ) -> Bool {
        guard !scope.isEmpty else { return false }
        let isASCIIDecimal = scope.utf8.allSatisfy { (0x30...0x39).contains($0) }
        if isASCIIDecimal {
            guard let numericScope = UInt32(scope) else { return false }
            return numericScope != 0
        }
        return interfaceIndex(String(scope)) != 0
    }
}
