import Foundation
import Network
import SwiftUI
import UIKit

/// Diagnostic log + LAN export (1.4.3, KH-1 — cures ĐG-3: the app
/// shipped with NO retrievable log at all, four `print()` calls
/// nobody could ever read on tvOS, in breach of the LOG RETRIEVAL
/// LAW).
///
/// Ported from the Joe TV 2.0.33 pattern (JoeDiagLog.swift), which
/// runs on the owner's Apple TV today: the app keeps a small
/// rolling log in its own sandbox, and the log screen serves that
/// one file over the home LAN from a tiny HTTP server; the screen
/// shows the address in large type plus a QR code of it, and the
/// owner downloads the .txt in Safari on his iPhone. tvOS gives an
/// app no share sheet, no activity view and no file exporter
/// (Apple's HIG states activity views are not supported on tvOS),
/// so the LAN route is the only one that exists.
///
/// WHAT may be written: short, factual breadcrumbs from the load /
/// poll / resolve / playback paths. NEVER a full stream URL:
/// write() scrubs every http(s) URL in a message down to
/// scheme://host before the line touches disk (defence in depth —
/// callers log ids, hosts and outcomes, not links).
enum DiagLog {

    // MARK: - Storage

    /// The log's directory: Application Support (created if
    /// needed), falling back to Caches. Resolved ONCE — `static
    /// let` initialisation is thread-safe by the runtime's own
    /// guarantee, so no caller ever races the creation.
    private static let storageDirectory: URL = {
        let fm = FileManager.default
        if let base = try? fm.url(for: .applicationSupportDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true) {
            try? fm.createDirectory(at: base,
                                    withIntermediateDirectories: true)
            return base
        }
        if let base = try? fm.url(for: .cachesDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true) {
            try? fm.createDirectory(at: base,
                                    withIntermediateDirectories: true)
            return base
        }
        return fm.temporaryDirectory
    }()

    /// The log file itself: Application Support/dabanh-diag.log.
    static var fileURL: URL {
        storageDirectory.appendingPathComponent("dabanh-diag.log")
    }

    // MARK: - Serialisation state
    //
    // Every mutable value below is touched ONLY while `lock`
    // is held. NSLock is Sendable, and the `let` statics are
    // immutable references, so the enum is safe to call from
    // ANY thread or actor — URLSession delegate queues and
    // @MainActor view code alike. The access pattern is
    // deliberately synchronous (DiagLog.write is called from
    // hot sync paths), so actor isolation would change every
    // call site's signature; the lock discipline is the safety
    // argument, exactly as in the Joe TV original.

    private static let lock = NSLock()
    private nonisolated(unsafe) static var writeCounter = 0
    private nonisolated(unsafe) static var didLogSessionStart = false

    /// Bounded size: the file is capped at 1 MB; on rotation
    /// the newest ~700 KB are kept (see rotateIfNeededLocked).
    private static let sizeCap = 1_000_000
    private static let rotationKeepBytes = 700_000

    /// The URL scrubber's pattern: a whole http(s) URL run —
    /// no whitespace, no quotes (a quoted URL in a message
    /// ends at its closing quote, which must survive).
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s"']+"#)

    // MARK: - Writing

    /// Append ONE line: `[yyyy-MM-dd HH:mm:ss.SSS] [category]
    /// message`. The message is URL-scrubbed first (see the
    /// file header) and flattened to a single line, so one
    /// write is always exactly one log line.
    static func write(_ category: String, _ message: String) {
        let clean = scrubbed(message)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let line = "[\(timestamp())] [\(category)] \(clean)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        appendLocked(data)
        writeCounter += 1
        if writeCounter % 64 == 0 {
            rotateIfNeededLocked()
        }
    }

    /// The file's full current contents ("" when absent or
    /// unreadable) — the export server's body source and the
    /// log screen's in-app text.
    static func currentText() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Append under the lock: create the file on first use,
    /// then write at its end through a file handle. Failures
    /// are silent by design — a diagnostic log must never be
    /// able to break the feature it is observing.
    private static func appendLocked(_ data: Data) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Rotation, called under the lock every 64 writes: when
    /// the file is over the cap, drop from the front up to the
    /// first newline AFTER (size − keepBytes) — so the kept
    /// tail starts on a whole line — and prepend a marker
    /// saying the older lines are gone.
    private static func rotateIfNeededLocked() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > sizeCap,
              let data = try? Data(contentsOf: fileURL),
              data.count > rotationKeepBytes
        else { return }
        let threshold = data.count - rotationKeepBytes
        var start = data.count
        if let newline = data[threshold...].firstIndex(of: 0x0A) {
            start = newline + 1
        }
        let marker = "[\(timestamp())] [diag] log rotated — older lines dropped\n"
        var rotated = Data(marker.utf8)
        if start < data.count {
            rotated.append(data[start...])
        }
        try? rotated.write(to: fileURL)
    }

    // MARK: - Formatting + redaction

    /// One line's timestamp prefix. A fresh DateFormatter per
    /// call: formatters are not thread-safe, writes are rare,
    /// and this keeps the formatter entirely out of the
    /// shared-state story above.
    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// Reduce every http(s) URL in the message to
    /// scheme://host — paths and queries never reach disk.
    /// A match URLComponents cannot parse at all becomes
    /// "[url]". Matches are replaced back-to-front so the
    /// earlier ranges stay valid while the string mutates.
    private static func scrubbed(_ message: String) -> String {
        var result = message
        let full = NSRange(location: 0,
                           length: (message as NSString).length)
        let matches = urlRegex.matches(in: message, range: full)
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let raw = String(result[range])
            if let comps = URLComponents(string: raw),
               let scheme = comps.scheme, let host = comps.host {
                result.replaceSubrange(range, with: "\(scheme)://\(host)")
            } else {
                result.replaceSubrange(range, with: "[url]")
            }
        }
        return result
    }

    // MARK: - Session header

    /// ONE session line per process: app build + system
    /// version, so a returned log always says which build
    /// produced it. The once-per-process guard is the
    /// lock-protected flag; it is flipped under the lock and
    /// released BEFORE the write, because write() takes the
    /// same (non-recursive) lock itself.
    static func logSessionStart() {
        lock.lock()
        if didLogSessionStart {
            lock.unlock()
            return
        }
        didLogSessionStart = true
        lock.unlock()

        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        write("diag", "session start app=\(short)/\(build) "
              + "system=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}

// MARK: - Focus signpost (KH-2's measuring instrument)

/// Focus-step timing for the log: a rail's focus change calls
/// begin(); the root's focus handler then schedules end() on
/// the next main-actor turn — i.e. after the body evaluations
/// the focus change triggered have been scheduled — and the
/// elapsed milliseconds land in the log as one "focus" line.
/// It measures the app's own scheduling cost of a focus step,
/// not the compositor's frame time; the owner's eyes remain
/// the final gate for KH-2, exactly as the plan states.
@MainActor
enum FocusSignpost {
    private static var pendingStart: Date?

    static func begin() {
        pendingStart = Date()
    }

    static func end() {
        guard let start = pendingStart else { return }
        pendingStart = nil
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        DiagLog.write("focus", "step \(ms) ms")
    }
}

// MARK: - LAN export server

/// The tiny HTTP server behind the log screen: while the
/// screen is open it serves DiagLog's file at
/// http://<Apple-TV-LAN-IP>:18082/log to ANY path, as a
/// download named dabanh-diag.txt. (Port 18082 since 1.4.6,
/// FL-332: a fixed port is a DEVICE-wide resource — 18080 is
/// JoeTV's on this Apple TV and 18081 is JTV tvOS's, so the
/// old 18080 bind died with NWError 48 whenever a sibling
/// app's listener was bound first.) It exists only for the
/// screen's lifetime (the view starts it on appear and stops
/// it on disappear), binds no authentication — the file is
/// already URL-scrubbed by DiagLog — and serves nothing else.
///
/// Swift 6: the server is @MainActor — the listener, the
/// live-connection table and the state callback are touched
/// ONLY on the main actor. Network.framework handlers are
/// @Sendable closures running on the server's private serial
/// queue; each one captures only Sendable values (the
/// listener / connection) plus a weak self, and hops straight
/// back with Task { @MainActor in } before touching any
/// state, so the class needs no unchecked Sendable
/// conformance and no unsafe isolation opt-outs.
@MainActor
final class DiagLogServer {

    enum State {
        case starting
        case serving(url: String)
        case failed(String)
    }

    /// State observer — set by the log view before start().
    /// Always invoked on the main actor (see emit).
    var onStateChange: ((State) -> Void)?

    /// The queue the listener and its connections run on.
    private let queue = DispatchQueue(label: "dabanh.diaglog.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Start serving on port 18082. Idempotent while a
    /// listener is alive.
    func start() {
        guard listener == nil else { return }
        DiagLog.write("logserver", "start requested port=18082")
        emit(.starting)
        guard let port = NWEndpoint.Port(rawValue: 18082) else {
            emit(.failed("Không mở được kênh gửi log (cổng không hợp lệ)."))
            return
        }
        let created: NWListener
        do {
            created = try NWListener(using: NWParameters.tcp, on: port)
        } catch {
            emit(.failed("Không mở được kênh gửi log: \(error.localizedDescription)"))
            return
        }
        listener = created
        created.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.listenerStateChanged(state, listener: created)
            }
        }
        created.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.accept(conn)
            }
        }
        created.start(queue: queue)
    }

    /// Cancel the listener and every live connection. The
    /// log view calls this on disappear, so the server never
    /// outlives its screen.
    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
    }

    // MARK: - Listener / connection handling (main actor)

    private func listenerStateChanged(_ state: NWListener.State,
                                      listener: NWListener) {
        switch state {
        case .ready:
            guard let ip = Self.lanIPAddress(), let port = listener.port else {
                emit(.failed("Không tìm thấy địa chỉ mạng nội bộ"))
                return
            }
            DiagLog.write("logserver", "listener bound on \(port.rawValue)")
            emit(.serving(url: "http://\(ip):\(port.rawValue)/log"))
        case .failed(let error):
            if self.listener === listener { self.listener = nil }
            DiagLog.write("logserver", "listener failed: \(error.localizedDescription)")
            emit(.failed("Kênh gửi log lỗi: \(error.localizedDescription)"))
        case .cancelled:
            if self.listener === listener { self.listener = nil }
        default:
            break
        }
    }

    /// Accept one connection: register it (so stop() can
    /// cancel it), start it on the server queue, and read ONE
    /// bounded request. The request's content is never
    /// inspected — ANY path gets the log.
    private func accept(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] _, _, _, _ in
            Task { @MainActor in
                self?.respond(to: conn)
            }
        }
    }

    /// Send the log as a plain-text download and close.
    private func respond(to conn: NWConnection) {
        let text = DiagLog.currentText()
        let bodyText = text.isEmpty
            ? "Da Banh TV diagnostic log is empty.\n" : text
        let body = Data(bodyText.utf8)
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Disposition: attachment; filename=\"dabanh-diag.txt\"\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed {
            [weak self] _ in
            conn.cancel()
            Task { @MainActor in
                self?.connections.removeValue(
                    forKey: ObjectIdentifier(conn))
            }
        })
    }

    /// Deliver a state change on the main actor, as the
    /// contract promises the view.
    private func emit(_ state: State) {
        let callback = onStateChange
        Task { @MainActor in
            callback?(state)
        }
    }

    // MARK: - LAN address

    /// The box's first LAN IPv4 address: the first AF_INET
    /// address on en0/en1/en2 that is up, not loopback and
    /// not 127.*. nil when the box has no LAN address at all.
    nonisolated static func lanIPAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let ptr = cursor {
            cursor = ptr.pointee.ifa_next
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" || name == "en2"
            else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr,
                              socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("127.") { return ip }
        }
        return nil
    }
}

// MARK: - Log screen

/// The full-screen log view behind the header's Log button
/// (KH-1): the log's contents readable in the app itself,
/// the LAN download address in large type, and its QR code
/// for the owner's iPhone. It owns ONE DiagLogServer for its
/// own lifetime only. The QR is rendered on a white rounded
/// rect on purpose: a QR code needs its light background and
/// quiet zone to scan — that white card is a functional
/// element, not a theme surface.
struct TVLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tvTheme) private var theme
    @State private var server = DiagLogServer()
    @State private var serverState: DiagLogServer.State = .starting
    @State private var logText: String = ""
    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            TVPalette.boardBG.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center, spacing: 24) {
                    Text("Log chẩn đoán")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("Đóng")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 10)
                            .background(TVPillFace(focused: closeFocused,
                                                   selected: false, theme: theme))
                    }
                    .tvCardButton()
                    .focused($closeFocused)
                }
                HStack(alignment: .top, spacing: 40) {
                    // The log itself, readable on the TV.
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(logText.isEmpty ? "(log trống)" : logText)
                            .font(.system(size: 17, design: .monospaced))
                            .foregroundStyle(TVPalette.evTx)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 1150)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(TVPalette.tileBG)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .strokeBorder(TVPalette.tileBorder, lineWidth: 2)))
                    // The download route: address + QR.
                    VStack(alignment: .center, spacing: 26) {
                        switch serverState {
                        case .starting:
                            ProgressView()
                                .tint(.white)
                            Text("Đang mở kênh gửi log…")
                                .font(.system(size: 24))
                                .foregroundStyle(.white)
                        case .serving(let url):
                            Text(url)
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let qr = Self.qrImage(for: url) {
                                Image(uiImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 300, height: 300)
                                    .padding(24)
                                    .background(RoundedRectangle(cornerRadius: 24)
                                        .fill(Color.white))
                            }
                            Text("Trên iPhone, mở Safari và nhập đúng địa chỉ trên — file log sẽ tải về máy. Hoặc dùng Camera của iPhone quét mã QR.")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.65))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 520, alignment: .center)
                        case .failed(let message):
                            Text(message)
                                .font(.system(size: 24))
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 520, alignment: .center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 44)
        }
        .defaultFocus($closeFocused, true)
        .onAppear {
            logText = DiagLog.currentText()
            server.onStateChange = { state in
                serverState = state
            }
            server.start()
        }
        .onDisappear {
            server.stop()
        }
        .onExitCommand { dismiss() }
    }

    /// QR code for the serving URL (CoreImage's
    /// CIQRCodeGenerator): the filter's output is a tiny
    /// bitmap (one pixel per module), so it is scaled up
    /// with a plain transform and rendered through a
    /// CIContext into a UIImage; the SwiftUI Image above
    /// then draws it with interpolation OFF, so the modules
    /// stay hard-edged and scannable.
    private static func qrImage(for string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled,
                                                  from: scaled.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
