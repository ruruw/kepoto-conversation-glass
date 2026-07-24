# kepoto-conversation-glass

Conversation copilot agent for Rokid AI glasses, modeled on the Mira
Glasses reference pattern: it listens to a live conversation (wake word or
manual start), transcribes it via `SpeechRecognition`, then surfaces three
fixed actions — **Get Info**, **Fact Check**, **Answer** — instead of
automatically generating one reply. Each action sends a different
instruction to the `LanguageModel` over the same heard transcript; only
**Answer** produces a sub-picklist (short reply-tone options), the other
two return a single short text result.

## Permissions

- Microphone (ASR)
- Network (LLM calls)

## Getting Started

1. `npm install`
2. `npm start`

## Where the logic lives

- `pages/index/index.ink` — single page. Adapted from the AIUI
  `samples/capabilities/pages/chat` sample (same wake/ASR/session
  plumbing), but:
  - `ACTIONS` (`answer` / `get-info` / `fact-check`) each carry their own
    `buildPrompt(transcript)` — sent inline per `session.prompt()` call
    rather than baked into a fixed system prompt, so the three actions
    don't bias each other's output format on the same session.
  - ASR `onend` no longer auto-triggers the LLM; it just sets `heardText`
    and waits for `runAction()` to be called via one of the three fixed
    pills.
  - `runAction()` dispatches on `action.kind`: `'variants'` (Answer) parses
    a JSON array via `parseVariants()` into `{label, text}` pairs
    (`VARIANT_LABELS`); `'text'` (Get Info / Fact Check) just normalizes
    and shows the raw result.

## Known gaps / next steps

- No TTS playback wired up yet (sample had it via `speechSynthesis` /
  `wx.speech.playTTS` — could speak the Get Info / Fact Check result or the
  picked Answer variant aloud).
- "Get Info" and "Fact Check" only draw on the LLM's own training data —
  there's no real web search / retrieval behind them, so treat results as
  the model's best guess, not verified lookup.
- `parseVariants` falls back to treating the whole response as one option if
  the model doesn't return valid JSON — worth tightening once tested against
  real hardware output.
- ASR language is hardcoded to `id-ID`; make configurable if needed.
