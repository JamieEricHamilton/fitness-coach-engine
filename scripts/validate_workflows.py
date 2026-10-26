#!/usr/bin/env python3
"""Validate the exported n8n workflow JSON files.

Checks, per file:
  - parses as JSON and has the importable shape (name, nodes, connections)
  - every node has a unique name, a type and a typeVersion
  - every connection source and target refers to a node that exists
  - every Code node's JavaScript at least parses (node --check), when node is available
  - no credential ids, hosts or chat ids survived the scrub (see check_scrub.sh for the
    broader pattern sweep; this one checks the structural places they live)
Exit code 1 on any failure.
"""
import json, re, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
files = sorted((ROOT / "n8n").glob("*.json"))
if not files:
    print("no workflow files found under n8n/"); sys.exit(1)

PLACEHOLDER = re.compile(r"^\{\{[A-Z0-9_]+\}\}$")
failures = 0
def fail(msg):
    global failures
    failures += 1
    print(f"  FAIL  {msg}")

node_bin = shutil.which("node")

for f in files:
    print(f"{f.relative_to(ROOT)}")
    try:
        wf = json.loads(f.read_text())
    except json.JSONDecodeError as e:
        fail(f"invalid JSON: {e}"); continue
    for key in ("name", "nodes", "connections"):
        if key not in wf:
            fail(f"missing top-level key {key!r}")
    nodes = wf.get("nodes", [])
    names = [n.get("name") for n in nodes]
    if len(names) != len(set(names)):
        dupes = {n for n in names if names.count(n) > 1}
        fail(f"duplicate node names: {sorted(dupes)}")
    for n in nodes:
        for key in ("name", "type", "typeVersion", "parameters"):
            if key not in n:
                fail(f"node {n.get('name')!r} missing {key!r}")
        for cred_type, cred in (n.get("credentials") or {}).items():
            if not PLACEHOLDER.match(str(cred.get("id", ""))):
                fail(f"node {n['name']!r}: credential id for {cred_type} is not a placeholder")
        if "webhookId" in n and not PLACEHOLDER.match(n["webhookId"]):
            fail(f"node {n['name']!r}: webhookId is not a placeholder")
        chat = str(n.get("parameters", {}).get("chatId", ""))
        if re.fullmatch(r"-?\d{5,}", chat):   # literal id; expressions like ={{ $json.chatId }} are fine
            fail(f"node {n['name']!r}: chatId is a literal, not a placeholder")
        url = n.get("parameters", {}).get("url", "")
        if "supabase.co" in url and "{{SUPABASE_URL}}" not in url:
            fail(f"node {n['name']!r}: raw Supabase host in url")
        # Code nodes: syntax check only. n8n globals ($input, $json, DateTime...) are
        # declared so `node --check` sees valid, self-contained JavaScript.
        if n.get("type") == "n8n-nodes-base.code" and node_bin:
            code = n["parameters"].get("jsCode", "")
            wrapped = ("const $input={},$json={},$items=()=>[],$env={},$now=null,$today=null,DateTime={},"
                       "$=()=>({first:()=>({json:{}}),all:()=>[],item:{json:{}}});\n"
                       "async function __n8n(){\n" + code + "\n}\n")
            with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as t:
                t.write(wrapped)
            r = subprocess.run([node_bin, "--check", t.name], capture_output=True, text=True)
            if r.returncode != 0:
                fail(f"Code node {n['name']!r} does not parse: {r.stderr.strip().splitlines()[-1]}")
    name_set = set(names)
    for src, outs in wf.get("connections", {}).items():
        if src not in name_set:
            fail(f"connection from unknown node {src!r}")
        for branch in outs.get("main", []):
            for edge in branch or []:
                if edge.get("node") not in name_set:
                    fail(f"connection {src!r} -> unknown node {edge.get('node')!r}")
    n_code = sum(1 for n in nodes if n.get("type") == "n8n-nodes-base.code")
    print(f"  ok    {len(nodes)} nodes, {n_code} Code nodes, {sum(len(b) for o in wf.get('connections', {}).values() for b in o.get('main', []))} edges")

if failures:
    print(f"\n{failures} failure(s)"); sys.exit(1)
print("\nall workflows valid")
