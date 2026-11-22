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

    /// Reads a call the strict parser refused, forgiving the slips small models make: a parameter tag missing its
    /// `>`, or missing closing tags. Values that are JSON (numbers, arrays, objects) stay JSON, the rest are strings.
    static func recover(_ text: String) -> (name: String, argumentsJSON: String)? {
        guard let fn = text.firstMatch(of: /<function=([A-Za-z0-9_.\-]+)>?/) else { return nil }
        var args: [String: JSONValue] = [:]
        for m in text[fn.range.upperBound...].matches(of: /<parameter=([A-Za-z0-9_\-]+)>?\n?(.*?)\n?(?:<\/parameter>|(?=<parameter=)|<\/function>|$)/.dotMatchesNewlines()) {
            let raw = String(m.2).trimmingCharacters(in: .whitespacesAndNewlines)
            let json = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
            args[String(m.1)] = json.flatMap { if case .string = $0 { nil } else { $0 } } ?? .string(raw)
        }
        return (String(fn.1), encodeJSON(.object(args)))
    }

    static func response(_ text: String) -> String { "<tool_response>\n\(text)\n</tool_response>" }
}
