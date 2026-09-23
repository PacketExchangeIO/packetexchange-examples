// A small, dependency-free mock of the PacketExchange API for running the examples
// locally and in CI. It implements only the endpoints the examples call, with the same
// request validation rules, response envelopes and field names as the real API, and
// keeps state in memory so multi-step flows (start then check, buy then route) work.
//
// Nothing here talks to the network, sends a message or moves money.
//
//   node mock/server.mjs            listens on 127.0.0.1:4010 (override with MOCK_PORT)

import { createServer } from 'node:http';
import { randomUUID, randomBytes } from 'node:crypto';

const PORT = Number(process.env.MOCK_PORT ?? 4010);
const PREFIX = '/api/v1';

// Fixed values the example runners rely on (documented in mock/README.md).
const VERIFY_CODE = '123456';
const BLOCKED_NUMBER = '15005550000';
const DID_GROUP_ID = '6a1f7c0e-3b4d-4c55-9a8e-2f0d9c1b7e21';
const DID_SKU_ID = 'b2c4e6f8-1a3c-4e5f-8a9b-0c1d2e3f4a5b';
const X402_PAY_TO = '0x5e7f3b2a9c1d4e6f8a0b2c4d6e8f0a1b3c5d7e9f';
const USDC_BASE = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';

const E164 = /^\+?[1-9][0-9]{6,14}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SENDER_ID = /^[A-Za-z0-9 .+_-]{1,30}$/;
const STRATEGIES = ['cheapest', 'best_quality', 'balanced'];
const VOICE_LANGUAGES = ['en', 'es', 'fr', 'de', 'pt', 'hi'];
const SMS_LANGUAGES = [...VOICE_LANGUAGES, 'ar'];

// In-memory state, reset on restart.
const verifications = new Map();
const messages = new Map();
const ledger = [];
const dids = new Map();
const agents = new Map();
const cliTests = new Map();
let balance = 100;

const now = () => new Date().toISOString();
const money = (n) => n.toFixed(6);
const digits = (s) => String(s).replace(/\D/g, '');

// ── Errors ──────────────────────────────────────────────────────────────────

class ApiError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

/** Collects field problems and throws one VALIDATION_ERROR, like the API's zod handler. */
class Checker {
  constructor(input) {
    this.input = input && typeof input === 'object' && !Array.isArray(input) ? input : {};
    this.details = [];
  }
  fail(path, message) {
    this.details.push({ path, message });
  }
  // Returns the value when the field is present, or undefined when optional and absent.
  field(path, { required = false, type = 'string', min, max, pattern, patternMessage, oneOf, nullable = false } = {}) {
    const v = this.input[path];
    if (v === undefined) {
      if (required) this.fail(path, 'Required');
      return undefined;
    }
    if (v === null) {
      if (!nullable) this.fail(path, `Expected ${type}, received null`);
      return null;
    }
    if (type === 'integer' ? !Number.isInteger(v) : typeof v !== type) {
      this.fail(path, `Expected ${type}, received ${typeof v}`);
      return undefined;
    }
    const size = typeof v === 'string' ? v.length : v;
    if (min !== undefined && size < min) this.fail(path, typeof v === 'string' ? `String must contain at least ${min} character(s)` : `Number must be greater than or equal to ${min}`);
    if (max !== undefined && size > max) this.fail(path, typeof v === 'string' ? `String must contain at most ${max} character(s)` : `Number must be less than or equal to ${max}`);
    if (pattern && !pattern.test(v)) this.fail(path, patternMessage ?? 'Invalid');
    if (oneOf && !oneOf.includes(v)) this.fail(path, `Invalid enum value. Expected ${oneOf.map((o) => `'${o}'`).join(' | ')}, received '${v}'`);
    return v;
  }
  phone(path, required = true) {
    return this.field(path, { required, pattern: E164, patternMessage: 'Must be a valid E.164 phone number (e.g. +14155550100)' });
  }
  done() {
    if (this.details.length) throw new ApiError(400, 'VALIDATION_ERROR', 'Validation failed', this.details);
  }
}

function requireUuid(value, what) {
  if (!UUID.test(value)) throw new ApiError(400, 'INVALID_INPUT', `${what} is not a valid id`);
  return value;
}

/** The mock refuses one documented number so every example can show its error path. */
function refuseBlocked(to) {
  if (digits(to) === BLOCKED_NUMBER) {
    throw new ApiError(400, 'VALIDATION_ERROR', 'Validation failed', [
      { path: 'to', message: 'This destination is refused by the mock API (use any other number)' },
    ]);
  }
}

// ── Verify ──────────────────────────────────────────────────────────────────

function verifyStart({ body, testKey }) {
  const c = new Checker(body);
  const to = c.phone('to');
  const channel = c.field('channel', { required: true, oneOf: ['sms', 'voice'] });
  c.field('length', { type: 'integer', min: 4, max: 10 });
  const language = c.field('language', { pattern: /^[a-z]{2}$/i, patternMessage: 'Use a two-letter language code, e.g. en' }) ?? 'en';
  c.field('brand', { max: 120 });
  const expirySeconds = c.field('expirySeconds', { type: 'integer', min: 60, max: 3600 }) ?? 600;
  const from = c.field('from', { min: 1, max: 30 });
  c.field('strategy', { oneOf: STRATEGIES });
  c.done();

  const langs = channel === 'voice' ? VOICE_LANGUAGES : SMS_LANGUAGES;
  if (!langs.includes(language.toLowerCase())) {
    throw new ApiError(400, 'VALIDATION_ERROR', `${channel === 'voice' ? 'Voice' : 'SMS'} codes are not available in "${language}". Supported languages: ${langs.join(', ')}.`);
  }
  if (channel === 'voice' && !from) {
    throw new ApiError(400, 'VALIDATION_ERROR', '`from` is required: pass the caller ID (E.164) the code call should present');
  }
  if (channel === 'voice' && !E164.test(from)) {
    throw new ApiError(400, 'VALIDATION_ERROR', '`from` must be a valid E.164 number for a voice code');
  }
  if (digits(to) === BLOCKED_NUMBER) {
    throw new ApiError(400, 'VALIDATION_ERROR', 'Verification codes cannot be sent to this destination (premium-rate or high-risk range)');
  }

  const id = randomUUID();
  const createdAt = now();
  const row = {
    verificationId: id, to, channel, status: 'pending', attempts: 0, maxAttempts: 5,
    expiresAt: new Date(Date.now() + expirySeconds * 1000).toISOString(), createdAt, approvedAt: null,
    sendRef: randomUUID(), sendStatus: channel === 'voice' ? (testKey ? 'accepted' : 'initiated') : 'accepted',
    testKey,
  };
  verifications.set(id, row);
  return {
    verificationId: id, to, channel, status: 'pending', expiresAt: row.expiresAt, maxAttempts: 5,
    sendRef: row.sendRef, sendStatus: row.sendStatus,
    ...(testKey ? { simulated: true, testCode: VERIFY_CODE } : {}),
    createdAt,
  };
}

function verifyCheck({ body }) {
  const c = new Checker(body);
  const id = c.field('verificationId', { required: true, pattern: UUID, patternMessage: 'Invalid uuid' });
  const code = c.field('code', { required: true, min: 1, max: 32 });
  c.done();
  const row = verifications.get(id);
  if (!row) throw new ApiError(404, 'NOT_FOUND', 'Verification not found');

  const base = { verificationId: id };
  if (row.status === 'approved') return { ...base, status: 'denied', attemptsRemaining: 0, reason: 'already_used' };
  if (row.status === 'max_attempts') return { ...base, status: 'max_attempts', attemptsRemaining: 0 };
  if (Date.parse(row.expiresAt) <= Date.now()) {
    row.status = 'expired';
    return { ...base, status: 'expired', attemptsRemaining: 0 };
  }
  row.attempts += 1;
  const left = row.maxAttempts - row.attempts;
  if (code.replace(/[\s-]/g, '') === VERIFY_CODE) {
    row.status = 'approved';
    row.approvedAt = now();
    return { ...base, status: 'approved', attemptsRemaining: left };
  }
  if (left <= 0) {
    row.status = 'max_attempts';
    return { ...base, status: 'max_attempts', attemptsRemaining: 0, reason: 'wrong_code' };
  }
  return { ...base, status: 'denied', attemptsRemaining: left, reason: 'wrong_code' };
}

function verifyGet({ params }) {
  const row = verifications.get(requireUuid(params.id, 'id'));
  if (!row) throw new ApiError(404, 'NOT_FOUND', 'Verification not found');
  const { testKey, ...rest } = row;
  return { ...rest, ...(testKey ? { simulated: true } : {}) };
}

// ── SMS and calls ───────────────────────────────────────────────────────────

/** Segment count for GSM-7 (160, or 153 when concatenated) or UCS-2 (70 / 67). */
function segmentsFor(text) {
  const gsm = /^[\x20-\x7E\n\r£¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ¤¡ÄÖÑÜ§¿äöñüà]*$/.test(text);
  const single = gsm ? 160 : 70;
  const multi = gsm ? 153 : 67;
  return text.length <= single ? 1 : Math.ceil(text.length / multi);
}

function charge(amount, reference, relatedEntityType, relatedEntityId) {
  balance -= amount;
  const entry = {
    id: randomUUID(), userId: MOCK_USER_ID, type: 'charge', amount: money(-amount), balanceAfter: money(balance),
    reference, relatedEntityType, relatedEntityId, callId: relatedEntityType === 'api_call' ? relatedEntityId : null,
    createdAt: now(),
  };
  ledger.unshift(entry);
  return entry;
}
const MOCK_USER_ID = '0b7e3c1a-5d2f-4e8b-9a6c-1f3d5e7a9b0c';

function sendSms({ body, testKey }) {
  const c = new Checker(body);
  const to = c.phone('to');
  const from = c.field('from', { required: true, pattern: SENDER_ID, patternMessage: 'Sender ID may contain only letters, digits, spaces and . + _ -' });
  c.field('routeId', { pattern: UUID, patternMessage: 'Invalid uuid' });
  c.field('strategy', { oneOf: STRATEGIES });
  const message = c.field('message', { required: true, min: 1, max: 1600 });
  c.done();
  refuseBlocked(to);

  const messageId = randomUUID();
  const segments = segmentsFor(message);
  const cost = 0.0065 * segments;
  charge(cost, `SMS to ${to}`, 'api_sms', messageId);
  const result = { messageId, to, from, status: 'accepted', segments, cost: money(cost), submittedAt: now(), ...(testKey ? { simulated: true } : {}) };
  messages.set(messageId, result);
  return result;
}

function getSms({ params }) {
  const m = messages.get(params.messageId);
  if (!m) return { messageId: params.messageId, status: 'not_found', message: 'Message ID not found or does not belong to your account.' };
  return { messageId: m.messageId, status: m.status, dlrSupported: false, cost: m.cost, reference: `SMS to ${m.to}`, sentAt: m.submittedAt };
}

function makeCall({ body, testKey }) {
  const c = new Checker(body);
  const to = c.phone('to');
  const from = c.phone('from');
  c.field('routeId', { pattern: UUID, patternMessage: 'Invalid uuid' });
  c.field('strategy', { oneOf: STRATEGIES });
  const maxDuration = c.field('maxDuration', { type: 'integer', min: 10, max: 3600 }) ?? 300;
  c.done();
  refuseBlocked(to);

  const callId = randomUUID();
  const durationSeconds = Math.min(42, maxDuration);
  const billableSeconds = Math.ceil(durationSeconds / 6) * 6;
  const cost = (billableSeconds / 60) * 0.012;
  charge(cost, `Call to ${to}`, 'api_call', callId);
  const started = new Date(Date.now() - durationSeconds * 1000).toISOString();
  return {
    callId, to, from, status: testKey ? 'accepted' : 'answered', sipResponseCode: 200, hangupCause: 'NORMAL_CLEARING',
    durationSeconds, billableSeconds, cost: money(cost), billingIncrement: '6/6', startedAt: started, completedAt: now(),
    ...(testKey ? { simulated: true } : {}),
  };
}

function listCalls({ query }) {
  const limit = Math.min(100, Math.max(1, Number(query.get('limit') ?? 25) || 25));
  const rows = ledger.filter((e) => e.relatedEntityType === 'api_call').slice(0, limit);
  return { envelope: { success: true, data: rows, nextCursor: null, hasMore: false } };
}

// ── Route pricing ───────────────────────────────────────────────────────────

/** A few plausible routes for a number, derived from its country code. */
function routesFor(number, type) {
  const country = number.startsWith('44') ? { name: 'United Kingdom', code: '44', dest: 'United Kingdom-Mobile', prefix: '447' }
    : number.startsWith('1') ? { name: 'United States', code: '1', dest: 'United States', prefix: '1' }
    : { name: 'Germany', code: '49', dest: 'Germany-Mobile', prefix: number.slice(0, 3) };
  const base = type === 'sms' ? 0.0061 : 0.0042;
  const tiers = [
    { routeType: 'standard', cliType: 'mixed', asr: '38.00', acd: '95', mult: 1, score: 64 },
    { routeType: 'premium', cliType: 'full', asr: '52.00', acd: '140', mult: 1.8, score: 81 },
    { routeType: 'standard', cliType: 'full', asr: '45.00', acd: '120', mult: 1.3, score: null },
  ];
  return tiers.map((t, i) => ({
    id: ['4f6b1c2d-8e9a-4b3c-9d1e-2f3a4b5c6d7e', '7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d', 'c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f'][i],
    type, name: `${country.name} ${t.routeType === 'premium' ? 'Premium' : 'Direct'} ${t.cliType === 'full' ? 'CLI' : 'Mixed CLI'}`,
    country: country.name, countryCode: country.code, matchedPrefix: country.prefix, destination: country.dest,
    rate: money(base * t.mult), billingIncrement: type === 'sms' ? null : '6/6', pricedBy: i === 2 ? 'flat' : 'deck',
    expectedAsr: type === 'sms' ? null : t.asr, expectedAcd: type === 'sms' ? null : t.acd,
    cliType: t.cliType, routeType: t.routeType, capacity: type === 'sms' ? 50 : 200, exchangeScore: t.score, isOwn: false,
  })).sort((a, b) => Number(a.rate) - Number(b.rate));
}

function priceNumber({ query }) {
  const raw = query.get('number') ?? '';
  const type = query.get('type') ?? 'voice';
  const c = new Checker({ number: raw || undefined, type });
  c.field('number', { required: true, min: 1, max: 32 });
  c.field('type', { oneOf: ['voice', 'sms'] });
  c.done();
  const number = digits(raw).replace(/^00/, '');
  const unit = type === 'sms' ? 'msg' : 'min';
  // Cuba (+53) stands in for an embargoed destination.
  if (number.startsWith('53')) return { number, type, unit, total: 0, routes: [], notice: 'sanctioned' };
  const routes = routesFor(number, type);
  return { number, type, unit, total: routes.length, routes, notice: null };
}

function resolveRoute({ query }) {
  const to = query.get('to');
  const type = query.get('type') === 'sms' ? 'sms' : 'voice';
  const strategy = STRATEGIES.includes(query.get('strategy')) ? query.get('strategy') : 'balanced';
  if (!to) throw new ApiError(400, 'VALIDATION_ERROR', 'Validation failed', [{ path: 'to', message: 'Required' }]);
  const routes = routesFor(digits(to), type).map((r) => ({
    id: r.id, destinationName: r.destination, country: r.country, countryCode: r.countryCode, type,
    cliType: r.cliType, price: r.rate, asr: r.expectedAsr ? Number(r.expectedAsr) : null,
    acd: r.expectedAcd ? Number(r.expectedAcd) : null, matchedPrefix: r.matchedPrefix,
  }));
  const score = (r) => strategy === 'cheapest' ? -Number(r.price)
    : strategy === 'best_quality' ? (r.asr ?? 0) * 100 - Number(r.price)
    : (r.asr ?? 50) / Number(r.price);
  routes.sort((a, b) => score(b) - score(a));
  return { strategy, selected: routes[0] ?? null, alternatives: routes.slice(1), count: routes.length };
}

// ── Phone numbers ───────────────────────────────────────────────────────────

function searchDids({ query }) {
  const pattern = query.get('pattern') ?? '';
  const c = new Checker({ pattern: pattern || undefined, limit: query.has('limit') ? Number(query.get('limit')) : undefined });
  c.field('pattern', { max: 24 });
  c.field('limit', { type: 'integer', min: 1, max: 100 });
  c.done();
  const hits = [{
    groupId: DID_GROUP_ID, country: 'United States', countryId: '1f2e3d4c-5b6a-4978-8a9b-0c1d2e3f4a5b', countryPrefix: '1',
    city: 'San Francisco', areaPrefix: '415', typeId: '9e8d7c6b-5a49-4382-9716-a5b4c3d2e1f0', typeName: 'Local',
    skus: [{ skuId: DID_SKU_ID, channels: 2, setupPrice: 1.3, monthlyPrice: 2.6 }],
    dialingPrefix: '1415', vanity: false,
  }].filter((h) => !pattern || h.dialingPrefix.includes(digits(pattern)));
  // The search body is NOT wrapped in `data`, matching the real endpoint.
  return { envelope: { success: true, hits, scannedPages: 1, truncated: false } };
}

function didView(d) {
  return {
    id: d.id, number: d.number, country: 'United States', countryCode: 'US', city: 'San Francisco', areaPrefix: '415',
    didType: 'Local', channelsIncluded: 2, status: d.status, pointMode: d.pointMode, pointsTo: d.pointsTo,
    pointsToBackup: null, autoRenew: true, setupPrice: '1.300000', monthlyPrice: '2.600000', orderedAt: d.orderedAt,
    activatedAt: d.status === 'active' ? d.orderedAt : null,
    nextRenewalAt: d.status === 'active' ? new Date(Date.now() + 30 * 86400_000).toISOString() : null,
    suspendedAt: null, releasedAt: null, endpointReachable: null, endpointCause: null, endpointCheckedAt: null, graceDays: 7,
  };
}

function buyDid({ body }) {
  const c = new Checker(body);
  const skuId = c.field('skuId', { required: true, min: 1, max: 64 });
  const groupId = c.field('groupId', { required: true, min: 1, max: 64 });
  c.field('subAccountId', { pattern: UUID, patternMessage: 'Invalid uuid' });
  c.done();
  if (skuId !== DID_SKU_ID || groupId !== DID_GROUP_ID) throw new ApiError(404, 'NOT_FOUND', 'SKU not found');
  const d = { id: randomUUID(), number: null, status: 'pending', pointMode: 'unrouted', pointsTo: null, orderedAt: now() };
  dids.set(d.id, d);
  charge(1.3 + 2.6, 'Phone number: setup and first month', 'did_purchase', d.id);
  return { status: 201, data: didView(d) };
}

function routeDid({ params, body }) {
  const id = requireUuid(params.id, 'id');
  const c = new Checker(body);
  const mode = c.field('mode', { required: true, oneOf: ['sip', 'forward'] });
  const target = c.field('target', { required: true, min: 1, max: 255 });
  c.done();
  if (mode === 'forward' && !E164.test(target)) {
    throw new ApiError(400, 'VALIDATION_ERROR', 'Validation failed', [{ path: 'target', message: 'Forward target must be an E.164 number' }]);
  }
  if (mode === 'sip' && !/^[A-Za-z0-9.-]+(:\d{1,5})?$/.test(target)) {
    throw new ApiError(400, 'VALIDATION_ERROR', 'Validation failed', [{ path: 'target', message: 'SIP target must be host[:port]' }]);
  }
  // Any well-formed id is treated as an active number the caller owns.
  const d = dids.get(id) ?? { id, number: '+14155550142', orderedAt: now() };
  Object.assign(d, { status: 'active', number: d.number ?? '+14155550142', pointMode: mode, pointsTo: target });
  dids.set(id, d);
  return didView(d);
}

// ── AI voice agents ─────────────────────────────────────────────────────────

function listVoices() {
  return [
    { id: 'a0e99841-438c-4a64-b679-ae501e7d6091', name: 'Studio Premium', description: 'Warm, confident narrator', gender: 'male', language: 'en', is_pro: true },
    { id: '156fb8d2-335b-4950-9cb3-a2d33befec77', name: 'Friendly Receptionist', description: 'Clear, friendly and calm', gender: 'female', language: 'en', is_pro: false },
    { id: '5c42302c-194b-4d0c-ba1a-8cb485c84ab9', name: 'Agente Amable', description: 'Neutral Spanish voice', gender: 'female', language: 'es', is_pro: false },
  ];
}

function createAgent({ body }) {
  const c = new Checker(body);
  const name = c.field('name', { required: true, min: 1, max: 120 });
  const voiceId = c.field('voiceId', { max: 120, nullable: true });
  const language = c.field('language', { max: 12 }) ?? 'en';
  const firstMessage = c.field('firstMessage', { max: 500, nullable: true });
  const systemPrompt = c.field('systemPrompt', { required: true, min: 1, max: 8000 });
  const guardrails = c.field('guardrails', { max: 4000, nullable: true });
  const maxCallSeconds = c.field('maxCallSeconds', { type: 'integer', min: 1, max: 3600 }) ?? 300;
  const enabled = c.field('enabled', { type: 'boolean' }) ?? true;
  if (body?.tools !== undefined && (!Array.isArray(body.tools) || body.tools.length > 20)) c.fail('tools', 'Expected an array of at most 20 tool names');
  c.done();
  const at = now();
  const agent = {
    id: randomUUID(), userId: MOCK_USER_ID, name, voiceId: voiceId ?? null, voiceProvider: 'default', language,
    firstMessage: firstMessage ?? null, systemPrompt, model: 'default', guardrails: guardrails ?? null,
    tools: body.tools ?? [], maxCallSeconds, enabled, createdAt: at, updatedAt: at,
  };
  agents.set(agent.id, agent);
  return { status: 201, data: agent };
}

function simulateAgent({ params, body }) {
  const agent = agents.get(requireUuid(params.id, 'id'));
  if (!agent) throw new ApiError(404, 'NOT_FOUND', 'Agent not found');
  const c = new Checker(body);
  c.field('message', { required: true, min: 1, max: 2000 });
  if (body?.history !== undefined && !Array.isArray(body.history)) c.fail('history', 'Expected array');
  c.done();
  return { reply: 'Wonderful, you are all set for tomorrow at 10:30. Is there anything else I can help with?', action: 'continue', captured: { attending: 'yes' } };
}

function updateCampaign({ params, body }) {
  const id = requireUuid(params.id, 'id');
  const c = new Checker(body);
  const aiAgentId = c.field('aiAgentId', { pattern: UUID, patternMessage: 'Invalid uuid', nullable: true });
  c.done();
  if (aiAgentId && !agents.has(aiAgentId)) throw new ApiError(404, 'NOT_FOUND', 'AI agent not found');
  return { id, name: 'Appointment confirmations', type: 'voice', status: 'draft', aiAgentId: aiAgentId ?? null, updatedAt: now() };
}

// ── Caller-ID tests ─────────────────────────────────────────────────────────

function cliQuota() {
  return { costPerTest: 0.5, usedThisHour: cliTests.size, limitPerHour: 10, remaining: Math.max(0, 10 - cliTests.size) };
}

function createCliTest({ body }) {
  const c = new Checker(body);
  const routeId = c.field('routeId', { pattern: UUID, patternMessage: 'Invalid uuid' });
  const blendRouteId = c.field('blendRouteId', { pattern: UUID, patternMessage: 'Invalid uuid' });
  const displayCli = c.field('displayCli', { required: true, pattern: /^\+?[1-9]\d{2,19}$/, patternMessage: 'Enter the caller ID in E.164 format, e.g. +447700900123' });
  const testCountry = c.field('testCountry', { required: true, min: 2, max: 100 });
  const testNumber = c.field('testNumber', { pattern: /^\+?[1-9]\d{5,19}$/, patternMessage: 'Enter a valid number in E.164 format' });
  const recurrence = c.field('recurrence', { oneOf: ['none', 'daily', 'weekly'] }) ?? 'none';
  if ((routeId == null) === (blendRouteId == null)) c.fail('routeId', 'Provide exactly one of routeId or blendRouteId.');
  c.done();
  const test = {
    id: randomUUID(), routeId: routeId ?? null, blendRouteId: blendRouteId ?? null, displayCli, testCountry,
    testNumber: testNumber ?? null, status: 'pending', recurrence, scheduledAt: null, reportedCli: null,
    displayedCorrectly: null, resultNotes: null, dispatchedAt: null, completedAt: null, createdAt: now(),
  };
  cliTests.set(test.id, test);
  return { status: 201, data: test };
}

function getCliTest({ params }) {
  const test = cliTests.get(requireUuid(params.id, 'id'));
  if (!test) throw new ApiError(404, 'NOT_FOUND', 'Caller-ID test not found');
  // The mock completes a test on its first read, so runners do not wait.
  if (test.status === 'pending') {
    Object.assign(test, {
      status: 'completed', testNumber: '+14155550123', reportedCli: test.displayCli, displayedCorrectly: true,
      resultNotes: 'The handset displayed the caller ID that was sent.', dispatchedAt: test.createdAt, completedAt: now(),
    });
    charge(0.5, `Caller-ID test ${test.id}`, 'cli_test_call', test.id);
  }
  return test;
}

// ── x402 top-up ─────────────────────────────────────────────────────────────

function x402Requirements(amountUsd, resource) {
  return {
    scheme: 'exact', network: 'base', maxAmountRequired: String(Math.round(amountUsd * 1e6)), resource,
    description: `PacketExchange balance top-up ($${amountUsd.toFixed(2)} USDC)`, mimeType: 'application/json',
    payTo: X402_PAY_TO, maxTimeoutSeconds: 300, asset: USDC_BASE, extra: { name: 'USD Coin', version: '2' },
  };
}

/** Structural checks the real facilitator would also make (the signature itself is not recovered here). */
function checkPayment(header, reqs) {
  let p;
  try {
    p = JSON.parse(Buffer.from(header, 'base64').toString('utf8'));
  } catch {
    return 'bad_header: malformed X-PAYMENT header';
  }
  const a = p?.payload?.authorization;
  const nowSec = Math.floor(Date.now() / 1000);
  if (p.x402Version !== 1) return 'invalid: unsupported x402Version';
  if (p.scheme !== 'exact' || p.network !== reqs.network) return 'invalid: scheme or network mismatch';
  if (!/^0x[0-9a-fA-F]{130}$/.test(p.payload?.signature ?? '')) return 'invalid: signature is not a 65-byte hex string';
  if (!a || !/^0x[0-9a-fA-F]{40}$/.test(a.from ?? '')) return 'invalid: authorization.from';
  if (String(a.to).toLowerCase() !== reqs.payTo.toLowerCase()) return 'invalid: authorization.to does not match payTo';
  if (String(a.value) !== reqs.maxAmountRequired) return 'invalid: authorization.value does not match maxAmountRequired';
  if (!(Number(a.validAfter) <= nowSec && Number(a.validBefore) > nowSec)) return 'invalid: authorization is outside its validity window';
  if (!/^0x[0-9a-fA-F]{64}$/.test(a.nonce ?? '')) return 'invalid: nonce must be 32 bytes of hex';
  return null;
}

function x402Topup({ body, headers, url }) {
  const c = new Checker(body);
  const amountUsd = c.field('amountUsd', { required: true, type: 'number', min: 5, max: 50000 });
  c.done();
  const reqs = x402Requirements(amountUsd, `http://${headers.host}${url}`);
  const payment = headers['x-payment'];
  if (!payment) {
    return { status: 402, raw: { x402Version: 1, accepts: [reqs], error: 'X-PAYMENT header required to fund balance' } };
  }
  const problem = checkPayment(payment, reqs);
  if (problem) return { status: 402, raw: { x402Version: 1, accepts: [reqs], error: `payment ${problem}` } };

  const payer = JSON.parse(Buffer.from(payment, 'base64').toString('utf8')).payload.authorization.from;
  const txHash = `0x${randomBytes(32).toString('hex')}`;
  balance += amountUsd;
  const settle = Buffer.from(JSON.stringify({ success: true, transaction: txHash, network: 'base', payer })).toString('base64');
  return {
    status: 200,
    headers: { 'X-PAYMENT-RESPONSE': settle },
    data: { topupId: randomUUID(), amountUsd, method: 'x402', status: 'confirmed', network: 'base', txHash, payer, newBalance: Number(balance.toFixed(6)) },
  };
}

// ── Routing table ───────────────────────────────────────────────────────────

const routes = [
  ['GET', '/health', () => ({ status: 'ok' }), { auth: false }],
  ['POST', '/verify/start', verifyStart],
  ['POST', '/verify/check', verifyCheck],
  ['GET', '/verify/:id', verifyGet],
  ['POST', '/comms/sms', sendSms],
  ['GET', '/comms/sms/:messageId', getSms],
  ['POST', '/comms/calls', makeCall],
  ['GET', '/comms/calls', listCalls],
  ['GET', '/routes/price-number', priceNumber, { auth: 'optional' }],
  ['GET', '/routes/resolve', resolveRoute],
  ['GET', '/dids/search', searchDids],
  ['POST', '/dids/buy', buyDid],
  ['PATCH', '/dids/:id/routing', routeDid],
  ['GET', '/ai-agents/voices', listVoices],
  ['POST', '/ai-agents', createAgent],
  ['POST', '/ai-agents/:id/simulate', simulateAgent],
  ['PUT', '/dialer/campaigns/:id', updateCampaign],
  ['GET', '/cli-tests/quota', cliQuota],
  ['POST', '/cli-tests', createCliTest],
  ['GET', '/cli-tests/:id', getCliTest],
  ['POST', '/topups/x402', x402Topup],
].map(([method, path, handler, opts = {}]) => ({
  method,
  handler,
  auth: opts.auth ?? true,
  keys: [...path.matchAll(/:(\w+)/g)].map((m) => m[1]),
  regex: new RegExp(`^${path.replace(/:\w+/g, '([^/]+)')}$`),
}));

function match(method, path) {
  for (const r of routes) {
    const m = r.regex.exec(path);
    if (m && r.method === method) {
      return { route: r, params: Object.fromEntries(r.keys.map((k, i) => [k, decodeURIComponent(m[i + 1])])) };
    }
  }
  return null;
}

function send(res, status, payload, extraHeaders = {}) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', ...extraHeaders });
  res.end(JSON.stringify(payload));
}

const server = createServer((req, res) => {
  res.setHeader('X-Request-Id', randomUUID());
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    try {
      const url = new URL(req.url, 'http://mock');
      if (!url.pathname.startsWith(PREFIX)) throw new ApiError(404, 'NOT_FOUND', 'Route not found');
      const found = match(req.method, url.pathname.slice(PREFIX.length));
      if (!found) throw new ApiError(404, 'NOT_FOUND', `Route ${req.method} ${url.pathname} not found`);

      const auth = req.headers.authorization ?? '';
      const key = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
      if (found.route.auth === true && !key.startsWith('wmmn_')) {
        throw new ApiError(401, 'UNAUTHORIZED', 'Missing or invalid API key');
      }

      let body;
      const text = Buffer.concat(chunks).toString('utf8');
      if (text) {
        if (!(req.headers['content-type'] ?? '').includes('application/json')) {
          throw new ApiError(400, 'BAD_REQUEST', 'Unsupported content type; send application/json');
        }
        try {
          body = JSON.parse(text);
        } catch {
          throw new ApiError(400, 'BAD_REQUEST', 'Body is not valid JSON');
        }
      }

      const out = found.route.handler({
        body, params: found.params, query: url.searchParams, headers: req.headers, url: req.url,
        testKey: key.startsWith('wmmn_test_sk_'),
      });
      if (out && out.envelope) return send(res, 200, out.envelope);
      if (out && out.raw) return send(res, out.status, out.raw, out.headers);
      if (out && out.status && 'data' in out) return send(res, out.status, { success: true, data: out.data }, out.headers);
      return send(res, 200, { success: true, data: out });
    } catch (err) {
      if (err instanceof ApiError) {
        return send(res, err.status, { success: false, error: { code: err.code, message: err.message, ...(err.details ? { details: err.details } : {}) } });
      }
      console.error(err);
      return send(res, 500, { success: false, error: { code: 'INTERNAL_ERROR', message: 'Mock server error' } });
    }
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`PacketExchange mock API listening on http://127.0.0.1:${PORT}${PREFIX}`);
});
