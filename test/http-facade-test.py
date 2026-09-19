#!/usr/bin/env python3
"""Focused tests for the localhost HTTP/JSONL boundary."""

import http.client
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FACADE = ROOT / "bin" / "nelisp-agent-http"


class HttpFacadeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        # The fake worker has the same one-line request/response contract as
        # bin/nelisp-agent --jsonl, while keeping this boundary test fast.
        worker = Path(self.tmp.name) / "worker.py"
        worker.write_text(
            "import json,sys\n"
            "for line in sys.stdin:\n"
            "  x=json.loads(line)\n"
            "  if x.get('method') == 'bad': print('{not-json', flush=True)\n"
            "  elif x.get('method') == 'huge': print('x' * 200, flush=True)\n"
            "  else: print(json.dumps({'id':x.get('id'),'ok':True,'result':x.get('method')}), flush=True)\n",
            encoding="utf-8",
        )
        self.port = self._free_port()
        environment = dict(os.environ, TEST_HTTP_TOKEN="unit-secret")
        self.process = subprocess.Popen(
            [sys.executable, str(FACADE), "--port", str(self.port),
             "--token-env", "TEST_HTTP_TOKEN", "--max-body", "128",
             "--max-response", "64", "--max-requests", "4",
             "--worker", sys.executable, str(worker)],
            env=environment,
        )
        for _ in range(50):
            try:
                self.request("GET", "/health")
                break
            except OSError:
                time.sleep(0.02)
        else:
            self.fail("HTTP facade did not start")

    def tearDown(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
        self.tmp.cleanup()

    def _free_port(self):
        import socket
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        return port

    def request(self, method, path, body=None, token=None, timeout=2):
        connection = http.client.HTTPConnection("127.0.0.1", self.port,
                                                timeout=timeout)
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, json.loads(data)

    def test_health_auth_limits_and_jsonl_forwarding(self):
        self.assertEqual(self.request("GET", "/health"),
                         (200, {"ok": True, "service": "nelisp-agent"}))
        self.assertEqual(self.request("POST", "/v1/jsonl", "{}"),
                         (401, {"error": "unauthorized"}))
        status, result = self.request(
            "POST", "/v1/jsonl", json.dumps({"id": "one", "method": "status"}),
            "unit-secret")
        self.assertEqual(status, 200)
        self.assertEqual(result, {"id": "one", "ok": True, "result": "status"})
        self.assertEqual(self.request("POST", "/v1/jsonl", "{}", "wrong")[0], 401)
        self.assertEqual(self.request("POST", "/v1/jsonl", "x" * 129,
                                      "unit-secret")[0], 413)
        self.assertEqual(self.request("POST", "/v1/jsonl",
                                      json.dumps({"id": "bad", "method": "bad"}),
                                      "unit-secret"),
                         (502, {"error": "worker_failure",
                                "message": "agent worker returned invalid JSON"}))
        self.assertEqual(self.request("POST", "/v1/jsonl",
                                      json.dumps({"id": "huge", "method": "huge"}),
                                      "unit-secret")[0], 502)
        # The fourth worker request is accepted; the next one exceeds the
        # process request budget.
        self.assertEqual(self.request("POST", "/v1/jsonl",
                                      json.dumps({"id": "two", "method": "quit"}),
                                      "unit-secret")[0], 200)
        self.assertEqual(self.request("POST", "/v1/jsonl",
                                      json.dumps({"id": "three", "method": "status"}),
                                      "unit-secret")[0], 502)

    def test_packaged_worker_models_and_quit(self):
        """Exercise the shipped worker without making an inference call."""
        nelisp = ROOT.parent / "nelisp" / "target" / "nelisp"
        if not nelisp.exists():
            self.skipTest("standalone NeLisp binary is not available")
        self.process.terminate()
        self.process.wait(timeout=3)
        environment = dict(os.environ, TEST_HTTP_TOKEN="unit-secret")
        for key in list(environment):
            if key.startswith("NELISP_AGENT_"):
                del environment[key]
        self.process = subprocess.Popen(
            [sys.executable, str(FACADE), "--port", str(self.port),
             "--token-env", "TEST_HTTP_TOKEN", "--timeout", "15",
             "--max-requests", "2", "--worker", str(ROOT / "bin" / "nelisp-agent"),
             "--jsonl", "--unattended", "--base-url", "http://127.0.0.1:9",
             "--model", "remote/poolside/laguna-xs-2.1:free"],
            env=environment, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                self.request("GET", "/health")
                break
            except OSError:
                time.sleep(0.05)
        else:
            self.fail("HTTP facade did not restart")
        status, response = self.request(
            "POST", "/v1/jsonl",
            json.dumps({"id": "models", "method": "models"}), "unit-secret",
            timeout=10)
        self.assertEqual(status, 200)
        self.assertEqual(response.get("id"), "models")
        self.assertTrue(response.get("ok"))
        models = response.get("result", {}).get("models", [])
        self.assertTrue(any(item.get("qualified-id") ==
                            "remote/poolside/laguna-xs-2.1:free"
                            for item in models))
        status, response = self.request(
            "POST", "/v1/jsonl",
            json.dumps({"id": "quit", "method": "quit"}), "unit-secret",
            timeout=10)
        self.assertEqual(status, 200)
        self.assertEqual(response.get("id"), "quit")
        self.assertTrue(response.get("ok"))


if __name__ == "__main__":
    unittest.main()
