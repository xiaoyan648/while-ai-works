"""Run the installed Harness against a loopback fixture model; no external model calls."""
import http.server
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import time

class Model(http.server.BaseHTTPRequestHandler):
    calls=0
    entered=threading.Event()
    release=threading.Event()
    def log_message(self,*args): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        Model.calls+=1
        Model.entered.set(); Model.release.wait(30)
        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
        chunks=[{'id':'fixture','object':'chat.completion.chunk','model':'fixture','choices':[{'index':0,'delta':{'role':'assistant','content':'Local fixture completed.'},'finish_reason':None}]},
                {'id':'fixture','object':'chat.completion.chunk','model':'fixture','choices':[{'index':0,'delta':{},'finish_reason':'stop'}],'usage':{'prompt_tokens':120,'completion_tokens':8,'total_tokens':128}}]
        for chunk in chunks:self.wfile.write(('data: '+json.dumps(chunk)+'\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n')

with tempfile.TemporaryDirectory(prefix='waw-dsh-runtime-') as tmp:
    root=Path(tmp)
    server=socketserver.TCPServer(('127.0.0.1',0),Model)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    plugin=Path('Sources/WhileAIWorks/Resources/LocalAgents/dsh/index.mjs').resolve()
    patch=root/'fixture.yml'
    patch.write_text(f'''- id: llm-pi-ai
  config:
    providers:
      waw-fixture:
        api: openai-completions
        apiKeyEnv: WAW_FIXTURE_KEY
        baseURL: http://127.0.0.1:{server.server_address[1]}/v1
        models:
          - id: fixture
        retryPolicy:
          mode: normal
          maxRetries: 0
- id: agent-default-model
  config:
    provider: waw-fixture
    model: fixture
- insert:
    - id: while-ai-works
      name: {plugin}
''')
    env={**os.environ,'DSH_HOME':str(root/'home'),'WAW_FIXTURE_KEY':'fixture-not-a-secret'}
    # Remove ambient credentials; the only configured model endpoint is loopback.
    for key in list(env):
        if any(s in key for s in ['API_KEY','BASE_URL','AUTH_TOKEN']) and key!='WAW_FIXTURE_KEY':env.pop(key)
    probe=Path(__file__).resolve().parents[1]/'.build/native/LocalAgentChecks'
    def inspect():
        return json.loads(subprocess.check_output([str(probe),'--probe-dsh-root',str(root/'home')],text=True,timeout=25))
    try:
        # Exercise the documented package installation/bundle mounting path in an isolated profile.
        install=subprocess.run(['dsh','plugin','--profile','headless','add',str(plugin.parent)],env=env,cwd=root,capture_output=True,text=True,timeout=90)
        if install.returncode:raise RuntimeError(install.stderr[-3000:])
        patch.write_text(patch.read_text().split('- insert:')[0])
        child=subprocess.Popen(['dsh','headless','--patch',str(patch),'Say fixture completed.'],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            assert Model.entered.wait(30),'Harness never called loopback model'
            live=inspect()
            assert any(x['running'] for x in live),('Native adapter did not detect a real live session',live)
            Model.release.set()
            stdout,stderr=child.communicate(timeout=60)
            result=subprocess.CompletedProcess(child.args,child.returncode,stdout,stderr)
        finally:
            Model.release.set()
            if child.poll() is None:child.terminate();child.wait(timeout=10)
        final=inspect()
        assert any(x['finished'] and not x['running'] and x['input']>=120 and x['output']>=8 for x in final),final
        if result.returncode:print(result.stderr[-6000:]);raise SystemExit(result.returncode)
        assert 'Local fixture completed.' in result.stdout,result.stdout[-1000:]
        states=list((root/'home/while-ai-works').glob('*.json'));assert states,'Plugin was not mounted'
        state=json.loads(states[0].read_text());assert state['completed'] and not state['running'],state
        logs=list((root/'home/sessions').rglob('session*.jsonl.zstd'));assert logs,'No durable compressed session'
        output=Path(os.environ.get('WAW_RUNTIME_EVIDENCE','.build/dsh-runtime-evidence'))
        if not output.is_absolute():output=Path(__file__).resolve().parents[1]/output
        output.mkdir(parents=True,exist_ok=True)
        # These are generated fixture-only logs, safe to feed to the native adapter acceptance check.
        import shutil
        shutil.copytree(root/'home/sessions',output/'sessions',dirs_exist_ok=True)
        (output/'result.json').write_text(json.dumps({'exit':result.returncode,'model_calls':Model.calls,'state':state,'live_native':live,'final_native':final},indent=2))
        print('PASS: real DSH package install + headless process, loopback model, native App detects live lock then completion and tokens from zstd')
    finally:server.shutdown();server.server_close()
