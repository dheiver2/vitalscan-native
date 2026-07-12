//
//  Widgets.swift — Componentes do monitor: gauge circular com coração pulsante,
//  pletismograma ao vivo, gráfico de tendência, barra de qualidade e métricas.
//

import SwiftUI

// Faixa adulto normal (config.py). Fora dela: alerta visual.
private let bpmBaixo = 60.0
private let bpmAlto = 100.0

/// Gauge circular animado da FC com coração pulsante em sincronia com a batida.
struct GaugeFC: View {
    let bpm: Double
    let ok: Bool
    let flash: Double            // 0..1, pico a cada batida
    let progresso: Double

    private var cor: Color {
        guard ok else { return Tema.mut }
        if bpm < bpmBaixo || bpm > bpmAlto { return Tema.warn }
        return Tema.acc
    }
    private var fracao: Double {
        guard bpm > 0 else { return 0 }
        return min(max((bpm - Par.bpmMin) / (Par.bpmMax - Par.bpmMin), 0), 1)
    }

    var body: some View {
        ZStack {
            // trilho
            Circle().trim(from: 0, to: 0.75)
                .stroke(Tema.line, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(135))
            // arco de progresso enquanto calibra (branco), senão FC (cor)
            Circle().trim(from: 0, to: 0.75 * (ok ? fracao : progresso))
                .stroke(ok ? cor : Tema.accB,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.4), value: fracao)
                .animation(.easeOut(duration: 0.2), value: progresso)

            VStack(spacing: 2) {
                // coração pulsante
                Image(systemName: "heart.fill")
                    .font(.system(size: 22))
                    .foregroundColor(cor)
                    .scaleEffect(1.0 + 0.35 * flash)
                    .opacity(ok ? (0.55 + 0.45 * flash) : 0.3)
                    .animation(.easeOut(duration: 0.15), value: flash)
                Text(bpm > 0 && ok ? String(format: "%.0f", bpm) : "--")
                    .font(.system(size: 46, weight: .thin, design: .rounded))
                    .foregroundColor(Tema.txt)
                    .monospacedDigit()
                Text("BPM").font(.system(size: 11, weight: .semibold))
                    .tracking(3).foregroundColor(Tema.mut)
            }
        }
        .frame(width: 190, height: 190)
    }
}

/// Pletismograma ao vivo (forma de onda do melhor método).
struct Pletismograma: View {
    let dados: [Double]
    let cor: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if dados.count > 2 {
                let mn = dados.min() ?? 0, mx = dados.max() ?? 1
                let rng = (mx - mn) == 0 ? 1 : (mx - mn)
                Path { path in
                    for (i, v) in dados.enumerated() {
                        let x = w * Double(i) / Double(dados.count - 1)
                        let y = h - (v - mn) / rng * h * 0.9 - h * 0.05
                        i == 0 ? path.move(to: CGPoint(x: x, y: y))
                               : path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(cor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                .shadow(color: cor.opacity(0.5), radius: 3)
            } else {
                Path { p in p.move(to: CGPoint(x: 0, y: h/2)); p.addLine(to: CGPoint(x: w, y: h/2)) }
                    .stroke(Tema.line, lineWidth: 1)
            }
        }
    }
}

/// Gráfico de tendência do BPM (histórico ~5 min).
struct Tendencia: View {
    let dados: [Double]
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if dados.count > 1 {
                let mn = (dados.min() ?? 60) - 5, mx = (dados.max() ?? 100) + 5
                let rng = (mx - mn) == 0 ? 1 : (mx - mn)
                Path { path in
                    for (i, v) in dados.enumerated() {
                        let x = w * Double(i) / Double(dados.count - 1)
                        let y = h - (v - mn) / rng * h
                        i == 0 ? path.move(to: CGPoint(x: x, y: y))
                               : path.addLine(to: CGPoint(x: x, y: y))
                    }
                }.stroke(Tema.acc.opacity(0.8), lineWidth: 1.5)
            } else {
                Text("aguardando tendência…")
                    .font(.system(size: 10)).foregroundColor(Tema.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Barra de qualidade do sinal (SQI 0..1).
struct BarraQualidade: View {
    let sqi: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tema.line).frame(height: 5)
                Capsule().fill(sqi >= 0.6 ? Tema.acc : (sqi >= 0.4 ? Tema.accB : Tema.warn))
                    .frame(width: geo.size.width * min(max(sqi, 0), 1), height: 5)
                    .animation(.easeOut(duration: 0.3), value: sqi)
            }
        }.frame(height: 5)
    }
}

/// Métrica compacta (rótulo + valor grande + unidade).
struct Metrica: View {
    let titulo: String
    let valor: String
    let unidade: String
    var cor: Color = Tema.txt
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(titulo).rotulo()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(valor).font(.system(size: 30, weight: .light, design: .rounded))
                    .foregroundColor(cor).monospacedDigit()
                Text(unidade).font(.system(size: 12)).foregroundColor(Tema.mut)
            }
        }
    }
}

/// Cartão sem moldura (separação por espaço).
struct Cartao<Content: View>: View {
    let titulo: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titulo).rotulo()
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tema.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tema.line, lineWidth: 1))
    }
}
