# Kaze Cloud

Hold a global hotkey, speak, and paste the transcription into the active macOS app. This fork uses only Cloudflare-hosted `@cf/openai/whisper-large-v3-turbo`. Speech recognition does not run locally.

## How it works

1. Press the global hotkey to begin recording.
2. Kaze writes mono PCM audio to a private, locally synchronized recording journal as it arrives and displays a waveform.
3. Release the hotkey (or press it again in toggle mode).
4. Kaze sends independent 30-second WAV chunks to Whisper Large V3 Turbo on Workers AI. Each successful chunk and its transcript are checkpointed to disk before the next request.
5. The complete transcript is saved before Kaze posts ⌘V to the focused app. The app cannot prove that another app accepted the paste; delivery stays unconfirmed until you mark it delivered.

There is no five-minute recording cutoff. If a network request fails temporarily, Kaze retries with backoff, including after relaunch; other failures remain available for manual retry. The model runs on Cloudflare's infrastructure. Long recordings use disk space (about 5.5 MB per minute at 48 kHz); free space and the recording format are practical limits. Standard WAV export is limited to files below 4 GB, although the original journal can be larger.

## Cloudflare setup

You need:

- A Cloudflare account with Workers AI access.
- Your 32-character Cloudflare Account ID.
- A token created with Cloudflare's **Create a Workers AI API Token** template. A custom token needs **Workers AI → Read** on the selected account.

Enter these values during onboarding or under **Settings → General → Cloudflare Workers AI**. The Account ID is stored in app preferences. The API token is stored in macOS Keychain.

## Privacy

Audio is sent directly to Cloudflare's native Workers AI endpoint for transcription by the Cloudflare-hosted model. It is not sent through an OpenAI provider account, and the app does not run an additional LLM over the transcript.

Your employer must still approve Cloudflare as a processor. Kaze stores audio and transcripts in its sandboxed Application Support `com.kavin.KazeCloud/Recordings` directory until you explicitly delete each recording under **Settings → Recordings**. Marking a recording delivered does not delete its audio. The separate, most-recent-50 text History can be cleared independently and is not a backup for the recording journal. Recordings are not encrypted beyond normal macOS account/FileVault protection. You can export WAV, retry failed jobs, and copy saved or partial transcripts from the Recordings tab.

Capture-format errors, microphone interruptions, and detected timestamp gaps stop recording and flag the saved portion for manual review. A sudden hardware failure, lack of free disk space, or a microphone that never delivers audio cannot be repaired by software. The app does not use background URLSession transfers: a persisted local journal and saved per-chunk progress allow work to resume after launch even when an in-flight request is interrupted.

## Requirements

- macOS 26+
- Xcode 26+
- Microphone and Accessibility permissions
- Network access to `api.cloudflare.com`

## Build

Open `Kaze.xcodeproj` in Xcode, select your Apple development team under Signing & Capabilities, and run the **Kaze Dev** scheme.

For a personal build on a Mac that already has Apple's Command Line Tools, run `bash scripts/build-local-app.sh`. This creates an ad-hoc-signed `build/local/Kaze Cloud.app` without Xcode or Homebrew dependencies. Ad-hoc signing is suitable for running locally; internal distribution should use your organization's Developer ID or MDM signing workflow.

Offline recovery test (synthetic audio, mocked HTTP, no microphone or Keychain):

```sh
swiftc -swift-version 5 -warnings-as-errors -default-isolation MainActor -target arm64-apple-macos26.0 Kaze/Support/AppPreferences.swift Kaze/Transcription/TranscriberProtocol.swift Kaze/Audio/MicrophoneCaptureSession.swift Kaze/Transcription/CloudflareTranscriber.swift Kaze/Data/RecordingVault.swift Tests/RecordingVaultTests.swift -o build/local/RecordingVaultTests
build/local/RecordingVaultTests -cloudflareAccountID 0123456789abcdef0123456789abcdef
```

The bundle identifiers for this fork are `com.kavin.KazeCloud` and `com.kavin.KazeCloud.dev`. Change them before distributing the app if those identifiers do not belong to your organization.

## Upstream and license

This project is based on [fayazara/Kaze](https://github.com/fayazara/Kaze). Upstream automatic updates are disabled so this fork cannot replace itself with the local-model build.

The physical-notch recording HUD draws design inspiration from [Atoll](https://github.com/Ebullioscopic/Atoll).

Kaze is licensed under the MIT License. See [LICENSE](LICENSE).
