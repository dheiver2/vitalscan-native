//
//  LoginView.swift — Tela de acesso local simples (sem persistência, sem Keychain).
//  Credenciais fixas: admin / admin (case-sensitive). Barreira básica, não segurança real.
//

import SwiftUI

struct LoginView: View {
    var onSuccess: () -> Void

    @State private var usuario: String = ""
    @State private var senha: String = ""
    @State private var erro: String? = nil

    var body: some View {
        ZStack {
            Tema.bg.ignoresSafeArea()

            VStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VITALSCAN")
                        .font(.system(size: 22, weight: .heavy)).tracking(4)
                        .foregroundColor(Tema.txt)
                    Text("acesso local · frequência cardíaca por rPPG")
                        .font(.system(size: 10)).tracking(0.5).foregroundColor(Tema.mut)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 14) {
                    Text("USUÁRIO").rotulo()
                    TextField("admin", text: $usuario)
                        .textFieldStyle(.plain)
                        .disableAutocorrection(true)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.panelHi))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tema.line, lineWidth: 1))
                        .foregroundColor(Tema.txt)
                        .onSubmit { tentarEntrar() }

                    Text("SENHA").rotulo()
                    SecureField("••••••", text: $senha)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.panelHi))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tema.line, lineWidth: 1))
                        .foregroundColor(Tema.txt)
                        .onSubmit { tentarEntrar() }

                    if let erro {
                        Text(erro)
                            .font(.system(size: 11)).foregroundColor(Tema.warn)
                    }

                    Button("Entrar") { tentarEntrar() }
                        .buttonStyle(BotaoPrimario(ativo: true))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 14).fill(Tema.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tema.line, lineWidth: 1))
                .frame(width: 320)
            }
            .frame(width: 320)
        }
    }

    private func tentarEntrar() {
        if usuario == "admin" && senha == "admin" {
            erro = nil
            onSuccess()
        } else {
            erro = "Usuário ou senha incorretos."
        }
    }
}
