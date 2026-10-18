import UIKit
import AVFoundation
import ImageIO

/// Webcam iPhone: menyiarkan kamera sebagai stream MJPEG di http://<IP-iPhone>:8080/
final class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: - Pengaturan
    private let port: UInt16 = 8080
    private let jpegQuality: CGFloat = 0.6
    private let preset: AVCaptureSession.Preset = .hd1280x720   // ganti .vga640x480 jika lag
    private let cameraPosition: AVCaptureDevice.Position = .back // .front untuk kamera depan

    // MARK: - State
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()
    private let sendQueue = DispatchQueue(label: "webcam.send")  // semua pengiriman serial di sini
    private var clients: [Int32] = []
    private let infoLabel = UILabel()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    // Layar dikunci landscape supaya gambar ke PC juga landscape.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }
    override var shouldAutorotate: Bool { false }
    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        UIApplication.shared.isIdleTimerDisabled = true // layar tidak mati

        infoLabel.textColor = .white
        infoLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        infoLabel.numberOfLines = 0
        infoLabel.textAlignment = .center
        infoLabel.font = UIFont.boldSystemFont(ofSize: 16)
        infoLabel.text = "Memulai..."
        view.addSubview(infoLabel)

        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.setupCamera()
                    self.startServer()
                } else {
                    self.infoLabel.text = "Izin kamera ditolak. Aktifkan di Settings."
                }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        infoLabel.frame = CGRect(x: 0, y: view.bounds.height - 56, width: view.bounds.width, height: 56)
        view.bringSubviewToFront(infoLabel)
    }

    // MARK: - Kamera
    private func setupCamera() {
        session.beginConfiguration()
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            infoLabel.text = "Kamera tidak bisa dibuka"
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sendQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        output.connection(with: .video)?.videoOrientation = .landscapeRight

        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        preview.frame = view.bounds
        preview.connection?.videoOrientation = .landscapeRight
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        session.startRunning()
    }

    // MARK: - Frame -> JPEG -> klien
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !clients.isEmpty,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else { return }

        var packet = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        packet.append(jpeg)
        packet.append(Data("\r\n".utf8))

        clients = clients.filter { fd in
            if writeAll(fd, packet) { return true }
            close(fd)
            return false
        }
        updateStatus()
    }

    // MARK: - Server HTTP sederhana (BSD socket)
    private func startServer() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 5) == 0 else {
            infoLabel.text = "Gagal membuka port \(port)"
            return
        }
        updateStatus()

        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }

                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

                var buffer = [UInt8](repeating: 0, count: 2048)
                _ = recv(client, &buffer, buffer.count, 0) // baca request, isinya diabaikan

                let header = "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
                    + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
                if self.writeAll(client, Data(header.utf8)) {
                    self.sendQueue.async { self.clients.append(client) }
                } else {
                    close(client)
                }
            }
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < data.count {
                let n = send(fd, base + sent, data.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    // MARK: - Info
    private func updateStatus() {
        let count = clients.count
        let ip = wifiAddress() ?? "(tidak ada Wi-Fi)"
        DispatchQueue.main.async {
            self.infoLabel.text = "URL: http://\(ip):\(self.port)/   |   Terhubung: \(count)"
        }
    }

    private func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var ptr = first
        while true {
            let ifa = ptr.pointee
            if let sa = ifa.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            guard let next = ifa.ifa_next else { break }
            ptr = next
        }
        return nil
    }
}
