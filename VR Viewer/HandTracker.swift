import ARKit
import Vision
import simd

// ─────────────────────────────────────────────
//  MARK: - HandTracker
//  Detecta manos usando Vision (VNDetectHumanHandPoseRequest)
//  sobre los mismos frames de cámara que ya usa ARKit para
//  el tracking de posición (PositionTracker). No abre una
//  sesión de cámara aparte (no se puede tener dos sesiones
//  de ARKit/cámara a la vez): PositionTracker le reenvía
//  cada ARFrame.
//
//  LIMITACIÓN IMPORTANTE: Vision solo da la posición 2D de
//  la muñeca en la imagen, no hay profundidad real (a menos
//  que el dispositivo tenga LiDAR, lo cual no asumimos aquí).
//  Por eso se asume una distancia fija frente a la cámara
//  (HAND_DISTANCE_METERS) para reconstruir una posición 3D
//  aproximada. Esto es una aproximación razonable para uso
//  como "mano virtual" en VR, pero no es tracking de
//  profundidad real. Si las manos se ven muy cerca/lejos de
//  lo esperado, ajusta HAND_DISTANCE_METERS o el FOV asumido.
// ─────────────────────────────────────────────

final class HandTracker {

    // Distancia asumida de la mano respecto a la cámara (metros).
    // Ajustable si las manos aparecen muy cerca/lejos en el visor.
    private let HAND_DISTANCE_METERS: Double = 0.45

    // FOV aproximado de la cámara trasera gran angular del iPhone.
    // No usamos los intrinsics directamente porque Vision devuelve
    // los puntos ya reorientados según `imageOrientation`, y mezclar
    // eso con los intrinsics nativos (que están en la orientación
    // original del sensor) da resultados incorrectos sin más trabajo.
    // Esta aproximación es suficiente para una mano "flotante" en VR.
    private let ASSUMED_HFOV_DEGREES: Double = 65
    private let ASSUMED_VFOV_DEGREES: Double = 50

    // Orientación de la imagen para Vision. La app usa el teléfono en
    // landscape (ver `alignZ` en MotionTracker). Si las manos salen
    // giradas o reflejadas, prueba cambiar a `.left` o `.up`/`.down`.
    private let imageOrientation: CGImagePropertyOrientation = .right

    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    // Solo procesamos 1 de cada N frames: Vision es costoso y no
    // necesitamos 60-90 Hz para manos.
    private let processEveryNFrames = 3
    private var frameCounter = 0

    // Resultado por mano: posición relativa (metros) + si se detectó
    // esta vez, más el estado de los dedos. Si no se detecta, se
    // mantiene la última posición conocida pero `tracked` pasa a
    // false tras un timeout.
    struct HandResult {
        var x: Double = 0
        var y: Double = 0
        var z: Double = 0
        var tracked: Bool = false

        // Grip: qué tan cerrado está el puño en general, 0 (abierta)
        // a 1 (cerrada). Se manda al campo "grip" del paquete, que es
        // lo que la mayoría de los juegos VR usan para detectar que
        // agarraste un objeto (además del esqueleto visual).
        var grip: Double = 0

        // Pinch: distancia pulgar-índice normalizada, 0 (separados) a
        // 1 (juntos). Útil para interacciones de precisión (botones,
        // gatillo fino).
        var pinch: Double = 0

        // Curl por dedo (thumb, index, middle, ring, pinky), 0..1
        // cada uno. Esto es lo que anima el esqueleto de la mano en
        // SteamVR dedo por dedo (ver HandSkeleton.h del driver).
        var curlThumb: Double = 0
        var curlIndex: Double = 0
        var curlMiddle: Double = 0
        var curlRing: Double = 0
        var curlPinky: Double = 0
    }

    typealias HandsCallback = (_ left: HandResult, _ right: HandResult) -> Void
    private var callback: HandsCallback?

    private var lastSeenLeft: Date?
    private var lastSeenRight: Date?
    private let trackingTimeout: TimeInterval = 0.5

    // FIX: antes solo se guardaba la FECHA de la última detección, y
    // cuando una mano no se detectaba en un frame puntual (algo muy
    // común: solo se procesa 1 de cada `processEveryNFrames`, y Vision
    // falla seguido) se enviaba un HandResult() por defecto — es decir,
    // posición (0,0,0) — aunque `tracked` siguiera en `true` por estar
    // dentro del timeout. Como VrUdpSender solo actualiza la posición
    // cuando `tracked == true`, esto hacía que la mano "saltara" al
    // origen (cerca de la cabeza) en la mayoría de los frames en vez
    // de mantenerse en su última posición real — percibido como manos
    // congeladas/pegadas en vez de seguir el movimiento. Ahora se
    // guarda el ÚLTIMO HandResult completo y se reutiliza mientras se
    // esté dentro del timeout.
    private var lastLeft: HandResult?
    private var lastRight: HandResult?

    func start(onHands: @escaping HandsCallback) {
        callback = onHands
        frameCounter = 0
        lastSeenLeft = nil
        lastSeenRight = nil
        lastLeft = nil
        lastRight = nil
    }

    func stop() {
        callback = nil
    }

    /// Llamado por PositionTracker con cada ARFrame nuevo y la posición
    /// de referencia actual (para expresar las manos en el mismo espacio
    /// recentrado que el HMD).
    func process(frame: ARFrame, referencePosition: SIMD3<Double>?) {
        guard let callback else { return }

        frameCounter += 1
        guard frameCounter % processEveryNFrames == 0 else { return }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.capturedImage,
            orientation: imageOrientation,
            options: [:]
        )

        do {
            try handler.perform([handPoseRequest])
        } catch {
            // No hay mano detectable en este frame o falló Vision; no es
            // un error fatal, simplemente no actualizamos nada ahora.
            return
        }

        guard let observations = handPoseRequest.results, !observations.isEmpty else {
            sendFallback(callback: callback)
            return
        }

        // Vision no indica directamente si una mano es izquierda o
        // derecha en todas las versiones de iOS, así que la inferimos
        // por su posición horizontal en la imagen: como la cámara
        // trasera mira hacia adelante (mismo sentido que la mirada del
        // usuario) y no hay espejo, la mano del usuario que aparece más
        // a la derecha de la imagen es su mano derecha.
        //
        // Para cada mano detectada juntamos: el punto de la muñeca
        // (posición) + los 20 puntos restantes (para curl por dedo).
        struct Candidate {
            let wristPoint: CGPoint
            let grip: Double
            let pinch: Double
            let curls: (thumb: Double, index: Double, middle: Double, ring: Double, pinky: Double)
        }

        var candidates: [Candidate] = []
        for obs in observations {
            guard let wrist = try? obs.recognizedPoint(.wrist), wrist.confidence > 0.3 else { continue }
            let curls = Self.computeCurls(obs)
            let (grip, pinch) = Self.computeGripPinch(obs, wrist: wrist.location, curls: curls)
            candidates.append(Candidate(wristPoint: wrist.location, grip: grip, pinch: pinch, curls: curls))
        }

        guard !candidates.isEmpty else {
            sendFallback(callback: callback)
            return
        }

        candidates.sort { $0.wristPoint.x < $1.wristPoint.x }

        let camTransform = frame.camera.transform
        let ref = referencePosition ?? SIMD3<Double>(
            Double(camTransform.columns.3.x),
            Double(camTransform.columns.3.y),
            Double(camTransform.columns.3.z)
        )

        func makeResult(_ c: Candidate) -> HandResult {
            let pos = worldPosition(from: c.wristPoint, camTransform: camTransform, referencePosition: ref)
            return HandResult(
                x: pos.x, y: pos.y, z: pos.z, tracked: true,
                grip: c.grip, pinch: c.pinch,
                curlThumb: c.curls.thumb, curlIndex: c.curls.index, curlMiddle: c.curls.middle,
                curlRing: c.curls.ring, curlPinky: c.curls.pinky
            )
        }

        var left: HandResult
        var right: HandResult

        if candidates.count == 1 {
            // Solo una mano visible: decidimos lado por si está en la
            // mitad izquierda o derecha del encuadre. El lado NO
            // detectado ahora usa el último resultado real conocido
            // (con `tracked` recalculado por timeout), en vez de
            // resetearse a (0,0,0).
            if candidates[0].wristPoint.x < 0.5 {
                let newLeft = makeResult(candidates[0])
                left = newLeft
                lastLeft = newLeft
                lastSeenLeft = Date()
                right = fallbackResult(lastRight, seenDate: lastSeenRight)
            } else {
                let newRight = makeResult(candidates[0])
                right = newRight
                lastRight = newRight
                lastSeenRight = Date()
                left = fallbackResult(lastLeft, seenDate: lastSeenLeft)
            }
        } else {
            // Dos manos: la de menor X de imagen = izquierda, mayor X = derecha
            let newLeft = makeResult(candidates[0])
            let newRight = makeResult(candidates[candidates.count - 1])
            left = newLeft
            right = newRight
            lastLeft = newLeft
            lastRight = newRight
            lastSeenLeft = Date()
            lastSeenRight = Date()
        }

        callback(left, right)
    }

    private func isRecentlyTracked(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) < trackingTimeout
    }

    /// Devuelve el último resultado real conocido para una mano, con
    /// `tracked` recalculado según el timeout. Si nunca se detectó esa
    /// mano, devuelve un resultado vacío (no tracked).
    private func fallbackResult(_ last: HandResult?, seenDate: Date?) -> HandResult {
        guard var result = last else { return HandResult(tracked: false) }
        result.tracked = isRecentlyTracked(seenDate)
        return result
    }

    private func sendFallback(callback: HandsCallback) {
        let left = fallbackResult(lastLeft, seenDate: lastSeenLeft)
        let right = fallbackResult(lastRight, seenDate: lastSeenRight)
        callback(left, right)
    }

    // Reconstruye una posición 3D aproximada a partir de un punto 2D
    // normalizado (coordenadas de Vision: origen abajo-izquierda, 0-1)
    // asumiendo una distancia fija frente a la cámara.
    private func worldPosition(
        from point: CGPoint,
        camTransform: simd_float4x4,
        referencePosition: SIMD3<Double>
    ) -> SIMD3<Double> {
        // Centrar: -1..1 en cada eje (x: derecha+, y: arriba+)
        let nx = (Double(point.x) - 0.5) * 2
        let ny = (Double(point.y) - 0.5) * 2

        let hfov = ASSUMED_HFOV_DEGREES * .pi / 180
        let vfov = ASSUMED_VFOV_DEGREES * .pi / 180

        let dx = tan(nx * hfov / 2) * HAND_DISTANCE_METERS
        let dy = tan(ny * vfov / 2) * HAND_DISTANCE_METERS
        let dz = -HAND_DISTANCE_METERS // la cámara "mira" hacia su -Z local

        // Punto en espacio de cámara (homogéneo)
        let camSpace = SIMD4<Double>(dx, dy, dz, 1)

        // Transform de cámara a mundo (convertimos a Double)
        let m = camTransform
        let worldM = double4x4(
            SIMD4<Double>(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z), Double(m.columns.0.w)),
            SIMD4<Double>(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z), Double(m.columns.1.w)),
            SIMD4<Double>(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z), Double(m.columns.2.w)),
            SIMD4<Double>(Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z), Double(m.columns.3.w))
        )

        let worldPoint4 = worldM * camSpace
        let worldPoint = SIMD3<Double>(worldPoint4.x, worldPoint4.y, worldPoint4.z)

        return worldPoint - referencePosition
    }

    // ── Curl por dedo + grip/pinch ───────────────────────────
    //  Vision (VNHumanHandPoseObservation) da los 21 puntos de la
    //  mano en 2D normalizado, igual que MediaPipe. Usamos el mismo
    //  método que la versión de Android (HandGestureCurl.kt): por
    //  cada dedo, el ángulo entre el segmento base→medio y el
    //  segmento medio→punta. Un dedo recto da ángulo ~0, doblado da
    //  un ángulo grande. Se salta la articulación intermedia (DIP /
    //  IP del pulgar) para simplificar, igual que en Android.

    private static func point(
        _ obs: VNHumanHandPoseObservation,
        _ joint: VNHumanHandPoseObservation.JointName
    ) -> CGPoint? {
        guard let p = try? obs.recognizedPoint(joint), p.confidence > 0.3 else { return nil }
        return p.location
    }

    private static func angleCurl(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
        let v1x = Double(b.x - a.x), v1y = Double(b.y - a.y)
        let v2x = Double(c.x - b.x), v2y = Double(c.y - b.y)
        let len1 = (v1x*v1x + v1y*v1y).squareRoot()
        let len2 = (v2x*v2x + v2y*v2y).squareRoot()
        guard len1 > 1e-6, len2 > 1e-6 else { return 0 }
        let dot = (v1x*v2x + v1y*v2y) / (len1 * len2)
        let angle = acos(min(1, max(-1, dot)))
        // Máximo empírico (~110°) en vez de 180°: un dedo real satura
        // antes, así que con esto curl=1.0 se alcanza con un puño real.
        let maxBendRad = 110.0 * .pi / 180.0
        return min(1, max(0, angle / maxBendRad))
    }

    private static func computeCurls(
        _ obs: VNHumanHandPoseObservation
    ) -> (thumb: Double, index: Double, middle: Double, ring: Double, pinky: Double) {
        func curl(
            _ a: VNHumanHandPoseObservation.JointName,
            _ b: VNHumanHandPoseObservation.JointName,
            _ c: VNHumanHandPoseObservation.JointName
        ) -> Double {
            guard let pa = point(obs, a), let pb = point(obs, b), let pc = point(obs, c) else { return 0 }
            return angleCurl(pa, pb, pc)
        }
        return (
            thumb:  curl(.thumbCMC, .thumbMP, .thumbTip),
            index:  curl(.indexMCP, .indexPIP, .indexTip),
            middle: curl(.middleMCP, .middlePIP, .middleTip),
            ring:   curl(.ringMCP, .ringPIP, .ringTip),
            pinky:  curl(.littleMCP, .littlePIP, .littleTip)
        )
    }

    /// grip = promedio del curl de los 4 dedos largos (sin el pulgar,
    /// igual que HandGesture.kt en Android). pinch = distancia
    /// pulgar-índice normalizada por el tamaño de la mano.
    private static func computeGripPinch(
        _ obs: VNHumanHandPoseObservation,
        wrist: CGPoint,
        curls: (thumb: Double, index: Double, middle: Double, ring: Double, pinky: Double)
    ) -> (grip: Double, pinch: Double) {
        let grip = (curls.index + curls.middle + curls.ring + curls.pinky) / 4.0

        var pinch = 0.0
        if let thumbTip = point(obs, .thumbTip),
           let indexTip = point(obs, .indexTip),
           let middleMCP = point(obs, .middleMCP) {
            let handSize = max(0.01, hypot(Double(middleMCP.x - wrist.x), Double(middleMCP.y - wrist.y)))
            let pinchDist = hypot(Double(thumbTip.x - indexTip.x), Double(thumbTip.y - indexTip.y)) / handSize
            pinch = min(1, max(0, 1 - pinchDist / 0.9))
        }
        return (grip, pinch)
    }
}
