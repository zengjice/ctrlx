import Foundation

/// Local operator entry point. No administration route is exposed over HTTP.
public enum RelayAdmin {
    public static func run(arguments: [String], environment: [String: String]) async throws -> String {
        guard
            let directory = environment["DATA_DIRECTORY"], !directory.isEmpty,
            arguments.count >= 2 else {
            throw AdminError("DATA_DIRECTORY and a command are required. Commands: account create|set|enable|disable, usage show, quota add, key rotate, pair revoke")
        }
        var options: [String: String] = [:]
        var remaining = ArraySlice(arguments.dropFirst(2))
        while let flag = remaining.popFirst() {
            guard flag.hasPrefix("--"), options[flag] == nil else { throw AdminError("Invalid or duplicate option") }
            if flag == "--revoke-pairs" {
                options[flag] = "true"
            } else {
                guard let value = remaining.popFirst(), !value.hasPrefix("--") else { throw AdminError("Missing value for \(flag)") }
                options[flag] = value
            }
        }
        let command = arguments.prefix(2).joined(separator: " ")
        let allowed: Set<String>
        switch command {
        case "account create": allowed = ["--name", "--monthly-quota"]
        case "account set": allowed = ["--account", "--monthly-quota"]
        case "account enable",
             "account disable",
             "usage show": allowed = ["--account"]
        case "quota add": allowed = ["--account", "--month", "--amount", "--request-id", "--reason"]
        case "key rotate": allowed = ["--account", "--revoke-pairs"]
        case "pair revoke": allowed = ["--pair"]
        default: throw AdminError("Unknown Relay admin command")
        }
        guard Set(options.keys).isSubset(of: allowed) else { throw AdminError("Unknown option for \(command)") }
        func required(_ flag: String) throws -> String {
            guard let value = options[flag], !value.isEmpty else { throw AdminError("Missing \(flag)") }
            return value
        }
        let store = try await RelayAccessService.open(directory: URL(fileURLWithPath: directory))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func json(_ value: some Encodable) throws -> String {
            try String(decoding: encoder.encode(value), as: UTF8.self)
        }
        do {
            let result: String
            switch command {
            case "account create":
                result = try await json(store.createAccount(name: required("--name"), monthlyBytes: parseBytes(required("--monthly-quota"))))
            case "account set":
                let account = try required("--account")
                try await store.setAccount(account: account, monthlyBytes: parseBytes(required("--monthly-quota")))
                result = try await json(store.accountStatus(account: account))
            case "account enable",
                 "account disable":
                let account = try required("--account")
                try await store.setAccount(account: account, enabled: command == "account enable")
                result = try await json(store.accountStatus(account: account))
            case "usage show": result = try await json(store.accountStatus(account: required("--account")))
            case "quota add":
                result = try await json(store.addQuota(
                    account: required("--account"),
                    month: required("--month"),
                    bytes: parseBytes(required("--amount")),
                    requestID: required("--request-id"),
                    reason: required("--reason")
                ))
            case "key rotate": result = try await json(store.rotateKey(account: required("--account"), revokePairs: options["--revoke-pairs"] != nil))
            case "pair revoke":
                try await store.revokePair(required("--pair"))
                result = "{\"revoked\":true}"
            default: throw AdminError("Unknown Relay admin command")
            }
            try await store.shutdown()
            return result
        } catch {
            try await store.shutdown()
            throw error
        }
    }

    static func parseBytes(_ input: String) throws -> Int64 {
        let units: [(String, Int64)] = [("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10), ("B", 1)]
        var number = input
        var multiplier: Int64 = 1
        if let unit = units.first(where: { input.hasSuffix($0.0) }) {
            number = String(input.dropLast(unit.0.count))
            multiplier = unit.1
        }
        guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }), let integer = Int64(number) else {
            throw AdminError("Quota must be integer bytes, KiB, MiB or GiB")
        }
        let (bytes, overflow) = integer.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { throw AdminError("Quota exceeds integer limit") }
        return bytes
    }

    struct AdminError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
