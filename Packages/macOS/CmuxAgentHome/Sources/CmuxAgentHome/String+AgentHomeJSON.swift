import Foundation

extension String {
    /// The JSON value this text holds, or `nil` when it isn't JSON.
    ///
    /// Agent Home reads JSON from hook tool inputs, T3's payload columns and
    /// GitHub's responses; they all parse through here.
    var agentHomeJSONObject: Any? {
        try? JSONSerialization.jsonObject(with: Data(utf8))
    }

    /// The JSON object this text holds, or an empty dictionary when it isn't one.
    var agentHomeJSONDictionary: [String: Any] {
        agentHomeJSONObject as? [String: Any] ?? [:]
    }
}
