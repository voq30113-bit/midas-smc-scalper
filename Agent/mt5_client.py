"""Read-only client for the MT5 terminal MCP server (see MT5/.mcp.json). Only market-data calls are used here:
the Agent never places, modifies or closes anything."""
import json, os, urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def _cfg():
    c = json.load(open(os.path.join(ROOT, "MT5", ".mcp.json"), encoding="utf-8"))["mcpServers"]["mt5-terminal"]
    return c["url"], c["headers"]["Authorization"]


class MT5:
    def __init__(self):
        self.url, self.auth = _cfg()
        self.sid = None
        self._rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "midas-agent", "version": "1"}})
        self._rpc("notifications/initialized", None, note=True)

    def _rpc(self, method, params, note=False):
        body = {"jsonrpc": "2.0", "method": method}
        if not note: body["id"] = 1
        if params is not None: body["params"] = params
        h = {"Authorization": self.auth, "Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.sid: h["Mcp-Session-Id"] = self.sid
        r = urllib.request.urlopen(urllib.request.Request(self.url, json.dumps(body).encode(), h), timeout=60)
        self.sid = self.sid or r.headers.get("Mcp-Session-Id")
        raw = r.read().decode("utf-8")
        return json.loads(raw) if raw else None

    def call(self, tool, args):
        r = self._rpc("tools/call", {"name": tool, "arguments": args})
        return json.loads(r["result"]["content"][0]["text"])

    def bars(self, symbol, period, frm, to):
        return self.call("get_chart_history", {"symbol": symbol, "period": period, "datetime_from": frm, "datetime_to": to}).get("history", [])

    def info(self, symbol):
        d = self.call("get_marketwatch_symbols", {"symbol": symbol})
        return d["symbols"][0]
