//
//  CameraView.swift — Preview da câmera (AVCaptureVideoPreviewLayer) espelhada
//  + overlay dos landmarks/ROIs desenhado por cima (porte de landmarks.desenha).
//

import SwiftUI
import AVFoundation

/// NSView que hospeda o preview layer da sessão.
final class PreviewNSView: NSView {
    let camada: AVCaptureVideoPreviewLayer
    init(_ layer: AVCaptureVideoPreviewLayer) {
        camada = layer
        super.init(frame: .zero)
        wantsLayer = true
        layer.videoGravity = .resizeAspectFill
        self.layer = camada
        // espelha o preview (selfie), como o cv2.flip do original
        camada.connection?.automaticallyAdjustsVideoMirroring = false
        camada.connection?.isVideoMirrored = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); camada.frame = bounds }
}

struct PreviewCamera: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView(layer) }
    func updateNSView(_ nsView: PreviewNSView, context: Context) {}
}

/// Overlay vetorial (contorno facial, polígonos das ROIs e malha esparsa).
struct OverlayFace: View {
    let det: DeteccaoFace?
    let ativo: Bool

    // pontos vêm normalizados (0..1) topo-esquerda; espelhamos em X p/ casar
    // com o preview espelhado (selfie).
    private func caminho(_ pts: [CGPoint], _ sz: CGSize) -> Path {
        Path { path in
            guard let first = pts.first else { return }
            path.move(to: CGPoint(x: (1 - first.x) * sz.width, y: first.y * sz.height))
            for pt in pts.dropFirst() {
                path.addLine(to: CGPoint(x: (1 - pt.x) * sz.width, y: pt.y * sz.height))
            }
            path.closeSubpath()
        }
    }

    var body: some View {
        GeometryReader { geo in
            let sz = geo.size
            if let det {
                let cor = ativo ? Tema.acc : Tema.mut
                caminho(det.oval, sz).stroke(Color(hex: 0x46a0c8).opacity(0.7), lineWidth: 1)
                ForEach(Array(det.rois.enumerated()), id: \.offset) { _, poly in
                    caminho(poly, sz).stroke(cor.opacity(0.85), lineWidth: 1)
                }
                ForEach(Array(stride(from: 0, to: det.malha.count, by: 5)), id: \.self) { i in
                    Circle().fill(Color(hex: 0x5a825a).opacity(0.7))
                        .frame(width: 2, height: 2)
                        .position(x: (1 - det.malha[i].x) * sz.width,
                                  y: det.malha[i].y * sz.height)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
