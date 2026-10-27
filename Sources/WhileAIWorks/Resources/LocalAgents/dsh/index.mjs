import { createConnection } from 'node:net';
import { mkdirSync, writeFileSync, renameSync, lstatSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
export const name = 'while-ai-works';
const started = Date.now() / 1000 - process.uptime();
const root = process.env.DSH_HOME || join(homedir(), '.dsh');
const socketPath = process.env.WHILE_AI_WORKS_INTERACTION_SOCKET || join(homedir(), '.while-ai-works/interactions.sock');
const states = new Map();
let profile;
function record(session, changes) {
  if (!session?.id) return;
  const old = states.get(session.id) || {};
  const value = { ...old, ...changes, session_id: session.id, pid: process.pid,
    process_started_at: started, updated_at: Date.now() / 1000, profile, cwd: session.header?.cwd,
    parent_session_id: session.header?.origin === 'subagent' || session.header?.delegationDepth > 0 ? session.header?.parentSession : undefined };
  states.set(session.id, value);
  try {
    const folder = join(root, 'while-ai-works'); mkdirSync(folder, { recursive: true, mode: 0o700 });
    const path = join(folder, createHash('sha256').update(session.id).digest('hex') + '.json');
    const tmp = path + '.' + process.pid + '.tmp';
    writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 }); renameSync(tmp, path);
  } catch { /* Monitoring never changes the agent's outcome. */ }
}
export function request(payload, signal, timeout = 600000) {
  return new Promise(resolve => {
    try { const s = lstatSync(socketPath); if (!s.isSocket() || s.uid !== process.getuid() || (s.mode & 0o077)) return resolve(null); }
    catch { return resolve(null); }
    if (signal?.aborted) return resolve(null);
    const token = randomUUID();
    payload = { ...payload, _catRequestToken: token, _catOwnerPID: process.pid,
      _catOwnerStart: started, _catExpiresAt: Date.now() / 1000 + timeout / 1000 };
    const socket = createConnection({ path: socketPath, allowHalfOpen: true });
    let bytes = Buffer.alloc(0), settled = false;
    const finish = value => { if (settled) return; settled = true; clearTimeout(timer); signal?.removeEventListener('abort', cancel); socket.destroy(); resolve(value); };
    const cancel = () => {
      if (settled) return;
      // Half-close frames requests, so withdrawal needs an explicit message on a new connection.
      const withdrawal = createConnection({ path: socketPath });
      withdrawal.on('error', () => withdrawal.destroy());
      withdrawal.on('connect', () => withdrawal.end(JSON.stringify({ _catHubCancel: token })));
      withdrawal.setTimeout(1000, () => withdrawal.destroy());
      finish(null);
    };
    const timer = setTimeout(cancel, timeout);
    signal?.addEventListener('abort', cancel, { once: true });
    socket.on('connect', () => socket.end(JSON.stringify(payload)));
    socket.on('data', chunk => { bytes = Buffer.concat([bytes, chunk]); if (bytes.length > 1048576) cancel(); });
    socket.on('error', cancel);
    socket.on('end', () => { try { finish(JSON.parse(bytes.toString('utf8'))); } catch { cancel(); } });
    socket.on('close', cancel);
  });
}
export function apply(ctx) {
  const calls = new Map();
  profile = ctx.get?.('profileContext')?.name ?? process.env.DSH_TUI_PROFILE;
  const waits = new Map();
  function publishWaiting(session) {
    if (!states.has(session.id)) return;
    let continued = false;
    try {
      continued = (ctx.get?.('sessionProjections')?.stateOf(session, 'userQuestions')?.questions?.active || []).some(q => q.state === 'continued');
    } catch { /* Older clients may not expose the projection. */ }
    const kind = [...(waits.get(session.id)?.values() || [])][0] || (continued ? 'question' : null);
    const old = states.get(session.id);
    if (old.waiting !== !!kind || old.waiting_kind !== kind) record(session, { waiting: !!kind, question: kind === 'question', waiting_kind: kind });
  }
  function beginWait(req, kind) {
    const session = req.agent.session, token = randomUUID();
    const active = waits.get(session.id) || new Map();
    waits.set(session.id, active);
    active.set(token, kind);
    // A resumed agent may ask before its first lifecycle event reaches this plugin.
    if (!states.has(session.id)) record(session, {});
    let ended = false;
    const end = () => {
      if (ended) return;
      ended = true; req.signal?.removeEventListener('abort', end);
      active.delete(token);
      if (waits.get(session.id) !== active) return;
      publishWaiting(session); if (!active.size) waits.delete(session.id);
    };
    publishWaiting(session); req.signal?.addEventListener('abort', end, { once: true });
    if (req.signal?.aborted) end();
    return end;
  }
  ctx.on('session/event', (session, event) => {
    const data = event.data || {};
    if (event.type === 'turn/start') { waits.delete(session.id); record(session, { running: true, completed: false, waiting: false, waiting_kind: null }); }
    if (event.type === 'turn/end') { waits.delete(session.id); record(session, { running: false, completed: data.reason?.kind === 'completed', waiting: false, waiting_kind: null }); }
    if (event.type === 'tool/call') calls.set(session.id + ':' + data.callId, { name: data.name, arguments: data.arguments });
    if (event.type === 'tool/result') calls.delete(session.id + ':' + data.message?.callId);
    // A timed-out tool can remain answerable while the agent continues. Read the
    // client's projection after its event listeners have folded this event.
    queueMicrotask(() => publishWaiting(session));
  });
  ctx.on('agent/created', ({ agent }) => { record(agent.session, { running: agent.status === 'running', completed: false, waiting: false }); });
  ctx.on('agent/disposed', ({ agent }) => { waits.delete(agent.session.id); record(agent.session, { running: false, waiting: false, waiting_kind: null }); for (const key of calls.keys()) if (key.startsWith(agent.session.id + ':')) calls.delete(key); states.delete(agent.session.id); });
  ctx.on('user-questions/request', async (req, next) => {
    if (!req.agent?.session || !req.questions?.length || req.signal?.aborted) return next();
    const plan = req.questions.some(q => q.intent?.kind === 'plan-review');
    const end = beginWait(req, plan ? 'plan' : 'question');
    try {
      // Native-only requests still advertise waiting for their entire lifetime.
      if (req.wait?.timed || plan || req.questions.some(q => q.detail)) return await next();
      const answer = await request({ _catHubSource: 'dsh', hook_event_name: 'PermissionRequest',
        session_id: 'deepseek:' + req.agent.session.id, tool_name: 'AskUserQuestion', cwd: req.agent.session.header?.cwd,
        tool_input: { questions: req.questions.map(q => ({ ...q, options: q.options || [] })) } }, req.signal);
      if (req.signal?.aborted) throw req.signal.reason ?? new Error('Question cancelled');
      if (answer?.action === 'answer' && !req.signal?.aborted) return { answers: answer.answers };
      return await next();
    } finally { end(); }
  }, true);
  ctx.on('approval/request', async (req, next) => {
    if (!req.agent?.session) return next();
    if (req.signal?.aborted) return 'cancelled';
    const call = calls.get(req.agent?.session?.id + ':' + req.callId);
    const end = beginWait(req, 'approval');
    try {
      // Missing arguments prevent answering here, but must not hide the request.
      if (!call || call.name !== req.toolName) return await next();
      const answer = await request({ _catHubSource: 'dsh', hook_event_name: 'PermissionRequest',
        session_id: 'deepseek:' + req.agent.session.id, tool_name: req.toolName, cwd: req.agent.session.header?.cwd,
        tool_input: { arguments: call.arguments, reason: req.reason || '' } }, req.signal);
      if (req.signal?.aborted) return 'cancelled';
      if (!req.signal?.aborted && answer?.action === 'allow') return 'allowed-once';
      if (!req.signal?.aborted && answer?.action === 'deny') return 'rejected';
      return await next();
    } finally { end(); }
  }, true);
}
