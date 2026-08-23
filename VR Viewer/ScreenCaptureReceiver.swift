import Foundation
import Network

final class ScreenCaptureReceiver {
    private let PORT: UInt16 = 47295
    private var connection: NWConnection?

    typealias FrameCallback = (Data) -> Void
    private var onFrame: FrameCallback?
    private(set) var isConnected = false

    // TCP is a byte stream: one receive() is NOT guaranteed to contain
    // exactly 4 bytes or exactly one payload. Keep a persistent buffer so
    // fragmentation/coalescing cannot desynchronise the H.264 stream.
    private var streamBuffer = Data()
    private var expectedPayloadLength: Int?

    var onStats: ((String) -> Void)?

    func connect(to ip: String, onFrame: @escaping FrameCallback) {
        self.onFrame = onFrame
        disconnect()
        streamBuffer.removeAll(keepingCapacity: true)
        expectedPayloadLength = nil

        guard let port = NWEndpoint.Port(rawValue: PORT) else {
            onStats?("Invalid TCP port")
            return
        }

        let conn = NWConnection(host: NWEndpoint.Host(ip), port: port, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup:
                self.onStats?("TCP setup")
            case .preparing:
                self.onStats?("TCP preparing")
            case .ready:
                self.isConnected = true
                self.onStats?("TCP connected \(ip):\(self.PORT)")
                self.receiveBytes()
            case .failed(let error):
                self.isConnected = false
                self.onStats?("TCP failed: \(error.localizedDescription)")
            case .waiting(let error):
                self.onStats?("TCP waiting: \(error.localizedDescription)")
            case .cancelled:
                self.isConnected = false
                self.onStats?("TCP cancelled")
            @unknown default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        streamBuffer.removeAll(keepingCapacity: true)
        expectedPayloadLength = nil
    }

    private func receiveBytes() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isDone, error in
            guard let self else { return }

            if let error {
                self.isConnected = false
                self.onStats?("TCP read error: \(error.localizedDescription)")
                return
            }

            if let data, !data.isEmpty {
                self.streamBuffer.append(data)
                self.parseBufferedStream()
            }

            if isDone {
                self.isConnected = false
                self.onStats?("TCP closed by PC")
                return
            }

            self.receiveBytes()
        }
    }

    private func parseBufferedStream() {
        while true {
            if expectedPayloadLength == nil {
                guard streamBuffer.count >= 4 else { return }
                let length = streamBuffer.prefix(4).withUnsafeBytes { raw -> UInt32 in
                    raw.loadUnaligned(as: UInt32.self).bigEndian
                }
                streamBuffer.removeFirst(4)

                let n = Int(length)
                guard n > 0, n <= 20_000_000 else {
                    onStats?("Invalid payload length: \(n); resetting stream")
                    streamBuffer.removeAll(keepingCapacity: true)
                    expectedPayloadLength = nil
                    return
                }
                expectedPayloadLength = n
            }

            guard let expected = expectedPayloadLength else { return }
            guard streamBuffer.count >= expected else { return }

            let payload = streamBuffer.prefix(expected)
            streamBuffer.removeFirst(expected)
            expectedPayloadLength = nil

            onFrame?(Data(payload))
        }
    }
}
