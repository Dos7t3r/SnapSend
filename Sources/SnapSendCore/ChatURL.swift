import Foundation

public enum ChatURL {
    /// Ordinary chats and chats nested under a project/custom GPT. A landing page is not a chat.
    public static func isConversation(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value), parts.scheme == "https",
              parts.host?.lowercased() == "chatgpt.com", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil else { return false }
        return parts.percentEncodedPath.range(of: "^/(?:g/[A-Za-z0-9_-]+/)?c/[A-Za-z0-9_-]+/?$",
                                              options: .regularExpression) != nil
    }
}
