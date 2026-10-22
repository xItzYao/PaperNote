import SwiftUI

/// 雲端備份設定（Google Drive）
struct BackupView: View {
    @ObservedObject private var backup = BackupManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var signedIn = GoogleAuth.shared.isSignedIn
    @State private var clientID = UserDefaults.standard.string(forKey: "google.clientID") ?? ""
    @State private var autoBackup = BackupManager.shared.autoBackup
    @State private var message: String?
    @State private var confirmRestore = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if signedIn {
                        Label("已連結 Google Drive", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button {
                            backup.backupNow()
                        } label: {
                            Label("立即備份", systemImage: "icloud.and.arrow.up")
                        }
                        .disabled(backup.isRunning)
                        Button {
                            confirmRestore = true
                        } label: {
                            Label("從 Google Drive 還原…", systemImage: "icloud.and.arrow.down")
                        }
                        .disabled(backup.isRunning)
                        Button(role: .destructive) {
                            confirmSignOut = true
                        } label: {
                            Label("中斷連結", systemImage: "link.badge.plus")
                        }
                    } else {
                        Button {
                            connect()
                        } label: {
                            Label("連結 Google Drive", systemImage: "link")
                        }
                        .disabled(!GoogleAuth.shared.hasClientID)
                        if !GoogleAuth.shared.hasClientID {
                            Text("請先在下方貼上 OAuth 用戶端 ID。").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Google Drive")
                }

                Section {
                    Toggle("自動備份", isOn: $autoBackup)
                        .onChange(of: autoBackup) { _, v in backup.autoBackup = v }
                } footer: {
                    Text("每 10 分鐘，以及關閉筆記本後，自動備份到 Google Drive 的「\(BackupManager.rootFolderName)」資料夾。備份的是原始檔，筆跡、PDF、表格、螢光標示還原後都能繼續編輯；只會上傳有變動的檔案。")
                }

                Section("狀態") {
                    if backup.isRunning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(backup.status).foregroundStyle(.secondary)
                        }
                    } else if !backup.status.isEmpty {
                        Text(backup.status).foregroundStyle(.secondary)
                    }
                    LabeledContent("上次備份", value: backup.lastBackup?.formatted(date: .abbreviated, time: .shortened) ?? "尚未備份")
                    if let e = backup.lastError {
                        Text(e).font(.footnote).foregroundStyle(.red)
                    }
                }

                if GoogleAuth.builtInClientID.isEmpty {
                    Section {
                        TextField("xxxx.apps.googleusercontent.com", text: $clientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                            .onChange(of: clientID) { _, v in
                                UserDefaults.standard.set(v.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "google.clientID")
                            }
                    } header: {
                        Text("OAuth 用戶端 ID")
                    } footer: {
                        Text("在 Google Cloud 建立「iOS」類型的 OAuth 用戶端後，把用戶端 ID 貼在這裡。")
                    }
                }
            }
            .navigationTitle("雲端備份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .confirmationDialog("從 Google Drive 還原？", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("還原") { restore() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只會加入本機沒有的筆記本，不會覆蓋或刪除本機現有的筆記本。")
            }
            .confirmationDialog("中斷與 Google Drive 的連結？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("中斷連結", role: .destructive) {
                    GoogleAuth.shared.signOut()
                    BackupManager.shared.resetRemoteState()
                    signedIn = false
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("雲端已經備份的檔案會保留。")
            }
            .alert("雲端備份", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func connect() {
        GoogleAuth.shared.signIn { result in
            switch result {
            case .success:
                signedIn = true
                backup.backupNow()
            case let .failure(error):
                message = error.localizedDescription
            }
        }
    }

    private func restore() {
        Task {
            do {
                let n = try await backup.restore()
                await MainActor.run { message = n == 0 ? "本機已經有全部的筆記本。" : "已還原 \(n) 本筆記本。" }
            } catch {
                await MainActor.run { message = "還原失敗：\(error.localizedDescription)" }
            }
        }
    }
}
