import Foundation
import Network
import CryptoKit

// ─────────────────────────────────────────────
//  MARK: - VrUdpSender
//  Protocolo idéntico al de la app Android:
//    • Autenticación HMAC-SHA256 en puerto 47292
//    • Datos de tracking UDP en puerto 47291
//    • Paquete de 156 bytes (39 floats)
// ─────────────────────────────────────────────

// Pequeño guardián thread-safe para asegurar que una continuation
// solo se resuelva una vez, incluso si varios contextos concurrentes
// intentan llamarla (requerido por el modo de concurrencia de Swift 6).
nonisolated final class ResumeGuard: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

final class VrUdpSender {

    // Puertos (mismos que el driver C++)
    private let DATA_PORT: UInt16 = 47291
    private let AUTH_PORT: UInt16 = 47292

    // Clave HMAC (idéntica al driver y Android)
    private let secret: [UInt8] = [
        0x4b, 0x3a, 0x1f, 0x08,
        0xc2, 0x77, 0x9e, 0x34,
        0x05, 0xab, 0x61, 0xd9,
        0xf8, 0x2e, 0x47, 0xbc
    ]

    // Estado de sesión
    private var sessionToken: UInt32 = 0
    private var isAuthenticated = false
    private var pcHost: String = ""

    // Sockets NWConnection
    private var dataConn: NWConnection?
    private var authConn: NWConnection?

    // Datos de tracking (protegidos con lock ligero)
    private var hmdQx: Float = 0
    private var hmdQy: Float = 0
    private var hmdQz: Float = 0
    private var hmdQw: Float = 1
    private var hmdEnabled = false

    // Posición 6DOF del HMD (ARKit). Por defecto 1.6 m de altura de pie,
    // igual que el valor fijo que se usaba antes.
    private var hmdPosX: Float = 0
    private var hmdPosY: Float = 1.6
    private var hmdPosZ: Float = 0

    // Manos izquierda/derecha. Se inicializan con una posición "de
    // reposo" por defecto y se actualizan en tiempo real con
    // HandTracker (Vision) cuando hay una mano detectada; si no,
    // se mantiene la última posición conocida pero `tracked` = false.
    private var leftX:  Float = -0.35
    private var leftY:  Float =  0.10
    private var leftZ:  Float = -0.50
    private var leftTracked: Bool = false
    private var leftGrip: Float = 0
    private var leftTrigger: Float = 0
    private var leftCurl: (thumb: Float, index: Float, middle: Float, ring: Float, pinky: Float) = (0,0,0,0,0)

    private var rightX: Float =  0.35
    private var rightY: Float =  0.10
    private var rightZ: Float = -0.50
    private var rightTracked: Bool = false
    private var rightGrip: Float = 0
    private var rightTrigger: Float = 0
    private var rightCurl: (thumb: Float, index: Float, middle: Float, ring: Float, pinky: Float) = (0,0,0,0,0)

    // ── Conexión ────────────────────────────────────────────

    func connect(to host: String) async throws {
        pcHost = host
        try await authenticate(host: host)
    }

    func stop() {
        dataConn?.cancel()
        authConn?.cancel()
        isAuthenticated = false
        sessionToken    = 0
    }

    // ── API pública ─────────────────────────────────────────

    func setHmdEnabled(_ enabled: Bool) {
        hmdEnabled = enabled
    }

    func updateHMDRotation(qx: Double, qy: Double, qz: Double, qw: Double) {
        guard hmdEnabled else { return }
        hmdQx = Float(qx)
        hmdQy = Float(qy)
        hmdQz = Float(qz)
        hmdQw = Float(qw)
    }

    /// Actualiza la posición 6DOF del HMD (proviene de PositionTracker/ARKit).
    /// Se suma 1.6 m en Y como altura base de pie, ya que ARKit reporta la
    /// posición relativa al punto de recentrado (que suele estar a la altura
    /// de la cámara, no del suelo).
    func updateHMDPosition(x: Double, y: Double, z: Double) {
        guard hmdEnabled else { return }
        hmdPosX = Float(x)
        hmdPosY = Float(y) + 1.6
        hmdPosZ = Float(z)
    }

    /// Actualiza la posición de una mano (proviene de HandTracker/Vision),
    /// junto con el grip general (puño cerrado, 0..1), el pinch (0..1,
    /// usado como "trigger") y el curl por dedo (para animar el
    /// esqueleto de la mano en SteamVR).
    ///
    /// FIX: antes se sumaban 1.6 m en Y igual que al HMD ("altura de
    /// pie"), pero el driver del PC trata x/y/z de la mano como un
    /// OFFSET RELATIVO a la posición/rotación del HMD (ver
    /// CMyController::GetPose en el driver: `lx = h->x + OX...` y
    /// después se multiplica por la matriz del HMD), NO como una
    /// posición absoluta respecto al suelo. Sumarle 1.6 m corría la
    /// mano 1.6 m por encima de donde debía estar relativo a la
    /// cabeza — por eso las manos aparecían muy arriba del usuario en
    /// SteamVR. Ahora se manda x/y/z tal cual, sin ese offset.
    func updateHandPosition(
        isLeft: Bool, x: Double, y: Double, z: Double, tracked: Bool,
        grip: Double = 0, pinch: Double = 0,
        curlThumb: Double = 0, curlIndex: Double = 0, curlMiddle: Double = 0,
        curlRing: Double = 0, curlPinky: Double = 0
    ) {
        guard hmdEnabled else { return }
        if isLeft {
            if tracked {
                leftX = Float(x)
                leftY = Float(y)
                leftZ = Float(z)
                leftGrip = Float(grip)
                leftTrigger = Float(pinch)
                leftCurl = (Float(curlThumb), Float(curlIndex), Float(curlMiddle), Float(curlRing), Float(curlPinky))
            }
            leftTracked = tracked
        } else {
            if tracked {
                rightX = Float(x)
                rightY = Float(y)
                rightZ = Float(z)
                rightGrip = Float(grip)
                rightTrigger = Float(pinch)
                rightCurl = (Float(curlThumb), Float(curlIndex), Float(curlMiddle), Float(curlRing), Float(curlPinky))
            }
            rightTracked = tracked
        }
    }

    // ── Autenticación (TCP-like sobre UDP con timeouts) ──────

    private func authenticate(host: String) async throws {
        // Crear conexión UDP al puerto de auth
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: AUTH_PORT)!
        )
        let conn = NWConnection(to: endpoint, using: .udp)
        authConn = conn

        return try await withCheckedThrowingContinuation { cont in
            let resumeGuard = ResumeGuard()

            @Sendable func finish(_ result: Result<Void, Error>) {
                guard resumeGuard.tryResume() else { return }
                cont.resume(with: result)
            }

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.doHandshake(conn: conn)
                            finish(.success(()))
                        } catch {
                            finish(.failure(error))
                        }
                    }
                case .failed(let err):
                    finish(.failure(err))
                default: break
                }
            }
            conn.start(queue: .global())

            // Timeout 6 s
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                finish(.failure(VRError.timeout))
            }
        }
    }

    private func doHandshake(conn: NWConnection) async throws {
        // 1. Enviar CVRHELLO
        let hello = Data("CVRHELLO".utf8)
        try await send(conn: conn, data: hello)

        // 2. Recibir CHLG + 8 bytes de challenge
        let chlgData = try await receive(conn: conn, minBytes: 12)
        guard chlgData.count >= 12,
              String(data: chlgData.prefix(4), encoding: .ascii) == "CHLG"
        else { throw VRError.badResponse }

        let challenge = chlgData[4..<12]

        // 3. Calcular HMAC-SHA256 (primeros 8 bytes)
        let keyData  = Data(secret)
        let symKey   = SymmetricKey(data: keyData)
        let mac      = HMAC<SHA256>.authenticationCode(for: challenge, using: symKey)
        let hmac8    = Data(mac.prefix(8))

        // 4. Enviar RESP + hmac8
        var resp = Data("RESP".utf8)
        resp.append(hmac8)
        try await send(conn: conn, data: resp)

        // 5. Recibir TOKN + token (4 bytes)
        let toknData = try await receive(conn: conn, minBytes: 8)
        guard toknData.count >= 8,
              String(data: toknData.prefix(4), encoding: .ascii) == "TOKN"
        else { throw VRError.authFailed }

        // FIX: antes se usaba `toknData[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }`,
        // lo cual puede crashear con "Fatal error: load from misaligned raw pointer"
        // porque el slice de Data conserva los índices originales (4..<8) y el buffer
        // subyacente no siempre está alineado a 4 bytes. Decodificamos manualmente
        // byte a byte (little-endian) para evitar el crash sin importar el offset.
        let tokenBytes = [UInt8](toknData[4..<8])
        sessionToken = UInt32(tokenBytes[0])
                     | (UInt32(tokenBytes[1]) << 8)
                     | (UInt32(tokenBytes[2]) << 16)
                     | (UInt32(tokenBytes[3]) << 24)

        isAuthenticated = true

        // Abrir socket de datos UDP
        let dataEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(pcHost),
            port: NWEndpoint.Port(rawValue: DATA_PORT)!
        )
        dataConn = NWConnection(to: dataEndpoint, using: .udp)
        dataConn?.start(queue: .global())
    }

    // ── Envío del paquete de tracking ───────────────────────

    func sendPacket() {
        guard isAuthenticated, let conn = dataConn else { return }

        // FIX: el driver del PC (versión que agrega tracking de dedos
        // vía MediaPipe/Android) espera 49 floats × 4 bytes = 196 bytes
        // por paquete: token(1) + left(20) + right(20) + hmd(8). El
        // formato viejo (39 floats/156 bytes, sin curl por dedo) hace
        // que `ProcessData()` en el driver descarte TODOS los paquetes
        // (`if (n != PACKET_BYTES) continue;`), aunque la autenticación
        // se complete bien.
        //
        // Grip/trigger/curl por dedo ahora vienen de HandTracker
        // (Vision detecta los 21 puntos de la mano, no solo la
        // muñeca), así que el puño cerrado sí "agarra" objetos en
        // SteamVR (via el campo grip) y los dedos se doblan
        // individualmente en el esqueleto (via curlThumb..curlPinky).
        var buf = Data(capacity: 196)

        // Token
        var tokenF = Float(bitPattern: sessionToken)
        buf.append(floatBytes(&tokenF))

        // Mano izquierda. Rotación identidad (Vision da los 21 puntos
        // en 2D, no una orientación 3D confiable de la muñeca).
        buf.append(handData(
            x: leftX, y: leftY, z: leftZ,
            qx: 0, qy: 0, qz: 0, qw: 1,
            trigger: leftTrigger, grip: leftGrip, joyX: 0, joyY: 0,
            sys: 0, app: 0, click: 0, tracked: leftTracked ? 1 : 0,
            curlThumb: leftCurl.thumb, curlIndex: leftCurl.index, curlMiddle: leftCurl.middle,
            curlRing: leftCurl.ring, curlPinky: leftCurl.pinky
        ))

        // Mano derecha
        buf.append(handData(
            x: rightX, y: rightY, z: rightZ,
            qx: 0, qy: 0, qz: 0, qw: 1,
            trigger: rightTrigger, grip: rightGrip, joyX: 0, joyY: 0,
            sys: 0, app: 0, click: 0, tracked: rightTracked ? 1 : 0,
            curlThumb: rightCurl.thumb, curlIndex: rightCurl.index, curlMiddle: rightCurl.middle,
            curlRing: rightCurl.ring, curlPinky: rightCurl.pinky
        ))

        // HMD: ahora usa la posición 6DOF real (ARKit) en vez del valor fijo
        var hx = hmdPosX, hy = hmdPosY, hz = hmdPosZ
        buf.append(floatBytes(&hx))
        buf.append(floatBytes(&hy))
        buf.append(floatBytes(&hz))

        if hmdEnabled {
            buf.append(floatBytes(&hmdQx))
            buf.append(floatBytes(&hmdQy))
            buf.append(floatBytes(&hmdQz))
            buf.append(floatBytes(&hmdQw))
            var tracked: Float = 1
            buf.append(floatBytes(&tracked))
        } else {
            var z: Float = 0, one: Float = 1
            buf.append(floatBytes(&z))
            buf.append(floatBytes(&z))
            buf.append(floatBytes(&z))
            buf.append(floatBytes(&one))
            buf.append(floatBytes(&z))
        }

        conn.send(content: buf, completion: .idempotent)
    }

    // ── Helpers ─────────────────────────────────────────────

    private func handData(
        x: Float, y: Float, z: Float,
        qx: Float, qy: Float, qz: Float, qw: Float,
        trigger: Float, grip: Float,
        joyX: Float, joyY: Float,
        sys: Float, app: Float, click: Float,
        tracked: Float,
        curlThumb: Float, curlIndex: Float, curlMiddle: Float, curlRing: Float, curlPinky: Float
    ) -> Data {
        // Orden EXACTO del struct HandData del driver (20 floats):
        // x,y,z,qx,qy,qz,qw,trigger,grip,joyX,joyY,sysBtn,appBtn,clickBtn,isTracked,
        // curlThumb,curlIndex,curlMiddle,curlRing,curlPinky
        var vals: [Float] = [x, y, z, qx, qy, qz, qw,
                             trigger, grip, joyX, joyY,
                             sys, app, click, tracked,
                             curlThumb, curlIndex, curlMiddle, curlRing, curlPinky]
        return Data(bytes: &vals, count: vals.count * 4)
    }

    private func floatBytes(_ f: inout Float) -> Data {
        Data(bytes: &f, count: 4)
    }

    private func send(conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) }
                else        { cont.resume() }
            })
        }
    }

    private func receive(conn: NWConnection, minBytes: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receiveMessage { data, _, _, err in
                if let err  { cont.resume(throwing: err); return }
                if let data { cont.resume(returning: data) }
                else        { cont.resume(throwing: VRError.noData) }
            }
        }
    }
}

// ─────────────────────────────────────────────
//  MARK: - Errores
// ─────────────────────────────────────────────

enum VRError: LocalizedError {
    case timeout, badResponse, authFailed, noData

    var errorDescription: String? {
        switch self {
        case .timeout:     return "Tiempo de espera agotado"
        case .badResponse: return "Respuesta inesperada del driver"
        case .authFailed:  return "Autenticación fallida"
        case .noData:      return "Sin datos recibidos"
        }
    }
}
