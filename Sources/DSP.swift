//
//  DSP.swift — Núcleo de processamento de sinal rPPG (porte nativo Swift).
//
//  Porte fiel de vitalscan/dsp.py, sem NumPy/SciPy. Usa Accelerate (vDSP) para
//  a FFT e implementa em Swift puro:
//    - Butterworth passa-banda ordem 4 + filtfilt (design zpk -> lp2bp -> bilinear)
//    - Ensemble de 5 métodos: POS (Wang 2017, janela deslizante + overlap-add),
//      CHROM (de Haan 2013), LGI (Pilz 2018), OMIT (Álvarez-Casado 2023), verde.
//    - Fusão ESPECTRAL das PSDs normalizadas ponderadas por SNR.
//    - Desambiguação de harmônico contra a autocorrelação.
//    - Interpolação parabólica sub-bin, SQI composto, HRV (SDNN).
//
//  Truques matemáticos que evitam SVD/QR completos:
//    - LGI: direção dominante = autovetor dominante da 3x3 C·Cᵀ (power iteration).
//    - OMIT: Q[:,0] da QR de C(3×N) == primeira coluna de C normalizada.
//    - Em ambos P = I − s·sᵀ é invariante ao sinal de s.
//
//  Módulo puro: recebe RGB/tempo e devolve dados. Sem dependência de UI.
//

import Foundation
import Accelerate

// ----- Parâmetros globais (espelham dsp.py) -----
enum Par {
    static let fsAlvo: Double = 30.0
    static let freqMin: Double = 0.7            // Hz -> 42 bpm
    static let freqMax: Double = 3.0            // Hz -> 180 bpm
    static let bpmMin: Double = 40.0
    static let bpmMax: Double = 180.0
    static let nfftFusao: Int = 4096            // grid espectral comum
    static let snrMinConf: Double = 4.0         // dB p/ confirmar pulso real
}

// ============================ Estrutura de resultado ============================

struct Estimativa {
    var bpm: Double = 0
    var bpmAc: Double = 0
    var snr: Double = 0
    var hrv: Double = 0
    var sqi: Double = 0
    var melhor: String = "-"
    var segundo: String = "-"
    var bpmM1: Double = 0
    var bpmM2: Double = 0
    var acordoMet: Double = 0
    var acordoAc: Double = 0
    var sig: [Double] = []

    /// Concordância entre métodos pode subir por acaso (derivam dos mesmos dados);
    /// o SNR é o discriminador real entre pulso e ruído.
    var confirmado: Bool {
        snr >= Par.snrMinConf && acordoMet >= 0.6 && acordoAc >= 0.5
    }
}

// ============================ Utilidades vetoriais ============================

enum Vec {
    static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count)
    }
    static func std(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        let v = x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)
        return (v).squareRoot()
    }
    static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }
    static func clip(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}

// ============================ Reamostragem / detrend / banda ============================

/// Interpola sinais multicanal (N×3) num grid temporal uniforme.
func reamostraUniforme(_ t: [Double], _ y: [[Double]], fs: Double = Par.fsAlvo)
    -> (y: [[Double]], fs: Double) {
    guard t.count >= 2, y.count == t.count else { return (y, fs) }
    let dur = t[t.count - 1] - t[0]
    let n = Int(dur * fs)
    if n < 8 { return (y, fs) }
    let nc = y[0].count
    let t0 = t[0], t1 = t[t.count - 1]
    var out = [[Double]](repeating: [Double](repeating: 0, count: nc), count: n)
    for i in 0..<n {
        let tu = t0 + (t1 - t0) * Double(i) / Double(n - 1)
        // busca o intervalo [j, j+1] que contém tu
        var j = 0
        while j < t.count - 2 && t[j + 1] < tu { j += 1 }
        let ta = t[j], tb = t[j + 1]
        let frac = tb > ta ? (tu - ta) / (tb - ta) : 0
        for c in 0..<nc {
            out[i][c] = y[j][c] + frac * (y[j + 1][c] - y[j][c])
        }
    }
    return (out, fs)
}

/// Remove tendência linear (equivalente a subtrair reta ajustada por mínimos quadrados).
func detrend(_ x: [Double]) -> [Double] {
    let n = x.count
    guard n > 1 else { return x }
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
    for i in 0..<n {
        let ti = Double(i)
        sx += ti; sy += x[i]; sxx += ti * ti; sxy += ti * x[i]
    }
    let dn = Double(n)
    let denom = dn * sxx - sx * sx
    let a = denom != 0 ? (dn * sxy - sx * sy) / denom : 0
    let b = (sy - a * sx) / dn
    return (0..<n).map { x[$0] - (a * Double($0) + b) }
}

/// Passa-banda Butterworth ordem 4 + filtfilt (forward-backward, zero-phase).
func banda(_ x: [Double], _ fs: Double,
           low: Double = Par.freqMin, high: Double = Par.freqMax,
           ordem: Int = 4) -> [Double] {
    let nyq = 0.5 * fs
    let lo = max(low / nyq, 1e-3)
    let hi = min(high / nyq, 0.99)
    guard hi > lo else { return x }
    let (b, a) = Butterworth.bandpass(order: ordem, lowNorm: lo, highNorm: hi)
    return Filtfilt.apply(b: b, a: a, x: x)
}

// ============================ Métodos rPPG (ensemble) ============================

private let PROJ_POS: [[Double]] = [[0.0, 1.0, -1.0], [-2.0, 1.0, 1.0]]

/// Converte RGB (N,3) -> C (3,N).
private func transpose3(_ rgb: [[Double]]) -> [[Double]] {
    let n = rgb.count
    var C = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
    for i in 0..<n { for c in 0..<3 { C[c][i] = rgb[i][c] } }
    return C
}

/// POS canônico com janela deslizante + overlap-add (Wang et al. 2017).
func pulsoPOS(_ rgb: [[Double]], _ fs: Double) -> [Double] {
    let C = transpose3(rgb)
    let n = rgb.count
    let w = max(Int(1.6 * fs), 2)
    var H = [Double](repeating: 0, count: n)
    if n <= w { return banda(H, fs) }
    for endIdx in w..<n {
        let m = endIdx - w + 1
        // médias por canal na janela
        var mu = [Double](repeating: 0, count: 3)
        for c in 0..<3 {
            var s = 0.0
            for i in m...endIdx { s += C[c][i] }
            mu[c] = s / Double(w)
            if mu[c] == 0 { mu[c] = 1e-8 }
        }
        // normaliza + projeta (2×w)
        var s1 = [Double](repeating: 0, count: w)
        var s2 = [Double](repeating: 0, count: w)
        for k in 0..<w {
            let idx = m + k
            let r = C[0][idx] / mu[0], g = C[1][idx] / mu[1], b = C[2][idx] / mu[2]
            s1[k] = PROJ_POS[0][0] * r + PROJ_POS[0][1] * g + PROJ_POS[0][2] * b
            s2[k] = PROJ_POS[1][0] * r + PROJ_POS[1][1] * g + PROJ_POS[1][2] * b
        }
        let sd2 = Vec.std(s2)
        let alpha = sd2 > 1e-8 ? Vec.std(s1) / sd2 : 0
        var h = [Double](repeating: 0, count: w)
        for k in 0..<w { h[k] = s1[k] + alpha * s2[k] }
        let hm = Vec.mean(h)
        for k in 0..<w { H[m + k] += (h[k] - hm) }
    }
    return banda(H, fs)
}

/// CHROM (de Haan & Jeanne 2013).
func pulsoCHROM(_ rgb: [[Double]], _ fs: Double) -> [Double] {
    let C = transpose3(rgb)
    let n = rgb.count
    // normaliza pela média temporal de cada canal
    var Cn = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
    for c in 0..<3 {
        var mu = Vec.mean(C[c]); if mu == 0 { mu = 1e-8 }
        for i in 0..<n { Cn[c][i] = C[c][i] / mu }
    }
    var X = [Double](repeating: 0, count: n)
    var Y = [Double](repeating: 0, count: n)
    for i in 0..<n {
        X[i] = 3 * Cn[0][i] - 2 * Cn[1][i]
        Y[i] = 1.5 * Cn[0][i] + Cn[1][i] - 1.5 * Cn[2][i]
    }
    let Xf = banda(detrend(X), fs)
    let Yf = banda(detrend(Y), fs)
    let s = Vec.std(Yf)
    let alpha = s > 1e-8 ? Vec.std(Xf) / s : 0
    return zip(Xf, Yf).map { $0 - alpha * $1 }
}

/// LGI — Local Group Invariance (Pilz et al. 2018).
/// Projeta no complemento ortogonal da direção dominante (autovetor de C·Cᵀ).
func pulsoLGI(_ rgb: [[Double]], _ fs: Double) -> [Double] {
    let C = transpose3(rgb)
    let s = direcaoDominante(C)                 // (3,) unitário
    let Y = projetaComplemento(C, s)            // (3,N)
    return banda(detrend(Y[1]), fs)
}

/// OMIT — Orthogonal Matrix Image Transformation (Álvarez-Casado 2023).
/// Q[:,0] da QR == primeira coluna de C normalizada; P = I − s·sᵀ invariante ao sinal.
func pulsoOMIT(_ rgb: [[Double]], _ fs: Double) -> [Double] {
    let C = transpose3(rgb)
    var s = [C[0][0], C[1][0], C[2][0]]
    var nrm = (s[0] * s[0] + s[1] * s[1] + s[2] * s[2]).squareRoot()
    if nrm < 1e-12 { nrm = 1e-12 }
    s = s.map { $0 / nrm }
    let Y = projetaComplemento(C, s)
    return banda(detrend(Y[1]), fs)
}

/// Canal verde simples (linha de base).
func pulsoVerde(_ rgb: [[Double]], _ fs: Double) -> [Double] {
    banda(detrend(rgb.map { $0[1] }), fs)
}

/// Y = (I − s·sᵀ)·C, com s unitário 3-vetor.
private func projetaComplemento(_ C: [[Double]], _ s: [Double]) -> [[Double]] {
    let n = C[0].count
    var Y = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
    for i in 0..<n {
        let v = [C[0][i], C[1][i], C[2][i]]
        let dot = s[0] * v[0] + s[1] * v[1] + s[2] * v[2]
        for r in 0..<3 { Y[r][i] = v[r] - dot * s[r] }
    }
    return Y
}

/// Autovetor dominante da 3×3 simétrica C·Cᵀ via power iteration.
private func direcaoDominante(_ C: [[Double]]) -> [Double] {
    let n = C[0].count
    // M = C·Cᵀ (3×3 simétrica)
    var M = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
    for a in 0..<3 {
        for b in a..<3 {
            var acc = 0.0
            for i in 0..<n { acc += C[a][i] * C[b][i] }
            M[a][b] = acc; M[b][a] = acc
        }
    }
    var v = [1.0, 1.0, 1.0]
    for _ in 0..<60 {
        var w = [Double](repeating: 0, count: 3)
        for r in 0..<3 { w[r] = M[r][0] * v[0] + M[r][1] * v[1] + M[r][2] * v[2] }
        var nrm = (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).squareRoot()
        if nrm < 1e-12 { nrm = 1e-12 }
        v = w.map { $0 / nrm }
    }
    return v
}

// ============================ FFT / PSD / picos ============================

/// PSD na banda de interesse num grid de frequência fixo (nfft = 4096).
func psdBanda(_ sinal: [Double], _ fs: Double) -> (f: [Double], p: [Double]) {
    let n = sinal.count
    guard n >= 2 else { return ([], []) }
    let mu = Vec.mean(sinal)
    // janela de Hann sobre o comprimento original
    var win = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let hann = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(n - 1))
        win[i] = (sinal[i] - mu) * hann
    }
    let psd = FFT.powerSpectrum(win, nfft: Par.nfftFusao)   // rfft magnitude²
    let df = fs / Double(Par.nfftFusao)
    var fOut = [Double](), pOut = [Double]()
    fOut.reserveCapacity(psd.count); pOut.reserveCapacity(psd.count)
    for k in 0..<psd.count {
        let f = Double(k) * df
        if f >= Par.freqMin && f <= Par.freqMax { fOut.append(f); pOut.append(psd[k]) }
    }
    return (fOut, pOut)
}

/// Refina índice do pico por interpolação parabólica (sub-bin).
private func interpParabolica(_ p: [Double], _ i: Int) -> Double {
    if i > 0 && i < p.count - 1 {
        let a = p[i - 1], b = p[i], c = p[i + 1]
        let denom = a - 2 * b + c
        if abs(denom) > 1e-12 { return Double(i) + 0.5 * (a - c) / denom }
    }
    return Double(i)
}

private func picoBPM(_ f: [Double], _ p: [Double]) -> Double {
    guard !p.isEmpty else { return 0 }
    var iPico = 0
    for k in 1..<p.count where p[k] > p[iPico] { iPico = k }
    let df = f.count > 1 ? f[1] - f[0] : 0
    let fPico = f[0] + interpParabolica(p, iPico) * df
    return fPico * 60.0
}

/// SNR (dB) somando fundamental+2º harmônico vs ruído, e proeminência.
private func snrProm(_ f: [Double], _ p: [Double], _ fPico: Double) -> (Double, Double) {
    guard !p.isEmpty, fPico > 0 else { return (-99, 0) }
    var sigP = 0.0, noiseP = 1e-12
    var pico = p[0]; var iPico = 0
    for k in 0..<p.count {
        if p[k] > pico { pico = p[k]; iPico = k }
        let inSig = abs(f[k] - fPico) <= 0.15 || abs(f[k] - 2 * fPico) <= 0.15
        if inSig { sigP += p[k] } else { noiseP += p[k] }
    }
    let snr = 10 * log10(sigP / noiseP)
    let prom = p[iPico] / (Vec.median(p) + 1e-12)
    return (snr, prom)
}

// ============================ Autocorrelação / HRV / harmônico ============================

/// HR independente via autocorrelação (verificação cruzada com a FFT).
func hrAutocorrelacao(_ sinal: [Double], _ fs: Double) -> Double {
    let n = sinal.count
    guard n > 4 else { return 0 }
    let mu = Vec.mean(sinal)
    let s = sinal.map { $0 - mu }
    let lo = Int(fs / Par.freqMax)
    let hi = Int(fs / Par.freqMin)
    if hi <= lo + 1 || hi >= n { return 0 }
    var bestLag = 0; var best = -Double.infinity
    for lag in lo..<hi {
        var acc = 0.0
        for i in 0..<(n - lag) { acc += s[i] * s[i + lag] }
        if acc > best { best = acc; bestLag = lag }
    }
    return bestLag > 0 ? 60.0 * fs / Double(bestLag) : 0
}

/// SDNN (ms) a partir dos intervalos entre picos.
func calculaHRV(_ sinal: [Double], _ fs: Double) -> Double {
    let n = sinal.count
    guard n > 3 else { return 0 }
    let mu = Vec.mean(sinal), sd = Vec.std(sinal) + 1e-8
    let s = sinal.map { ($0 - mu) / sd }
    let dist = max(Int(fs * 0.4), 1)
    let picos = achaPicos(s, distancia: dist, proeminencia: 0.3)
    if picos.count < 3 { return 0 }
    var rr = [Double]()
    for k in 1..<picos.count { rr.append(Double(picos[k] - picos[k - 1]) / fs * 1000.0) }
    return Vec.std(rr)
}

/// find_peaks simplificado: máximos locais com distância mínima e proeminência.
private func achaPicos(_ x: [Double], distancia: Int, proeminencia: Double) -> [Int] {
    let n = x.count
    var cand = [Int]()
    for i in 1..<(n - 1) where x[i] > x[i - 1] && x[i] >= x[i + 1] {
        // proeminência aproximada: altura acima do menor vale vizinho numa janela
        let lo = max(0, i - distancia), hi = min(n - 1, i + distancia)
        var minL = x[i], minR = x[i]
        for j in stride(from: i, through: lo, by: -1) { minL = min(minL, x[j]) }
        for j in i...hi { minR = min(minR, x[j]) }
        let prom = x[i] - max(minL, minR)
        if prom >= proeminencia { cand.append(i) }
    }
    // impõe distância mínima mantendo os maiores
    var picos = [Int]()
    for i in cand.sorted(by: { x[$0] > x[$1] }) {
        if picos.allSatisfy({ abs($0 - i) >= distancia }) { picos.append(i) }
    }
    return picos.sorted()
}

/// Corrige travamento em 2× ou 0.5× de uma referência confiável (autocorrelação).
private func corrigeHarmonico(_ bpm: Double, _ ref: Double) -> Double {
    if bpm <= 0 || ref <= 0 { return bpm }
    if abs(bpm - 2 * ref) < 8.0 && Par.bpmMin <= bpm / 2 && bpm / 2 <= Par.bpmMax {
        return bpm / 2
    }
    if abs(bpm - 0.5 * ref) < 8.0 && Par.bpmMin <= bpm * 2 && bpm * 2 <= Par.bpmMax {
        return bpm * 2
    }
    return bpm
}

// ============================ Ensemble ============================

func estimaEnsemble(_ rgbU: [[Double]], _ fs: Double) -> Estimativa {
    let metodos: [(String, [Double])] = [
        ("POS", pulsoPOS(rgbU, fs)),
        ("CHROM", pulsoCHROM(rgbU, fs)),
        ("LGI", pulsoLGI(rgbU, fs)),
        ("OMIT", pulsoOMIT(rgbU, fs)),
        ("GREEN", pulsoVerde(rgbU, fs)),
    ]

    struct M { var bpm: Double; var snr: Double; var prom: Double; var sig: [Double] }
    var est = [String: M]()
    var fBand: [Double] = []
    var psdFus: [Double] = []

    for (nome, sig) in metodos {
        let (fb, pb) = psdBanda(sig, fs)
        let bpm = picoBPM(fb, pb)
        let (snr, prom) = snrProm(fb, pb, bpm / 60.0)
        est[nome] = M(bpm: bpm, snr: snr, prom: prom, sig: sig)
        if !pb.isEmpty {
            let w = max(snr, 0.0) + 1e-3
            let soma = pb.reduce(0, +) + 1e-12
            if psdFus.isEmpty {
                psdFus = pb.map { ($0 / soma) * w }
                fBand = fb
            } else if pb.count == psdFus.count {
                for k in 0..<pb.count { psdFus[k] += (pb[k] / soma) * w }
            }
        }
    }

    let rank = metodos.map { $0.0 }.sorted { est[$0]!.snr > est[$1]!.snr }
    let melhor = rank[0], segundo = rank[1]
    let mMelhor = est[melhor]!
    let bpmAc = hrAutocorrelacao(mMelhor.sig, fs)

    var bpmFus = psdFus.isEmpty ? mMelhor.bpm : picoBPM(fBand, psdFus)
    bpmFus = corrigeHarmonico(bpmFus, bpmAc)
    let hrv = calculaHRV(mMelhor.sig, fs)

    let difMet = abs(mMelhor.bpm - est[segundo]!.bpm)
    let acordoMet = Vec.clip(1 - difMet / 12.0, 0, 1)
    let difAc = bpmAc > 0 ? abs(bpmFus - bpmAc) : 12.0
    let acordoAc = Vec.clip(1 - difAc / 12.0, 0, 1)
    let sqiSnr = Vec.clip((mMelhor.snr - 2) / 10.0, 0, 1)
    let sqiProm = Vec.clip((mMelhor.prom - 2) / 10.0, 0, 1)
    let fFus = bpmFus / 60.0
    let margem = min(fFus - Par.freqMin, Par.freqMax - fFus)
    let sqiEdge = Vec.clip(margem / 0.15, 0, 1)
    let sqi = 0.35 * sqiSnr + 0.28 * acordoMet + 0.18 * acordoAc
            + 0.09 * sqiProm + 0.10 * sqiEdge

    return Estimativa(
        bpm: bpmFus, bpmAc: bpmAc, snr: mMelhor.snr, hrv: hrv, sqi: sqi,
        melhor: melhor, segundo: segundo,
        bpmM1: mMelhor.bpm, bpmM2: est[segundo]!.bpm,
        acordoMet: acordoMet, acordoAc: acordoAc, sig: mMelhor.sig)
}
