import Foundation

/// POSIX shell quoting for persisting restart commands built from a process's
/// argv. Prevents argv contents from being reinterpreted as shell syntax and
/// keeps paths with spaces runnable.
enum ShellQuoting {

    private static let safeCharacters: Set<Character> = {
        var set = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.formUnion("_%+=:,./@-")
        return set
    }()

    static func quote(_ argument: String) -> String {
        if !argument.isEmpty, argument.allSatisfy({ safeCharacters.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }
}
