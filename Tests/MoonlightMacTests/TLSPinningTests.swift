import Foundation
import Testing
@testable import MoonlightMac

private func makeTestCertificate(in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                         "-subj", "/CN=localhost", "-keyout", directory.appendingPathComponent("key.pem").path,
                         "-out", directory.appendingPathComponent("cert.pem").path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

private struct FixturePorts: Decodable {
    let https: UInt16
    let http: UInt16?
}

private func awaitFixturePorts(_ server: Process, in directory: URL) async throws -> FixturePorts {
    let readyURL = directory.appendingPathComponent("ready.json")
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline && server.isRunning {
        if let data = try? Data(contentsOf: readyURL) {
            return try JSONDecoder().decode(FixturePorts.self, from: data)
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    let diagnostics = (try? String(contentsOf: directory.appendingPathComponent("server-stderr.log"), encoding: .utf8)) ?? ""
    let state = server.isRunning ? "still running" : "exited with status \(server.terminationStatus)"
    throw NSError(domain: "TLSFixture", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "TLS fixture server \(state): \(diagnostics)"])
}

@Test func tlsHandshakeAcceptsOnlyPinnedCertificate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeTestCertificate(in: directory)
    let pem = try String(contentsOf: directory.appendingPathComponent("cert.pem"), encoding: .utf8)
    let pin = try #require(HostTrust.certificateDER(pem: pem))
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["python3", "-c", """
import http.server, socketserver, ssl, sys, json, os
# Avoid HTTPServer's hostname lookup: these fixtures only serve loopback.
class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'pinned host test'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = Server(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1] + '/cert.pem', sys.argv[1] + '/key.pem')
server.socket = context.wrap_socket(server.socket, server_side=True)
with open(sys.argv[1] + '/ready.tmp', 'w') as ready:
    json.dump({'https': server.server_port}, ready)
os.replace(sys.argv[1] + '/ready.tmp', sys.argv[1] + '/ready.json')
server.serve_forever()
""", directory.path]
    server.standardInput = FileHandle.nullDevice
    server.standardOutput = FileHandle.nullDevice
    let errorURL = directory.appendingPathComponent("server-stderr.log")
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer { try? errorHandle.close() }
    server.standardError = errorHandle
    try server.run()
    defer {
        if server.isRunning { server.terminate() }
        server.waitUntilExit()
    }
    let port = try await awaitFixturePorts(server, in: directory).https
    let url = try #require(URL(string: "https://127.0.0.1:\(port)/"))
    // This server does not request a client identity, so the test never accesses
    // the user's real client credentials or contacts a streaming host.
    let differentCertificateURL = try #require(Bundle.module.url(forResource: "host.der", withExtension: nil, subdirectory: "Fixtures"))
    let differentCertificate = try Data(contentsOf: differentCertificateURL)
    for (certificate, shouldSucceed) in [(Optional(pin), true), (Optional(differentCertificate), false),
                                         (Optional(Data([1, 2, 3])), false), (nil, false)] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config,
                                 delegate: PinnedHostDelegate(certificateDER: certificate), delegateQueue: nil)
        do {
            let (_, response) = try await session.data(from: url)
            #expect(shouldSucceed)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        } catch {
            #expect(!shouldSucceed, "Pinned TLS handshake failed: \(error)")
        }
        session.invalidateAndCancel()
    }
}

@Test func remoteFallbackAuthenticatesThenUsesWinningRoute() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeTestCertificate(in: directory)
    let pem = try String(contentsOf: directory.appendingPathComponent("cert.pem"), encoding: .utf8)
    let pin = try #require(HostTrust.certificateDER(pem: pem))
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["python3", "-c", """
import http.server, socketserver, ssl, sys, threading, json, os
from urllib.parse import urlsplit, parse_qs
# Avoid HTTPServer's hostname lookup: these fixtures only serve loopback.
class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        # localhost is reachable but represents an unrelated host. Fallback must
        # still proceed after validation, using the same pinned certificate.
        if path in ('/api/abr/capabilities', '/api/hardware-metrics'):
            payload = {'supported': False, 'version': 1, 'features': ['runtime_bitrate']} if path.endswith('capabilities') else {'version': 1, 'sampled_at_unix_ms': 1, 'interval_ms': 1000, 'cpu': {'cpu_usage_percent': 0}, 'gpus': []}
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == '/serverinfo':
            identity = 'wrong-host' if self.headers.get('Host', '').startswith('localhost:') else 'expected-host'
            if self.server is plain and 'wrong-http-client' in self.path:
                identity = 'wrong-http-host'
            content = '<hostname>Fixture</hostname><uniqueid>' + identity + '</uniqueid><appversion>7.1.0.-1</appversion><PairStatus>1</PairStatus><ExternalIP>0.0.0.0</ExternalIP><ExternalPort>12345</ExternalPort>'
        elif path == '/bitrate':
            content = '<bitrate>' + str(min(25000, int(parse_qs(urlsplit(self.path).query)['bitrate'][0]))) + '</bitrate>'
        elif path == '/applist':
            content = '<App><ID>1</ID><AppTitle>Desktop</AppTitle></App>'
        elif path in ('/launch', '/resume'):
            content = '<gamesession>1</gamesession><sessionUrl0>rtsp://127.0.0.1:48010</sessionUrl0>'
        else:
            self.send_error(404)
            return
        body = ('<root status_code="200">' + content + '</root>').encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
plain = Server(('127.0.0.1', 0), Handler)
threading.Thread(target=plain.serve_forever, daemon=True).start()
server = Server(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1] + '/cert.pem', sys.argv[1] + '/key.pem')
server.socket = context.wrap_socket(server.socket, server_side=True)
with open(sys.argv[1] + '/ready.tmp', 'w') as ready:
    json.dump({'https': server.server_port, 'http': plain.server_port}, ready)
os.replace(sys.argv[1] + '/ready.tmp', sys.argv[1] + '/ready.json')
server.serve_forever()
""", directory.path]
    server.standardInput = FileHandle.nullDevice
    server.standardOutput = FileHandle.nullDevice
    let errorURL = directory.appendingPathComponent("server-stderr.log")
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer { try? errorHandle.close() }
    server.standardError = errorHandle
    try server.run()
    defer {
        if server.isRunning { server.terminate() }
        server.waitUntilExit()
    }
    let ports = try await awaitFixturePorts(server, in: directory)
    let port = ports.https
    let httpPort = try #require(ports.http)
    let client = SunshineHTTPClient(uniqueID: { "test-client" })
    let expected = Host(name: "Fixture", address: "127.0.0.1", serverId: "expected-host",
                        isPaired: true, serverCertificateDER: pin)
    #expect(await client.verifyRemoteEndpoint(address: "127.0.0.1", httpsPort: Int(port), httpPort: Int(httpPort), host: expected))
    // Even with the correct certificate, a different server UUID must fail.
    #expect(await !client.verifyRemoteEndpoint(address: "localhost", httpsPort: Int(port), httpPort: Int(httpPort), host: expected))
    let wrongHTTPClient = SunshineHTTPClient(uniqueID: { "wrong-http-client" })
    #expect(await !wrongHTTPClient.verifyRemoteEndpoint(address: "127.0.0.1", httpsPort: Int(port), httpPort: Int(httpPort), host: expected))
    // An open plaintext listener cannot stand in for pinned HTTPS.
    #expect(await !client.verifyRemoteEndpoint(address: "127.0.0.1", httpsPort: Int(httpPort), host: expected))
    #expect(await !client.verifyRemoteEndpoint(address: "127.0.0.1", httpsPort: 0, host: expected))
    var wrongIdentity = expected
    wrongIdentity.serverId = "other-PC"
    #expect(await !client.verifyRemoteEndpoint(address: "127.0.0.1", httpsPort: Int(port), host: wrongIdentity))
    var noIdentity = expected
    noIdentity.serverId = nil
    #expect(await !client.verifyRemoteEndpoint(address: "127.0.0.1", httpsPort: Int(port), host: noIdentity))
    // The reported HTTP port must answer as the same PC too.
    #expect(await !client.verifyRemoteEndpoint(address: "127.0.0.1", httpsPort: Int(port), httpPort: Int(port), host: expected))
    for primary in ["127.0.0.2", "localhost"] {
        let host = Host(name: "Fixture", address: primary, remoteAddress: "127.0.0.1",
                        httpsPort: Int(port), httpPort: 47989, serverId: "expected-host",
                        isPaired: true, serverCertificateDER: pin)
        let (resolved, _) = try await client.fetchServerInfo(host: host)
        #expect(resolved.effectiveAddress == "127.0.0.1")
        #expect(resolved.serverId == "expected-host")
        #expect(resolved.isSecurelyPaired)
        #expect(resolved.remoteAddress == "127.0.0.1") // Ignore unspecified ExternalIP.
        #expect(resolved.httpPort == 47989) // ExternalPort must not corrupt LAN port.
        let apps = try await client.fetchAppList(host: resolved)
        #expect(apps.map(\.id) == [1])
        #expect(apps.first?.boxArtUrl?.host == "127.0.0.1")
        let url = try await client.launchApp(host: resolved, appId: 1, settings: StreamSettings(), rikey: String(repeating: "0", count: 32), rikeyId: 1)
        #expect(url == "rtsp://127.0.0.1:48010")
        let resumed = try await client.resumeApp(host: resolved, settings: StreamSettings(), rikey: String(repeating: "0", count: 32), rikeyId: 1)
        #expect(resumed == url)
    }
    var mapped = Host(name: "Mapped ports", address: "127.0.0.2", remoteAddress: "127.0.0.1",
                      httpsPort: 9, httpPort: 8, serverId: "expected-host",
                      isPaired: true, serverCertificateDER: pin)
    mapped.remoteHTTPSPort = Int(port)
    mapped.remoteHTTPPort = Int(httpPort)
    let (mappedRoute, _) = try await client.fetchServerInfo(host: mapped)
    #expect(mappedRoute.effectiveHTTPSPort == Int(port))
    #expect(mappedRoute.httpsPort == 9)
    let mappedApps = try await client.fetchAppList(host: mappedRoute)
    #expect(mappedApps.first?.boxArtUrl?.port == Int(port))
    #expect(mappedApps.first?.title == "Desktop")
    #expect(await client.supportsRuntimeBitrate(host: mappedRoute))
    #expect(try await client.setRuntimeBitrate(host: mappedRoute, kbps: 40000) == 25000)
    let sample = try await client.fetchHardwareMetrics(host: mappedRoute)
    #expect(sample.cpu.cpu_usage_percent == 0)
    #expect(sample.gpus.isEmpty)
    let differentCertificateURL = try #require(Bundle.module.url(forResource: "host.der", withExtension: nil, subdirectory: "Fixtures"))
    let wrongPin = try Data(contentsOf: differentCertificateURL)
    let untrusted = Host(name: "Wrong pin", address: "127.0.0.2", remoteAddress: "127.0.0.1",
                         httpsPort: Int(port), isPaired: true, serverCertificateDER: wrongPin)
    #expect(await !client.verifyRemoteEndpoint(address: "127.0.0.1", httpsPort: Int(port), host: untrusted))
    await #expect(throws: (any Error).self) { try await client.fetchServerInfo(host: untrusted) }
}
