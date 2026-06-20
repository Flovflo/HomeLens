import Foundation
import Network

/// Tiny loopback-only HTTP server that serves the HLS segments ffmpeg writes to
/// a session directory. AVPlayer cannot read RTSP, so we remux to HLS on disk
/// and hand AVPlayer a `http://127.0.0.1:<port>/index.m3u8` URL. No external
/// dependency: built on Network.framework, bound to loopback, path-sanitised.
final class LocalHLSServer: @unchecked Sendable {
    private let rootDir: URL
    private let queue = DispatchQueue(label: "com.homelens.app.hls-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private(set) var port: UInt16 = 0

    init(rootDir: URL) {
        self.rootDir = rootDir
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener?.port?.rawValue ?? 0
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        // Wait briefly for the ephemeral port to resolve.
        _ = ready.wait(timeout: .now() + 2)
        guard port != 0 else {
            stop()
            throw NSError(domain: "LocalHLSServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Le serveur HLS local n'a pas démarré."])
        }
    }

    func stop() {
        queue.sync {
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, let request = String(data: data, encoding: .utf8) {
                self.respond(to: request, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        guard let requestLine = request.split(separator: "\r\n", omittingEmptySubsequences: true).first else {
            send(status: "400 Bad Request", connection: connection)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let name = sanitizedName(String(parts[1])) else {
            send(status: "404 Not Found", connection: connection)
            return
        }

        let fileURL = rootDir.appendingPathComponent(name)
        guard let fileData = try? Data(contentsOf: fileURL) else {
            send(status: "404 Not Found", connection: connection)
            return
        }

        // Honour a single Range request (AVPlayer occasionally byte-ranges segments).
        if let range = parseRange(in: request, total: fileData.count) {
            let slice = fileData.subdata(in: range)
            sendBody(slice,
                     status: "206 Partial Content",
                     contentType: contentType(for: name),
                     extraHeaders: ["Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(fileData.count)"],
                     connection: connection)
        } else {
            sendBody(fileData, status: "200 OK", contentType: contentType(for: name), extraHeaders: [], connection: connection)
        }
    }

    /// Only allow flat filenames produced by our ffmpeg HLS muxer.
    private func sanitizedName(_ path: String) -> String? {
        let name = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !name.isEmpty, !name.contains(".."), !name.contains("/") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return name
    }

    private func contentType(for name: String) -> String {
        if name.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if name.hasSuffix(".m4s") || name.hasSuffix(".mp4") { return "video/mp4" }
        if name.hasSuffix(".ts") { return "video/mp2t" }
        return "application/octet-stream"
    }

    private func parseRange(in request: String, total: Int) -> Range<Int>? {
        guard let line = request
            .split(separator: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }) else { return nil }
        guard let spec = line.split(separator: "=").last else { return nil }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard let startStr = bounds.first, let start = Int(startStr.trimmingCharacters(in: .whitespaces)), start < total else { return nil }
        var end = total - 1
        if bounds.count > 1, let endStr = bounds.last, let parsed = Int(endStr.trimmingCharacters(in: .whitespaces)) {
            end = min(parsed, total - 1)
        }
        guard end >= start else { return nil }
        return start..<(end + 1)
    }

    private func send(status: String, connection: NWConnection) {
        sendBody(Data(), status: status, contentType: "text/plain", extraHeaders: [], connection: connection)
    }

    private func sendBody(_ body: Data, status: String, contentType: String, extraHeaders: [String], connection: NWConnection) {
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Accept-Ranges: bytes",
            "Cache-Control: no-cache",
            "Connection: close",
        ]
        headers.append(contentsOf: extraHeaders)
        let head = headers.joined(separator: "\r\n") + "\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
