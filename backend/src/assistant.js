// "Ask Margin": explains an affordability verdict the phone already computed, using Claude.
// The SDK is loaded lazily so tests and the bank routes run without it installed.
const httpError = (status, message) => Object.assign(new Error(message), { status, expose: true });
const DAY_MS = 24 * 60 * 60 * 1000;

export const SYSTEM_PROMPT = `You are Margin's budgeting assistant. The person you help is self-employed: their income arrives per job rather than as a salary. "Gross" is what a job paid into their business account; "Net" is what they then transferred to their personal account to live on.

You receive a budget snapshot (JSON computed on their phone) and one question, usually "can I afford this?".
- Answer in 120 words or fewer, in plain, warm, shame-free language. No lectures.
- Ground every figure you mention in the snapshot. Never invent, estimate, or extrapolate numbers that are not there; if something you need is missing, say so.
- The snapshot's "verdict" was computed by the app. Explain why it came out that way; never contradict its math.
- End with one concrete plan: which flexible categories to trim and by how much, or which month the purchase fits.
- The Peace Number is their protected reserve. Never suggest dipping into it for a want.
- You do not give tax or investment advice; if asked, say briefly that it's outside what you can help with.`;

// Pure handling of a Messages API response: refusal first, then the joined text.
export function readAnswer(response) {
  if (response?.stop_reason === 'refusal') throw httpError(422, "Margin can't help with that question.");
  const text = (Array.isArray(response?.content) ? response.content : []).filter(block => block?.type === 'text' && typeof block.text === 'string').map(block => block.text).join('').trim();
  if (!text) throw httpError(502, 'Ask Margin could not answer right now');
  return text;
}

// Maps SDK errors (most specific first) to the statuses the app returns; anything else is rethrown untouched.
export function mapSdkError(error, Anthropic) {
  if (error instanceof Anthropic.RateLimitError) return httpError(429, 'Assistant is busy, try again shortly');
  if (error instanceof Anthropic.AuthenticationError) return httpError(503, "Ask Margin isn't configured");
  if (error instanceof Anthropic.APIError) return httpError(502, 'Ask Margin could not answer right now');
  return error;
}

export const userContent = (question, context) => `Budget snapshot (JSON, computed on the user's phone):\n${JSON.stringify(context)}\n\nQuestion: ${question}`;

export function createAssistant(config, { loadSdk = () => import('@anthropic-ai/sdk') } = {}) {
  if (!config.anthropicApiKey) return null;
  let sdk;
  async function client() {
    if (sdk) return sdk;
    let Anthropic;
    try { ({ default: Anthropic } = await loadSdk()); } catch (error) { console.error('Ask Margin: @anthropic-ai/sdk could not be loaded; run npm install in backend/', error.message); throw httpError(503, "Ask Margin isn't configured"); }
    sdk = { Anthropic, client: new Anthropic({ apiKey: config.anthropicApiKey }) };
    return sdk;
  }
  return {
    async answer({ question, context }) {
      const { Anthropic, client: anthropic } = await client();
      let response;
      try {
        response = await anthropic.beta.messages.create({
          model: config.anthropicModel || 'claude-opus-5-5',
          max_tokens: 8000,
          betas: ['server-side-fallback-2026-07-01'],
          fallbacks: 'default', // server-side safety fallback
          output_config: { effort: 'medium' },
          system: SYSTEM_PROMPT,
          messages: [{ role: 'user', content: userContent(question, context) }],
        });
      } catch (error) { throw mapSdkError(error, Anthropic); }
      return readAnswer(response);
    }
  };
}

// Rolling-window per-user limiter; `now` is injectable so tests can move the clock.
export function createAskLimiter({ limit = 30, windowMs = DAY_MS, now = () => Date.now() } = {}) {
  const hits = new Map();
  return {
    take(userId) {
      const t = now(), recent = (hits.get(userId) || []).filter(at => t - at < windowMs);
      if (recent.length >= limit) { hits.set(userId, recent); return false; }
      recent.push(t); hits.set(userId, recent); return true;
    }
  };
}
