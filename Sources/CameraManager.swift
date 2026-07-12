//
//  CameraManager.swift — Captura AVFoundation + laço rPPG (porte de worker.py).
//
//  Captura frames em fila dedicada (a UI nunca trava), detecta rosto via Vision,
//  extrai a média RGB de ROIs de pele, mantém um buffer deslizante de ~8 s, roda
//  o ensemble rPPG e publica os resultados para a interface SwiftUI.
//

import Foundation
import AVFoundation
import Combine
import CoreGraphics

private let janelaSeg = 8
private let nMax = janelaSeg * 60

/// Câmera disponível para seleção na UI.
struct CameraInfo: Identifiable, Hashable {
    let id: String            // uniqueID do device
    let nome: String
}

@MainActor
final class CameraManager: NSObject, ObservableObject {

    // ---- estado publicado p/ SwiftUI ----
    @Published var bpm: Double = 0
    @Published var sqi: Double = 0
    @Published var ok: Bool = false
    @Published var temRosto: Bool = false
    @Published var progresso: Double = 0
    @Published var fps: Double = 0
    @Published var batidaFlash: Double = 0            // decai após cada batida
    @Published var status: String = "Pronto"
    @Published var est = Estimativa()
    @Published var historico: [Double] = []
    @Published var pletismograma: [Double] = []
    @Published var deteccao: DeteccaoFace? = nil
    @Published var cameras: [CameraInfo] = []
    @Published var cameraSelecionada: String = ""
    @Published var erro: String? = nil
    @Published var rodando: Bool = false

    var modoDeteccao: String { "Vision Face Landmarks" }

    // ---- captura ----
    // start/stopRunning são thread-safe; acessados fora do main actor de propósito.
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated private let fila = DispatchQueue(label: "ai.mangaba.vitalscan.captura")
    nonisolated(unsafe) private var output = AVCaptureVideoDataOutput()
    let previewLayer = AVCaptureVideoPreviewLayer()

    // ---- buffers do laço (mutados SOMENTE na fila serial de captura;
    //      por isso nonisolated(unsafe) — a serialização da fila garante segurança) ----
    nonisolated(unsafe) private var rgbBuf = [[Double]]()
    nonisolated(unsafe) private var tBuf = [Double]()
    nonisolated(unsafe) private var bpmRecent = [Double]()
    nonisolated(unsafe) private var bpmHist = [Double]()
    nonisolated(unsafe) private var ultimaBatida: Double = 0
    nonisolated(unsafe) private var verdeAnt: Double? = nil
    nonisolated(unsafe) private var t0: Double = 0
    nonisolated(unsafe) private var ultimoHist: Double = 0
    nonisolated(unsafe) private var tPrev: Double = 0
    nonisolated(unsafe) private var fpsLocal: Double = 0
    nonisolated(unsafe) private var estLocal = Estimativa()
    nonisolated(unsafe) private var bpmLocal: Double = 0
    nonisolated(unsafe) private var sqiLocal: Double = 0
    nonisolated(unsafe) private var batidaFlashLocal: Double = 0

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        enumeraCameras()
    }

    // ---- enumeração de câmeras ----
    func enumeraCameras() {
        var tipos: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .continuityCamera,
        ]
        if #available(macOS 14.0, *) { tipos.append(.external) }
        let disc = AVCaptureDevice.DiscoverySession(
            deviceTypes: tipos, mediaType: .video, position: .unspecified)
        cameras = disc.devices.map { CameraInfo(id: $0.uniqueID, nome: $0.localizedName) }
        if cameraSelecionada.isEmpty, let primeira = cameras.first {
            cameraSelecionada = primeira.id
        }
    }

    // ---- controle ----
    func iniciar() {
        erro = nil
        AVCaptureDevice.requestAccess(for: .video) { [weak self] concedido in
            Task { @MainActor in
                guard let self else { return }
                if concedido { self.configuraEInicia() }
                else {
                    self.erro = "Permissão de câmera negada.\n\nAbra Ajustes do Sistema → "
                        + "Privacidade e Segurança → Câmera e ative o VitalScan."
                }
            }
        }
    }

    private func configuraEInicia() {
        guard let device = AVCaptureDevice(uniqueID: cameraSelecionada)
                ?? AVCaptureDevice.default(for: .video) else {
            erro = "Nenhuma câmera encontrada."
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            self.erro = "Falha ao abrir a câmera: \(error.localizedDescription)"
            session.commitConfiguration()
            return
        }
        output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: fila)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let conn = output.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = false        // sampling usa buffer não-espelhado
        }
        session.commitConfiguration()

        status = "Mantenha o rosto iluminado e parado por ~8 s."
        rodando = true
        fila.async { [weak self] in
            self?.reseta()               // limpa buffers na própria fila (sem corrida)
            self?.session.startRunning()
        }
    }

    func parar() {
        rodando = false
        fila.async { [weak self] in self?.session.stopRunning() }
        status = "Pausado"
    }

    func trocarCamera(_ id: String) {
        cameraSelecionada = id
        if rodando { parar(); iniciar() }
    }

    nonisolated private func reseta() {
        rgbBuf.removeAll(); tBuf.removeAll(); bpmRecent.removeAll(); bpmHist.removeAll()
        verdeAnt = nil; ultimaBatida = 0; ultimoHist = 0
        bpmLocal = 0; sqiLocal = 0; estLocal = Estimativa(); batidaFlashLocal = 0
        t0 = CACurrentMediaTime(); tPrev = t0; fpsLocal = 0
    }
}

// ============================ Laço de captura (fila dedicada) ============================

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Chamado pela AVFoundation na fila serial de captura (NÃO no main actor).
    /// Todo o trabalho pesado (Vision + DSP) roda aqui; só o estado final é
    /// publicado no main actor.
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let agora = CACurrentMediaTime()
        let det = FaceROI.processa(pb)
        let snap = processaFrame(det, agora: agora)     // computa na fila
        // hop idiomático até o main actor p/ publicar (sem assumeIsolated — este
        // é o único caminho garantidamente correto e não dispara asserção de fila)
        Task { @MainActor [weak self] in self?.aplica(snap) }
    }

    /// Snapshot imutável do estado a publicar (Sendable).
    struct Snapshot {
        var bpm = 0.0, sqi = 0.0, fps = 0.0, progresso = 0.0, batidaFlash = 0.0
        var ok = false, temRosto = false
        var est = Estimativa()
        var historico = [Double]()
        var pletismograma = [Double]()
        var deteccao: DeteccaoFace? = nil
        var status = ""
    }

    /// Aplica o snapshot às @Published (roda no main actor).
    private func aplica(_ s: Snapshot) {
        bpm = s.bpm; sqi = s.sqi; ok = s.ok; temRosto = s.temRosto
        progresso = s.progresso; fps = s.fps; est = s.est
        historico = s.historico; pletismograma = s.pletismograma
        deteccao = s.deteccao; batidaFlash = s.batidaFlash; status = s.status
    }

    /// Porte do corpo do while-loop de worker.py.run(). Roda na fila de captura.
    nonisolated private func processaFrame(_ det: DeteccaoFace?, agora: Double) -> Snapshot {
        let temRostoAgora = det != nil
        let rgb = det?.rgb

        // acumula RGB com rejeição de artefato de movimento (relativa à intensidade)
        if let rgb {
            let saltoRel = verdeAnt != nil ? abs(rgb[1] - verdeAnt!) / (verdeAnt! + 1e-6) : 0
            if verdeAnt == nil || saltoRel < 0.08 {
                rgbBuf.append(rgb); tBuf.append(agora - t0)
                if rgbBuf.count > nMax { rgbBuf.removeFirst(); tBuf.removeFirst() }
            }
            verdeAnt = rgb[1]
        }

        // estimativa quando há histórico suficiente (>= 4 s)
        if rgbBuf.count >= Int(Par.fsAlvo * 4) {
            let (rgbU, fs) = reamostraUniforme(tBuf, rgbBuf)
            let e = estimaEnsemble(rgbU, fs)
            estLocal = e; sqiLocal = e.sqi
            let bpmInst = e.bpm
            if bpmInst >= Par.bpmMin && bpmInst <= Par.bpmMax && sqiLocal >= 0.4 {
                if bpmRecent.isEmpty || abs(bpmInst - Vec.median(bpmRecent)) < 15 {
                    bpmRecent.append(bpmInst)
                    if bpmRecent.count > 7 { bpmRecent.removeFirst() }
                }
            }
            if !bpmRecent.isEmpty { bpmLocal = Vec.median(bpmRecent) }
        }

        // gate de validação: faixa + qualidade + concordância cruzada + estabilidade
        let okBpm = bpmLocal >= Par.bpmMin && bpmLocal <= Par.bpmMax && sqiLocal >= 0.4
            && bpmRecent.count >= 2 && estLocal.confirmado

        var batida = false
        if okBpm && bpmLocal > 0 && (agora - ultimaBatida) >= (60.0 / bpmLocal) {
            ultimaBatida = agora; batida = true
        }
        if okBpm && (bpmHist.isEmpty || agora - ultimoHist >= 1.0) {
            bpmHist.append(bpmLocal); ultimoHist = agora
            if bpmHist.count > 300 { bpmHist.removeFirst() }
        }

        // fps suavizado
        let dt = agora - tPrev; tPrev = agora
        if dt > 0 { fpsLocal = fpsLocal > 0 ? 0.9 * fpsLocal + 0.1 * (1.0 / dt) : 1.0 / dt }

        // batida: pico a cada batimento, com decaimento
        if batida { batidaFlashLocal = 1.0 }
        else { batidaFlashLocal = max(0, batidaFlashLocal - 0.12) }

        let progresso = min(Double(rgbBuf.count) / (Par.fsAlvo * 4), 1.0)
        let statusMsg: String
        if !temRostoAgora { statusMsg = "Nenhum rosto detectado" }
        else if progresso < 1 { statusMsg = "Calibrando… \(Int(progresso * 100))%" }
        else if okBpm { statusMsg = "Sinal OK" }
        else { statusMsg = "Ajustando… mantenha-se parado" }

        return Snapshot(
            bpm: bpmLocal, sqi: sqiLocal, fps: fpsLocal, progresso: progresso,
            batidaFlash: batidaFlashLocal, ok: okBpm, temRosto: temRostoAgora,
            est: estLocal, historico: bpmHist,
            pletismograma: estLocal.sig.isEmpty ? [] : Array(estLocal.sig.suffix(150)),
            deteccao: det, status: statusMsg)
    }
}
