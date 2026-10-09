"""Serve deterministic local-only responses for native UI workflow evidence."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(sys.argv[1])
ROOT.mkdir(parents=True, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        serialized = json.dumps(body)
        with (ROOT / "requests.jsonl").open("a") as output:
            output.write(json.dumps({"path": self.path, "body": body}) + "\n")
        if "fixture-error" in serialized and not (ROOT / "recovered").exists():
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"Fixture rejected an invalid input. Correct the prompt and retry."}}')
            return
        tool_done = "function_call_output" in serialized
        use_tool = "fixture-tool-cycle" in serialized and not tool_done
        content = ("The local review is complete.\n\n"
                   "* Findings\n"
                   "- Keep the draft separate from attachments.\n"
                   "- Review requested effects before approval.\n"
                   "- Preserve the reading position while output arrives.\n\n"
                   "* Next step\n"
                   "Inspect the result and choose whether to continue.\n")
        result = {"id": "resp_workflow", "object": "response", "status": "completed",
                  "output": [{"type": "function_call", "id": "fc_fixture", "call_id": "call_fixture",
                              "name": "fixture-write", "arguments": '{"text":"Reviewed locally."}'}]
                  if use_tool else [{"type": "message", "id": "msg_fixture", "role": "assistant",
                                     "content": [{"type": "output_text", "text": content}]}],
                  "usage": {"input_tokens": 32, "output_tokens": 48}}
        if body.get("stream") and not use_tool:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            try:
                chunks = content.splitlines(keepends=True)
                for index, chunk in enumerate(chunks):
                    self.event({"type": "response.output_text.delta", "delta": chunk})
                    time.sleep(10 if "fixture-slow" in serialized and index == 0 else .18)
                self.event({"type": "response.completed", "response": result})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass  # Expected when the real client cancels the fixture stream.
            return
        encoded = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def event(self, payload):
        self.wfile.write(("event: " + payload["type"] + "\ndata: " + json.dumps(payload) + "\n\n").encode())
        self.wfile.flush()


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(ROOT / "port").write_text(str(server.server_port))
server.serve_forever()
