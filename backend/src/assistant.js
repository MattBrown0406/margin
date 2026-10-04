// "Ask Margin": explains an affordability verdict the phone already computed, using Claude.
// The SDK is loaded lazily so tests and the bank routes run without it installed.
const httpError = (status, message) => Object.assign(new Error(message), { status, expose: true });
const DAY_MS = 24 * 60 * 60 * 1000;
export const MAX_TOKENS = 3000;
const CONTEXT_MAX_DEPTH = 6, CONTEXT_MAX_ENTRIES = 400;

export const SYSTEM_PROMPT = `You are Margin's budgeting assistant. The person you help is self-employed: their income arrives per job rather than as a salary. "Gross" is what a job paid into their business account; "Net" is what they then transferred to their personal account to live on.

You receive a budget snapshot (JSON computed on their phone) and one question, usually "can I afford this?".
- Answer in 120 words or fewer, in plain, warm, shame-free language. No lectures.
- Ground every figure you mention in the snapshot. Never invent, estimate, or extrapolate numbers that are not there; if something you need is missing, say so.
- The snapshot's "verdict" was computed by the app. Explain why it came out that way; never contradict its math.
- End with one concrete plan: which flexible categories to trim and by how much, or which month the purchase fits.
- The Peace Number is their protected reserve. Never suggest dipping into it for a want.
- You do not give tax or investment advice; if asked, say briefly that it's outside what you can help with.`;

// Pure handling of a Messages API response: refusal first, then the joined text. A response cut off at
// max_tokens still returns whatever text it produced; with none (all spent thinking) it is a 502.
export function readAnswer(response) {
  if (response?.stop_reason === 'refusal') throw httpError(422, "Margin can't help with that question.");
  const text = (Array.isArray(response?.content) ? response.content : []).filter(block => block?.type === 'text' && typeof block.text === 'string').map(block => block.text).join('').trim();
  if (response?.stop_reason === 'max_tokens') { if (text) return text; throw httpError(502, 'Ask Margin could not answer right now'); }
  if (!text) throw httpError(502, 'Ask Margin could not answer right now');
  return text;
}

// Structural check run before the snapshot is ever serialized: a plain object, at most 6 levels deep and
// 400 keys/array items in total, no cycles. Bails out early, so hostile nesting never reaches JSON.stringify.
export function isAskContext(context) {
  const isPlain = value => Boolean(value) && typeof value === 'object' && !Array.isArray(value) && [Object.prototype, null].includes(Object.getPrototypeOf(value));
  if (!isPlain(context)) return false;
  let entries = 0;
  const ancestors = new Set();
  const walk = (value, depth) => {
    if (value === null || typeof value !== 'object') return true;
    if (depth > CONTEXT_MAX_DEPTH || ancestors.has(value) || (!Array.isArray(value) && !isPlain(value))) return false;
    const children = Array.isArray(value) ? value : Object.values(value);
    entries += children.length;
    if (entries > CONTEXT_MAX_ENTRIES) return false;
    ancestors.add(value);
    const ok = children.every(child => walk(child, depth + 1));
    ancestors.delete(value);
    return ok;
  };
  return walk(context, 1);
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
    sdk = { Anthropic, client: new Anthropic({ apiKey: config.anthropicApiKey, maxRetries: 1 }) };
    return sdk;
  }
  return {
    async answer({ question, context }) {
      const { Anthropic, client: anthropic } = await client();
      let response;
      try {
        response = await anthropic.beta.messages.create({
          model: config.anthropicModel || 'claude-opus-5-5',
          max_tokens: MAX_TOKENS, // caps the cost of a single question (thinking included)
          betas: ['server-side-fallback-2026-07-01'],
          fallbacks: 'default', // server-side safety fallback
          output_config: { effort: 'low' },
          system: SYSTEM_PROMPT,
          messages: [{ role: 'user', content: userContent(question, context) }],
        });
      } catch (error) { throw mapSdkError(error, Anthropic); }
      return readAnswer(response);
    }
  };
}

// Rolling-window limiter keyed by user (or one shared key for the global cap); `now` is injectable so
// tests can move the clock. release() hands back the most recent take when a later check rejects.
export function createAskLimiter({ limit = 30, windowMs = DAY_MS, now = () => Date.now() } = {}) {
  const hits = new Map();
  return {
    take(key) {
      const t = now(), recent = (hits.get(key) || []).filter(at => t - at < windowMs);
      if (recent.length >= limit) { hits.set(key, recent); return false; }
      recent.push(t); hits.set(key, recent); return true;
    },
    release(key) { hits.get(key)?.pop(); }
  };
}
