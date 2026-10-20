import Foundation

/// Reads the agent-chat sidecar's T3 chat URLs, as the browser ends up showing them.
///
/// cmux opens a T3 thread's chat at `<sidecar>/t3/<id>`; the sidecar redirects
/// to its session page `<sidecar>/s/t3-<…>` and keeps the query. A thread link
/// in the chat adds `via=link&thread=<id>` to the query.
public enum T3ChatLinks {
    /// Whether a URL is the sidecar's T3 chat, before or after the redirect.
    public static func isChatURL(_ url: URL?) -> Bool {
        guard let url, let host = url.host, host == "127.0.0.1" || host == "localhost" else { return false }
        let parent = url.pathComponents.dropLast().last
        if parent == "t3" { return true }
        return parent == "s" && url.lastPathComponent.hasPrefix("t3-")
    }

    /// The thread a chat URL shows when a thread link took the chat there.
    public static func linkedThreadId(in url: URL) -> String? {
        guard isChatURL(url),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.contains(where: { $0.name == "via" && $0.value == "link" }),
              let threadId = items.first(where: { $0.name == "thread" })?.value,
              !threadId.isEmpty
        else { return nil }
        return threadId
    }
}
