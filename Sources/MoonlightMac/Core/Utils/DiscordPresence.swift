import Foundation
import Darwin

struct DiscordIPCFrame: Equatable {
    var opcode: UInt32
    var payload: Data
    var encoded: Data {
        var opcode = opcode.littleEndian, size = UInt32(payload.count).littleEndian
        var result = Data(bytes: &opcode, count: 4)
        result.append(Data(bytes: &size, count: 4)); result.append(payload)
        return result
    }
    static func next(from bytes: inout Data) throws -> Self? {
        guard bytes.count >= 8 else { return nil }
        let opcode = bytes.prefix(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let count = bytes.dropFirst(4).prefix(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard count <= 1_048_576 else { throw NSError(domain: "DiscordIPC", code: 1) }
        guard bytes.count >= 8 + Int(count) else { return nil }
        let payload = Data(bytes.dropFirst(8).prefix(Int(count)))
        bytes.removeFirst(8 + Int(count))
        return Self(opcode: opcode, payload: payload)
    }
}

/// Local Discord IPC only. Presence is opt-in and uses no account tokens.
final class DiscordPresence: @unchecked Sendable {
    static let shared = DiscordPresence()
    private let queue = DispatchQueue(label: "com.moonlight.discord")
    private var channel: DispatchIO?
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 0
    private var ready = false
    private var received = Data()
    private var applicationID = ""
    private var game = ""
    private var host = ""
    private var began = Date()
    private var handshakeAt = Date()

    func start(applicationID: String, game: String, host: String) {
        queue.async {
            self.close()
            self.timer?.cancel(); self.timer = nil
            guard !applicationID.isEmpty, applicationID.count <= 32, applicationID.allSatisfy(\.isNumber) else {
                RuntimeServiceStatus.reportDiscord("Discord presence needs a valid application ID in Settings."); return
            }
            self.applicationID = applicationID; self.game = String(game.prefix(100)); self.host = String(host.prefix(100)); self.began = Date()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(15))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if self.channel == nil { self.connect() }
                else if self.ready { self.sendActivity() }
                else if Date().timeIntervalSince(self.handshakeAt) > 10 { self.close() }
            }
            self.timer = timer; timer.resume()
        }
    }

    func stop() {
        queue.async {
            if self.ready { self.send(opcode: 1, json: ["cmd": "SET_ACTIVITY", "args": ["pid": ProcessInfo.processInfo.processIdentifier, "activity": NSNull()], "nonce": UUID().uuidString]) }
            self.timer?.cancel(); self.timer = nil
            self.close()
            RuntimeServiceStatus.reportDiscord(nil)
        }
    }

    private func connect() {
        let environment = ProcessInfo.processInfo.environment
        var folders = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"].compactMap { environment[$0] }
        folders.append(NSTemporaryDirectory()); folders.append("/tmp")
        for folder in Set(folders) {
            for index in 0..<10 {
                let path = URL(fileURLWithPath: folder).appendingPathComponent("discord-ipc-\(index)").path
                guard FileManager.default.fileExists(atPath: path), path.utf8.count < 104 else { continue }
                let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
                guard socketFD >= 0 else { continue }
                _ = fcntl(socketFD, F_SETFL, O_NONBLOCK)
                var noSignal: Int32 = 1
                setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                    bytes.copyBytes(from: Array(path.utf8) + [0])
                }
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard result == 0 else { Darwin.close(socketFD); continue }
                generation &+= 1
                let current = generation
                let io = DispatchIO(type: .stream, fileDescriptor: socketFD, queue: queue) { _ in Darwin.close(socketFD) }
                channel = io; ready = false; received.removeAll(); handshakeAt = Date()
                io.setLimit(lowWater: 1)
                io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
                    guard let self, current == self.generation else { return }
                    if let data { self.receive(Data(data)) }
                    if done || error != 0 { self.close() }
                }
                send(opcode: 0, json: ["v": 1, "client_id": applicationID])
                return
            }
        }
        RuntimeServiceStatus.reportDiscord("Discord desktop is unavailable. Presence will reconnect automatically.")
    }

    private func receive(_ data: Data) {
        received.append(data)
        do {
            while let frame = try DiscordIPCFrame.next(from: &received) {
                if frame.opcode == 2 { close(); return }
                if frame.opcode == 3 { write(DiscordIPCFrame(opcode: 4, payload: frame.payload).encoded); continue }
                guard frame.opcode == 1, let json = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else { continue }
                if json["evt"] as? String == "READY" { ready = true; RuntimeServiceStatus.reportDiscord(nil); sendActivity() }
                if json["evt"] as? String == "ERROR" { RuntimeServiceStatus.reportDiscord("Discord rejected the presence request. Check the application ID.") }
            }
        } catch { close() }
    }

    private func sendActivity() {
        send(opcode: 1, json: ["cmd": "SET_ACTIVITY", "args": ["pid": ProcessInfo.processInfo.processIdentifier,
            "activity": ["details": "Streaming \(game)", "state": "From \(host)", "timestamps": ["start": Int(began.timeIntervalSince1970)]]], "nonce": UUID().uuidString])
    }
    private func send(opcode: UInt32, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        write(DiscordIPCFrame(opcode: opcode, payload: data).encoded)
    }
    private func write(_ data: Data) {
        let current = generation
        let packet = data.withUnsafeBytes { DispatchData(bytes: $0) }
        channel?.write(offset: 0, data: packet, queue: queue) { [weak self] _, _, error in
            guard let self, current == self.generation else { return }
            if error != 0 { self.close() }
        }
    }
    private func close() {
        generation &+= 1; ready = false; received.removeAll()
        channel?.close(flags: .stop); channel = nil
    }
}
