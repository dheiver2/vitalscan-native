import Foundation

// ============================ mini framework ============================
var passes = 0, fails = 0
var falhas = [String]()
func check(_ cond: Bool, _ nome: String, _ detalhe: String = "") {
    if cond { passes += 1; print("  ✓ \(nome)") }
    else { fails += 1; falhas.append(nome); print("  ✗ \(nome)  \(detalhe)") }
}
func aprox(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }
func grupo(_ t: String) { print("\n▸ \(t)") }

// gerador determinístico de ruído (sem Math.random p/ reprodutibilidade)
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(seed >> 40) / Double(1 << 24) * 2 - 1 }

/// RGB sintético com pulso no verde + harmônico + deriva de iluminação + ruído.
func geraRGB(bpm: Double, fs: Double, seg: Double, ruido: Double = 0.4,
             amp: Double = 0.6) -> (t: [Double], rgb: [[Double]]) {
    let n = Int(fs * seg); var t = [Double](); var rgb = [[Double]]()
    let f = bpm / 60.0
    for i in 0..<n {
        let ti = Double(i) / fs; t.append(ti)
        let pulso = amp * sin(2 * .pi * f * ti) + 0.15 * amp * sin(2 * .pi * 2 * f * ti)
        let ilum = 2.0 * sin(2 * .pi * 0.1 * ti)
        let base = 130.0 + ilum
        rgb.append([base * 1.05 + 0.3 * pulso + ruido * rnd(),
                    base + pulso + ruido * rnd(),
                    base * 0.95 + 0.1 * pulso + ruido * rnd()])
    }
    return (t, rgb)
}

// ============================ 1. utilidades vetoriais ============================
grupo("Vec (média / desvio / mediana / clip)")
check(aprox(Vec.mean([1, 2, 3, 4]), 2.5, 1e-9), "mean")
check(aprox(Vec.std([2, 2, 2, 2]), 0, 1e-9), "std constante = 0")
check(aprox(Vec.std([1, 2, 3, 4, 5]), 1.41421356, 1e-6), "std população")
check(aprox(Vec.median([3, 1, 2]), 2, 1e-9), "median ímpar")
check(aprox(Vec.median([4, 1, 2, 3]), 2.5, 1e-9), "median par")
check(Vec.clip(5, 0, 1) == 1 && Vec.clip(-5, 0, 1) == 0 && Vec.clip(0.3, 0, 1) == 0.3, "clip")

// ============================ 2. detrend ============================
grupo("detrend (remove reta)")
let rampa = (0..<50).map { 3.0 + 2.0 * Double($0) }        // reta pura
let semTend = detrend(rampa)
check(semTend.allSatisfy { abs($0) < 1e-6 }, "reta pura -> ~0")
let comSinal = (0..<100).map { 10.0 + 0.5 * Double($0) + sin(Double($0) * 0.3) }
let dt = detrend(comSinal)
check(abs(Vec.mean(dt)) < 1e-6, "média ~0 após detrend")

// ============================ 3. Butterworth + filtfilt ============================
grupo("Butterworth passa-banda + filtfilt (zero-phase)")
let fs = 30.0
// DC deve ser fortemente atenuado
let dc = [Double](repeating: 5.0, count: 240)
let dcFilt = banda(dc, fs)
check(dcFilt.map { abs($0) }.max()! < 0.05, "DC atenuado (<0.05)")
// senoide na banda (1.2 Hz = 72 bpm) passa; fora da banda (0.2 Hz) é barrada
let inBand = (0..<240).map { sin(2 * .pi * 1.2 * Double($0) / fs) }
let outBand = (0..<240).map { sin(2 * .pi * 0.2 * Double($0) / fs) }
let ampIn = banda(inBand, fs).map { abs($0) }.max()!
let ampOut = banda(outBand, fs).map { abs($0) }.max()!
check(ampIn > 0.7, "1.2 Hz passa (amp \(String(format: "%.2f", ampIn)))")
check(ampOut < 0.2, "0.2 Hz barrado (amp \(String(format: "%.2f", ampOut)))")
// zero-phase: pico do sinal filtrado alinhado com o de entrada (sem defasagem)
let puro = (0..<240).map { sin(2 * .pi * 1.0 * Double($0) / fs) }
let pf = banda(puro, fs)
let iIn = (0..<240).max { puro[$0] < puro[$1] }!
let iOut = (0..<240).max { pf[$0] < pf[$1] }!
check(abs(iIn - iOut) <= 2, "zero-phase: picos alinhados (Δ=\(abs(iIn-iOut)))")

// ============================ 4. FFT / PSD ============================
grupo("FFT (vDSP) + PSD na banda")
// tom em 1.5 Hz (90 bpm) -> pico da PSD em 1.5 Hz
let tom = (0..<240).map { sin(2 * .pi * 1.5 * Double($0) / fs) }
let (fb, pb) = psdBanda(tom, fs)
check(!pb.isEmpty, "PSD não vazia")
var iMax = 0; for k in 1..<pb.count where pb[k] > pb[iMax] { iMax = k }
check(aprox(fb[iMax], 1.5, 0.05), "pico da PSD em 1.5 Hz (\(String(format: "%.3f", fb[iMax])))")

// ============================ 5. autocorrelação ============================
grupo("HR por autocorrelação")
let tomAC = banda((0..<240).map { sin(2 * .pi * 1.2 * Double($0) / fs) }, fs)
check(aprox(hrAutocorrelacao(tomAC, fs), 72, 3), "autocorr recupera 72 bpm")

// ============================ 6. ensemble — precisão ============================
grupo("Ensemble rPPG — precisão de BPM")
for alvo in [50.0, 66.0, 78.0, 90.0, 110.0, 150.0] {
    seed = 0x9E3779B97F4A7C15
    let (t, rgb) = geraRGB(bpm: alvo, fs: 30, seg: 8)
    let (ru, f) = reamostraUniforme(t, rgb)
    let e = estimaEnsemble(ru, f)
    check(aprox(e.bpm, alvo, 3.0), "alvo \(Int(alvo)) -> \(String(format: "%.1f", e.bpm)) bpm",
          "erro \(String(format: "%.1f", abs(e.bpm - alvo)))")
}

// ============================ 7. ensemble — qualidade/confirmação ============================
grupo("Ensemble — SQI, confirmação e SNR")
seed = 0x123456789
let (tb, rb) = geraRGB(bpm: 75, fs: 30, seg: 8, ruido: 0.3)
let (rub, fb2) = reamostraUniforme(tb, rb)
let eBom = estimaEnsemble(rub, fb2)
check(eBom.confirmado, "sinal limpo é confirmado")
check(eBom.sqi > 0.5, "SQI alto p/ sinal limpo (\(String(format: "%.2f", eBom.sqi)))")
check(eBom.snr >= Par.snrMinConf, "SNR >= 4 dB")
check(eBom.acordoMet >= 0.6 && eBom.acordoAc >= 0.5, "concordância cruzada alta")
// ruído puro (sem pulso) NÃO deve ser confirmado
seed = 0xDEADBEEF
var puroRuido = [[Double]]()
for _ in 0..<240 { puroRuido.append([130 + 8 * rnd(), 130 + 8 * rnd(), 130 + 8 * rnd()]) }
let eRuido = estimaEnsemble(puroRuido, 30)
check(!eRuido.confirmado, "ruído puro NÃO é confirmado (anti-falso-positivo)")

// ============================ 8. correção de harmônico ============================
grupo("Correção de harmônico (evita travar no 2º harmônico)")
// sinal cujo verde é dominado pelo 2º harmônico, mas fundamental presente
seed = 0x55
let (th, rh) = geraRGB(bpm: 60, fs: 30, seg: 8, amp: 0.5)
let (ruh, fh) = reamostraUniforme(th, rh)
let eh = estimaEnsemble(ruh, fh)
check(eh.bpm < 90, "não travou em 120 (2×60); ficou em \(String(format: "%.0f", eh.bpm))")

// ============================ 9. HRV ============================
grupo("HRV (SDNN)")
// trem de picos regular -> SDNN baixo; irregular -> SDNN maior
let regular = (0..<300).map { sin(2 * .pi * 1.2 * Double($0) / fs) }
let hrvReg = calculaHRV(banda(regular, fs), fs)
check(hrvReg >= 0 && hrvReg < 40, "SDNN de sinal regular é baixo (\(String(format: "%.1f", hrvReg)) ms)")

// ============================ 10. reamostragem uniforme ============================
grupo("Reamostragem uniforme (timestamps irregulares)")
// tempos irregulares mas sinal linear -> interpolação preserva valores
var ti = [Double](); var yi = [[Double]]()
var acc = 0.0
for i in 0..<100 { acc += 0.02 + 0.01 * Double(i % 3); ti.append(acc); yi.append([acc * 2, acc * 3, acc]) }
let (yu, fsu) = reamostraUniforme(ti, yi, fs: 30)
check(fsu == 30, "fs alvo mantido")
check(yu.count > 8, "gerou grid uniforme (\(yu.count) amostras)")
// canal 0 deve ser ~2× o canal 2 (relação linear preservada)
let ok0 = zip(yu.map { $0[0] }, yu.map { $0[2] }).allSatisfy { aprox($0, $1 * 2, 1e-6) }
check(ok0, "relação linear entre canais preservada")

// ============================ 11. casos-limite ============================
grupo("Casos-limite (robustez, sem crash)")
check(psdBanda([1.0], 30).p.isEmpty, "sinal de 1 amostra -> PSD vazia")
check(hrAutocorrelacao([1, 2], 30) == 0, "sinal curto -> autocorr 0")
check(calculaHRV([1, 2, 3], 30) == 0, "poucos pontos -> HRV 0")
let eVazio = estimaEnsemble([[130, 130, 130]], 30)   // 1 amostra
check(!eVazio.confirmado, "1 amostra -> não confirmado (sem crash)")
let (yc, _) = reamostraUniforme([0, 0.1], [[1, 1, 1], [2, 2, 2]])   // dur curta
check(yc.count >= 2, "duração curta -> devolve entrada sem crash")

// ============================ resumo ============================
print("\n" + String(repeating: "─", count: 42))
print("RESULTADO: \(passes) passaram, \(fails) falharam")
if fails > 0 { print("Falhas: \(falhas.joined(separator: ", "))"); exit(1) }
print("✓ TODOS OS TESTES PASSARAM")
