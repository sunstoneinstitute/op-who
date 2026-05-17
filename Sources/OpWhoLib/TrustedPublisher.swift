import Foundation

/// A signing publisher whose binaries op-who considers verified for the
/// purpose of the matcher's "binary verified" predicate. Currently the
/// only built-in is 1Password (Team ID 2BUA8C4S2C), which is what the
/// `op` CLI is signed under. Users can add their own — e.g. the Apple
/// Team ID for an enterprise-signed `op` clone, or a future tool whose
/// triggers op-who should treat as trusted.
public struct TrustedPublisher: Codable, Equatable, Identifiable {
    public var id: UUID
    /// Human-facing name shown in the publishers config table.
    public var name: String
    /// Apple Developer Team ID (subject.OU in the signing cert).
    /// 10-character alphanumeric, e.g. "2BUA8C4S2C".
    public var teamID: String

    public init(id: UUID = UUID(), name: String, teamID: String) {
        self.id = id
        self.name = name
        self.teamID = teamID
    }

    /// Built-in publisher list, seeded with the team IDs op-who's
    /// classifier previously had hardcoded. `static let` (not `var`) so
    /// UUIDs are stable for the program's lifetime — same trick as
    /// `RequestRule.defaults`.
    public static let defaults: [TrustedPublisher] = [
        TrustedPublisher(name: "1Password", teamID: "2BUA8C4S2C"),
    ]
}

/// On-disk store for the user's trusted-publisher list, mirroring the
/// pattern used by `RequestRuleStore`. Missing or unparseable files fall
/// back to `TrustedPublisher.defaults` so the app still works out of the
/// box. The `onPublishersChanged` callback lets the AppDelegate publish
/// the team IDs to `OpWhoConfig.trustedTeamIDs` whenever the list is
/// edited — kept as an explicit hook (not a side effect in `save`) so
/// tests using temp-path stores don't pollute global state.
public final class TrustedPublisherStore {
    public private(set) var publishers: [TrustedPublisher]
    public let fileURL: URL
    public var onPublishersChanged: ([TrustedPublisher]) -> Void = { _ in }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        if let loaded = Self.load(from: self.fileURL) {
            self.publishers = loaded
        } else {
            self.publishers = TrustedPublisher.defaults
        }
    }

    public func replace(_ publishers: [TrustedPublisher]) {
        self.publishers = publishers
        save()
    }

    public func resetToDefaults() {
        publishers = TrustedPublisher.defaults
        save()
    }

    public func save() {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(publishers)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("Failed to save publishers.json: \(String(describing: error), privacy: .public)")
        }
        onPublishersChanged(publishers)
    }

    public static var defaultFileURL: URL {
        appSupportDirectory().appendingPathComponent("publishers.json")
    }

    private static func load(from url: URL) -> [TrustedPublisher]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode([TrustedPublisher].self, from: data)
        } catch {
            Log.app.error("Failed to decode publishers.json: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
