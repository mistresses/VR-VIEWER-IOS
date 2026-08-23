import SwiftUI
import UIKit
import AVFoundation
import CoreMotion
import Network
import Combine

// ─────────────────────────────────────────────
//  MARK: - Paleta
//  Acentos propios en vez de los azules/verdes por defecto de
//  sistema, para que la app tenga una identidad visual consistente
//  (se usan en toggles, indicadores de estado y el HUD de orientación).
// ─────────────────────────────────────────────

extension Color {
    /// Acento principal: usado en botones primarios y toggles activos.
    static let accentBlue = Color(red: 0.30, green: 0.55, blue: 1.0)
    /// Estado "en vivo / trackeado / conectado".
    static let accentGreen = Color(red: 0.30, green: 0.85, blue: 0.55)
    /// Fondo de tarjeta, un pelín más cálido que el negro puro.
    static let cardBackground = Color(red: 0.09, green: 0.09, blue: 0.11)
    /// Fondo de panel exterior (discovery, etc.)
    static let panelBackground = Color(red: 0.05, green: 0.05, blue: 0.065)
}

// ─────────────────────────────────────────────
//  MARK: - Modelo de estado principal
// ─────────────────────────────────────────────

@MainActor
final class VRViewModel: ObservableObject {

    // UI state
    @Published var connectionState: ConnectionState = .disconnected
    @Published var ipText:          String          = ""
    @Published var statusMessage:   String          = "Listo"
    @Published var discoveredPCs:   [DiscoveredPC]  = []
    @Published var scanning:        Bool            = false
    @Published var hmdEnabled:      Bool            = false
    @Published var connectedPCName: String          = ""

    // 6DOF - rotación (mostrar en UI)
    @Published var roll:  Double = 0
    @Published var pitch: Double = 0
    @Published var yaw:   Double = 0

    // 6DOF - posición (mostrar en UI), en metros
    @Published var posX: Double = 0
    @Published var posY: Double = 0
    @Published var posZ: Double = 0

    // Hand tracking (Vision), mostrar en UI si están trackeadas
    @Published var leftHandTracked:  Bool = false
    @Published var rightHandTracked: Bool = false

    // Captura de pantalla de SteamVR (video H.264 real, no fotos sueltas)
    @Published var showScreenCapture: Bool  = false
    @Published var screenConnected:   Bool   = false
    @Published var videoStatus: String = "Esperando stream"
    @Published var isFullscreenVideo: Bool   = false
    let videoDecoder = H264Decoder()

    private let sender          = VrUdpSender()
    private let discovery       = PcDiscovery()
    private let motion          = MotionTracker()
    private let position        = PositionTracker()
    private let screenReceiver  = ScreenCaptureReceiver()

    enum ConnectionState { case disconnected, connecting, connected }

    struct DiscoveredPC: Identifiable {
        let id    = UUID()
        let ip:   String
        let name: String
    }

    // ── Inicio ──────────────────────────────────────────────

    func startDiscovery() {
        discoveredPCs = []
        scanning      = true
        statusMessage = "Buscando PCs con SteamVR…"

        discovery.start { [weak self] ip, name in
            Task { @MainActor in
                guard let self else { return }
                if !self.discoveredPCs.contains(where: { $0.ip == ip }) {
                    self.discoveredPCs.append(DiscoveredPC(ip: ip, name: name))
                    self.statusMessage = "PC encontrada: \(name)"
                }
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                self.scanning = false
                if self.discoveredPCs.isEmpty {
                    self.statusMessage = "No se encontró ninguna PC"
                }
            }
        }
    }

    func connect(ip: String) {
        guard !ip.isEmpty else { statusMessage = "Ingresa una IP válida"; return }
        connectionState = .connecting
        statusMessage   = "Conectando…"
        discovery.stop()

        Task {
            do {
                try await sender.connect(to: ip)
                await MainActor.run {
                    self.connectionState = .connected
                    self.statusMessage   = "Conectado ✓"
                    self.connectedPCName = ip
                }
                startMotion()
                startPositionTracking()
                startHandTracking()
                startSendLoop()
            } catch {
                await MainActor.run {
                    self.connectionState = .disconnected
                    self.statusMessage   = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    func disconnect() {
        motion.stop()
        position.stop()
        screenReceiver.disconnect()
        sender.stop()
        connectionState    = .disconnected
        statusMessage      = "Desconectado"
        connectedPCName    = ""
        hmdEnabled         = false
        showScreenCapture  = false
        screenConnected    = false
        isFullscreenVideo  = false
        videoDecoder.reset()
        videoStatus = "Esperando stream"
    }

    func recenter() {
        motion.recenter()
        position.recenter()
        statusMessage = "Recentrado ✓"
    }

    func toggleHmd(_ enabled: Bool) {
        if enabled { motion.recenter(); position.recenter() }
        sender.setHmdEnabled(enabled)
        statusMessage = enabled ? "HMD activado" : "HMD desactivado"
    }

    // ── Captura de pantalla SteamVR ──────────────────────────

    func toggleScreenCapture(_ enabled: Bool) {
        guard !connectedPCName.isEmpty else { return }

        if enabled {
            statusMessage = "Conectando a la pantalla de SteamVR…"
            videoDecoder.reset()
            videoDecoder.onStats = { [weak self] stats in
                Task { @MainActor in
                    guard let self else { return }

                    if !stats.lastError.isEmpty {
                        self.videoStatus = stats.lastError
                    } else if stats.framesDecoded > 0 {
                        self.videoStatus = "Transmitiendo en vivo"
                    } else if stats.bytesReceived > 0 {
                        self.videoStatus = "Recibiendo stream…"
                    }
                }
            }

            screenReceiver.onStats = { [weak self] message in
                Task { @MainActor in
                    if message.contains("connected") { self?.videoStatus = message }
                    else if message.contains("failed") || message.contains("error") { self?.videoStatus = message }
                }
            }

            // `didSignalConnected` es local a esta clausura (no una
            // propiedad del ViewModel @MainActor), así que se puede leer
            // y escribir de forma segura desde el hilo de red sin saltar
            // de actor en cada frame — solo saltamos a MainActor la
            // primera vez, para actualizar el estado de la UI.
            var didSignalConnected = false

            // Capturamos `videoDecoder` directamente (no `self.videoDecoder`):
            // así el acceso dentro de la clausura no depende del aislamiento
            // de actor de VRViewModel. decode() es seguro de llamar desde
            // cualquier hilo (AVSampleBufferDisplayLayer lo permite), y
            // hacerlo aquí evita saltar a MainActor en cada frame de video.
            screenReceiver.connect(to: connectedPCName) { [videoDecoder, weak self] data in
                videoDecoder.decode(data)
                guard !didSignalConnected else { return }
                didSignalConnected = true
                Task { @MainActor in self?.screenConnected = true }
            }
        } else {
            screenReceiver.disconnect()
            screenConnected   = false
            isFullscreenVideo = false
            videoDecoder.reset()
            videoStatus = "Stream detenido"
        }
    }

    func toggleFullscreenVideo() {
        isFullscreenVideo.toggle()
    }

    // ── Motion (rotación) ────────────────────────────────────

    private func startMotion() {
        motion.start { [weak self] qx, qy, qz, qw, roll, pitch, yaw in
            Task { @MainActor in
                self?.roll  = roll
                self?.pitch = pitch
                self?.yaw   = yaw
            }
            self?.sender.updateHMDRotation(qx: qx, qy: qy, qz: qz, qw: qw)
        }
    }

    // ── Position (traslación, ARKit) ─────────────────────────

    private func startPositionTracking() {
        position.start { [weak self] x, y, z in
            Task { @MainActor in
                self?.posX = x
                self?.posY = y
                self?.posZ = z
            }
            self?.sender.updateHMDPosition(x: x, y: y, z: z)
        }
    }

    // ── Hand tracking (Vision, sobre los frames de ARKit) ────

    private func startHandTracking() {
        position.startHandTracking { [weak self] left, right in
            guard let self else { return }
            self.sender.updateHandPosition(
                isLeft: true, x: left.x, y: left.y, z: left.z, tracked: left.tracked,
                grip: left.grip, pinch: left.pinch,
                curlThumb: left.curlThumb, curlIndex: left.curlIndex, curlMiddle: left.curlMiddle,
                curlRing: left.curlRing, curlPinky: left.curlPinky
            )
            self.sender.updateHandPosition(
                isLeft: false, x: right.x, y: right.y, z: right.z, tracked: right.tracked,
                grip: right.grip, pinch: right.pinch,
                curlThumb: right.curlThumb, curlIndex: right.curlIndex, curlMiddle: right.curlMiddle,
                curlRing: right.curlRing, curlPinky: right.curlPinky
            )
            Task { @MainActor in
                self.leftHandTracked  = left.tracked
                self.rightHandTracked = right.tracked
            }
        }
    }

    // ── Send loop ~90 Hz ────────────────────────────────────

    private func startSendLoop() {
        Task {
            while self.connectionState == .connected {
                sender.sendPacket()
                try? await Task.sleep(nanoseconds: 11_000_000) // ~90 fps
            }
        }
    }
}

// ─────────────────────────────────────────────
//  MARK: - Vista principal
// ─────────────────────────────────────────────

struct ContentView: View {
    @StateObject private var vm = VRViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch vm.connectionState {
            case .disconnected, .connecting:
                ConnectView(vm: vm)
            case .connected:
                ControlView(vm: vm)
            }

            if vm.isFullscreenVideo {
                FullscreenVideoView(vm: vm)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear { vm.startDiscovery() }
        .preferredColorScheme(.dark)
        .statusBarHidden(vm.isFullscreenVideo)
        .animation(.easeInOut(duration: 0.2), value: vm.isFullscreenVideo)
    }
}

// ─────────────────────────────────────────────
//  MARK: - Video en pantalla completa
//  Cubre toda la pantalla (ignora safe areas) con la capa de video
//  real. Un solo tap muestra/oculta los controles superpuestos, para
//  que el video quede completamente limpio mientras se usa en el
//  headset.
// ─────────────────────────────────────────────

struct FullscreenVideoView: View {
    @ObservedObject var vm: VRViewModel
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VideoLayerView(decoder: vm.videoDecoder, videoGravity: .resizeAspectFill)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) { showControls.toggle() }
                }

            if showControls {
                Button {
                    vm.toggleFullscreenVideo()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.top, 16)
                .padding(.trailing, 16)
                .transition(.opacity)
            }
        }
    }
}

// ─────────────────────────────────────────────
//  MARK: - Panel de conexión
// ─────────────────────────────────────────────

struct ConnectView: View {
    @ObservedObject var vm: VRViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // Header
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentBlue.opacity(0.35), Color.accentGreen.opacity(0.15)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 64, height: 64)
                        Image(systemName: "visionpro")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(.white)
                    }
                    Text("VR Viewer")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Text("Conecta tu PC con SteamVR")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding(.top, 40)

                // Discovery
                VStack(alignment: .leading, spacing: 10) {
                    Label("DETECCIÓN AUTOMÁTICA", systemImage: "wifi")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .textCase(.uppercase)

                    Text(vm.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    if vm.scanning {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                    }

                    ForEach(vm.discoveredPCs) { pc in
                        Button {
                            vm.ipText = pc.ip
                            vm.connect(ip: pc.ip)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(pc.name)
                                    .font(.subheadline)
                                    .bold()
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color(white: 0.12))
                            .cornerRadius(10)
                            .foregroundColor(.white)
                        }
                    }

                    Button {
                        vm.startDiscovery()
                    } label: {
                        Label("Buscar de nuevo", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(vm.scanning)
                }
                .padding()
                .background(Color.panelBackground)
                .cornerRadius(16)

                // Manual IP
                VStack(alignment: .leading, spacing: 10) {
                    Text("O INTRODUCE LA IP MANUALMENTE")
                        .font(.caption2)
                        .foregroundColor(.gray)

                    TextField("192.168.1.X", text: $vm.ipText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button {
                        vm.connect(ip: vm.ipText.trimmingCharacters(in: .whitespaces))
                    } label: {
                        Group {
                            if vm.connectionState == .connecting {
                                ProgressView().tint(.white)
                            } else {
                                Text("CONECTAR")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .background(Color.accentBlue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .disabled(vm.connectionState == .connecting)
                }
                .padding()
                .background(Color.panelBackground)
                .cornerRadius(16)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }
}

// ─────────────────────────────────────────────
//  MARK: - Panel de control (conectado)
// ─────────────────────────────────────────────

struct ControlView: View {
    @ObservedObject var vm: VRViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VR Viewer")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                    if !vm.connectedPCName.isEmpty {
                        Text(vm.connectedPCName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.accentGreen)
                        .frame(width: 7, height: 7)
                    Text("Conectado")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.accentGreen)
                }
            }
            .padding()
            .background(Color.cardBackground)

            ScrollView {
                VStack(spacing: 16) {

                    // 6DOF live data: rotación + posición
                    OrientationCard(roll: vm.roll, pitch: vm.pitch, yaw: vm.yaw)
                    PositionCard(x: vm.posX, y: vm.posY, z: vm.posZ)
                    HandsCard(leftTracked: vm.leftHandTracked, rightTracked: vm.rightHandTracked)

                    // Captura de pantalla SteamVR (video H.264 en vivo)
                    ScreenCaptureCard(
                        enabled: Binding(
                            get: { vm.showScreenCapture },
                            set: { newValue in
                                vm.showScreenCapture = newValue
                                vm.toggleScreenCapture(newValue)
                            }
                        ),
                        connected: vm.screenConnected,
                        decoder: vm.videoDecoder,
                        videoStatus: vm.videoStatus,
                        isFullscreenActive: vm.isFullscreenVideo,
                        onExpand: { vm.toggleFullscreenVideo() }
                    )

                    // HMD Toggle
                    ControlCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("HMD Tracking")
                                    .foregroundColor(.white)
                                Text("Giroscopio + posición (ARKit)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $vm.hmdEnabled)
                                .onChange(of: vm.hmdEnabled) { _, newValue in
                                    vm.toggleHmd(newValue)
                                }
                                .labelsHidden()
                        }
                    }

                    // Recentrar
                    Button {
                        vm.recenter()
                    } label: {
                        Label("Recentrar HMD", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(white: 0.15))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    // Status
                    Text(vm.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    // Desconectar
                    Button(role: .destructive) {
                        vm.disconnect()
                    } label: {
                        Label("Desconectar", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.red.opacity(0.2))
                            .foregroundColor(.red)
                            .cornerRadius(12)
                    }
                }
                .padding()
            }
        }
    }
}

// ─────────────────────────────────────────────
//  MARK: - Subvistas auxiliares
// ─────────────────────────────────────────────

struct OrientationCard: View {
    let roll: Double
    let pitch: Double
    let yaw: Double

    var body: some View {
        ControlCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Orientación 6DOF")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 0) {
                    AxisValue(label: "ROLL",  value: roll,  color: .red)
                    AxisValue(label: "PITCH", value: pitch, color: .green)
                    AxisValue(label: "YAW",   value: yaw,   color: .blue)
                }

                OrientationIndicator(roll: roll, pitch: pitch, yaw: yaw)
                    .frame(height: 80)
            }
        }
    }
}

struct PositionCard: View {
    let x: Double
    let y: Double
    let z: Double

    var body: some View {
        ControlCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Posición 6DOF (metros)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 0) {
                    AxisValueMeters(label: "X", value: x, color: .red)
                    AxisValueMeters(label: "Y", value: y, color: .green)
                    AxisValueMeters(label: "Z", value: z, color: .blue)
                }

                Text("Requiere ARKit (cámara trasera libre, buena luz)")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
    }
}

struct HandsCard: View {
    let leftTracked: Bool
    let rightTracked: Bool

    var body: some View {
        ControlCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Manos (Vision)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 24) {
                    HandStatus(label: "IZQUIERDA", tracked: leftTracked)
                    HandStatus(label: "DERECHA", tracked: rightTracked)
                }

                Text("Muestra las manos frente a la cámara trasera")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
    }
}

struct HandStatus: View {
    let label: String
    let tracked: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tracked ? "hand.raised.fill" : "hand.raised.slash")
                .foregroundColor(tracked ? .green : .gray)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(tracked ? "Detectada" : "Sin detectar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
        }
    }
}

struct ScreenCaptureCard: View {
    @Binding var enabled: Bool
    let connected: Bool
    let decoder: H264Decoder
    let videoStatus: String
    let isFullscreenActive: Bool
    let onExpand: () -> Void

    var body: some View {
        ControlCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pantalla de SteamVR")
                            .foregroundColor(.white)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(connected ? Color.accentGreen : Color.gray.opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text(connected ? "Transmitiendo en vivo" : "Ver la pantalla del PC")
                                .font(.caption)
                                .foregroundColor(connected ? .accentGreen : .secondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .tint(.accentBlue)
                }

                if enabled {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(connected ? Color.accentGreen : Color.gray.opacity(0.5))
                            .frame(width: 6, height: 6)

                        Text(videoStatus)
                            .font(.caption2)
                            .foregroundColor(connected ? .accentGreen : .secondary)

                        Spacer()
                    }

                    ZStack(alignment: .bottomTrailing) {
                        Group {
                            // FIX: un AVSampleBufferDisplayLayer solo puede
                            // tener un padre a la vez. Antes esta miniatura
                            // Y la vista de pantalla completa montaban la
                            // MISMA capa (`decoder.displayLayer`) al mismo
                            // tiempo — la que se agregaba después le
                            // "robaba" la capa a la otra, dejándola en
                            // negro (y como SwiftUI puede re-renderizar
                            // ambas vistas en cualquier momento por los
                            // datos de tracking a 90Hz, el robo podía pasar
                            // en cualquier sentido, incluso afectando la de
                            // pantalla completa). Ahora, mientras el modo
                            // pantalla completa está activo, esta miniatura
                            // NO monta la capa — solo se muestra un aviso.
                            if isFullscreenActive {
                                ZStack {
                                    Rectangle().fill(Color.black)
                                    VStack(spacing: 6) {
                                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                                            .foregroundColor(.gray)
                                        Text("Mostrando en pantalla completa")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                            } else if connected {
                                VideoLayerView(decoder: decoder, videoGravity: .resizeAspect)
                            } else {
                                ZStack {
                                    Rectangle().fill(Color.black)
                                    VStack(spacing: 10) {
                                        ProgressView().tint(.white)
                                        Text("Conectando al stream…")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                        }
                        .aspectRatio(16/9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )

                        if connected && !isFullscreenActive {
                            Button(action: onExpand) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .padding(8)
                        }
                    }
                }
            }
        }
    }
}

struct AxisValue: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
            Text(String(format: "%.1f°", value))
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

struct AxisValueMeters: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
            Text(String(format: "%.2f m", value))
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

struct OrientationIndicator: View {
    let roll: Double
    let pitch: Double
    let yaw: Double

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2
            let r  = min(cx, cy) - 8

            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    .frame(width: r * 2, height: r * 2)
                    .position(x: cx, y: cy)

                Path { p in
                    p.move(to: CGPoint(x: cx - r, y: cy))
                    p.addLine(to: CGPoint(x: cx + r, y: cy))
                    p.move(to: CGPoint(x: cx, y: cy - r))
                    p.addLine(to: CGPoint(x: cx, y: cy + r))
                }
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)

                let px = cx + CGFloat(sin(yaw   * .pi / 180)) * r * 0.5
                let py = cy - CGFloat(sin(pitch * .pi / 180)) * r * 0.5

                Circle()
                    .fill(Color.blue)
                    .frame(width: 10, height: 10)
                    .position(x: px, y: py)

                Path { p in
                    let angle = CGFloat(roll * .pi / 180)
                    p.move(to: CGPoint(x: cx - cos(angle) * r * 0.6,
                                       y: cy + sin(angle) * r * 0.6))
                    p.addLine(to: CGPoint(x: cx + cos(angle) * r * 0.6,
                                          y: cy - sin(angle) * r * 0.6))
                }
                .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
            }
        }
    }
}

struct ControlCard<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        content()
            .padding()
            .background(Color.cardBackground)
            .cornerRadius(14)
    }
}

#Preview {
    ContentView()
}
