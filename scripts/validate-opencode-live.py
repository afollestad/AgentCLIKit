#!/usr/bin/env python3
"""Exercise the pinned OpenCode V1 HTTP/SSE contract without user credentials.

Uses only an isolated temporary home, XDG trees, empty Git worktrees, and a local
OpenAI-compatible fixture provider. The executable must already be installed;
this script never downloads, upgrades, or configures the user's OpenCode.
"""

import argparse
import base64
import json
import pathlib
import queue
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


VERSION = "1.18.31"


class FixtureProvider(BaseHTTPRequestHandler):
    """Minimal Chat Completions streaming provider; never forwards a request."""

    protocol_version = "HTTP/1.1"
    requests = []
    lock = threading.Lock()
    calls = set()
    slow_started = threading.Event()
    slow_release = threading.Event()

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/release":
            self.slow_release.set()
            value = {"released": True}
        elif self.path == "/state":
            with self.lock:
                count = len(self.requests)
                image_count = sum(any(
                    isinstance(part, dict) and part.get("type") == "image_url"
                    for message in request.get("messages", [])
                    for part in (message.get("content", []) if isinstance(message.get("content"), list) else [])
                ) for request in self.requests)
                overflow_count = int("OVERFLOW" in self.calls)
                tool_names = sorted({tool.get("function", {}).get("name", "")
                                     for request in self.requests for tool in request.get("tools", [])})
            value = {"requestCount": count, "slowStarted": self.slow_started.is_set(),
                     "imageRequestCount": image_count, "overflowCount": overflow_count, "toolNames": tool_names}
        else:
            self.send_error(404)
            return
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with self.lock:
            self.requests.append(body)
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        messages = body.get("messages", [])
        users = [m for m in messages if m.get("role") == "user"]
        last_user = json.dumps(users[-1].get("content", "")) if users else ""
        scenario = next((name for name in ("QUESTION", "PERMISSION", "STEER", "FOLLOWUP", "CHILD", "TASK", "IMAGE", "OVERFLOW", "READ", "OUTSIDE")
                         if "FIXTURE_" + name in last_user), "TEXT")
        tool = None
        available_tools = {item.get("function", {}).get("name") for item in body.get("tools", [])}
        if scenario == "OVERFLOW" and available_tools:
            with self.lock:
                first = scenario not in self.calls
                self.calls.add(scenario)
            if first:
                data = json.dumps({"error": {
                    "message": "This model's maximum context length is 32000 tokens. The input exceeds the context window.",
                    "type": "invalid_request_error", "code": "context_length_exceeded"
                }}).encode()
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
        scenario_tool = {"QUESTION": "question", "PERMISSION": "bash", "TASK": "task", "READ": "read", "OUTSIDE": "read"}.get(scenario)
        # Native title requests can contain the scenario marker but cannot execute tools.
        if scenario_tool is not None and scenario_tool in available_tools:
            with self.lock:
                first = scenario not in self.calls
                self.calls.add(scenario)
            if first:
                if scenario == "QUESTION":
                    tool = ("question", {"questions": [{"header": "Fixture", "question": "Choose a fixture?",
                             "options": [{"label": "First", "description": "Use the first fixture"},
                                         {"label": "Second", "description": "Use the second fixture"}]}]})
                elif scenario == "PERMISSION":
                    tool = ("bash", {"command": "printf fixture-tool", "description": "Print fixture text"})
                elif scenario in ("READ", "OUTSIDE"):
                    tool = ("read", {"filePath": "packet.txt" if scenario == "READ" else "../outside.txt"})
                else:
                    tool = ("task", {"subagent_type": "general", "prompt": "FIXTURE_CHILD", "description": "Fixture child task"})
        if scenario == "STEER":
            self.slow_started.set()
            self.slow_release.wait(15)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        completion_id = "chatcmpl-fixture"

        def chunk(delta, finish=None, usage=None):
            value = {"id": completion_id, "object": "chat.completion.chunk", "created": 1,
                     "model": body.get("model", "fixture"),
                     "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if usage:
                value["usage"] = usage
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            self.wfile.flush()

        try:
            chunk({"role": "assistant"})
            if tool:
                if scenario in ("READ", "OUTSIDE"):
                    chunk({"content": "I will inspect the requested file."})
                chunk({"tool_calls": [{"index": 0, "id": "call_fixture_" + scenario.lower(),
                       "type": "function", "function": {"name": tool[0], "arguments": json.dumps(tool[1])}}]})
                chunk({}, "tool_calls")
            else:
                chunk({"content": "Fixture "})
                chunk({"content": scenario.lower() + " complete."})
                chunk({}, "stop", {"prompt_tokens": 11, "completion_tokens": 5, "total_tokens": 16})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=pathlib.Path)
    parser.add_argument("--record", type=pathlib.Path, help="Write sanitized real-server fixtures to this JSON file")
    parser.add_argument("--serve-provider-only", action="store_true", help="Serve the local model fixture for adapter integration tests")
    args = parser.parse_args()
    if args.serve_provider_only:
        provider = ThreadingHTTPServer(("127.0.0.1", 0), FixtureProvider)
        print(json.dumps({"baseURL": f"http://127.0.0.1:{provider.server_port}/v1",
                          "releaseURL": f"http://127.0.0.1:{provider.server_port}/release",
                          "stateURL": f"http://127.0.0.1:{provider.server_port}/state"}), flush=True)
        try:
            provider.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            provider.server_close()
        return
    if args.binary is None:
        parser.error("--binary is required unless --serve-provider-only is selected")
    binary = args.binary.expanduser().resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="agentclikit-opencode-live-") as temporary:
        root = pathlib.Path(temporary).resolve()
        workspace = root / "source workspace"
        destination = root / "fork workspace"
        workspace.mkdir()
        destination.mkdir()
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(root), "HOME": str(root / "home"),
                       "OPENCODE_SERVER_PASSWORD": "fixture-password", "OPENCODE_DISABLE_AUTOUPDATE": "1",
                       "OPENCODE_DISABLE_MODELS_FETCH": "1", "OPENCODE_DISABLE_DEFAULT_PLUGINS": "1",
                       "OPENCODE_DISABLE_PROJECT_CONFIG": "1", "DO_NOT_TRACK": "1"}
        for name in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
            environment.setdefault(name, str(root / name.lower()))
            pathlib.Path(environment[name]).mkdir(parents=True)
        for command in (["init"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                                  "commit", "--allow-empty", "-m", "Isolated fixture"],
                        ["worktree", "add", "--detach", str(destination)]):
            subprocess.run(["/usr/bin/git", *command], cwd=workspace, env=environment,
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        version = subprocess.check_output([str(binary), "--version"], env=environment, cwd=workspace, text=True).strip()
        assert version == VERSION, f"Expected OpenCode {VERSION}; received {version}"
        provider = ThreadingHTTPServer(("127.0.0.1", 0), FixtureProvider)
        threading.Thread(target=provider.serve_forever, daemon=True).start()
        configuration = {"$schema": "https://opencode.ai/config.json", "model": "fixture/fixture",
                         "small_model": "fixture/fixture", "enabled_providers": ["fixture"],
                         "share": "disabled", "autoupdate": False,
                         "permission": {"*": "allow", "bash": "ask"},
                         "provider": {"fixture": {"npm": "@ai-sdk/openai-compatible", "name": "Local fixture",
                                      "options": {"baseURL": f"http://127.0.0.1:{provider.server_port}/v1", "apiKey": "fixture"},
                                      "models": {"fixture": {"name": "Fixture", "limit": {"context": 32000, "output": 4096}}}}}}
        config_path = root / "opencode.json"
        config_path.write_text(json.dumps(configuration))
        environment["OPENCODE_CONFIG"] = str(config_path)
        port = free_port()
        base_url = f"http://127.0.0.1:{port}"
        authorization = "Basic " + base64.b64encode(b"opencode:fixture-password").decode()
        observations = {"version": version, "responses": {}, "events": []}
        events = queue.Queue()

        def request(method, path, body=None, directory=workspace, authenticated=True, timeout=20):
            headers = {"Content-Type": "application/json", "x-opencode-directory": urllib.parse.quote(str(directory), safe="")}
            if authenticated:
                headers["Authorization"] = authorization
            req = urllib.request.Request(base_url + path, method=method, headers=headers,
                                         data=json.dumps(body).encode() if body is not None else None)
            with urllib.request.urlopen(req, timeout=timeout) as response:
                data = response.read()
                return json.loads(data) if data else None

        def listen():
            req = urllib.request.Request(base_url + "/event", headers={"Authorization": authorization,
                  "x-opencode-directory": urllib.parse.quote(str(workspace), safe="")})
            try:
                with urllib.request.urlopen(req, timeout=60) as response:
                    for raw_line in response:
                        line = raw_line.decode().strip()
                        if line.startswith("data:"):
                            event = json.loads(line[5:])
                            observations["events"].append(event)
                            events.put(event)
            except (OSError, ValueError):
                pass

        def wait_event(kind, session_id=None, timeout=20):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    event = events.get(timeout=min(1, deadline - time.monotonic()))
                except queue.Empty:
                    continue
                if event.get("type") == kind and (session_id is None or event.get("properties", {}).get("sessionID") == session_id):
                    return event
                if event.get("type") == "session.error":
                    raise AssertionError(event)
            raise AssertionError(f"Timed out waiting for {kind} ({session_id})")

        def prompt(session_id, text):
            return request("POST", f"/session/{session_id}/prompt_async", {"model": {"providerID": "fixture", "modelID": "fixture"},
                           "parts": [{"type": "text", "text": text}]})

        log_path = root / "server.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen([str(binary), "serve", "--hostname", "127.0.0.1", "--port", str(port)],
                                       env=environment, cwd=workspace, stdout=log, stderr=subprocess.STDOUT)
            try:
                for _ in range(100):
                    if process.poll() is not None:
                        raise AssertionError("Server exited: " + log_path.read_text())
                    try:
                        health = request("GET", "/global/health", timeout=1)
                        break
                    except (OSError, urllib.error.URLError):
                        time.sleep(0.1)
                else:
                    raise AssertionError("Server failed to become healthy: " + log_path.read_text())
                assert health["healthy"] and health["version"] == VERSION, health
                observations["responses"]["health"] = health
                try:
                    request("GET", "/global/health", authenticated=False)
                    raise AssertionError("Unauthenticated health request unexpectedly succeeded")
                except urllib.error.HTTPError as error:
                    assert error.code == 401, error.code
                threading.Thread(target=listen, daemon=True).start()
                wait_event("server.connected")
                session = request("POST", "/session", {"title": "Deterministic fixture session"})
                session_id = session["id"]
                assert pathlib.Path(session["directory"]).resolve() == workspace.resolve(), session
                observations["responses"]["created"] = session
                prompt(session_id, "FIXTURE_TEXT")
                wait_event("session.idle", session_id)
                history = request("GET", f"/session/{session_id}/message")
                assert any(m["info"]["role"] == "assistant" for m in history), history
                observations["responses"]["messages"] = history
                resumed = request("GET", f"/session/{session_id}")
                assert resumed["id"] == session_id
                observations["responses"]["resumed"] = resumed
                prompt(session_id, "FIXTURE_QUESTION")
                question = wait_event("question.asked", session_id)["properties"]
                request("POST", f"/question/{question['id']}/reply", {"answers": [["First"]]})
                wait_event("session.idle", session_id)
                prompt(session_id, "FIXTURE_PERMISSION")
                permission = wait_event("permission.asked", session_id)["properties"]
                request("POST", f"/permission/{permission['id']}/reply", {"reply": "once"})
                wait_event("session.idle", session_id)
                request("POST", f"/session/{session_id}/summarize", {"providerID": "fixture", "modelID": "fixture", "auto": False})
                wait_event("session.idle", session_id)
                prompt(session_id, "FIXTURE_STEER")
                assert FixtureProvider.slow_started.wait(10), "Fixture provider did not receive slow prompt"
                prompt(session_id, "FIXTURE_FOLLOWUP")
                FixtureProvider.slow_release.set()
                wait_event("session.idle", session_id)
                forked = request("POST", f"/session/{session_id}/fork", {}, directory=destination)
                observations["responses"]["forked"] = forked
                assert forked["id"] != session_id, forked
                # Existing-session routes prefer the saved directory over the header.
                assert pathlib.Path(forked["directory"]).resolve() == workspace.resolve(), forked
                fork_history = request("GET", f"/session/{forked['id']}/message")
                source_history = request("GET", f"/session/{session_id}/message")
                assert len(fork_history) == len(source_history), (len(fork_history), len(source_history))
                assert {m["info"]["id"] for m in fork_history}.isdisjoint({m["info"]["id"] for m in source_history})
                fork_ids = {m["info"]["id"] for m in fork_history}
                assert all(m["info"].get("parentID") in fork_ids for m in fork_history if m["info"]["role"] == "assistant")
                request("POST", "/experimental/control-plane/move-session", {
                    "sessionID": forked["id"], "destination": {"directory": str(destination)}, "moveChanges": False})
                moved = request("GET", f"/session/{forked['id']}")
                observations["responses"]["movedFork"] = moved
                assert pathlib.Path(moved["directory"]).resolve() == destination.resolve(), moved
                assert request("GET", f"/session/{forked['id']}/message") == fork_history
                result = request("POST", f"/session/{forked['id']}/message", {
                    "model": {"providerID": "fixture", "modelID": "fixture"},
                    "parts": [{"type": "text", "text": "FIXTURE_FORK_RESUME"}]}, directory=destination)
                observations["responses"]["forkResume"] = result
                assert pathlib.Path(result["info"]["path"]["cwd"]).resolve() == destination.resolve(), result
                assert request("GET", f"/session/{session_id}/message") == source_history
                assert pathlib.Path(request("GET", f"/session/{session_id}")["directory"]).resolve() == workspace.resolve()
                second_fork = request("POST", f"/session/{forked['id']}/fork", {}, directory=destination)
                request("POST", "/experimental/control-plane/move-session", {
                    "sessionID": second_fork["id"], "destination": {"directory": str(workspace)}, "moveChanges": False})
                assert pathlib.Path(request("GET", f"/session/{second_fork['id']}")["directory"]).resolve() == workspace.resolve()
                archived = request("PATCH", f"/session/{session_id}", {"time": {"archived": 123456789}})
                assert archived["time"]["archived"] == 123456789, archived
                # v1.18.31 cannot clear the native archive field through PATCH:
                # absent/null are ignored, and zero remains archived in list queries.
                empty_time = request("PATCH", f"/session/{session_id}", {"time": {}})
                null_time = request("PATCH", f"/session/{session_id}", {"time": {"archived": None}})
                zero_time = request("PATCH", f"/session/{session_id}", {"time": {"archived": 0}})
                assert empty_time["time"]["archived"] == 123456789
                assert null_time["time"]["archived"] == 123456789
                assert zero_time["time"]["archived"] == 0
                visible = request("GET", "/experimental/session")
                assert session_id not in {item["id"] for item in visible}
                observations["archiveClear"] = {"emptyTime": empty_time["time"], "nullTime": null_time["time"],
                                                "zeroTime": zero_time["time"], "zeroIsVisible": False}
                observations["checks"] = ["basic_auth_required", "directory_header_percent_encoding", "text_stream",
                                           "question_reply", "permission_reply", "native_compaction", "busy_prompt_accepted",
                                           "native_fork_message_remapping", "native_fork_move_preserves_history",
                                           "fork_resume_uses_target_cwd", "source_session_unchanged", "successive_worktree_fork",
                                           "native_archive", "native_delete"]
                observations["limitations"] = ["V1 PATCH cannot clear the native archive timestamp."]
                assert request("DELETE", f"/session/{second_fork['id']}") is True
                assert request("DELETE", f"/session/{forked['id']}", directory=destination) is True
                assert request("DELETE", f"/session/{session_id}") is True
                observations["providerRequestCount"] = len(FixtureProvider.requests)
                observations["events"] = [event for event in observations["events"]
                                          if event.get("properties", {}).get("sessionID") == session_id
                                          or event["type"] == "server.connected"]
                observations["eventTypes"] = sorted({event["type"] for event in observations["events"]})
                if args.record:
                    sanitized = json.dumps(observations, indent=2).replace(str(root), "/tmp/opencode-fixture")
                    args.record.parent.mkdir(parents=True, exist_ok=True)
                    args.record.write_text(sanitized + "\n")
                print(json.dumps({"status": "success", "version": version, "providerRequests": len(FixtureProvider.requests),
                                  "eventTypes": observations["eventTypes"], "limitations": observations["limitations"]}, indent=2))
            except Exception:
                print("OpenCode isolated server log:\n" + log_path.read_text())
                print("Recent events:\n" + json.dumps(observations["events"][-12:], indent=2))
                print("Provider request count:", len(FixtureProvider.requests))
                raise
            finally:
                FixtureProvider.slow_release.set()
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                provider.shutdown()


if __name__ == "__main__":
    main()
