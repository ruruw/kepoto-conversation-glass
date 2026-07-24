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
// Short action-style labels for the pills (Mira-reference pattern: tap a
// terse label, the actual reply text only shows once picked) — index-mapped
// to the tone order requested in the system prompt below (agree/short, ask
// a follow-up, polite decline).
const VARIANT_LABELS = ['Jawab', 'Tanya Lagi', 'Tolak'];
const EMPTY_TRANSCRIPT_TEXT = 'Tidak ada suara yang terdengar, coba lagi.';
const ASR_IDLE_TIMEOUT_TEXT = 'ASR tidak ada aktivitas 5 detik, otomatis berhenti.';

// The model is instructed to answer ONLY with a JSON array so we can render
// each suggestion as its own tappable option instead of one long reply —
// that's the entire point of this page over the stock chat sample.
const SESSION_OPTIONS = {
  initialPrompts: [
    {
      role: 'system',
      content:
        `You are a live conversation copilot. The user is listening to someone speak ` +
        `and needs short reply suggestions, not a conversation with you directly. ` +
        `Given the other person's last sentence (transcribed from speech), reply with ` +
        `ONLY a JSON array of ${VARIANT_COUNT} short reply options the user could say next, ` +
        `each under 12 words, in the same language as the transcript, covering different ` +
        `tones (e.g. agree/short, ask a follow-up, polite decline). ` +
        `No prose, no markdown, no explanation — JSON array of strings only.`,
    },
  ],
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
    variants: [],
    pickedVariant: '',
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

      this.setData({ heardText: transcript });
      await this.generateVariants(this.currentTurnId, transcript);
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

  async generateVariants(turnId, transcript) {
    if (!turnId || this.currentTurnId !== turnId) return;

    this.setStatus('thinking', { isBusy: true });

    try {
      const session = await this.ensureSession();
      // Non-streaming here on purpose: variants render as separate options,
      // not one growing bubble of text, so there's nothing useful to show
      // until the full JSON array is parseable anyway.
      const result = await session.prompt(transcript);
      const texts = parseVariants(result);
      const variants = texts.map((text, index) => ({
        label: VARIANT_LABELS[index] || `Opsi ${index + 1}`,
        text,
      }));
      this.setData({ variants });
      this.completeTurn('idle');
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
      variants: [],
      pickedVariant: '',
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

    <!-- Hero blurb and the transcript card only matter before there's
         something to act on — once variants exist, that picklist IS the
         payload, so this collapses to keep everything on one 352px-tall
         screen without needing the still-flaky scroll-view input. -->
    <view class="card" ink:if="{{variants.length === 0}}">
      <text class="page-description">Dengarkan lawan bicara, dapatkan opsi balasan singkat.</text>
      <text class="transcript-text">
        {{status === 'listening' ? (liveTranscript || 'Mendengarkan...') : (heardText || 'Belum ada percakapan.')}}
      </text>
    </view>

    <view class="variants-wrap" ink:if="{{variants.length > 0}}">
      <view class="heard-bubble">
        <text class="transcript-text-compact">{{heardText}}</text>
      </view>
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

  .variants-wrap {
    display: flex;
    flex-direction: column;
    gap: 8px;
    flex: 1;
    min-height: 0;
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
</style>
