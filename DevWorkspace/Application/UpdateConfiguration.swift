import Foundation

struct UpdateConfiguration: Equatable, Sendable {
    let feedURL: URL
    let publicKey: String

    init?(feedURLString: String?, publicKey: String?) {
        guard let feedURLString,
              let publicKey,
              let components = URLComponents(string: feedURLString),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let feedURL = components.url,
              let decodedKey = Data(base64Encoded: publicKey),
              decodedKey.count == 32 else {
            return nil
        }

        self.feedURL = feedURL
        self.publicKey = publicKey
    }

    init?(bundle: Bundle) {
        self.init(
            feedURLString: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
    }
}
