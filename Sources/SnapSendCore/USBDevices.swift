#if os(macOS)
import Foundation
import Darwin

/// One on-demand usbmux query; no daemon, polling process or Xcode dependency.
public enum USBDevices {
    public static func list() throws -> [String] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }; defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec:1,tv_usec:0), noSignal:Int32 = 1
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = Array("/var/run/usbmuxd".utf8) + [0]
        withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:path) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw CocoaError(.fileReadUnknown) }
        let body = try PropertyListSerialization.data(fromPropertyList:["MessageType":"ListDevices","ClientVersionString":"SnapSend","ProgName":"SnapSend","kLibUSBMuxVersion":3] as [String:Any],format:.xml,options:0)
        var packet = Data()
        for value in [UInt32(body.count + 16),1,8,1] { var v = value.littleEndian; withUnsafeBytes(of:&v) { packet.append(contentsOf:$0) } }
        packet.append(body)
        let deadline = Date().addingTimeInterval(2)
        try packet.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
                let count = Darwin.send(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset,0)
                guard count > 0 else { throw CocoaError(.fileReadUnknown) }; offset += count
            }
        }
        func read(_ size:Int) throws -> Data {
            var data = Data(count:size), offset = 0
            try data.withUnsafeMutableBytes { bytes in
                while offset < size {
                    guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
                    let n = recv(fd,bytes.baseAddress!.advanced(by:offset),size-offset,0)
                    guard n > 0 else { throw CocoaError(.fileReadUnknown) }; offset += n
                }
            }; return data
        }
        let header = try read(16)
        func word(_ offset:Int) -> Int { header[offset..<offset+4].reversed().reduce(0) { ($0 << 8) | Int($1) } }
        let length = word(0)
        guard length >= 16, length <= 1024 * 1024, word(4) == 1, word(8) == 8, word(12) == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let payload = try read(length-16)
        guard let plist = try PropertyListSerialization.propertyList(from:payload,format:nil) as? [String:Any], let devices = plist["DeviceList"] as? [[String:Any]] else { throw CocoaError(.fileReadCorruptFile) }
        return devices.compactMap { device in
            guard let props = device["Properties"] as? [String:Any], props["ConnectionType"] as? String == "USB", let serial = props["SerialNumber"] as? String, serial.range(of:"^[a-fA-F0-9-]{24,40}$",options:.regularExpression) != nil else { return nil }
            if serial.count == 24 { return String(serial.prefix(8)) + "-" + String(serial.dropFirst(8)) }
            return serial
        }.sorted()
    }
}
#endif
