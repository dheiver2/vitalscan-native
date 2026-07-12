//
//  FaceROI.swift — Extração de ROIs de pele e média RGB (porte de landmarks.py).
//
//  Substitui o MediaPipe Face Mesh pelo framework Vision (VNFaceLandmarks2D).
//  A partir das sobrancelhas, olhos, nariz e contorno facial, deriva três ROIs
//  de pele — testa + duas bochechas — onde o sinal rPPG é mais forte, e calcula
//  a média RGB apenas sobre pixels de pele (máscara YCrCb) sem clipping.
//

import Foundation
import Vision
import CoreVideo
import CoreGraphics

/// Resultado da extração por frame: RGB médio + geometria p/ desenho (0..1, topo-esq).
struct DeteccaoFace {
    var rgb: [Double]?                       // [R,G,B] média das ROIs de pele
    var oval: [CGPoint]                      // contorno facial (normalizado)
    var rois: [[CGPoint]]                    // polígonos das ROIs (normalizado)
    var malha: [CGPoint]                     // pontos esparsos p/ feedback
}

enum FaceROI {

    /// Detecta rosto/landmarks no pixel buffer e extrai RGB das ROIs de pele.
    /// Retorna nil se não houver rosto.
    static func processa(_ pixelBuffer: CVPixelBuffer) -> DeteccaoFace? {
        let req = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do { try handler.perform([req]) } catch { return nil }
        guard let face = (req.results)?.first as? VNFaceObservation,
              let lm = face.landmarks else { return nil }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let sz = CGSize(width: w, height: h)

        // Vision: origem inferior-esquerda. Convertemos p/ pixels topo-esquerda.
        func img(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let r = region else { return [] }
            return r.pointsInImage(imageSize: sz).map { CGPoint(x: $0.x, y: CGFloat(h) - $0.y) }
        }

        let leftBrow = img(lm.leftEyebrow)
        let rightBrow = img(lm.rightEyebrow)
        let leftEye = img(lm.leftEye)
        let rightEye = img(lm.rightEye)
        let nose = img(lm.nose)
        let contour = img(lm.faceContour)

        // caixa facial em pixels (topo-esquerda)
        let bb = face.boundingBox
        let fx = bb.minX * CGFloat(w)
        let fy = (1 - bb.maxY) * CGFloat(h)
        let fW = bb.width * CGFloat(w)
        let fH = bb.height * CGFloat(h)

        var rois = [[CGPoint]]()

        // ---- ROI TESTA: banda acima das sobrancelhas, ancorada no Y real ----
        let brows = leftBrow + rightBrow
        if !brows.isEmpty {
            let browY = brows.map { $0.y }.min() ?? fy          // topo das sobrancelhas
            let cx = fx + fW / 2
            let bw = fW * 0.46
            let alturaTesta = min(fH * 0.24, max(browY - fy, 8))
            let topo = max(browY - alturaTesta, fy + 2)
            rois.append([
                CGPoint(x: cx - bw / 2, y: topo),
                CGPoint(x: cx + bw / 2, y: topo),
                CGPoint(x: cx + bw / 2, y: browY - 4),
                CGPoint(x: cx - bw / 2, y: browY - 4),
            ])
        }

        // ---- ROI BOCHECHAS: abaixo do olho, ao lado do nariz ----
        func bochecha(olho: [CGPoint], ladoEsquerdo: Bool) -> [CGPoint]? {
            guard !olho.isEmpty, !nose.isEmpty else { return nil }
            let eyeBottom = olho.map { $0.y }.max() ?? fy
            let noseX = nose.map { $0.x }.reduce(0, +) / CGFloat(nose.count)
            let noseBottom = nose.map { $0.y }.max() ?? (fy + fH)
            let topo = eyeBottom + fH * 0.06
            let baixo = min(noseBottom, topo + fH * 0.20)
            let interno = ladoEsquerdo ? noseX - fW * 0.06 : noseX + fW * 0.06
            let externo = ladoEsquerdo ? fx + fW * 0.08 : fx + fW * 0.92
            let x0 = min(interno, externo), x1 = max(interno, externo)
            return [
                CGPoint(x: x0, y: topo), CGPoint(x: x1, y: topo),
                CGPoint(x: x1, y: baixo), CGPoint(x: x0, y: baixo),
            ]
        }
        if let bE = bochecha(olho: leftEye, ladoEsquerdo: true) { rois.append(bE) }
        if let bD = bochecha(olho: rightEye, ladoEsquerdo: false) { rois.append(bD) }

        // média RGB sobre as ROIs
        var medias = [[Double]]()
        pixelBuffer.comBaseAddress { buf, bytesPerRow in
            for poly in rois {
                if let m = mediaPoligono(buf, bytesPerRow, w, h, poly) { medias.append(m) }
            }
        }
        var rgb: [Double]? = nil
        if !medias.isEmpty {
            rgb = [0, 1, 2].map { c in medias.map { $0[c] }.reduce(0, +) / Double(medias.count) }
        }

        // normaliza geometria p/ desenho (0..1)
        func norm(_ pts: [CGPoint]) -> [CGPoint] {
            pts.map { CGPoint(x: $0.x / CGFloat(w), y: $0.y / CGFloat(h)) }
        }
        let malha = (leftBrow + rightBrow + leftEye + rightEye + nose + contour)

        return DeteccaoFace(
            rgb: rgb,
            oval: norm(contour),
            rois: rois.map { norm($0) },
            malha: norm(malha))
    }

    /// Média RGB dos pixels de pele (YCrCb) dentro do polígono, sem clipping.
    private static func mediaPoligono(_ buf: UnsafeMutableRawPointer, _ bpr: Int,
                                      _ w: Int, _ h: Int, _ poly: [CGPoint]) -> [Double]? {
        guard poly.count >= 3 else { return nil }
        let minX = max(0, Int(poly.map { $0.x }.min() ?? 0))
        let maxX = min(w - 1, Int(poly.map { $0.x }.max() ?? 0))
        let minY = max(0, Int(poly.map { $0.y }.min() ?? 0))
        let maxY = min(h - 1, Int(poly.map { $0.y }.max() ?? 0))
        guard maxX > minX, maxY > minY else { return nil }

        var sR = 0.0, sG = 0.0, sB = 0.0
        var nPele = 0
        var sRall = 0.0, sGall = 0.0, sBall = 0.0, nAll = 0
        let ptr = buf.assumingMemoryBound(to: UInt8.self)

        for y in minY...maxY {
            let row = ptr + y * bpr
            for x in minX...maxX where dentroPoligono(CGFloat(x) + 0.5, CGFloat(y) + 0.5, poly) {
                // BGRA
                let px = row + x * 4
                let b = Double(px[0]), g = Double(px[1]), r = Double(px[2])
                nAll += 1; sRall += r; sGall += g; sBall += b
                // declipping: descarta pixels estourados/escuros
                if r < 10 || r > 245 || g < 10 || g > 245 || b < 10 || b > 245 { continue }
                // máscara de pele YCrCb
                let yl = 0.299 * r + 0.587 * g + 0.114 * b
                let cr = (r - yl) * 0.713 + 128
                let cb = (b - yl) * 0.564 + 128
                if cr >= 133 && cr <= 173 && cb >= 77 && cb <= 127 {
                    sR += r; sG += g; sB += b; nPele += 1
                }
            }
        }
        let area = (maxX - minX) * (maxY - minY)
        if nPele >= Int(0.2 * Double(area)) && nPele >= 20 {
            return [sR / Double(nPele), sG / Double(nPele), sB / Double(nPele)]
        }
        // fallback: usa todos os pixels do polígono se pele insuficiente
        if nAll >= 20 {
            return [sRall / Double(nAll), sGall / Double(nAll), sBall / Double(nAll)]
        }
        return nil
    }

    /// Teste ponto-em-polígono (ray casting).
    private static func dentroPoligono(_ px: CGFloat, _ py: CGFloat, _ poly: [CGPoint]) -> Bool {
        var dentro = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > py) != (b.y > py) {
                let t = (py - a.y) / (b.y - a.y)
                if px < a.x + t * (b.x - a.x) { dentro.toggle() }
            }
            j = i
        }
        return dentro
    }
}

extension CVPixelBuffer {
    /// Acesso ao base address com lock (formato BGRA esperado).
    func comBaseAddress(_ body: (UnsafeMutableRawPointer, Int) -> Void) {
        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }
        if let base = CVPixelBufferGetBaseAddress(self) {
            body(base, CVPixelBufferGetBytesPerRow(self))
        }
    }
}
