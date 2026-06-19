import Darwin
import Foundation

public final class RTSPStreamManager: @unchecked Sendable {
    public init() {}

    public func test(camera: CameraConfig, password: String?, timeout: TimeInterval = 5) async -> ServiceTestResult {
        guard let url = camera.rtspURL(password: password),
              let host = url.host(),
              let port = url.port ?? 554 as Int?
        else {
            return ServiceTestResult(ok: false, title: "Invalid RTSP URL", detail: "Could not build an RTSP URL from the camera config.")
        }

        do {
            let response = try await sendDescribe(host: host, port: UInt16(port), pathURL: url, timeout: timeout)
            let firstLine = response.components(separatedBy: .newlines).first ?? response
            let ok = firstLine.contains("RTSP/1.0 200") || firstLine.contains("RTSP/1.0 401")
            let detail = firstLine.contains("401")
                ? "Camera answered RTSP but requested/rejected auth. This still proves the RTSP service is reachable."
                : firstLine
            return ServiceTestResult(ok: ok, title: ok ? "RTSP reachable" : "RTSP failed", detail: detail)
        } catch {
            return ServiceTestResult(ok: false, title: "RTSP failed", detail: error.localizedDescription)
        }
    }

    private func sendDescribe(host: String, port: UInt16, pathURL: URL, timeout: TimeInterval) async throws -> String {
        let request = """
        DESCRIBE \(pathURL.absoluteString) RTSP/1.0\r
        CSeq: 1\r
        Accept: application/sdp\r
        User-Agent: HomeLens/0.1\r
        \r

        """

        return try await Task.detached(priority: .utility) {
            try blockingRTSPRequest(host: host, port: port, request: request, timeout: timeout)
        }.value
    }
}

private func blockingRTSPRequest(host: String, port: UInt16, request: String, timeout: TimeInterval) throws -> String {
    var hints = addrinfo(
        ai_flags: 0,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )

    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &result)
    guard status == 0, let result else {
        throw RTSPError.resolve(String(cString: gai_strerror(status)))
    }
    defer { freeaddrinfo(result) }

    var pointer: UnsafeMutablePointer<addrinfo>? = result
    var lastErrno: Int32 = 0

    while let candidate = pointer {
        let fd = socket(candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol)
        if fd >= 0 {
            defer { close(fd) }

            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            if connect(fd, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                let sent = request.withCString { buffer in
                    Darwin.send(fd, buffer, strlen(buffer), 0)
                }
                guard sent > 0 else {
                    throw RTSPError.socket(String(cString: strerror(errno)))
                }

                var buffer = [UInt8](repeating: 0, count: 8192)
                let received = Darwin.recv(fd, &buffer, buffer.count, 0)
                if received > 0 {
                    return String(data: Data(buffer.prefix(received)), encoding: .utf8) ?? ""
                }
                throw RTSPError.emptyResponse
            }
            lastErrno = errno
        }
        pointer = candidate.pointee.ai_next
    }

    if lastErrno == ETIMEDOUT {
        throw RTSPError.timeout
    }
    throw RTSPError.socket(String(cString: strerror(lastErrno)))
}

public enum RTSPError: LocalizedError {
    case timeout
    case emptyResponse
    case resolve(String)
    case socket(String)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            "Timed out waiting for the RTSP server."
        case .emptyResponse:
            "RTSP server closed the connection without a response."
        case .resolve(let detail):
            "Could not resolve RTSP host: \(detail)."
        case .socket(let detail):
            "RTSP socket failed: \(detail)."
        }
    }
}
