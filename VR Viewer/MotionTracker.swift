import CoreMotion
import simd

// ─────────────────────────────────────────────
//  MARK: - MotionTracker
//  Usa CMMotionManager con DeviceMotion (fusión
//  giroscopio + acelerómetro + magnetómetro).
// ─────────────────────────────────────────────

final class MotionTracker {

    private let manager = CMMotionManager()

    private var refQuat: simd_quatd? = nil

    private let landscapeAlignAngle: Double = -.pi / 2
    private lazy var alignZ = simd_quatd(angle: landscapeAlignAngle, axis: SIMD3(0, 0, 1))

    typealias MotionCallback = (Double, Double, Double, Double, Double, Double, Double) -> Void
    private var callback: MotionCallback?

    func start(onMotion: @escaping MotionCallback) {
        guard manager.isDeviceMotionAvailable else {
            print("[MotionTracker] DeviceMotion no disponible en este dispositivo")
            return
        }
        callback = onMotion
        manager.deviceMotionUpdateInterval = 1.0 / 90.0

        manager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
        ) { [weak self] motion, error in
            if let error {
                print("[MotionTracker] Error: \(error.localizedDescription)")
                return
            }
            guard let self, let motion else { return }
            self.process(motion)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        callback = nil
    }

    func recenter() {
        refQuat = nil
    }

    private func process(_ motion: CMDeviceMotion) {
        let att = motion.attitude

        let raw = simd_quatd(
            ix: att.quaternion.x,
            iy: att.quaternion.y,
            iz: att.quaternion.z,
            r:  att.quaternion.w
        )

        let q = raw * alignZ

        if refQuat == nil {
            refQuat = q
        }
        let ref = refQuat!

        let relative = ref.inverse * q

        // FIX (real): los intentos anteriores negaban componentes del
        // cuaternión (primero solo Z, luego Y+Z) para "corregir" la
        // orientación. El primero era una reflexión inválida; el segundo
        // sí era una rotación propia (180° sobre X), pero sobre el eje
        // EQUIVOCADO — asumía que el eje X del cuaternión "relative" era
        // "derecha", cuando en realidad (ver docs de Apple sobre
        // CMAttitude) el frame local del dispositivo ya es:
        //   X = derecha, Y = arriba, Z = hacia el usuario (fuera de pantalla)
        // y tras aplicar `alignZ` (que solo reetiqueta ejes para el modo
        // landscape) sigue siendo X=derecha, Y=arriba, Z=hacia el usuario.
        // Esa es EXACTAMENTE la convención que usa OpenVR/SteamVR
        // (X=derecha, Y=arriba, Z=hacia el visor). Es decir: no hace
        // falta ningún flip ni intercambio de ejes.
        //
        // Al negar Y y Z se introducía una rotación extra de 180° sobre
        // X que mezclaba el eje de cabeceo (pitch) con el de guiñada
        // (yaw) en cualquier rotación compuesta grande. Con ángulos
        // pequeños (mirando casi al frente) el error era casi
        // imperceptible, pero al dar la vuelta (yaw ≈ 180°) y mirar
        // arriba/abajo, el pitch salía invertido — exactamente el bug
        // reportado. Enviamos el cuaternión relativo tal cual, sin
        // modificarlo.
        let qx = relative.imag.x
        let qy = relative.imag.y
        let qz = relative.imag.z
        let qw = relative.real

        let (roll, pitch, yaw) = Self.eulerDegrees(from: relative)

        callback?(qx, qy, qz, qw, roll, pitch, yaw)
    }

    private static func eulerDegrees(from q: simd_quatd) -> (Double, Double, Double) {
        let x = q.imag.x, y = q.imag.y, z = q.imag.z, w = q.real

        let sinr_cosp = 2 * (w * x + y * z)
        let cosr_cosp = 1 - 2 * (x * x + y * y)
        let roll = atan2(sinr_cosp, cosr_cosp)

        let sinp = 2 * (w * y - z * x)
        let pitch: Double
        if abs(sinp) >= 1 {
            pitch = copysign(.pi / 2, sinp)
        } else {
            pitch = asin(sinp)
        }

        let siny_cosp = 2 * (w * z + x * y)
        let cosy_cosp = 1 - 2 * (y * y + z * z)
        let yaw = atan2(siny_cosp, cosy_cosp)

        return (roll * 180 / .pi, pitch * 180 / .pi, yaw * 180 / .pi)
    }
}
