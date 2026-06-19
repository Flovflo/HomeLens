import Darwin
import Foundation

struct NetworkInterfaceInfo: Identifiable, Hashable {
    let name: String   // e.g. "en0"
    let ipv4: String   // e.g. "192.168.0.12"

    var id: String { name }
    var label: String { "\(name) · \(ipv4)" }
}

/// Lists the Mac's active IPv4 network interfaces so the user can pick which one
/// the HomeKit bridge publishes on (useful on multi-homed machines).
enum NetworkInterfaceService {
    static func list() -> [NetworkInterfaceInfo] {
        var interfaces: [NetworkInterfaceInfo] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var seen = Set<String>()
        var pointer = head
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: current.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty, !ip.hasPrefix("169.254"), seen.insert(name).inserted else { continue }

            interfaces.append(NetworkInterfaceInfo(name: name, ipv4: ip))
        }
        return interfaces.sorted { $0.name < $1.name }
    }
}
