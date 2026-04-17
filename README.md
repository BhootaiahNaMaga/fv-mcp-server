# fv-mcp-server

> **MCP server that bridges Gemini CLI (OpenClaw) to a TCL-based Formal Verification tool such as JasperGold — designed for air-gapped corporate environments.**

No internet access is required at runtime. The server uses the MCP stdio transport so it never opens a network socket. A single long-lived TCL subprocess keeps your JasperGold session state (loaded design, proved properties, constraints) alive across multiple agent tool calls within one Gemini session.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Repository Layout](#repository-layout)
3. [Air-Gapped Installation](#air-gapped-installation)
4. [Gemini CLI Configuration](#gemini-cli-configuration)
5. [Launch Modes](#launch-modes)
6. [Environment Variables](#environment-variables)
7. [Bridge Protocol](#bridge-protocol)
8. [Registering Custom JasperGold Procs](#registering-custom-jaspergold-procs)
9. [Built-in Tools Reference](#built-in-tools-reference)
10. [Example Agent Prompts](#example-agent-prompts)
11. [Troubleshooting](#troubleshooting)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Gemini CLI  (OpenClaw / gemini CLI)                        │
│                                                             │
│  User prompt ──► Agent reasoning ──► Tool call              │
└────────────────────────┬────────────────────────────────────┘
                         │  stdio  ·  MCP JSON-RPC
                         │  (Model Context Protocol)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  fv-mcp-server  [Python]                                    │
│                                                             │
│  server.py  ── discovers tools from TCL bridge at startup   │
│  tcl_bridge.py ── manages persistent subprocess            │
└────────────────────────┬────────────────────────────────────┘
                         │  subprocess stdin / stdout
                         │  newline-delimited JSON
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  bridge.tcl  [Long-lived TCL process]                       │
│                                                             │
│  • Sources all *.tcl files in procs/ at startup             │
│  • Dispatches JSON requests to named procs                  │
│  • Returns JSON responses                                   │
└────────────────────────┬────────────────────────────────────┘
                         │  native TCL / JG commands
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  JasperGold  (jaspergold -batch -tcl bridge.tcl)            │
│  — or any TCL-based EDA tool                                │
└─────────────────────────────────────────────────────────────┘
```

**Key design decisions:**

| Property | Detail |
|---|---|
| Transport | stdio only — no sockets, safe behind any firewall |
| Persistence | One TCL process per Gemini session — JG state survives across tool calls |
| Extensibility | Drop a `.tcl` file in `procs/` — no Python changes ever needed |
| Tool discovery | Dynamic — Python reads the proc registry from the TCL bridge at startup |
| Air-gap safe | Zero runtime internet dependency; install from local wheels |

---

## Repository Layout

```
fv-mcp-server/
├── src/
│   └── fv_mcp/
│       ├── __init__.py
│       ├── server.py          # MCP server — tool discovery + call dispatch
│       └── tcl_bridge.py      # Async subprocess manager + JSON protocol
│
├── tcl/
│   ├── bridge.tcl             # TCL-side JSON dispatcher (the bridge)
│   └── procs/
│       ├── 00_core.tcl        # Generic helpers: ping, get_env, list_registered_tools
│       ├── 01_jg_tools.tcl    # JasperGold: analyze, elaborate, prove, get_status, …
│       └── EXAMPLE_custom_proc.tcl   # Template — copy this to add your own tools
│
├── tests/
│   └── test_bridge_protocol.py   # Smoke tests (plain tclsh, no JG license needed)
│
├── pyproject.toml
├── gemini-settings.json              # Gemini CLI config snippet — JG batch mode
├── gemini-settings-tclsh-dev.json   # Gemini CLI config snippet — dev / CI mode
└── README.md
```

---

## Air-Gapped Installation

The server has a single runtime Python dependency: the official [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk) (`mcp>=1.3.0`).

### Step 1 — Download wheels on a machine with internet

```bash
mkdir offline-wheels
pip download "mcp>=1.3.0" hatchling -d ./offline-wheels/
```

### Step 2 — Transfer to the isolated machine

Copy the entire `fv-mcp-server/` directory and `offline-wheels/` via whatever your site allows (USB, internal artifact repo, SCP over jump host, etc.).

### Step 3 — Install on the isolated machine

```bash
# Create a dedicated venv (adjust path to taste)
python3 -m venv /tools/fv-mcp-venv
source /tools/fv-mcp-venv/bin/activate

# Install MCP SDK from local wheels — no outbound traffic
pip install --no-index --find-links ./offline-wheels/ "mcp>=1.3.0" hatchling

# Install this server in editable mode
pip install --no-index -e ./fv-mcp-server/
```

### Step 4 — Verify

```bash
# Should start, print nothing to stdout, then hang waiting for MCP client.
# Press Ctrl+C to exit.
FV_MCP_JG_MODE=tclsh FV_MCP_DEBUG=1 fv-mcp
```

You should see lines like:

```
[fv_mcp.bridge] Launching TCL bridge: tclsh /path/to/tcl/bridge.tcl
[bridge] Loading proc file: .../procs/00_core.tcl
[bridge] Registered tool: ping
[bridge] Registered tool: jg_analyze
...
[bridge] Ready — waiting for requests on stdin
```

### TCL dependency (tcllib)

`bridge.tcl` uses a built-in regexp-based JSON parser as a fallback so it works with a vanilla `tclsh`. If you want full `package require json` support (useful for complex argument payloads), install tcllib:

```bash
# RHEL / Rocky
yum install tcllib

# Debian / Ubuntu
apt-get install tcllib
```

---

## Gemini CLI Configuration

Gemini CLI reads MCP server configuration from `settings.json`. Add the `mcpServers` block to one of:

- `~/.gemini/settings.json` — global (all projects)
- `.gemini/settings.json` — project-local (checked in alongside your FV project)

### Production — JasperGold batch mode

```json
{
  "mcpServers": {
    "fv-tools": {
      "command": "/tools/fv-mcp-venv/bin/fv-mcp",
      "args": [],
      "env": {
        "FV_MCP_JG_MODE":         "jg_batch",
        "FV_MCP_JG_CMD":          "/tools/cadence/jasper/bin/jaspergold",
        "FV_MCP_WORK_DIR":        "/project/fv/work",
        "FV_MCP_LM_LICENSE_FILE": "27000@your-license-server",
        "FV_MCP_BRIDGE_TCL":      "/tools/fv-mcp-server/tcl/bridge.tcl",
        "FV_MCP_PROCS_DIR":       "/tools/fv-mcp-server/tcl/procs"
      },
      "cwd":    "/project/fv",
      "timeout": 600000,
      "trust":   true
    }
  }
}
```

> **Why `trust: true`?**  
> This is a fully controlled internal server — `trust: true` skips the "Allow tool call?" confirmation dialog for every JG command, which would otherwise make agentic flows unusable.

> **Why explicit `env` for `LM_LICENSE_FILE`?**  
> Gemini CLI automatically strips env vars matching patterns like `*LICENSE*`, `*KEY*`, `*TOKEN*` before passing the environment to the subprocess. You must explicitly re-declare them in the `env` block to override this sanitization.

### Development / CI — plain tclsh (no JG license)

```json
{
  "mcpServers": {
    "fv-tools": {
      "command": "/tools/fv-mcp-venv/bin/fv-mcp",
      "env": {
        "FV_MCP_JG_MODE":    "tclsh",
        "FV_MCP_WORK_DIR":   "/tmp/fv-dev",
        "FV_MCP_BRIDGE_TCL": "/tools/fv-mcp-server/tcl/bridge.tcl",
        "FV_MCP_PROCS_DIR":  "/tools/fv-mcp-server/tcl/procs",
        "FV_MCP_DEBUG":      "1"
      },
      "trust": true
    }
  }
}
```

### Verify in Gemini CLI

```
/mcp          # list connected MCP servers
/mcp desc     # show all tools with descriptions
```

You should see `ping`, `jg_analyze`, `jg_prove`, and any custom tools you added.

---

## Launch Modes

Controlled by the `FV_MCP_JG_MODE` environment variable:

| Mode | Command launched | How JG is invoked | Best for |
|---|---|---|---|
| `tclsh` | `tclsh bridge.tcl` | Via `jg_run_script` sub-subprocess per call | Dev, CI, unit tests |
| `jg_batch` | `jaspergold -batch -tcl bridge.tcl` | bridge.tcl runs *inside* JG — native cmds available | Production scripted flows |
| `jg_interactive` | `jaspergold -noenv -tcl bridge.tcl` | JG interactive session, GUI suppressed | Incremental agent-driven prove |

In `jg_batch` and `jg_interactive` modes, `bridge.tcl` is sourced directly by the JasperGold TCL interpreter. This means all native JG commands (`analyze`, `prove`, `elaborate`, `report`, `visualize`, `get_property_list`, etc.) are available at the global namespace inside your proc files — no subprocess wrapping needed.

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `FV_MCP_JG_MODE` | `tclsh` | Launch mode: `tclsh` \| `jg_batch` \| `jg_interactive` |
| `FV_MCP_JG_CMD` | `jaspergold` | Full path to the JasperGold binary |
| `FV_MCP_TCL_EXE` | `tclsh` | TCL interpreter to use when mode is `tclsh` |
| `FV_MCP_BRIDGE_TCL` | auto-detected | Absolute path to `tcl/bridge.tcl` |
| `FV_MCP_PROCS_DIR` | auto-detected | Directory containing proc `.tcl` files |
| `FV_MCP_WORK_DIR` | `bridge.tcl` directory | Working directory for the TCL subprocess |
| `FV_MCP_LM_LICENSE_FILE` | (unset) | Cadence license string — forwarded to subprocess |
| `FV_MCP_DEBUG` | `0` | Set to `1` for verbose stderr logging |

Auto-detection of `FV_MCP_BRIDGE_TCL` and `FV_MCP_PROCS_DIR` resolves relative to `server.py`'s install location using the package layout (`src/fv_mcp/server.py` → `../../tcl/`). Set these explicitly if you install in a non-standard layout.

---

## Bridge Protocol

This section documents the wire protocol between `server.py` (Python) and `bridge.tcl` (TCL). You only need this if you want to understand internals or build an alternative Python client.

### Transport

- Communication happens over the **subprocess's stdin (Python → TCL) and stdout (TCL → Python)**.
- Each message is a **single line of JSON** terminated by `\n`.
- stderr from the TCL process is captured and logged by Python (never sent to the MCP client).

### Request format (Python → TCL)

```json
{
  "id":   "<uuid-v4>",
  "proc": "<tcl_proc_name>",
  "args": ["arg1", "arg2", "..."]
}
```

- `id` — a UUID generated per call; used to match responses to outstanding requests
- `proc` — the TCL proc name to invoke (must be defined and registered in a procs file)
- `args` — positional arguments as strings; the proc receives them via `{*}$proc_args`

**Special built-in proc:** `__list_tools__` — returns the full tool registry as a JSON array (called once at Python startup to discover available tools).

### Response format (TCL → Python)

**Success:**
```json
{
  "id":     "<same-uuid>",
  "status": "ok",
  "result": "<string output of the proc>"
}
```

**Error:**
```json
{
  "id":     "<same-uuid>",
  "status": "error",
  "error":  "<TCL error message>"
}
```

### Concurrency

The Python side maintains a `dict[id → asyncio.Future]` of in-flight requests. The bridge processes requests **sequentially** (single-threaded TCL event loop), but the Python `asyncio` layer can queue multiple calls and match responses by `id` when they arrive. This means the agent can issue parallel tool calls — they are serialized at the TCL layer without deadlock.

### Example exchange

```
Python → TCL:
{"id":"550e8400-e29b-41d4-a716-446655440000","proc":"jg_prove","args":["*","40","ic3"]}

TCL → Python:
{"id":"550e8400-e29b-41d4-a716-446655440000","status":"ok","result":"PROVED: reset_check\nPROVED: fifo_not_overflow\nFAILED: arb_fairness"}
```

### `__list_tools__` response

```json
[
  {
    "name":        "jg_prove",
    "description": "Run formal proof on JasperGold properties. ...",
    "schema": {
      "type": "object",
      "properties": {
        "property_pattern": { "type": "string", "description": "..." },
        "depth":            { "type": "string", "description": "..." },
        "engine":           { "type": "string", "description": "..." }
      }
    }
  },
  ...
]
```

The Python server converts these directly into MCP `Tool` objects and returns them to Gemini CLI via `list_tools`.

---

## Registering Custom JasperGold Procs

This is the primary extension point. No Python code changes are ever needed.

### The pattern

```tcl
# 1. Write a regular TCL proc
proc <tool_name> {arg1 {optional_arg "default"}} {
    # your JG commands here
    return <string result>
}

# 2. Register it as an MCP tool
::bridge::register_tool <tool_name> \
    "<description for the AI agent>" \
    {<JSON Schema string describing parameters>}
```

`::bridge::register_tool` takes three arguments:

| Argument | Required | Description |
|---|---|---|
| `name` | yes | Must exactly match the proc name |
| `description` | yes | Shown to the AI agent — be precise, the agent reads this to decide when to call the tool |
| `schema` | no | JSON Schema `object` describing the proc's parameters. Omit or pass `{}` for no-arg tools |

### Parameter ordering

The Python server passes arguments **positionally** to the TCL proc, in the order they appear in the schema's `"required"` list (required args first), followed by optional args in alphabetical order of their property key. Your proc's parameter list must match this order.

### Step-by-step example

**File:** `tcl/procs/02_my_project.tcl`

```tcl
# ---------------------------------------------------------------------------
# Check coverage for a specific module
# ---------------------------------------------------------------------------
proc jg_check_cover {module_name {cover_type "all"}} {
    # In jg_batch / jg_interactive mode, these are native JG commands:
    check_cover -init -type $cover_type
    analyze  -sv09 [glob /project/rtl/${module_name}.sv]
    elaborate -top $module_name
    cover    -property *
    return   [report -cover]
}
::bridge::register_tool jg_check_cover \
    "Run JasperGold coverage check for a given RTL module and return the coverage report." \
    {{"type":"object",
      "properties":{
        "module_name": {"type":"string","description":"RTL module name (without .sv extension)"},
        "cover_type":  {"type":"string","description":"Coverage type: all, branch, toggle, statement (default: all)"}
      },
      "required":["module_name"]
    }}


# ---------------------------------------------------------------------------
# Write agent-generated TCL to disk and execute in JG batch mode
# (Lets the agent craft and run arbitrary JG scripts)
# ---------------------------------------------------------------------------
proc jg_exec_snippet {tcl_snippet {script_name "agent_snippet"}} {
    global env
    set work [expr {[info exists env(FV_MCP_WORK_DIR)] ? $env(FV_MCP_WORK_DIR) : "/tmp"}]
    set outf [file join $work "${script_name}.tcl"]
    set fh   [open $outf w]
    puts $fh $tcl_snippet
    close $fh
    return   [jg_run_script $outf]
}
::bridge::register_tool jg_exec_snippet \
    "Write a JasperGold TCL snippet to a temp file and run it in batch mode. Use this when you need to execute custom JG commands not covered by other tools." \
    {{"type":"object",
      "properties":{
        "tcl_snippet":  {"type":"string","description":"Complete JasperGold TCL script to execute"},
        "script_name":  {"type":"string","description":"Base filename for the temp file (default: agent_snippet)"}
      },
      "required":["tcl_snippet"]
    }}
```

Drop this file in `tcl/procs/`, restart Gemini CLI, and both tools appear immediately under `fv-tools` in `/mcp desc`.

### Naming convention

| Prefix | Purpose |
|---|---|
| `jg_` | JasperGold operations |
| `vcf_` | VC Formal operations |
| `fv_` | Generic FV utilities |
| (none) | General helpers (`ping`, `read_log_tail`, etc.) |

### Tips for writing agent-friendly descriptions

- State the **precondition**: "Requires `jg_analyze` and `jg_elaborate` to have already been called."
- State the **return value**: "Returns a multi-line string with one `PROPERTY : STATUS` entry per line."
- State **failure behavior**: "Returns an error string (not a TCL exception) if no properties are loaded."
- Keep it under ~150 words — longer descriptions consume agent context budget.

### Loading order

Files are sourced in lexicographic filename order. Use numeric prefixes to control load order when one file depends on procs defined in another:

```
procs/
  00_core.tcl        ← helpers used by everything
  01_jg_tools.tcl    ← standard JG tools
  02_my_project.tcl  ← project-specific tools (can call procs from 01_)
```

---

## Built-in Tools Reference

### `00_core.tcl`

| Tool | Args | Description |
|---|---|---|
| `ping` | — | Returns `pong`. Connectivity check. |
| `get_env` | `var_name` | Read an environment variable from the bridge process. |
| `list_registered_tools` | — | List names of all registered MCP tools. |

### `01_jg_tools.tcl`

| Tool | Required Args | Optional Args | Description |
|---|---|---|---|
| `jg_analyze` | `files_csv` | `defines`, `top` | Run JasperGold analyze on RTL files (comma-separated paths). |
| `jg_elaborate` | — | `top`, `generics` | Elaborate the design. |
| `jg_prove` | — | `property_pattern`, `depth`, `engine` | Run formal proof. Default: all properties, depth 20, auto engine. |
| `jg_get_status` | — | — | Return proof status of all properties in the session. |
| `jg_get_cex` | `property_name` | — | Return counterexample trace for a failing property. |
| `jg_set_engine` | `engine` | — | Switch engine: `aba`, `bdd`, `ic3`, `pdr`, `sharpSAT`, `ternary`. |
| `jg_source_tcl` | `tcl_file_path` | — | Source a `.tcl` file inside the live JG session. |
| `jg_run_script` | `tcl_file_path` | `extra_args` | Launch JG in batch mode on a complete TCL script. |

---

## Example Agent Prompts

```
# Basic connectivity check
Ping the fv-tools server to confirm it's alive.

# Full analyze → elaborate → prove flow
Using fv-tools: analyze /project/rtl/fifo.sv and /project/rtl/fifo_assert.sv,
elaborate with top module fifo_tb, then prove all properties with depth 40 and
ic3 engine. Report the status and for any failures fetch the counterexample trace.

# Iterative debugging
The property arb_fairness is failing. Get its counterexample, identify the
earliest cycle where the invariant breaks, and suggest a fix to the SVA assertion.

# Custom script execution
Generate a JasperGold TCL script that loads my design at /project/fv/verify.tcl,
runs a 50-cycle bounded proof with the ternary engine, and saves the report to
/project/fv/results/run1.rpt. Then execute it using jg_run_script.
```

---

## Troubleshooting

### Bridge fails to start

```bash
# Run the bridge standalone to see raw errors:
FV_MCP_DEBUG=1 fv-mcp 2>bridge.log
cat bridge.log

# Or launch the bridge directly:
tclsh /path/to/fv-mcp-server/tcl/bridge.tcl
# It should hang silently, waiting for JSON on stdin.
# Type a request manually to test:
{"id":"test-1","proc":"ping","args":[]}
# Expected response:
{"id":"test-1","status":"ok","result":"pong"}
```

### Tools not appearing in `/mcp desc`

1. Check for TCL syntax errors: `tclsh tcl/procs/your_file.tcl` — look for `Error` output.
2. Confirm `::bridge::register_tool` is called *after* the `proc` definition, not before.
3. Restart Gemini CLI after every `settings.json` change.

### JasperGold license errors

Ensure `FV_MCP_LM_LICENSE_FILE` is set and matches your site's `LM_LICENSE_FILE`. The value is explicitly forwarded to the JG subprocess via the `env` block in `settings.json` — Gemini CLI's environment sanitization would otherwise strip it.

### `package require json` not found

The bridge falls back to a built-in regexp parser automatically. Install tcllib for full JSON support only if you write custom procs that call `package require json` themselves.

### Timeout on long proofs

The Python bridge has a default 600-second (10 min) call timeout. For deep proofs, either:
- Increase `timeout` in `settings.json` (value is in milliseconds)
- Have the agent call `jg_run_script` asynchronously and poll `jg_get_status`

---

## License

Internal use. Do not distribute outside your organization's network.
