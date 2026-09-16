# Kaze Cloud

Hold a global hotkey, speak, and paste the transcription into the active macOS app. This fork uses only Cloudflare-hosted `@cf/openai/whisper-large-v3-turbo`. Speech recognition does not run locally.

## How it works

1. Press the global hotkey to begin recording.
2. Kaze captures microphone audio and displays a waveform.
3. Release the hotkey (or press it again in toggle mode).
4. Kaze converts the recording to 16 kHz mono PCM WAV and sends it to Whisper Large V3 Turbo on Workers AI.
5. The returned text is pasted into the focused app.

Recordings are limited to five minutes. The model runs on Cloudflare's infrastructure and is currently priced by Cloudflare at $0.00051 per audio minute.

## Cloudflare setup

You need:

- A Cloudflare account with Workers AI access.
- Your 32-character Cloudflare Account ID.
- A token created with Cloudflare's **Create a Workers AI API Token** template. A custom token needs **Workers AI → Read** on the selected account.

Enter these values during onboarding or under **Settings → General → Cloudflare Workers AI**. The Account ID is stored in app preferences. The API token is stored in macOS Keychain.

## Privacy

Audio is sent directly to Cloudflare's native Workers AI endpoint for transcription by the Cloudflare-hosted model. It is not sent through an OpenAI provider account, and the app does not run an additional LLM over the transcript.

Your employer must still approve Cloudflare as a processor. The app keeps transcription history locally unless you clear it in Settings.

## Requirements

- macOS 26+
- Xcode 26+
- Microphone and Accessibility permissions
- Network access to `api.cloudflare.com`

## Build

Open `Kaze.xcodeproj` in Xcode, select your Apple development team under Signing & Capabilities, and run the **Kaze Dev** scheme.

For a personal build on a Mac that already has Apple's Command Line Tools, run `bash scripts/build-local-app.sh`. This creates an ad-hoc-signed `build/local/Kaze Cloud.app` without Xcode or Homebrew dependencies. Ad-hoc signing is suitable for running locally; internal distribution should use your organization's Developer ID or MDM signing workflow.

The bundle identifiers for this fork are `com.kavin.KazeCloud` and `com.kavin.KazeCloud.dev`. Change them before distributing the app if those identifiers do not belong to your organization.

## Upstream and license

This project is based on [fayazara/Kaze](https://github.com/fayazara/Kaze). Upstream automatic updates are disabled so this fork cannot replace itself with the local-model build.

The physical-notch recording HUD draws design inspiration from [Atoll](https://github.com/Ebullioscopic/Atoll).

Kaze is licensed under the MIT License. See [LICENSE](LICENSE).
