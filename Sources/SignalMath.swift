//
//  SignalMath.swift — FFT (Accelerate/vDSP), design Butterworth passa-banda e
//  filtfilt (zero-phase). Substituem numpy.fft e scipy.signal.{butter,filtfilt}.
//

import Foundation
import Accelerate

// ============================ FFT real via vDSP ============================

enum FFT {
    /// Espectro de potência (|rfft|²) de `x` com zero-padding até `nfft`
    /// (potência de 2). Retorna nfft/2 + 1 bins (0..Nyquist).
    static func powerSpectrum(_ x: [Double], nfft: Int) -> [Double] {
        let log2n = vDSP_Length(log2(Double(nfft)).rounded())
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            return [Double](repeating: 0, count: nfft / 2 + 1)
        }
        defer { vDSP_destroy_fftsetupD(setup) }

        // zero-pad
        var input = [Double](repeating: 0, count: nfft)
        for i in 0..<min(x.count, nfft) { input[i] = x[i] }

        let half = nfft / 2
        var real = [Double](repeating: 0, count: half)
        var imag = [Double](repeating: 0, count: half)
        var power = [Double](repeating: 0, count: half + 1)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBufferPointer { inp in
                    inp.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) { cplx in
                        vDSP_ctozD(cplx, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                // vDSP empacota: real[0]=DC, imag[0]=Nyquist. Escala 1/2 (convenção vDSP).
                let dc = rp[0] * 0.5
                let nyq = ip[0] * 0.5
                power[0] = dc * dc
                power[half] = nyq * nyq
                for k in 1..<half {
                    let re = rp[k] * 0.5
                    let im = ip[k] * 0.5
                    power[k] = re * re + im * im
                }
            }
        }
        return power
    }
}

// ============================ Números complexos (design de filtro) ============================

struct Cx {
    var re: Double
    var im: Double
    init(_ re: Double, _ im: Double = 0) { self.re = re; self.im = im }
    static func + (a: Cx, b: Cx) -> Cx { Cx(a.re + b.re, a.im + b.im) }
    static func - (a: Cx, b: Cx) -> Cx { Cx(a.re - b.re, a.im - b.im) }
    static func * (a: Cx, b: Cx) -> Cx { Cx(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
    static func / (a: Cx, b: Cx) -> Cx {
        let d = b.re * b.re + b.im * b.im
        return Cx((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }
    var abs2: Double { re * re + im * im }
    func sqrtC() -> Cx {
        let r = (re * re + im * im).squareRoot()
        let sr = ((r + re) / 2).squareRoot()
        var si = ((r - re) / 2).squareRoot()
        if im < 0 { si = -si }
        return Cx(sr, si)
    }
}

// ============================ Butterworth passa-banda (zpk) ============================

enum Butterworth {
    /// Passa-banda ordem `order` (por banda; efetivamente 2·order polos).
    /// `lowNorm`/`highNorm` normalizados por Nyquist (0..1). Retorna (b, a).
    static func bandpass(order N: Int, lowNorm: Double, highNorm: Double)
        -> (b: [Double], a: [Double]) {
        // 1) protótipo Butterworth analógico passa-baixa (Wn=1): buttap.
        //    polos p_k = -exp(1j·π·m/(2N)) = -(cosθ + j·sinθ), m ∈ {-N+1,…,N-1}.
        let poles: [Cx] = (0..<N).map { k in
            let m = Double(-N + 1 + 2 * k)
            let theta = Double.pi * m / (2 * Double(N))
            return Cx(-cos(theta), -sin(theta))
        }
        let zeros = [Cx]()
        var gain = 1.0

        // 2) prewarp (scipy usa fs_=2.0): warped = 2*fs_*tan(pi*Wn/fs_)
        let fs_ = 2.0
        let warpedLo = 2 * fs_ * tan(Double.pi * lowNorm / fs_)
        let warpedHi = 2 * fs_ * tan(Double.pi * highNorm / fs_)
        let bw = warpedHi - warpedLo
        let wo = (warpedLo * warpedHi).squareRoot()

        // 3) lp2bp_zpk
        let degree = poles.count - zeros.count
        let zLp = zeros.map { $0 * Cx(bw / 2) }
        let pLp = poles.map { $0 * Cx(bw / 2) }
        let wo2 = Cx(wo * wo)
        func expand(_ v: [Cx]) -> [Cx] {
            var out = [Cx]()
            for x in v {
                let disc = (x * x - wo2).sqrtC()
                out.append(x + disc)
                out.append(x - disc)
            }
            return out
        }
        var zBp = expand(zLp)
        let pBp = expand(pLp)
        for _ in 0..<degree { zBp.append(Cx(0)) }            // zeros na origem
        gain *= pow(bw, Double(degree))

        // 4) bilinear_zpk (fs=fs_)
        let fs2 = Cx(2 * fs_)
        func bilin(_ v: [Cx]) -> [Cx] { v.map { (fs2 + $0) / (fs2 - $0) } }
        let deg2 = pBp.count - zBp.count
        var zZ = bilin(zBp)
        let pZ = bilin(pBp)
        for _ in 0..<deg2 { zZ.append(Cx(-1)) }
        // ganho: k * real(prod(fs2 - z)/prod(fs2 - p))
        var numG = Cx(1), denG = Cx(1)
        for z in zBp { numG = numG * (fs2 - z) }
        for p in pBp { denG = denG * (fs2 - p) }
        let kZ = gain * (numG / denG).re

        // 5) zpk -> tf (polinômios reais)
        let b = polyFromRoots(zZ).map { $0.re * kZ }
        let a = polyFromRoots(pZ).map { $0.re }
        return (b, a)
    }

    /// Expande raízes em coeficientes polinomiais: prod(x - r_i).
    private static func polyFromRoots(_ roots: [Cx]) -> [Cx] {
        var coeffs = [Cx(1)]
        for r in roots {
            var next = [Cx](repeating: Cx(0), count: coeffs.count + 1)
            for i in 0..<coeffs.count {
                next[i] = next[i] + coeffs[i]
                next[i + 1] = next[i + 1] - coeffs[i] * r
            }
            coeffs = next
        }
        return coeffs
    }
}

// ============================ filtfilt (zero-phase) ============================

enum Filtfilt {
    /// Filtragem forward-backward equivalente a scipy.signal.filtfilt com
    /// padding por reflexão ímpar (padtype='odd', padlen = 3·max(len a,len b)).
    static func apply(b: [Double], a: [Double], x: [Double]) -> [Double] {
        let ntaps = max(a.count, b.count)
        let edge = 3 * ntaps
        guard x.count > edge else {
            // sinal curto demais p/ padding — filtra sem padding
            let f = lfilter(b, a, x, zi: lfilterZi(b, a).map { $0 * (x.first ?? 0) })
            let bwd = lfilter(b, a, Array(f.reversed()),
                              zi: lfilterZi(b, a).map { $0 * (f.last ?? 0) })
            return Array(bwd.reversed())
        }
        // padding ímpar: 2*x[0] - x[edge..1], e 2*x[-1] - x[-2..-edge-1]
        var ext = [Double]()
        ext.reserveCapacity(x.count + 2 * edge)
        for i in stride(from: edge, through: 1, by: -1) { ext.append(2 * x[0] - x[i]) }
        ext.append(contentsOf: x)
        let n = x.count
        for i in 2...(edge + 1) { ext.append(2 * x[n - 1] - x[n - 1 - i + 1]) }

        let zi = lfilterZi(b, a)
        let fwd = lfilter(b, a, ext, zi: zi.map { $0 * ext[0] })
        let rev = Array(fwd.reversed())
        let bwd = lfilter(b, a, rev, zi: zi.map { $0 * rev[0] })
        let y = Array(bwd.reversed())
        return Array(y[edge..<(edge + n)])
    }

    /// lfilter Direct-Form II transposto com condições iniciais `zi`.
    private static func lfilter(_ b0: [Double], _ a0: [Double], _ x: [Double],
                                zi: [Double]) -> [Double] {
        let a00 = a0[0]
        let b = b0.map { $0 / a00 }
        let a = a0.map { $0 / a00 }
        let n = max(a.count, b.count)
        var bb = b + [Double](repeating: 0, count: max(0, n - b.count))
        var aa = a + [Double](repeating: 0, count: max(0, n - a.count))
        bb = Array(bb[0..<n]); aa = Array(aa[0..<n])
        var z = zi
        if z.count < n - 1 { z += [Double](repeating: 0, count: n - 1 - z.count) }
        var y = [Double](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let xi = x[i]
            let yi = bb[0] * xi + (z.isEmpty ? 0 : z[0])
            y[i] = yi
            for j in 1..<(n - 1) {
                z[j - 1] = bb[j] * xi + z[j] - aa[j] * yi
            }
            if n - 1 >= 1 { z[n - 2] = bb[n - 1] * xi - aa[n - 1] * yi }
        }
        return y
    }

    /// Condições iniciais de regime estacionário (scipy.signal.lfilter_zi).
    private static func lfilterZi(_ b0: [Double], _ a0: [Double]) -> [Double] {
        let a00 = a0[0]
        let b = b0.map { $0 / a00 }
        let a = a0.map { $0 / a00 }
        let n = max(a.count, b.count)
        var bb = b + [Double](repeating: 0, count: max(0, n - b.count))
        var aa = a + [Double](repeating: 0, count: max(0, n - a.count))
        bb = Array(bb[0..<n]); aa = Array(aa[0..<n])
        guard n > 1 else { return [] }
        // zi[0] = B.sum()/(I−A companion).col0.sum(); recorrência acumulada
        var zi = [Double](repeating: 0, count: n - 1)
        // IminusA[:,0].sum() = 1 + sum(a[1:])  (coluna 0 da companion transposta)
        var asum = 1.0
        var bsum = 0.0
        for k in 1..<n { asum += aa[k]; bsum += bb[k] - aa[k] * bb[0] }
        zi[0] = bsum / asum
        var acc = 1.0, csum = 0.0
        for k in 1..<(n - 1) {
            acc += aa[k]
            csum += bb[k] - aa[k] * bb[0]
            zi[k] = acc * zi[0] - csum
        }
        return zi
    }
}
