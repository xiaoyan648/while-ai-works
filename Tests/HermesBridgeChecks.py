import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
sys.dont_write_bytecode = True

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module);return module
with tempfile.TemporaryDirectory(prefix='waw-hermes-') as tmp:
    os.environ['HERMES_HOME']=tmp
    path=tmp+'/approval.sock';os.environ['WHILE_AI_WORKS_INTERACTION_SOCKET']=path
    bridge=load('waw_hermes','Sources/WhileAIWorks/Resources/LocalAgents/hermes/__init__.py')
    contract=load('hermes_transport_contract',os.environ['HERMES_TRANSPORT_CONTRACT'])
    class Context:
        hooks={}
        def register_hook(self,name,fn):self.hooks[name]=fn
        def register_approval_transport(self,name,fn):self.transport=fn
    ctx=Context();bridge.register(ctx)
    ctx.hooks['pre_llm_call'](session_id='fixture',user_message='PRIVATE-PROMPT',conversation_history=['PRIVATE-HISTORY'])
    ctx.hooks['on_human_input_request'](session_id='fixture',kind='clarify',prompt='PRIVATE-QUESTION')
    value=json.loads(next((Path(tmp)/'while-ai-works').glob('*.json')).read_text());assert value['waiting'] and value['question']
    ctx.hooks['on_human_input_resolved'](session_id='fixture')
    ctx.hooks['on_session_end'](session_id='fixture',completed=True)
    value=json.loads(next((Path(tmp)/'while-ai-works').glob('*.json')).read_text());assert value['completed'] and not value['running'] and not value['waiting']
    assert 'PRIVATE' not in json.dumps(value)
    ctx.hooks['pre_llm_call'](session_id='fixture')
    ctx.hooks['on_session_end'](session_id='fixture',completed=False,interrupted=True)
    value=json.loads(next((Path(tmp)/'while-ai-works').glob('*.json')).read_text());assert not value['completed'] and not value['running']
    request=contract.ApprovalRequest.create(command='echo fixture',description='Fixture approval',pattern_key='fixture',pattern_keys=('fixture',),session_key='private-session',surface='cli',allow_session=False,allow_permanent=False,timeout_seconds=5)
    server=socket.socket(socket.AF_UNIX);server.bind(path);os.chmod(path,0o600);server.listen()
    def respond():
        client,_=server.accept()
        with client:
            data=b''
            while True:
                part=client.recv(65536)
                if not part:break
                data+=part
            payload=json.loads(data);assert payload['tool_input']['command']=='echo fixture'
            client.sendall(b'{"action":"allow"}')
    thread=threading.Thread(target=respond);thread.start()
    result=ctx.transport(request);thread.join();server.close()
    assert result.request_id==request.request_id and result.request_digest==request.digest and result.choice=='once'
    print('PASS: Hermes lifecycle/privacy and actual upstream request-bound approval contract')
