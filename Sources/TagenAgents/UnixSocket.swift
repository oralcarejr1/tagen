import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Minimal blocking Unix-domain stream socket helpers (cross-platform).
public enum UnixSocket {
    public struct SocketError: Error, CustomStringConvertible { public let description: String }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError(description: "socket path too long (\(bytes.count) ≥ \(capacity))") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    #if canImport(Glibc)
    static let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    static let streamType = SOCK_STREAM
    #endif

    public static func listen(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw SocketError(description: "socket() failed: \(errno)") }
        var addr = try makeAddress(path)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw SocketError(description: "bind(\(path)) failed: \(errno)") }
        chmod(path, 0o600)
        guard Glibc_or_Darwin_listen(fd, 16) == 0 else { close(fd); throw SocketError(description: "listen failed: \(errno)") }
        return fd
    }

    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw SocketError(description: "socket() failed") }
        var addr = try makeAddress(path)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc_or_Darwin_connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw SocketError(description: "connect(\(path)) failed: \(errno)") }
        return fd
    }

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            while offset < data.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Read one newline-terminated line (max 1 MB).
    public static func readLine(_ fd: Int32) -> String? {
        var buf = [UInt8]()
        var byte: UInt8 = 0
        while buf.count < 1_048_576 {
            let n = read(fd, &byte, 1)
            if n <= 0 { return buf.isEmpty ? nil : String(decoding: buf, as: UTF8.self) }
            if byte == 0x0A { return String(decoding: buf, as: UTF8.self) }
            buf.append(byte)
        }
        return nil
    }

    public static func closeFD(_ fd: Int32) { _ = close(fd) }
    public static func shutdownFD(_ fd: Int32) { _ = shutdown(fd, Int32(SHUT_RDWR)) }
}

@inline(__always) func Glibc_or_Darwin_listen(_ fd: Int32, _ n: Int32) -> Int32 { listen(fd, n) }
@inline(__always) func Glibc_or_Darwin_connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { connect(fd, a, l) }
