//
//  App.swift — Ponto de entrada e layout do monitor VitalScan (SwiftUI/AppKit).
//

import SwiftUI

@main
struct VitalScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var isAuthenticated = false

    var body: some Scene {
        WindowGroup("VitalScan") {
            Group {
                if isAuthenticated {
                    MonitorView()
                } else {
                    LoginView(onSuccess: { isAuthenticated = true })
                }
            }
            .frame(minWidth: 1000, minHeight: 820)
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 880)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MonitorView: View {
    @StateObject private var cam = CameraManager()

    var body: some View {
        VStack(spacing: 16) {
            cabecalho
            if let erro = cam.erro {
                avisoErro(erro)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    painelCamera.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView(.vertical, showsIndicators: false) {
                        painelMetricas
                    }
                    .frame(width: 300)
                }
                .frame(maxHeight: .infinity)
            }
            rodape
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // o preto preenche a janela inteira (inclusive a faixa dos controles),
        // mas o conteúdo acima respeita a safe area e fica abaixo deles.
        .background(Tema.bg.ignoresSafeArea())
    }

    // ---- cabeçalho: marca + seletor de câmera + status ----
    private var cabecalho: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("VITALSCAN")
                    .font(.system(size: 20, weight: .heavy)).tracking(4)
                    .foregroundColor(Tema.txt)
                Text("frequência cardíaca por rPPG · nativo macOS")
                    .font(.system(size: 10)).tracking(0.5).foregroundColor(Tema.mut)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(cam.ok ? Tema.acc : (cam.temRosto ? Tema.accB : Tema.mut))
                    .frame(width: 7, height: 7)
                Text(cam.status).font(.system(size: 11)).foregroundColor(Tema.mut)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Tema.panel))
            .overlay(Capsule().stroke(Tema.line, lineWidth: 1))

            if cam.cameras.count > 1 {
                Picker("", selection: Binding(
                    get: { cam.cameraSelecionada },
                    set: { cam.trocarCamera($0) })) {
                    ForEach(cam.cameras) { c in Text(c.nome).tag(c.id) }
                }
                .pickerStyle(.menu).frame(width: 160).tint(Tema.mut)
            }

            Button(cam.rodando ? "Parar" : "Iniciar") {
                cam.rodando ? cam.parar() : cam.iniciar()
            }
            .buttonStyle(BotaoPrimario(ativo: !cam.rodando))
        }
    }

    // ---- painel esquerdo: câmera + overlay ----
    private var painelCamera: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Tema.panel)
            if cam.rodando {
                PreviewCamera(layer: cam.previewLayer)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                OverlayFace(det: cam.deteccao, ativo: cam.ok)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack {
                    Spacer()
                    Pletismograma(dados: cam.pletismograma,
                                  cor: cam.ok ? Tema.acc : Tema.mut)
                        .frame(height: 54)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                        .background(
                            LinearGradient(colors: [.clear, Tema.bg.opacity(0.7)],
                                           startPoint: .top, endPoint: .bottom))
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 44)).foregroundColor(Tema.faint)
                    Text("Clique em Iniciar e posicione o rosto")
                        .font(.system(size: 12)).foregroundColor(Tema.mut)
                }
            }
            // progresso de calibração
            if cam.rodando && cam.progresso < 1 && cam.temRosto {
                VStack {
                    HStack {
                        Spacer()
                        Text("calibrando \(Int(cam.progresso * 100))%")
                            .font(.system(size: 10)).foregroundColor(Tema.accB)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Tema.bg.opacity(0.6)))
                            .padding(12)
                    }
                    Spacer()
                }
            }
        }
        .frame(minHeight: 440)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Tema.line, lineWidth: 1))
    }

    // ---- painel direito: gauge + métricas + validação ----
    private var painelMetricas: some View {
        VStack(spacing: 16) {
            Cartao(titulo: "FREQUÊNCIA CARDÍACA") {
                HStack { Spacer()
                    GaugeFC(bpm: cam.bpm, ok: cam.ok, flash: cam.batidaFlash,
                            progresso: cam.progresso)
                    Spacer() }
            }
            Cartao(titulo: "QUALIDADE DO SINAL") {
                VStack(alignment: .leading, spacing: 8) {
                    BarraQualidade(sqi: cam.sqi)
                    HStack {
                        Text(String(format: "SQI %.0f%%", cam.sqi * 100))
                            .font(.system(size: 11)).foregroundColor(Tema.mut)
                        Spacer()
                        Text(String(format: "%.0f fps", cam.fps))
                            .font(.system(size: 11)).foregroundColor(Tema.faint)
                    }
                }
            }
            Cartao(titulo: "MÉTRICAS") {
                HStack {
                    Metrica(titulo: "HRV · SDNN",
                            valor: cam.est.hrv > 0 ? String(format: "%.0f", cam.est.hrv) : "--",
                            unidade: "ms", cor: Tema.accP)
                    Spacer()
                    Metrica(titulo: "SNR",
                            valor: cam.est.snr > -90 ? String(format: "%.1f", cam.est.snr) : "--",
                            unidade: "dB", cor: Tema.accB)
                }
            }
            Cartao(titulo: "VALIDAÇÃO CRUZADA") {
                VStack(alignment: .leading, spacing: 6) {
                    linhaVal("método", cam.est.melhor, "\(Int(cam.est.bpmM1)) bpm")
                    linhaVal("2º método", cam.est.segundo, "\(Int(cam.est.bpmM2)) bpm")
                    linhaVal("autocorr.", "AC", cam.est.bpmAc > 0 ? "\(Int(cam.est.bpmAc)) bpm" : "--")
                    HStack {
                        Text("concordância").font(.system(size: 10)).foregroundColor(Tema.faint)
                        Spacer()
                        Text(String(format: "%.0f%% / %.0f%%",
                                    cam.est.acordoMet * 100, cam.est.acordoAc * 100))
                            .font(.system(size: 10)).foregroundColor(Tema.mut)
                    }
                }
            }
            Cartao(titulo: "TENDÊNCIA") {
                Tendencia(dados: cam.historico).frame(height: 48)
            }
        }
    }

    private func linhaVal(_ r: String, _ nome: String, _ v: String) -> some View {
        HStack {
            Text(r).font(.system(size: 10)).foregroundColor(Tema.faint).frame(width: 66, alignment: .leading)
            Text(nome).font(.system(size: 11, weight: .medium)).foregroundColor(Tema.txt)
            Spacer()
            Text(v).font(.system(size: 11)).foregroundColor(Tema.mut).monospacedDigit()
        }
    }

    private func avisoErro(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 40)).foregroundColor(Tema.warn)
            Text(msg).font(.system(size: 13)).foregroundColor(Tema.txt)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Tentar novamente") { cam.iniciar() }
                .buttonStyle(BotaoPrimario(ativo: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rodape: some View {
        HStack {
            Text("POS · CHROM · LGI · OMIT · GREEN  ·  fusão espectral por SNR  ·  \(cam.modoDeteccao)")
                .font(.system(size: 10)).tracking(0.5).foregroundColor(Tema.faint)
            Spacer()
            Text("Não é dispositivo médico · uso informativo")
                .font(.system(size: 10)).foregroundColor(Tema.faint)
        }
    }
}

/// Botão pílula (fantasma ou preenchido de acento).
struct BotaoPrimario: ButtonStyle {
    let ativo: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold)).tracking(0.5)
            .padding(.horizontal, 22).padding(.vertical, 9)
            .foregroundColor(ativo ? Color(hex: 0x032512) : Tema.txt)
            .background(
                Capsule().fill(ativo ? Tema.acc : Color.clear))
            .overlay(Capsule().stroke(ativo ? Color.clear : Tema.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
