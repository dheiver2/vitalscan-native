# 💓 VitalScan — nativo macOS (Swift)

Mede a **frequência cardíaca pela webcam**, sem sensor de contato, detectando a
variação sutil da cor da pele a cada batimento (**fotopletismografia remota —
rPPG**). Interface no estilo de **monitor de sinais vitais hospitalar**.

Esta é a reescrita **100% nativa** do [`batimentos_pele`](../../batimentos_pele)
(que era Python/PyQt6): **Swift + SwiftUI + AVFoundation + Vision + Accelerate**.
**Zero Python, zero OpenCV, zero MediaPipe, zero dependências externas.**

## Por que nativo

| Antes (Python) | Agora (nativo) |
|---|---|
| OpenCV `VideoCapture` | **AVFoundation** (`AVCaptureSession`) |
| MediaPipe Face Mesh (modelo ~3,8 MB baixado) | **Vision** (`VNDetectFaceLandmarksRequest`) |
| NumPy / SciPy (`butter`, `filtfilt`, `fft`, `svd`, `qr`) | **Accelerate** (vDSP) + álgebra em Swift puro |
| PyQt6 + pyqtgraph | **SwiftUI** |
| `pip install` de 6 pacotes | **nenhuma dependência** — só as Command Line Tools |

## Compilar e rodar

```bash
./build_app.sh            # gera ~/Desktop/VitalScan.app
open ~/Desktop/VitalScan.app
```

O `build_app.sh` compila todos os fontes com `swiftc` num bundle `.app` assinado
(ad-hoc) com `NSCameraUsageDescription`. Na primeira execução o macOS pede
permissão de câmera (Ajustes → Privacidade e Segurança → Câmera).

## Núcleo científico (porte fiel de `dsp.py`)

- **Ensemble de 5 métodos** — **POS** (Wang 2017, janela deslizante + overlap-add),
  **CHROM** (de Haan 2013), **LGI** (Pilz 2018), **OMIT** (Álvarez-Casado 2023)
  e canal verde.
- **Fusão espectral por SNR** — soma das PSDs normalizadas num grid de frequência
  comum (`nfft = 4096`), robusta a um método travado num harmônico.
- **Desambiguação de harmônico** contra a autocorrelação.
- **Validação cruzada** entre métodos + verificação independente por
  autocorrelação + piso de SNR (4 dB) para confirmar pulso real.
- **Interpolação parabólica do pico** (precisão sub-bin), **SQI composto**,
  **HRV (SDNN)**.

### Truques que evitam SVD/QR completos
- **LGI** precisa da direção dominante = autovetor dominante da 3×3 `C·Cᵀ`
  (via *power iteration*).
- **OMIT** precisa de `Q[:,0]` da QR de `C` (3×N), que é apenas a **primeira
  coluna de `C` normalizada**.
- Em ambos `P = I − s·sᵀ` é invariante ao sinal de `s`.

### Filtro
Butterworth passa-banda ordem 4 (0,7–3,0 Hz) projetado em runtime
(`zpk → lp2bp → bilinear`, réplica de `scipy.signal.butter`) + `filtfilt`
zero-phase com condições iniciais de regime (`lfilter_zi`).

## Arquitetura

| Arquivo | Papel |
|---|---|
| `DSP.swift` | Ensemble rPPG, PSD, autocorrelação, HRV, SQI (porte de `dsp.py`) |
| `SignalMath.swift` | FFT (vDSP), design Butterworth, `filtfilt` |
| `FaceROI.swift` | ROIs de pele (testa + bochechas) via Vision, média RGB (YCrCb) |
| `CameraManager.swift` | Captura AVFoundation + laço rPPG (porte de `worker.py`) |
| `CameraView.swift` | Preview + overlay dos landmarks/ROIs |
| `Widgets.swift` | Gauge com coração pulsante, pletismograma, tendência, métricas |
| `App.swift` | Layout do monitor + entry point |
| `Theme.swift` | Paleta (porte de `theme.py`) |

## Ícone

Gerado nativamente com CoreGraphics (sem editor externo):

```bash
./scripts/make_icon.sh     # regenera assets/VitalScan.icns e assets/icon_master.png
```

O `build_app.sh` embute `assets/VitalScan.icns` no bundle.

## Testes

```bash
./run_tests.sh     # 36 testes do núcleo DSP, sem câmera (só CLT)
```

Cobre: Butterworth+`filtfilt` (atenuação DC, banda passante/rejeitada, zero-phase),
FFT/PSD, autocorrelação, ensemble em 6 frequências, SQI/confirmação,
**anti-falso-positivo** (ruído puro não é confirmado), correção de harmônico,
HRV, reamostragem e casos-limite sem crash.

## Validação do DSP

Sinal sintético (pulso + harmônico + deriva de iluminação + ruído), 8 s @ 30 fps:

| Alvo (bpm) | Estimado | Erro | SNR |
|---|---|---|---|
| 55 | 55,2 | 0,2 | 13,2 dB |
| 72 | 72,5 | 0,5 | 13,6 dB |
| 96 | 96,5 | 0,5 | 13,7 dB |
| 120 | 120,3 | 0,3 | 13,0 dB |

## Aviso

Não é dispositivo médico. Uso informativo/educacional.
