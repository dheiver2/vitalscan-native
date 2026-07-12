//
//  Theme.swift — Paleta VitalScan (minimalista, black). Porte de theme.py.
//

import SwiftUI

enum Tema {
    static let bg = Color(hex: 0x000000)
    static let panel = Color(hex: 0x080808)
    static let panelHi = Color(hex: 0x111111)
    static let line = Color(hex: 0x1c1c1c)
    static let txt = Color(hex: 0xf5f5f5)
    static let mut = Color(hex: 0x666666)
    static let faint = Color(hex: 0x3a3a3a)

    static let acc = Color(hex: 0x5cf08a)        // verde clínico — só p/ dado vivo
    static let accDim = Color(hex: 0x1e3a28)
    static let warn = Color(hex: 0xff5a4d)
    static let accB = Color(hex: 0xf5f5f5)        // SQI monocromático
    static let accP = Color(hex: 0x9a9a9a)        // HRV cinza
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

extension Text {
    func rotulo() -> some View {
        self.font(.system(size: 10, weight: .bold))
            .tracking(2.5).foregroundColor(Tema.faint)
    }
}
