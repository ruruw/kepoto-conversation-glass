# kepoto-conversation-glass

Conversation copilot agent for Rokid AI glasses. Listens to a live
conversation (wake word or manual start), transcribes it via
`SpeechRecognition`, asks the on-device/edge `LanguageModel` for several
short reply-option variants (not one long answer), and renders them as
tappable choices on the glasses display.

## Permissions

- Microphone (ASR)
- Network (LLM calls)

## Getting Started

1. `npm install`
2. `npm start`

## Where the logic lives

- `pages/index/index.ink` — single page: ASR loop, `LanguageModel` session,
  variant parsing (`parseVariants`), and the tappable option list UI.
  Adapted from the AIUI `samples/capabilities/pages/chat` sample — same
  wake/ASR/session plumbing, but the system prompt asks for a JSON array of
  reply options instead of one streamed answer, so the page renders a
  picklist instead of a chat bubble.

## Known gaps / next steps

- No TTS playback wired up yet (sample had it via `speechSynthesis` /
  `wx.speech.playTTS` — could speak the picked variant aloud).
- `parseVariants` falls back to treating the whole response as one option if
  the model doesn't return valid JSON — worth tightening once tested against
  real hardware output.
- ASR language is hardcoded to `id-ID`; make configurable if needed.
