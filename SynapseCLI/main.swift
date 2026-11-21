import Foundation

// `synapse`: manages your own models (Models → Added from Hugging Face) through the running Synapse app, which owns
// that list. It talks to the app's local server on this Mac (the routes refuse other machines).

let usage = """
    Usage: synapse models [list] [--json]
           synapse models add <repo or link> [--file <file or quantization>] [--no-download] [--wait]
           synapse models delete <id>

      list      Your models with their download state.
      add       Inspects a Hugging Face repo as Models → + does, adds it to your list and downloads it.
                --file picks a quantization (Q4_K_M) or file instead of the default; --no-download only adds it;
                --wait stays until the download finishes.
      delete    Removes a model from your list and deletes its files.

    Synapse must be running with its server on. SYNAPSE_URL overrides the address (default: this Mac, Synapse's port).
    """

struct Entry: Decodable {
    var id: String, name: String, engine: String, base: String?, sizeMB: Int, state: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("synapse: \(message)\n".utf8))
    exit(1)
}

/// Synapse's own port from its settings, so a changed port needs no flag.
func baseURL() -> URL {
    if let s = ProcessInfo.processInfo.environment["SYNAPSE_URL"], let u = URL(string: s) { return u }
    let stored = UserDefaults(suiteName: "app.synapse.mac")?.object(forKey: "settings.v1")
    let data = (stored as? Data) ?? (stored as? String).map { Data($0.utf8) }
    let port = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["port"] as? Int ?? 9000
    return URL(string: "http://127.0.0.1:\(port)")!
}

func call(_ method: String, _ path: String, body: [String: Any]? = nil) async -> (Int, Data) {
    var req = URLRequest(url: baseURL().appending(path: "v1/synapse/models" + path))
    req.httpMethod = method
    req.timeoutInterval = 120   // adding inspects the repo on Hugging Face first
    if let body {
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    } catch {
        fail("can't reach Synapse at \(baseURL().absoluteString) (\(error.localizedDescription)). Open Synapse and turn its server on.")
    }
}

/// The API's error message, or the raw body.
func message(_ data: Data) -> String {
    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    return (obj?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data, as: UTF8.self)
}

let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()

func list() async -> [Entry] {
    let (status, data) = await call("GET", "")
    guard status == 200 else { fail(message(data)) }
    struct Page: Decodable { var data: [Entry] }
    guard let page = try? decoder.decode(Page.self, from: data) else { fail("unexpected reply: \(message(data))") }
    return page.data
}

func size(_ mb: Int) -> String { mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000) : "\(mb) MB" }

func printTable(_ rows: [Entry]) {
    guard !rows.isEmpty else { print("No models in your list. Add one with: synapse models add <repo>"); return }
    let table = [["ID", "NAME", "SIZE", "STATE"]] + rows.map {
        [$0.id, $0.name + ($0.base.map { " (LoRA on \($0))" } ?? ""), size($0.sizeMB), $0.state]
    }
    let widths = (0..<4).map { c in table.map { $0[c].count }.max() ?? 0 }
    for row in table {
        print(row.enumerated().map { c, v in c == 3 ? v : v.padding(toLength: widths[c], withPad: " ", startingAt: 0) }.joined(separator: "  "))
    }
}

func waitForDownload(_ id: String) async {
    var last = ""
    while true {
        guard let e = await list().first(where: { $0.id == id }) else { fail("\(id) left the list.") }
        if e.state != last { print(e.state); last = e.state }
        if e.state == "downloaded" { return }
        if e.state.hasPrefix("failed") || e.state == "not downloaded" { exit(1) }
        try? await Task.sleep(for: .seconds(2))
    }
}

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true }; return false }
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value.") }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}

if args.isEmpty || flag("--help") || flag("-h") || args.first == "help" { print(usage); exit(0) }
guard args.removeFirst() == "models" else { fail("unknown command. Run: synapse --help") }
let json = flag("--json"), noDownload = flag("--no-download"), wait = flag("--wait"), file = option("--file")
let command = args.isEmpty ? "list" : args.removeFirst()

switch command {
case "list", "ls":
    let rows = await list()
    if json {
        let (_, data) = await call("GET", "")
        print(String(decoding: data, as: UTF8.self))
    } else {
        printTable(rows)
    }
case "add":
    guard let repo = args.first else { fail("add needs a Hugging Face repo or link.") }
    var body: [String: Any] = ["repo": repo, "download": !noDownload]
    if let file { body["file"] = file }
    let (status, data) = await call("POST", "", body: body)
    guard status == 201 else { fail(message(data)) }
    struct Added: Decodable { var model: Entry; var notes: [String]; var choices: [String] }
    guard let added = try? decoder.decode(Added.self, from: data) else { fail("unexpected reply: \(message(data))") }
    print("Added \(added.model.id) (\(added.model.name), \(size(added.model.sizeMB)))")
    for note in added.notes { print("  \(note)") }
    if added.choices.count > 1 { print("  Other choices (--file): \(added.choices.joined(separator: ", "))") }
    if wait && !noDownload { await waitForDownload(added.model.id) } else if !noDownload { print("Downloading; see progress with: synapse models") }
case "delete", "rm", "remove":
    guard let id = args.first else { fail("delete needs a model id (see: synapse models).") }
    let (status, data) = await call("DELETE", "/" + id)
    guard status == 200 else { fail(message(data)) }
    print("Deleted \(id)")
default:
    fail("unknown models command '\(command)'. Run: synapse --help")
}
