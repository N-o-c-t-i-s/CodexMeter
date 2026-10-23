#!/usr/bin/python3
"""Deterministic stdio peer: never reads credentials or sends network requests."""
import json
from pathlib import Path
import sys
import time

root = Path(__file__).parent
scenario = (root / "scenario").read_text().strip()
account_update_sent = False
logout_update_sent = False

def emit(payload):
    print(json.dumps(payload), flush=True)

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    with (root / "requests.jsonl").open("a") as stream:
        stream.write(json.dumps(request) + "\n")
    if "id" not in request:
        continue
    response = {"id": request["id"]}
    if method == "initialize":
        response["result"] = {}
    elif method == "account/read":
        if (root / "logged-out").exists():
            if not logout_update_sent:
                logout_update_sent = True
                emit({"method": "account/updated", "params": {"authMode": None, "planType": None}})
            response["result"] = {"account": None, "requiresOpenaiAuth": True}
        elif scenario == "account-update-feedback" and request.get("params", {}).get("refreshToken"):
            emit({"method": "account/updated", "params": {"authMode": None, "planType": None}})
            response["result"] = {"account": None, "requiresOpenaiAuth": True}
        else:
            response["result"] = {"account": {"type": "chatgpt", "email": "fixture@example.invalid", "planType": "plus"}}
    elif method == "model/list":
        if scenario == "account-update-feedback" and not account_update_sent:
            account_update_sent = True
            emit({"method": "account/updated", "params": {"authMode": "chatgpt", "planType": "plus"}})
        response["result"] = {"data": [
            {"id": "fixture-a", "model": "fixture-a", "displayName": "Fixture A",
             "supportedReasoningEfforts": [{"reasoningEffort": "low"}]},
            {"id": "fixture-b", "model": "fixture-b", "displayName": "Fixture B",
             "supportedReasoningEfforts": [{"reasoningEffort": "medium"}]}
        ]}
    elif method == "account/rateLimits/read":
        response["result"] = {"ordinaryUsageAllowed": True, "rateLimits": {"limitId": "codex", "primary": {
            "usedPercent": 20 if scenario == "account-update-feedback" else 0,
            "windowDurationMins": 300, "resetsAt": int(time.time()) + 18000}}}
    elif method == "account/usage/read":
        response["result"] = {"summary": {}}
    elif method == "thread/start":
        if scenario == "thread-error":
            response["error"] = {"code": -32000, "message": "Model unavailable: private-backend-text"}
        elif scenario == "thread-malformed":
            response["unexpected"] = True
        else:
            response["result"] = {"thread": {"id": "thread-fixture"}, "modelProvider": "openai"}
    elif method == "turn/start":
        if scenario == "turn-error":
            response["error"] = {"code": -32000, "message": "401 unauthorized private-backend-text"}
        elif scenario == "turn-malformed":
            response["unexpected"] = True
        elif scenario == "output-overflow":
            print("x" * 1_100_000, flush=True)
            continue
        elif scenario == "process-exit":
            sys.exit(0)
        else:
            response["result"] = {"turn": {"id": "turn-fixture"}}
    else:
        response["result"] = {}
    emit(response)
