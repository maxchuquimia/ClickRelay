import Foundation

/// The bridge's part of scripts: it reads a script file from the agent's
/// project for `clickrelay_run_script` and writes one for
/// `clickrelay_save_script`, so the agent never pastes a script into a call
/// (paying for it in tokens twice) and the app never touches the agent's files.
///
/// Runs in the bridge, so plain Foundation only: no capture, Accessibility or
/// events (`BridgeIsolationTests`).
nonisolated enum ScriptFiles {
    static let maxBytes = 1_000_000

    enum Prepared: Equatable {
        /// Relay this line; for a save, write the result to `saveTo` when it comes back.
        case relay(Data, saveTo: URL?)
        /// Answer the agent with this error without asking the app.
        case fail(String)
        /// Answer the agent with this result without asking the app.
        case answer(ToolResult)
    }

    /// Rewrites a `tools/call` line if it's a script call, or answers it
    /// (`validate_script` never reaches the app). Any other call is relayed as
    /// it is.
    static func prepare(_ line: Data, message: [String: Any], workingDirectory: String?,
                        isInstalled: (String) -> Bool = { _ in true }) -> Prepared {
        guard let params = message["params"] as? [String: Any],
              let name = params["name"] as? String else { return .relay(line, saveTo: nil) }
        var arguments = params["arguments"] as? [String: Any] ?? [:]
        let args = ToolArguments(arguments)

        switch name {
        case ToolName.runScript.rawValue:
            if args.value("script") != nil { return .relay(line, saveTo: nil) }
            switch load(args.string("path"), workingDirectory: workingDirectory) {
            case .failure(let error):
                return .fail(error.message)
            case .success(let loaded):
                arguments["script"] = loaded.script
                arguments["path"] = loaded.shown
                return .relay(rewrite(message, params: params, arguments: arguments) ?? line, saveTo: nil)
            }

        case ToolName.validateScript.rawValue:
            if let inline = args.value("script") {
                return .answer(ScriptCheck.result(inline, params: args.value("params"), label: nil,
                                                  isInstalled: isInstalled))
            }
            switch load(args.string("path"), workingDirectory: workingDirectory) {
            case .failure(let error):
                return .answer(.error(error.message))
            case .success(let loaded):
                return .answer(ScriptCheck.result(loaded.script, params: args.value("params"), label: loaded.shown,
                                                  isInstalled: isInstalled))
            }

        case ToolName.saveScript.rawValue:
            guard let path = args.string("path"), !path.isEmpty else {
                return .fail("Pass path: where to write the script, e.g. scripts/export-log.json.")
            }
            guard path.lowercased().hasSuffix(".json") else {
                return .fail("Scripts are JSON files; give the path a .json extension.")
            }
            let url: URL
            switch resolve(path, workingDirectory: workingDirectory) {
            case .success(let resolved): url = resolved
            case .failure(let error): return .fail(error.message)
            }
            let shown = display(url, workingDirectory: workingDirectory)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), args.bool("overwrite") != true {
                return .fail("\(shown) already exists. Pass overwrite: true to replace it, or pick another path.")
            }
            arguments["path"] = shown
            return .relay(rewrite(message, params: params, arguments: arguments) ?? line, saveTo: url)

        default:
            return .relay(line, saveTo: nil)
        }
    }

    /// Writes a save's script (the result's last text block) to `url`, and
    /// returns the response to give the agent: the summary and where it went.
    static func finishSave(_ line: Data, to url: URL, workingDirectory: String?) -> Data {
        guard var response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              var result = response["result"] as? [String: Any],
              (result["isError"] as? Bool) != true,
              let content = result["content"] as? [[String: Any]] else { return line }
        let texts = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
        guard texts.count >= 2, let file = texts.last else { return line }
        let summary = texts.dropLast().joined(separator: "\n")
        let shown = display(url, workingDirectory: workingDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.utf8).write(to: url, options: .atomic)
            result["content"] = [["type": "text", "text": summary + "\nSaved to \(shown). Run it with clickrelay_run_script."]]
        } catch {
            result["content"] = [["type": "text", "text":
                "ClickRelay built the script but couldn't write \(shown) (\(error.localizedDescription)). "
                + "Here it is, to save yourself:\n" + file]]
            result["isError"] = true
        }
        response["result"] = result
        return (try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])) ?? line
    }

    // MARK: - Paths

    /// Reads a script file: the parsed JSON object and the path as shown to the agent.
    static func load(_ path: String?, workingDirectory: String?) -> Result<(script: [String: Any], shown: String), PathError> {
        guard let path, !path.isEmpty else {
            return .failure(PathError(message: "Pass path: the script file, relative to your working directory."))
        }
        let url: URL
        switch resolve(path, workingDirectory: workingDirectory) {
        case .success(let resolved): url = resolved
        case .failure(let error): return .failure(error)
        }
        let shown = display(url, workingDirectory: workingDirectory)
        let filePath = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .failure(PathError(message: "There's no script at \(shown). Check the path, which is relative to your "
                + "working directory" + (workingDirectory.map { " (\(MCPLocal.abbreviatingHome($0)))" } ?? "") + "."))
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
        if let size = attributes?[.size] as? Int, size > maxBytes {
            return .failure(PathError(message: "\(shown) is over 1 MB, which is too big for a script."))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(PathError(message: "ClickRelay couldn't read \(shown)."))
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            return .failure(PathError(message: "\(shown) isn't valid JSON: \(detail)"))
        }
        guard let object = parsed as? [String: Any] else {
            return .failure(PathError(message: "\(shown) should hold a JSON object with \"steps\"."))
        }
        return .success((object, shown))
    }

    struct PathError: Error, Equatable {
        let message: String
    }

    static func resolve(_ path: String, workingDirectory: String?) -> Result<URL, PathError> {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return .success(URL(filePath: expanded).standardizedFileURL) }
        guard let workingDirectory else {
            return .failure(PathError(message: "ClickRelay doesn't know your working directory, so give an absolute path."))
        }
        let base = URL(filePath: workingDirectory, directoryHint: .isDirectory)
        return .success(base.appending(path: expanded).standardizedFileURL)
    }

    /// Relative to the working directory when it's inside it, for messages and the log.
    static func display(_ url: URL, workingDirectory: String?) -> String {
        let path = url.path(percentEncoded: false)
        if let workingDirectory {
            let base = URL(filePath: workingDirectory, directoryHint: .isDirectory).standardizedFileURL
                .path(percentEncoded: false)
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return MCPLocal.abbreviatingHome(path)
    }

    private static func rewrite(_ message: [String: Any], params: [String: Any], arguments: [String: Any]) -> Data? {
        var message = message
        var params = params
        params["arguments"] = arguments
        message["params"] = params
        return try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
    }
}
