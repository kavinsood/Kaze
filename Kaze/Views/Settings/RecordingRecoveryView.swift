import AppKit
import SwiftUI

struct RecordingRecoveryView: View {
    @ObservedObject var vault: RecordingVault
    @State private var alertText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Recordings").font(.title2.bold())
            Text("Audio is written privately to disk while you speak. A transcript stays here even if the network fails or a paste is not accepted. Kaze cannot verify a paste in every app, so delivery is never confirmed automatically.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = vault.storageError {
                Text("Recording storage unavailable: \(error)").foregroundStyle(.red)
            }
            Divider()
            if vault.jobs.isEmpty {
                Spacer()
                Text("No saved recordings yet").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(vault.jobs) { job in row(job) }
                    }
                }
            }
            Text("Audio and text remain on this Mac until you use Delete. Mark Delivered only records your confirmation; it does not erase the audio. Export WAV before deleting if you want another copy.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .alert("Recording", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("OK") { alertText = nil }
        } message: { Text(alertText ?? "") }
    }

    private func row(_ job: RecordingJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                Spacer()
                Text(statusLabel(job)).font(.caption).foregroundStyle(.secondary)
            }
            if let warning = job.captureWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = job.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !job.transcript.isEmpty {
                Text(job.transcript).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if job.status != .ready && job.status != .delivered {
                    Text("Partial transcript — more audio may remain to transcribe.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                if job.status == .failed || job.status == .waitingToRetry {
                    Button("Retry") { perform { try vault.retry(id: job.id) } }
                }
                if !job.transcript.isEmpty {
                    Button("Copy Text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(job.transcript, forType: .string)
                    }
                }
                if job.status == .ready {
                    Button("Mark Delivered") { perform { try vault.markDelivered(id: job.id) } }
                }
                Button("Export WAV…") { export(job.id) }
                    .disabled(job.status == .recording)
                Spacer()
                Button("Delete…", role: .destructive) { confirmDelete(job.id) }
                    .disabled(job.status == .recording || job.status == .transcribing)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func statusLabel(_ job: RecordingJob) -> String {
        switch job.status {
        case .recording: return "Recording"
        case .pending: return "Queued"
        case .transcribing: return "Transcribing"
        case .waitingToRetry:
            return "Retrying \(job.nextAttempt?.formatted(date: .omitted, time: .shortened) ?? "soon")"
        case .failed: return "Needs manual retry"
        case .ready: return "Ready · paste unconfirmed"
        case .delivered: return "Delivered · confirmed by you"
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { alertText = error.localizedDescription }
    }

    private func export(_ id: UUID) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Kaze-\(id.uuidString.prefix(8)).wav"
        panel.allowedContentTypes = [.wav]
        if panel.runModal() == .OK, let destination = panel.url {
            perform { try vault.export(id: id, to: destination) }
        }
    }

    private func confirmDelete(_ id: UUID) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Permanently delete this recording?"
        alert.informativeText = "The saved audio and transcript for this job will be removed. This cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Recording")
        if alert.runModal() == .alertSecondButtonReturn {
            perform { try vault.delete(id: id) }
        }
    }
}
