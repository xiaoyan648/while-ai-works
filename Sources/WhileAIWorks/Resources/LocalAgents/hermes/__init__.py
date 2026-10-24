"""Observer-only lifecycle hooks plus an explicitly selected approval transport.
No prompt, response, password, API key, or tool argument is written to disk.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import threading
import time
import uuid
from datetime import datetime

_states = {}
_lock = threading.Lock()
try:
    _started = datetime.strptime(subprocess.check_output(['/bin/ps', '-p', str(os.getpid()), '-o', 'lstart='], text=True).strip(), '%a %b %d %H:%M:%S %Y').timestamp()
except Exception:
    _started = 0

def _root():
    try:
        from hermes_constants import get_hermes_home
        return Path(get_hermes_home())
    except ImportError:
        return Path(os.environ.get('HERMES_HOME', str(Path.home() / '.hermes')))

def record(session_id=None, **changes):
    if not session_id:
        return
    try:
        with _lock:
            key = (str(_root()), session_id)
            value = {**_states.get(key, {}), **changes, 'session_id': session_id,
                     'pid': os.getpid(), 'process_started_at': _started, 'updated_at': time.time()}
            _states[key] = value
            folder = _root() / 'while-ai-works'
            folder.mkdir(parents=True, exist_ok=True, mode=0o700)
            path = folder / (hashlib.sha256(session_id.encode()).hexdigest() + '.json')
            tmp = path.with_suffix('.%s.tmp' % os.getpid())
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'w') as f:
                json.dump(value, f)
            tmp.replace(path)
    except Exception:
        pass

def present(request):
    path = os.environ.get('WHILE_AI_WORKS_INTERACTION_SOCKET', str(Path.home() / '.while-ai-works/interactions.sock'))
    info = os.lstat(path)
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('While AI Works socket unavailable')
    # The host owns allowed choices, request binding, timeouts, and fallback policy.
    # The transport intentionally does not expose a session ID. Keep a separate request card
    # instead of attaching it to a guessed conversation.
    session_id = 'approval:' + request.request_id
    payload = {'_catHubSource': 'hermes', 'hook_event_name': 'PermissionRequest',
               'session_id': 'hermes:' + session_id, 'tool_name': 'terminal',
               '_catRequestToken': str(uuid.uuid4()), '_catOwnerPID': os.getpid(),
               '_catOwnerStart': _started, '_catExpiresAt': time.time() + min(float(request.timeout_seconds), 600),
               'tool_input': {'command': request.command, 'description': request.description}}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(min(float(request.timeout_seconds), 600))
        client.connect(path)
        client.sendall(json.dumps(payload).encode()); client.shutdown(socket.SHUT_WR)
        data = b''
        while len(data) <= 1048576:
            part = client.recv(65536)
            if not part:
                break
            data += part
    value = json.loads(data)
    choice = {'allow': 'once', 'deny': 'deny'}.get(value.get('action'))
    if choice is None:
        raise RuntimeError('No human decision')
    return request.respond(choice)

def register(ctx):
    def started(session_id=None, parent_session_id=None, **kwargs):
        record(session_id, running=True, completed=False, waiting=False, parent_session_id=parent_session_id)
    def ended(session_id=None, completed=None, failed=False, interrupted=False, **kwargs):
        if completed is None and not failed and not interrupted:
            return  # Legacy exit notifications cannot replace a canonical turn outcome.
        record(session_id, running=False, waiting=False, completed=completed is True and not failed and not interrupted)
    def waiting(session_id=None, kind=None, **kwargs):
        # Password prompts remain exclusively in the original client.
        record(session_id, waiting=True, question=kind in ('clarify', 'sudo'), completed=False)
    def resolved(session_id=None, **kwargs):
        record(session_id, waiting=False)
    ctx.register_hook('pre_llm_call', started)
    ctx.register_hook('on_session_end', ended)
    ctx.register_hook('on_human_input_request', waiting)
    ctx.register_hook('on_human_input_resolved', resolved)
    if hasattr(ctx, 'register_approval_transport'):
        ctx.register_approval_transport('while-ai-works', present)
