// Shared CLI argument helpers for every aetherctl subcommand.

import Foundation

/// Pluck a boolean flag out of the rest-args list, returning whether
/// it was present. Modifies `rest` in place. Unknown args stay in
/// `rest` so the URL positional ends up there.
func takeFlag(_ name: String, from rest: inout [String]) -> Bool {
    guard let idx = rest.firstIndex(of: name) else { return false }
    rest.remove(at: idx)
    return true
}

/// Pluck a `--key value` pair out of the rest-args list, returning
/// the value as Int. Returns nil if absent; exits 64 on a present but
/// missing/unparseable value (silently falling back to the default AND
/// leaving the flag token in `rest` used to corrupt the URL positional).
func takeIntFlag(_ name: String, from rest: inout [String]) -> Int? {
    guard let idx = rest.firstIndex(of: name) else { return nil }
    guard idx + 1 < rest.count, let value = Int(rest[idx + 1]) else {
        let got = idx + 1 < rest.count ? "'\(rest[idx + 1])'" : "nothing"
        print("ERROR: \(name) expects an integer value, got \(got)")
        exit(64)
    }
    rest.removeSubrange(idx...(idx + 1))
    return value
}

/// Pluck a `--key value` pair out of the rest-args list, returning
/// the value as String. Returns nil if absent or value-less.
func takeStringFlag(_ name: String, from rest: inout [String]) -> String? {
    guard let idx = rest.firstIndex(of: name),
          idx + 1 < rest.count else { return nil }
    let value = rest[idx + 1]
    rest.removeSubrange(idx...(idx + 1))
    return value
}

/// Pluck a `--key value` pair out of the rest-args list, returning
/// the value as Double. Returns nil if absent; exits 64 on a present
/// but missing/unparseable value (see `takeIntFlag`).
func takeDoubleFlag(_ name: String, from rest: inout [String]) -> Double? {
    guard let idx = rest.firstIndex(of: name) else { return nil }
    guard idx + 1 < rest.count, let value = Double(rest[idx + 1]), value.isFinite else {
        // isFinite: Double("nan")/"inf"/"1e300" parse successfully and
        // then trap in every downstream Int(Double) conversion.
        let got = idx + 1 < rest.count ? "'\(rest[idx + 1])'" : "nothing"
        print("ERROR: \(name) expects a finite numeric value, got \(got)")
        exit(64)
    }
    rest.removeSubrange(idx...(idx + 1))
    return value
}

/// Reject leftover `--flags` after a subcommand's known flags were
/// plucked: a typo'd flag otherwise either vanished silently or, worse,
/// became the URL positional and produced a misleading open error.
func rejectStrayFlags(_ rest: [String], subcommand: String) {
    if let stray = rest.first(where: { $0.hasPrefix("--") }) {
        print("ERROR: unknown flag '\(stray)' for subcommand '\(subcommand)'")
        print("")
        printUsage()
        exit(64)
    }
}
