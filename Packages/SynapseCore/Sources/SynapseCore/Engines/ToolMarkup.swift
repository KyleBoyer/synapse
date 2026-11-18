import Foundation

/// How a tool call and its result appear in a conversation's text: the XML markup Qwen3.5's and LFM3's chat templates
/// render (`<tool_call><function=…><parameter=…>`, `<tool_response>`), so a model sees earlier calls the way it
/// writes them. Used for Anthropic tool_use/tool_result blocks and realtime function calls.
enum ToolMarkup {
    /// `arguments`: a JSON object. String values go in as they are, other values as JSON.
    static func call(name: String, arguments: [String: JSONValue]) -> String {
        let params = arguments.keys.sorted().map { key -> String in
            let v = arguments[key]!
            let text: String = if case .string(let s) = v { s } else { encodeJSON(v) }
            return "<parameter=\(key)>\n\(text)\n</parameter>\n"
        }.joined()
        return "<tool_call>\n<function=\(name)>\n\(params)</function>\n</tool_call>"
    }

    /// `argumentsJSON`: a JSON object as text (what realtime and chat clients send); not an object counts as none.
    static func call(name: String, argumentsJSON: String) -> String {
        let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(argumentsJSON.utf8))
        if case .object(let o)? = parsed { return call(name: name, arguments: o) }
        return call(name: name, arguments: [:])
    }

    static func response(_ text: String) -> String { "<tool_response>\n\(text)\n</tool_response>" }
}
