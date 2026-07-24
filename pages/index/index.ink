<script type="application/json" def>
{
  "navigationBarTitleText": "Conversation Copilot"
}
</script>

<script setup>
import wx from 'wx';

const SPEECH_LANG = 'id-ID';
const ASR_IDLE_TIMEOUT_MS = 5000;
const VARIANT_COUNT = 3;
// Sub-option labels shown only after "Answer" is tapped — index-mapped to
// the tone order requested in ANSWER_PROMPT below (agree/short, follow-up,
// polite decline).
const VARIANT_LABELS = ['Jawab', 'Tanya Lagi', 'Tolak'];
const EMPTY_TRANSCRIPT_TEXT = 'Tidak ada suara yang terdengar, coba lagi.';
const ASR_IDLE_TIMEOUT_TEXT = 'ASR tidak ada aktivitas 5 detik, otomatis berhenti.';

// Kept generic on purpose — the task-specific instruction now lives in each
// ACTIONS.*.buildPrompt() below, sent inline with every session.prompt()
// call. A fixed task-shaped system prompt (e.g. "always answer with a JSON
// array") would leak into Get Info / Fact Check turns on the same session
// and bias their output format.
const SESSION_OPTIONS = {
  initialPrompts: [
    {
      role: 'system',
      content:
        'You are a helpful live conversation copilot. Always follow the specific ' +
        'instruction given in each user message exactly, and answer in the same ' +
        'language as the quoted conversation snippet.',
    },
  ],
};

// Mira-reference pattern: three fixed actions always available once
// something has been heard, each hitting the LLM with a different
// instruction over the same transcript, rather than one automatic reply.
const ACTIONS = {
  answer: {
    label: 'Answer',
    kind: 'variants',
    buildPrompt: (transcript) =>
      `The user is listening to someone say: "${transcript}"\n\n` +
      `Reply with ONLY a JSON array of ${VARIANT_COUNT} short reply options the user ` +
      `could say next, each under 12 words, covering different tones (agree/short, ` +
      `ask a follow-up, polite decline). No prose, no markdown, no explanation — JSON ` +
      `array of strings only.`,
  },
  'get-info': {
    label: 'Get Info',
    kind: 'text',
    buildPrompt: (transcript) =>
      `The user is listening to someone say: "${transcript}"\n\n` +
      `Give a short 1-2 sentence informative note with useful background/context ` +
      `about the main topic mentioned, to help the user understand it better. Plain ` +
      `text only, no markdown.`,
  },
  'fact-check': {
    label: 'Fact Check',
    kind: 'text',
    buildPrompt: (transcript) =>
      `The user is listening to someone say: "${transcript}"\n\n` +
      `Briefly fact-check any factual claim in that statement in 1-2 sentences — say ` +
      `whether it appears true, false, or unverifiable, and why. Plain text only, no ` +
      `markdown.`,
  },
};

function makeId(prefix) {
  return `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeText(value) {
  if (typeof value !== 'string') return '';
  return value.replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
}

function getErrorMessage(error) {
  if (!error) return 'Unknown error';
  if (typeof error === 'string') return error;
  if (error.message) return error.message;
  if (error.errMsg) return error.errMsg;
  return String(error);
}

// The model is asked for JSON-only, but real models still sometimes wrap it
// in prose or a ```json fence — pull out the first [...] block defensively
// rather than trusting JSON.parse on the raw string.
function parseVariants(rawText) {
  const text = normalizeText(rawText);
  const match = text.match(/\[[\s\S]*\]/);
  const jsonSlice = match ? match[0] : text;
  let parsed;
  try {
    parsed = JSON.parse(jsonSlice);
  } catch (_error) {
    return [text].filter(Boolean);
  }
  if (!Array.isArray(parsed)) {
    return [text].filter(Boolean);
  }
  return parsed
    .map((item) => (typeof item === 'string' ? normalizeText(item) : ''))
    .filter(Boolean)
    .slice(0, VARIANT_COUNT);
}

function extractTranscript(event) {
  const results = event && event.results ? event.results : null;
  if (!results || typeof results.length !== 'number') {
    return { transcript: '', hasFinal: false };
  }
  const parts = [];
  let hasFinal = false;
  for (let index = 0; index < results.length; index += 1) {
    const result = results[index];
    const alternative = result && result[0];
    if (!alternative || !alternative.transcript) continue;
    parts.push(alternative.transcript);
    if (result.isFinal) hasFinal = true;
  }
  return { transcript: normalizeText(parts.join('')), hasFinal };
}

export default {
  data: {
    availability: 'unknown',
    recognitionAvailable: false,
    status: 'checking', // checking | idle | listening | thinking | error | unavailable
    isBusy: false,
    liveTranscript: '',
    heardText: '',
    activeAction: '', // '' | 'answer' | 'get-info' | 'fact-check'
    variants: [],
    pickedVariant: '',
    actionResult: '',
    lastError: '',
  },

  async onLoad() {
    this.session = null;
    this.recognition = null;
    this.asrIdleTimer = null;
    this.currentTurnId = '';
    this.finalTranscript = '';
    this.recognitionFailed = false;

    await this.refreshAvailability();
  },

  onUnload() {
    this.recognitionFailed = true;
    this.currentTurnId = '';
    this.clearAsrIdleTimer();
    this.disposeRecognition();
    if (this.session) {
      try {
        this.session.destroy();
      } catch (_error) {}
      this.session = null;
    }
  },

  onVoiceWakeup() {
    this.beginListening();
  },

  setStatus(status, extra = {}) {
    this.setData({ status, ...extra });
  },

  setError(message) {
    this.setData({ lastError: message, status: 'error', isBusy: false });
  },

  clearError() {
    if (this.data.lastError) this.setData({ lastError: '' });
  },

  detectRecognitionSupport() {
    return typeof SpeechRecognition !== 'undefined';
  },

  async refreshAvailability() {
    const recognitionAvailable = this.detectRecognitionSupport();
    this.setData({ status: 'checking', recognitionAvailable, lastError: '' });

    try {
      const availability = await LanguageModel.availability();
      this.setData({
        availability,
        status: availability === 'available' ? 'idle' : 'unavailable',
      });
    } catch (error) {
      this.setData({ availability: 'unavailable', status: 'error' });
      this.setError(getErrorMessage(error));
    }
  },

  async ensureSession() {
    if (this.session) return this.session;
    if (this.data.availability !== 'available') {
      await this.refreshAvailability();
    }
    if (this.data.availability !== 'available') {
      throw new Error('LanguageModel tidak tersedia.');
    }
    this.session = await LanguageModel.create(SESSION_OPTIONS);
    return this.session;
  },

  bindRecognition() {
    if (!this.detectRecognitionSupport()) {
      this.recognition = null;
      this.setData({ recognitionAvailable: false });
      return false;
    }

    this.disposeRecognition();
    const recognition = new SpeechRecognition();
    recognition.lang = SPEECH_LANG;
    recognition.continuous = false;
    recognition.interimResults = true;
    recognition.maxAlternatives = 1;

    recognition.onstart = () => {
      this.refreshAsrIdleTimer();
      this.setStatus('listening', { isBusy: true });
    };
    recognition.onsoundstart = () => this.refreshAsrIdleTimer();
    recognition.onspeechstart = () => this.refreshAsrIdleTimer();

    recognition.onresult = (event) => {
      const { transcript, hasFinal } = extractTranscript(event);
      if (!this.currentTurnId) return;
      this.refreshAsrIdleTimer();
      this.setData({ liveTranscript: transcript });
      if (hasFinal && transcript) this.finalTranscript = transcript;
    };

    recognition.onerror = (event) => {
      this.releaseRecognition(recognition);
      this.clearAsrIdleTimer();
      const message =
        event && event.message ? `${event.error || 'error'}: ${event.message}` : 'Speech recognition gagal.';
      this.recognitionFailed = true;
      this.failTurn(message);
    };

    recognition.onend = async () => {
      this.clearAsrIdleTimer();
      this.releaseRecognition(recognition);
      if (!this.currentTurnId || this.recognitionFailed) return;

      const transcript = normalizeText(this.finalTranscript || this.data.liveTranscript);
      if (!transcript) {
        this.setError(EMPTY_TRANSCRIPT_TEXT);
        this.completeTurn('idle');
        return;
      }

      // No automatic LLM call here anymore — just surface the heard text
      // and let the three action buttons (Answer / Get Info / Fact Check)
      // wait for the user to pick what they actually want.
      this.setData({
        heardText: transcript,
        activeAction: '',
        variants: [],
        pickedVariant: '',
        actionResult: '',
      });
      this.completeTurn('idle');
    };

    this.recognition = recognition;
    this.setData({ recognitionAvailable: true });
    return true;
  },

  releaseRecognition(recognition) {
    if (this.recognition === recognition) this.recognition = null;
  },

  disposeRecognition() {
    const recognition = this.recognition;
    if (!recognition) return;
    try {
      recognition.onstart = null;
      recognition.onsoundstart = null;
      recognition.onspeechstart = null;
      recognition.onresult = null;
      recognition.onerror = null;
      recognition.onend = null;
      recognition.abort();
    } catch (_error) {}
    this.recognition = null;
  },

  clearAsrIdleTimer() {
    if (!this.asrIdleTimer) return;
    clearTimeout(this.asrIdleTimer);
    this.asrIdleTimer = null;
  },

  refreshAsrIdleTimer() {
    this.clearAsrIdleTimer();
    if (!this.currentTurnId || this.data.status !== 'listening') return;
    const turnId = this.currentTurnId;
    this.asrIdleTimer = setTimeout(() => {
      if (this.currentTurnId !== turnId || this.data.status !== 'listening') return;
      this.handleAsrIdleTimeout();
    }, ASR_IDLE_TIMEOUT_MS);
  },

  handleAsrIdleTimeout() {
    this.clearAsrIdleTimer();
    if (!this.currentTurnId || this.data.status !== 'listening') return;
    this.recognitionFailed = true;
    this.setError(ASR_IDLE_TIMEOUT_TEXT);
    this.completeTurn('idle');
    this.disposeRecognition();
  },

  beginListening() {
    if (this.data.isBusy) return;

    if (!this.data.recognitionAvailable) {
      this.setError('SpeechRecognition tidak didukung di lingkungan ini.');
      return;
    }
    if (this.data.availability !== 'available') {
      this.setError('LanguageModel tidak tersedia, tidak bisa mulai percakapan.');
      return;
    }
    if (!this.bindRecognition()) {
      this.setError('SpeechRecognition tidak didukung di lingkungan ini.');
      return;
    }

    this.clearAsrIdleTimer();
    this.clearError();
    this.finalTranscript = '';
    this.recognitionFailed = false;
    this.currentTurnId = makeId('turn');

    this.setData({
      isBusy: true,
      status: 'listening',
      liveTranscript: '',
      heardText: '',
      variants: [],
      pickedVariant: '',
    });

    try {
      this.recognition.start();
    } catch (error) {
      this.failTurn(getErrorMessage(error));
    }
  },

  toggleListening() {
    if (this.data.status === 'listening') {
      this.stopListening();
      return;
    }
    if (this.data.status === 'thinking') return;
    this.beginListening();
  },

  stopListening() {
    if (this.data.status !== 'listening') return;
    this.clearAsrIdleTimer();
    this.recognitionFailed = true;
    this.currentTurnId = '';
    this.setData({ status: 'idle', isBusy: false, liveTranscript: '' });
    this.disposeRecognition();
  },

  async runAction(event) {
    const actionKey = event && event.currentTarget && event.currentTarget.dataset
      ? event.currentTarget.dataset.action
      : '';
    const action = ACTIONS[actionKey];
    if (!action || this.data.isBusy || !this.data.heardText) return;

    this.setData({
      activeAction: actionKey,
      variants: [],
      pickedVariant: '',
      actionResult: '',
    });
    this.setStatus('thinking', { isBusy: true });

    try {
      const session = await this.ensureSession();
      const result = await session.prompt(action.buildPrompt(this.data.heardText));

      if (action.kind === 'variants') {
        const texts = parseVariants(result);
        const variants = texts.map((text, index) => ({
          label: VARIANT_LABELS[index] || `Opsi ${index + 1}`,
          text,
        }));
        this.setData({ variants });
      } else {
        this.setData({ actionResult: normalizeText(result) });
      }

      this.setData({ status: 'idle', isBusy: false });
    } catch (error) {
      this.failTurn(getErrorMessage(error));
    }
  },

  pickVariant(event) {
    const index = event && event.currentTarget && event.currentTarget.dataset
      ? Number(event.currentTarget.dataset.index)
      : -1;
    const variant = this.data.variants[index];
    if (!variant) return;
    this.setData({ pickedVariant: variant.text });
  },

  async resetTurn() {
    this.recognitionFailed = true;
    this.currentTurnId = '';
    this.clearAsrIdleTimer();
    this.disposeRecognition();
    this.finalTranscript = '';
    this.recognitionFailed = false;

    await this.refreshAvailability();
    this.setData({
      liveTranscript: '',
      heardText: '',
      activeAction: '',
      variants: [],
      pickedVariant: '',
      actionResult: '',
      lastError: '',
      isBusy: false,
    });
  },

  failTurn(message) {
    this.clearAsrIdleTimer();
    this.setError(message);
    this.currentTurnId = '';
    this.finalTranscript = '';
    this.setData({ isBusy: false });
  },

  completeTurn(status) {
    this.clearAsrIdleTimer();
    this.currentTurnId = '';
    this.finalTranscript = '';
    this.recognitionFailed = false;
    this.setData({ status, isBusy: false, liveTranscript: '' });
  },
};
</script>

<page>
  <scroll-view class="container" scroll-y="true">
    <view class="hero">
      <text class="page-title">Conversation Copilot</text>
      <text class="status-chip status-{{status}}">{{status}}</text>
    </view>

    <view class="error-banner" ink:if="{{lastError}}">
      <text class="error-text">{{lastError}}</text>
    </view>

    <!-- Before anything is heard, just show the live/placeholder transcript.
         Bounded to one 352px-tall screen throughout, so nothing here relies
         on the still-flaky scroll-view down-arrow input. -->
    <view class="card" ink:if="{{!heardText}}">
      <text class="page-description">Dengarkan lawan bicara, lalu pilih aksi.</text>
      <text class="transcript-text">
        {{status === 'listening' ? (liveTranscript || 'Mendengarkan...') : 'Belum ada percakapan.'}}
      </text>
    </view>

    <view class="heard-wrap" ink:if="{{heardText}}">
      <view class="heard-bubble">
        <text class="transcript-text-compact">{{heardText}}</text>
      </view>

      <!-- Three fixed actions, always available once something's been
           heard — Mira-reference pattern, not one automatic reply. -->
      <view class="pill-row">
        <button class="action-pill {{activeAction === 'get-info' ? 'action-pill-active' : ''}}" data-action="get-info" bindtap="runAction" disabled="{{isBusy}}">
          Get Info
        </button>
        <button class="action-pill {{activeAction === 'fact-check' ? 'action-pill-active' : ''}}" data-action="fact-check" bindtap="runAction" disabled="{{isBusy}}">
          Fact Check
        </button>
        <button class="action-pill {{activeAction === 'answer' ? 'action-pill-active' : ''}}" data-action="answer" bindtap="runAction" disabled="{{isBusy}}">
          Answer
        </button>
      </view>

      <!-- Answer: sub-picklist of short reply-tone labels; the full text
           only shows once one is tapped. -->
      <view class="result-wrap" ink:if="{{activeAction === 'answer' && variants.length > 0}}">
        <view class="picked-bubble" ink:if="{{pickedVariant}}">
          <text class="picked-text">{{pickedVariant}}</text>
        </view>
        <view class="pill-row">
          <button
            class="variant-pill {{pickedVariant === item.text ? 'variant-pill-picked' : ''}}"
            ink:for="{{variants}}"
            ink:key="index"
            data-index="{{index}}"
            bindtap="pickVariant"
          >
            {{item.label}}
          </button>
        </view>
      </view>

      <!-- Get Info / Fact Check: a single short plain-text result. -->
      <view class="picked-bubble" ink:if="{{(activeAction === 'get-info' || activeAction === 'fact-check') && actionResult}}">
        <text class="picked-text">{{actionResult}}</text>
      </view>
    </view>

    <view class="button-row">
      <button class="btn btn-primary" bindtap="toggleListening" disabled="{{isBusy && status !== 'listening'}}">
        {{status === 'listening' ? 'Berhenti' : 'Mulai Dengar'}}
      </button>
      <button class="btn" bindtap="resetTurn">Reset</button>
    </view>
  </scroll-view>
</page>

<style>
  .container {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 12px;
    /* Centered, full-width panel (back from the corner-anchored variant) —
       bounded to the real host canvas so nothing here needs the still-flaky
       scroll-view down-arrow input. */
    height: var(--app-height-max, 352px);
    box-sizing: border-box;
  }

  .hero {
    display: flex;
    flex-direction: row;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .page-title {
    font-size: 18px;
    font-weight: bold;
    color: #40FF5E;
  }

  .page-description {
    font-size: 12px;
    line-height: 16px;
    color: #40ff5dbf;
  }

  .status-chip {
    padding: 2px 8px;
    border-radius: 999px;
    border: 1px solid currentColor;
    font-size: 10px;
    font-weight: bold;
    text-transform: uppercase;
    color: #40ff5dbf;
  }

  .status-idle {
    color: #40FF5E;
  }

  .status-listening,
  .status-thinking,
  .status-checking {
    color: #FFC93D;
  }

  .status-error,
  .status-unavailable {
    color: #FF5B3D;
  }

  .error-banner {
    padding: 6px 10px;
    border-radius: 10px;
    border: 1px solid #FF5B3D;
  }

  .error-text {
    font-size: 11px;
    color: #FF5B3D;
  }

  .card {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 10px;
    border-radius: 10px;
    border: 1px solid #40ff5d42;
    flex: 1;
    min-height: 0;
    overflow: hidden;
  }

  .transcript-text {
    font-size: 13px;
    line-height: 17px;
    color: #40FF5E;
  }

  .transcript-text-compact {
    font-size: 11px;
    line-height: 14px;
    color: #40ff5dbf;
  }

  .button-row {
    display: flex;
    flex-direction: row;
    gap: 8px;
  }

  .btn {
    color: #40FF5E;
    border: 1px solid #40ff5d42;
    border-radius: 10px;
    padding: 5px 10px;
    font-size: 12px;
  }

  .btn-primary {
    border: 2px solid #40FF5E;
  }

  .heard-wrap,
  .result-wrap {
    display: flex;
    flex-direction: column;
    gap: 8px;
    flex: 1;
    min-height: 0;
    overflow: hidden;
  }

  /* Speech-bubble treatment for what was heard, distinct from the pill
     buttons below it — same visual language as the Mira reference's
     transcript bubble vs. its separate scattered action pills. */
  .heard-bubble {
    padding: 6px 10px;
    border-radius: 12px;
    border: 1px solid #40ff5d42;
    align-self: flex-start;
  }

  /* Full text of the picked option — the pill only ever carries a short
     action label (Mira-reference pattern), so the actual reply content has
     to surface somewhere once chosen. */
  .picked-bubble {
    padding: 8px 12px;
    border-radius: 12px;
    border: 2px solid #40FF5E;
    background-color: rgba(64, 255, 94, 0.1);
    align-self: flex-start;
  }

  .picked-text {
    font-size: 13px;
    line-height: 17px;
    color: #40FF5E;
  }

  /* Individual floating pills instead of one bordered list box — each
     option reads as its own small HUD affordance, not a menu item. */
  .pill-row {
    display: flex;
    flex-direction: row;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
  }

  .variant-pill {
    text-align: center;
    color: #40FF5E;
    border: 1px solid #40ff5d5d;
    border-radius: 999px;
    padding: 7px 16px;
    font-size: 13px;
    line-height: 16px;
    background-color: rgba(64, 255, 94, 0.06);
  }

  .variant-pill-picked {
    border: 2px solid #40FF5E;
    background-color: rgba(64, 255, 94, 0.15);
  }

  /* The three always-available fixed actions — visually distinct from the
     variant pills (square-ish corners vs. full pill) so it reads as "mode
     select" rather than "reply option". */
  .action-pill {
    color: #40FF5E;
    border: 1px solid #40ff5d5d;
    border-radius: 10px;
    padding: 7px 14px;
    font-size: 12px;
    font-weight: bold;
    background-color: transparent;
  }

  .action-pill-active {
    border: 2px solid #40FF5E;
    background-color: rgba(64, 255, 94, 0.1);
  }
</style>
