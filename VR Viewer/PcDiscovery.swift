import Foundation
import Network

// ─────────────────────────────────────────────
//  MARK: - PcDiscovery
//  Escucha el broadcast UDP que emite el driver
//  en el puerto 47294 con el mensaje:
//    "CVRANNOUNCE:<hostname>"
// ─────────────────────────────────────────────

final class PcDiscovery {

    private let ANNOUNCE_PORT: UInt16 = 47294
    private let MAGIC = "CVRANNOUNCE:"

    private var listener: NWListener?
    private var callback: ((String, String) -> Void)?

    // ── Inicio ──────────────────────────────────────────────

    func start(onFound: @escaping (String, String) -> Void) {
        callback = onFound
        stop()

        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true

            listener = try NWListener(using: params,
                                      on: NWEndpoint.Port(rawValue: ANNOUNCE_PORT)!)
        } catch {
            print("[PcDiscovery] Error creando listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            self?.readMessages(from: conn)
        }

        listener?.start(queue: .global())
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // ── Lectura de mensajes ──────────────────────────────────

    private func readMessages(from conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data,
                  let msg = String(data: data, encoding: .ascii),
                  msg.hasPrefix(self.MAGIC)
            else { return }

            let name = String(msg.dropFirst(self.MAGIC.count)).trimmingCharacters(in: .whitespacesAndNewlines)

            // Extraer IP del endpoint remoto
            if case let .hostPort(host, _) = conn.currentPath?.remoteEndpoint ?? conn.endpoint {
                let ip = "\(host)"
                self.callback?(ip, name.isEmpty ? ip : name)
            }

            // Seguir escuchando más mensajes en la misma conexión
            self.readMessages(from: conn)
        }
    }
}
