import ARKit
import simd

// ─────────────────────────────────────────────
//  MARK: - PositionTracker
//  CoreMotion (MotionTracker) solo da ROTACIÓN.
//  Para 6DOF completo necesitamos también la
//  POSICIÓN (X, Y, Z), que se obtiene con ARKit
//  (odometría visual-inercial vía cámara).
// ─────────────────────────────────────────────

final class PositionTracker: NSObject {

    private let session = ARSession()
    private var refPosition: SIMD3<Double>? = nil

    // Callback: (x, y, z) en metros, ya recentrados
    typealias PositionCallback = (Double, Double, Double) -> Void
    private var callback: PositionCallback?

    // Hand tracking: reutiliza los mismos frames de la cámara ARKit
    // (no se puede correr una segunda sesión de cámara en paralelo).
    private let handTracker = HandTracker()
    typealias HandsCallback = HandTracker.HandsCallback
    private var handsCallback: HandsCallback?

    // ── Inicio ──────────────────────────────────────────────

    func start(onPosition: @escaping PositionCallback) {
        guard ARWorldTrackingConfiguration.isSupported else {
            print("[PositionTracker] ARKit World Tracking no soportado en este dispositivo")
            return
        }
        callback = onPosition
        refPosition = nil

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity     // Y hacia arriba, alineado con la gravedad
        config.planeDetection = []           // no necesitamos detectar planos
        config.isAutoFocusEnabled = true

        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Activa la detección de manos (Vision) sobre los frames de esta
    /// misma sesión ARKit. Debe llamarse después de `start(onPosition:)`.
    func startHandTracking(onHands: @escaping HandsCallback) {
        handsCallback = onHands
        handTracker.start(onHands: onHands)
    }

    func stopHandTracking() {
        handTracker.stop()
        handsCallback = nil
    }

    func stop() {
        session.pause()
        callback = nil
        refPosition = nil
        stopHandTracking()
    }

    func recenter() {
        refPosition = nil   // se recalcula con el próximo frame de ARKit
    }

    // ── Procesamiento ────────────────────────────────────────

    private func handle(_ frame: ARFrame) {
        let t = frame.camera.transform.columns.3
        let pos = SIMD3<Double>(Double(t.x), Double(t.y), Double(t.z))

        if refPosition == nil {
            refPosition = pos
        }
        let rel = pos - refPosition!

        // ARKit: X derecha, Y arriba, Z hacia el usuario (fuera de pantalla).
        // Avance/retroceso estaba invertido con el signo anterior (-rel.z),
        // así que ahora se envía rel.z directamente (sin invertir).
        callback?(rel.x, rel.y, rel.z)

        // Reenviamos el mismo frame al detector de manos (si está activo),
        // usando la misma posición de referencia para que las manos queden
        // expresadas en el mismo espacio recentrado que el HMD.
        if handsCallback != nil {
            handTracker.process(frame: frame, referencePosition: refPosition)
        }
    }
}

extension PositionTracker: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        handle(frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        print("[PositionTracker] Error de sesión ARKit: \(error.localizedDescription)")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // Tras una interrupción (llamada, cambio de app, etc.) recentramos
        recenter()
    }
}
