#!/usr/bin/env python3
"""Serve deterministic gptel responses on loopback and record request bodies."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with (root / 'requests.jsonl').open('a') as stream:
            stream.write(json.dumps({'path': self.path, 'body': body}) + '\n')
        serialized = json.dumps(body)
        answer = 'Fixture answer.'
        if 'fixture-workbench' in serialized:
            def strings(value):
                if isinstance(value, str):
                    yield value
                elif isinstance(value, dict):
                    for child in value.values():
                        yield from strings(child)
                elif isinstance(value, list):
                    for child in value:
                        yield from strings(child)
            prompt = next(text for text in strings(body) if 'Comments:\n' in text)
            comments, _ = json.JSONDecoder().raw_decode(prompt.split('Comments:\n', 1)[1])
            answer = json.dumps([{'id': item['id'], 'text': item['text'] + ' Revised.'}
                                 for item in comments])
        if 'fixture-hang' in serialized:
            time.sleep(.5)
        if self.path == '/mcp':
            response = {'jsonrpc': '2.0', 'id': body['id'], 'result': {
                'content': [{'type': 'text', 'text': json.dumps(body['params']['arguments'])}]}}
        elif 'fixture-error' in serialized:
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"fixture validation error"}}')
            return
        else:
            responses = self.path.endswith('/responses')
            tool_done = 'function_call_output' in serialized or '"role": "tool"' in serialized
            use_tool = 'fixture-tool-cycle' in serialized and not tool_done
            if responses:
                output = ([{'type': 'function_call', 'id': 'fc_fixture', 'call_id': 'call_fixture',
                            'name': 'fixture-read', 'arguments': '{"text":"fixture value"}'}]
                          if use_tool else [{'type': 'message', 'id': 'msg_fixture', 'role': 'assistant',
                                             'content': [{'type': 'output_text', 'text': answer}]}])
                response = {'id': 'resp_fixture', 'object': 'response', 'status': 'completed',
                            'output': output, 'usage': {'input_tokens': 10, 'output_tokens': 3}}
            else:
                message = ({'role': 'assistant', 'content': None, 'tool_calls': [
                    {'id': 'call_fixture', 'type': 'function', 'function': {
                        'name': 'fixture-read', 'arguments': '{"text":"fixture value"}'}}]}
                           if use_tool else {'role': 'assistant', 'content': answer})
                response = {'id': 'chat_fixture', 'object': 'chat.completion', 'choices': [
                    {'index': 0, 'message': message, 'finish_reason': 'tool_calls' if use_tool else 'stop'}],
                            'usage': {'prompt_tokens': 10, 'completion_tokens': 3}}
            if body.get('stream') and not use_tool:
                if responses:
                    events = [{'type': 'response.output_text.delta', 'delta': answer},
                              {'type': 'response.completed', 'response': response}]
                else:
                    events = [{'choices': [{'index': 0, 'delta': {'content': answer}}]},
                              {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]}]
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                for event in events:
                    prefix = ('event: ' + event['type'] + '\n') if responses else ''
                    self.wfile.write((prefix + 'data: ' + json.dumps(event) + '\n\n').encode())
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
                return
        encoded = json.dumps(response).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
