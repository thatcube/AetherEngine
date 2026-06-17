import Foundation

/// Parses an `smb://[user[:password]@]host[:port]/share/path/to/file` URL into
/// connection parts. Missing credentials default to guest.
public struct SMBURL: Sendable {
    public let server: URL
    public let share: String
    public let path: String
    public let user: String
    public let password: String

    public struct ParseError: Error { public let message: String }

    public static func parse(_ raw: String) throws -> SMBURL {
        guard let comps = URLComponents(string: raw), comps.scheme == "smb" else {
            throw ParseError(message: "not an smb:// URL: \(raw)")
        }
        guard let host = comps.host, !host.isEmpty else {
            throw ParseError(message: "missing host")
        }
        // Path is /share/segments...; need at least share + one file segment.
        let segments = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2 else {
            throw ParseError(message: "expected /share/path/to/file, got \(comps.path)")
        }
        var serverComps = URLComponents()
        serverComps.scheme = "smb"
        serverComps.host = host
        serverComps.port = comps.port
        guard let server = serverComps.url else {
            throw ParseError(message: "could not rebuild server URL")
        }
        return SMBURL(
            server: server,
            share: segments[0],
            path: segments.dropFirst().joined(separator: "/"),
            user: comps.user ?? "guest",
            password: comps.password ?? ""
        )
    }
}
