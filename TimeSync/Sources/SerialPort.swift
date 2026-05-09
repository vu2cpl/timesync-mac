import Foundation
import Darwin

enum SerialError: Error, CustomStringConvertible {
    case open(errno: Int32, path: String)
    case config(errno: Int32, stage: String)
    case unsupportedBaud(Int32)
    case alreadyOpen
    case notOpen

    var description: String {
        switch self {
        case .open(let e, let path):
            return "open(\(path)) failed: \(String(cString: strerror(e))) (errno \(e))"
        case .config(let e, let stage):
            return "\(stage) failed: \(String(cString: strerror(e))) (errno \(e))"
        case .unsupportedBaud(let b):
            return "Unsupported baud rate: \(b)"
        case .alreadyOpen:
            return "Port is already open"
        case .notOpen:
            return "Port is not open"
        }
    }
}

/// Read-only serial port. Configures 8N1 raw mode and emits incoming bytes
/// on a dispatch queue along with the wall-clock time the bytes arrived.
final class SerialPort {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "TimeSync.SerialPort", qos: .userInitiated)

    /// Called with raw bytes and the time they were drained from the kernel buffer.
    var onData: ((Data, Date) -> Void)?
    /// Called once if the port is closed by the OS (device removed) or hits an error.
    var onClosed: ((Error?) -> Void)?

    var isOpen: Bool { fd >= 0 }

    func open(path: String, baud: Int32) throws {
        if fd >= 0 { throw SerialError.alreadyOpen }

        // Pre-configure the device via stty (sets baud/8N1/raw on the cu.* node). On macOS
        // the FTDI USB-serial driver has been flaky about honoring an in-process tcsetattr
        // after open — but it always honors stty. Doing this before open avoids the dance.
        try Self.runStty(path: path, baud: baud)

        // Match what `cat /dev/cu.usbserial-…` and Python's pyserial do: O_RDONLY | O_NOCTTY,
        // blocking. Adding O_RDWR or O_NONBLOCK at this step breaks the FTDI driver — it
        // delivers a few clean bytes, then garbage at the wrong baud.
        let opened = path.withCString { Darwin.open($0, O_RDONLY | O_NOCTTY) }
        if opened < 0 {
            throw SerialError.open(errno: errno, path: path)
        }

        // Now flip to non-blocking so DispatchSourceRead's event handler can drain without
        // blocking the queue. By this point the driver state is already settled.
        if fcntl(opened, F_SETFL, O_NONBLOCK) == -1 {
            let err = errno
            Darwin.close(opened)
            throw SerialError.config(errno: err, stage: "fcntl(set O_NONBLOCK)")
        }

        self.fd = opened

        let src = DispatchSource.makeReadSource(fileDescriptor: opened, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.handleReadable() }
        // Capture fd by value so the OS fd is closed even if SerialPort has been deallocated
        // by the time GCD runs the cancel handler. This is the GCD-correct pattern for fd
        // lifecycle: never close the fd before the source is cancelled.
        src.setCancelHandler {
            Darwin.close(opened)
        }
        src.resume()
        self.source = src
    }

    func close() {
        guard fd >= 0 else { return }
        fd = -1
        source?.cancel()
        source = nil
    }

    // MARK: - Internals

    private func handleReadable() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let arrivedAt = Date()
        let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
            Darwin.read(fd, ptr.baseAddress, ptr.count)
        }
        if n > 0 {
            let data = Data(buffer[0..<n])
            onData?(data, arrivedAt)
        } else if n == 0 {
            // EOF / device disconnected.
            let cb = onClosed
            close()
            cb?(nil)
        } else {
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK || err == EINTR { return }
            let cb = onClosed
            close()
            cb?(SerialError.config(errno: err, stage: "read"))
        }
    }

    private func configure(fd: Int32, baud: Int32) throws {
        var settings = termios()
        if tcgetattr(fd, &settings) != 0 {
            throw SerialError.config(errno: errno, stage: "tcgetattr")
        }

        cfmakeraw(&settings)

        guard let speed = Self.speed(for: baud) else {
            throw SerialError.unsupportedBaud(baud)
        }
        if cfsetspeed(&settings, speed) != 0 {
            throw SerialError.config(errno: errno, stage: "cfsetspeed")
        }
        // cfsetspeed via tcsetattr is unreliable on USB-serial bridges (FTDI, CH340 etc.)
        // on macOS — the kernel may quietly leave the chip at its previous rate. The
        // IOKit-blessed ioctl below tells the driver to set the actual hardware baud.
        // IOSSIOSPEED = _IOW('T', 2, speed_t); speed_t is unsigned long (8 bytes) on 64-bit.

        // 8N1, enable receiver, ignore modem control lines (so we open even without DCD).
        let cs8     = tcflag_t(CS8)
        let cread   = tcflag_t(CREAD)
        let clocal  = tcflag_t(CLOCAL)
        let parenb  = tcflag_t(PARENB)
        let cstopb  = tcflag_t(CSTOPB)
        let csize   = tcflag_t(CSIZE)
        let crtscts = tcflag_t(CRTSCTS)

        settings.c_cflag &= ~csize
        settings.c_cflag |=  cs8
        settings.c_cflag |=  cread | clocal
        settings.c_cflag &= ~parenb
        settings.c_cflag &= ~cstopb
        settings.c_cflag &= ~crtscts

        // Disable software flow control (XON/XOFF).
        let ixon  = tcflag_t(IXON)
        let ixoff = tcflag_t(IXOFF)
        let ixany = tcflag_t(IXANY)
        settings.c_iflag &= ~(ixon | ixoff | ixany)

        // VMIN=0, VTIME=0 — return immediately with whatever is available.
        // (We rely on DispatchSourceRead for blocking semantics.)
        withUnsafeMutableBytes(of: &settings.c_cc) { raw in
            let cc = raw.bindMemory(to: cc_t.self)
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }

        if tcsetattr(fd, TCSANOW, &settings) != 0 {
            throw SerialError.config(errno: errno, stage: "tcsetattr")
        }

        var hwSpeed = speed_t(baud)
        if ioctl(fd, Self.iossioSpeed, &hwSpeed) != 0 {
            throw SerialError.config(errno: errno, stage: "IOSSIOSPEED")
        }
    }

    // _IOW('T', 2, speed_t) on 64-bit macOS, where speed_t is 8 bytes.
    // = IOC_IN(0x80000000) | sizeof<<16(0x80000) | 'T'<<8(0x5400) | 2 = 0x80085402
    private static let iossioSpeed: UInt = 0x80085402

    /// Shell out to /bin/stty to pre-configure the device, before we open it.
    /// This is what the python sniff and other working tools do — and it's reliable
    /// where in-process tcsetattr after open has been flaky for FTDI on macOS.
    private static func runStty(path: String, baud: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/stty")
        process.arguments = ["-f", path,
                             "\(baud)",
                             "cs8", "-cstopb", "-parenb",
                             "-icanon", "-echo", "raw"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SerialError.config(errno: 0, stage: "stty spawn: \(error.localizedDescription)")
        }
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "(no output)"
            throw SerialError.config(errno: 0, stage: "stty exit \(process.terminationStatus): \(msg)")
        }
    }

    private static func speed(for baud: Int32) -> speed_t? {
        switch baud {
        case 1200:   return speed_t(B1200)
        case 2400:   return speed_t(B2400)
        case 4800:   return speed_t(B4800)
        case 9600:   return speed_t(B9600)
        case 19200:  return speed_t(B19200)
        case 38400:  return speed_t(B38400)
        case 57600:  return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default:     return nil
        }
    }
}
