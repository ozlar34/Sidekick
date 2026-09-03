import Foundation
import Network

/// Transport half of `DebugHarness`: NWListener accept loop and a minimal
/// HTTP/1.1 request parser / responder. Command handling lives in
/// `DebugHarness.swift`; this file knows nothing about the app.
extension DebugHarness {

    // MARK: - Minimal HTTP/1.1

    func accept(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.drop(conn) } }
            if case .cancelled = state { Task { @MainActor in self?.drop(conn) } }
        }
        conn.start(queue: .main)
        readRequest(conn, buffer: Data())
    }

    private func drop(_ conn: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(conn))
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = Self.parse(buf) {
                    let (status, body) = self.route(req)
                    self.respond(conn, status: status, json: body)
                } else if isComplete || error != nil {
                    conn.cancel()
                } else {
                    self.readRequest(conn, buffer: buf)
                }
            }
        }
    }

    struct Request {
        let method: String
        let path: String
        let json: [String: Any]
    }

    static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: 0..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return Request(method: String(parts[0]), path: String(parts[1]), json: json)
    }

    func respond(_ conn: NWConnection, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

}
