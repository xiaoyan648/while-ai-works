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
function record(session, changes) {
  if (!session?.id) return;
  const old = states.get(session.id) || {};
  const value = { ...old, ...changes, session_id: session.id, pid: process.pid,
    process_started_at: started, updated_at: Date.now() / 1000,
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
  ctx.on('session/event', (session, event) => {
    const data = event.data || {};
    if (event.type === 'turn/start') record(session, { running: true, completed: false, waiting: false });
    if (event.type === 'turn/end') record(session, { running: false, completed: data.reason?.kind === 'completed', waiting: false });
    if (event.type === 'tool/call') calls.set(session.id + ':' + data.callId, { name: data.name, arguments: data.arguments });
    if (event.type === 'tool/result') calls.delete(session.id + ':' + data.message?.callId);
  });
  ctx.on('agent/created', ({ agent }) => { record(agent.session, { running: agent.status === 'running', completed: false, waiting: false }); });
  ctx.on('agent/disposed', ({ agent }) => { record(agent.session, { running: false, waiting: false }); for (const key of calls.keys()) if (key.startsWith(agent.session.id + ':')) calls.delete(key); states.delete(agent.session.id); });
  ctx.on('user-questions/request', async (req, next) => {
    // Timed waits require the native UI's attachWait lease. Plan review stays on its complete native surface.
    if (!req.agent?.session || req.wait?.timed || !req.questions?.length || req.questions.some(q => q.intent?.kind === 'plan-review' || q.detail)) return next();
    record(req.agent.session, { waiting: true, question: true });
    try {
      const answer = await request({ _catHubSource: 'dsh', hook_event_name: 'PermissionRequest',
        session_id: 'deepseek:' + req.agent.session.id, tool_name: 'AskUserQuestion', cwd: req.agent.session.header?.cwd,
        tool_input: { questions: req.questions.map(q => ({ ...q, options: q.options || [] })) } }, req.signal);
      if (answer?.action === 'answer' && !req.signal?.aborted) return { answers: answer.answers };
      return await next();
    } finally { record(req.agent.session, { waiting: false, question: false }); }
  }, true);
  ctx.on('approval/request', async (req, next) => {
    const call = calls.get(req.agent?.session?.id + ':' + req.callId);
    // Do not ask users to authorize a tool without its exact pending arguments.
    if (!call || call.name !== req.toolName || !req.agent?.session) return next();
    record(req.agent.session, { waiting: true, question: false });
    try {
      const answer = await request({ _catHubSource: 'dsh', hook_event_name: 'PermissionRequest',
        session_id: 'deepseek:' + req.agent.session.id, tool_name: req.toolName, cwd: req.agent.session.header?.cwd,
        tool_input: { arguments: call.arguments, reason: req.reason || '' } }, req.signal);
      if (!req.signal?.aborted && answer?.action === 'allow') return 'allowed-once';
      if (!req.signal?.aborted && answer?.action === 'deny') return 'rejected';
      return await next();
    } finally { record(req.agent.session, { waiting: false }); }
  }, true);
}
