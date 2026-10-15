"""Isolated owner fixture, never connects to the user's Codex IPC socket."""
import json, pathlib, socket, struct, sys, threading

root = pathlib.Path(sys.argv[1])
thread_id = sys.argv[2]
(root / 'ipc').mkdir(parents=True, exist_ok=True)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(str(root / 'ipc' / 'ipc.sock'))
server.listen()

def read(conn, count):
    data = b''
    while len(data) < count:
        part = conn.recv(count - len(data))
        if not part:
            raise EOFError
        data += part
    return data

def write(conn, value):
    data = json.dumps(value).encode()
    conn.sendall(struct.pack('<I', len(data)) + data)

def handle(conn):
    try:
        while True:
            message = json.loads(read(conn, struct.unpack('<I', read(conn, 4))[0]))
            mode = (root / 'mode').read_text().strip()
            owner = 'other-owner' if mode == 'changed-owner' else 'fixture-owner'
            method = message.get('method')
            if message.get('type') == 'broadcast':
                if message['params'].get('following'):
                    items = [] if mode == 'answered' else [{'type': 'agentMessage', 'id': 'question-source',
                        'questions': [{'title': '选择测试输出格式', 'options': ['摘要', '详细']}]}]
                    write(conn, {'type': 'broadcast', 'method': 'thread-stream-state-changed', 'version': 11,
                        'sourceClientId': owner, 'params': {'hostId': 'local', 'conversationId': thread_id,
                            'change': {'type': 'snapshot', 'conversationState': {'cwd': '/fixture', 'requests': [],
                                'turns': [{'turnId': 'turn-fixture', 'status': 'inProgress', 'items': items}]}}}})
                continue
            result = {'type': 'response', 'requestId': message['requestId'], 'resultType': 'success', 'handledByClientId': owner}
            if method == 'initialize':
                result['result'] = {'clientId': 'fixture-follower'}
            elif method == 'thread-owner-discovery':
                pass
            elif method == 'thread-follower-steer-turn':
                with (root / 'submitted.jsonl').open('a') as output:
                    output.write(json.dumps(message) + '\n')
                result['result'] = {'method': method, 'result': {'result': {'turnId': 'wrong-turn' if mode == 'wrong-receipt' else 'turn-fixture'}}}
            else:
                raise AssertionError('unexpected method: ' + str(method))
            write(conn, result)
    except (EOFError, BrokenPipeError, ConnectionResetError):
        pass
    finally:
        conn.close()

print('ready', flush=True)
while True:
    conn, _ = server.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
