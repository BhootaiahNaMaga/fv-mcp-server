"""
server.py — Formal Verification MCP Server (Gemini CLI / stdio transport)

Architecture
============
  Gemini CLI
      │  (stdio / JSON-RPC)
      ▼
  [This MCP Server — Python]
      │  (subprocess stdin/stdout — JSON protocol)
      ▼
  [TCL Bridge Process — tclsh / jaspergold -tcl]
      │  (native TCL / JasperGold commands)
      ▼
  [Formal Verification Tool]

Key design points for air-gapped environments
----------------------------------------------
- stdio transport only (no network I/O)
- All paths resolved from env vars or config file (no hardcoded paths)
- TCL subprocess is persistent — keeps JG session state across tool calls
- Tools are discovered dynamically from TCL proc registry at startup
"""

import asyncio
import json
import logging
import os
import sys
from pathlib import Path

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import (
    CallToolResult,
    ListToolsResult,
    TextContent,
    Tool,
)
import mcp.types as types

from .tcl_bridge import TCLBridge

# ---------------------------------------------------------------------------
# Logging — goes to stderr so it doesn't pollute the stdio MCP channel
# ---------------------------------------------------------------------------
logging.basicConfig(
    stream=sys.stderr,
    level=logging.DEBUG if os.getenv("FV_MCP_DEBUG") else logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("fv_mcp.server")

# ---------------------------------------------------------------------------
# Configuration — all tunable via environment variables
# ---------------------------------------------------------------------------

def _resolve_bridge_tcl() -> Path:
    """Find bridge.tcl relative to this file's install location."""
    # Installed package layout:  src/fv_mcp/server.py → ../../tcl/bridge.tcl
    here = Path(__file__).parent
    candidate = here.parent.parent / "tcl" / "bridge.tcl"
    if candidate.exists():
        return candidate
    # Allow explicit override
    override = os.getenv("FV_MCP_BRIDGE_TCL")
    if override:
        return Path(override)
    raise FileNotFoundError(
        "Cannot locate bridge.tcl. Set FV_MCP_BRIDGE_TCL env var."
    )


def _resolve_procs_dir() -> Path:
    override = os.getenv("FV_MCP_PROCS_DIR")
    if override:
        return Path(override)
    bridge_tcl = _resolve_bridge_tcl()
    return bridge_tcl.parent / "procs"


def _build_bridge() -> TCLBridge:
    """
    Build the TCLBridge from environment variables.

    Environment variables
    ---------------------
    FV_MCP_TCL_EXE      : TCL/JG executable (default: tclsh)
    FV_MCP_JG_MODE      : "tclsh" | "jg_batch" | "jg_interactive"
                            tclsh          — plain tclsh, uses jg_run_script internally
                            jg_batch       — jaspergold -batch -tcl bridge.tcl
                            jg_interactive — jaspergold -tcl bridge.tcl (with GUI suppressed)
    FV_MCP_JG_CMD       : Full path to jaspergold binary (used when mode != tclsh)
    FV_MCP_WORK_DIR     : Working directory for the JG process
    FV_MCP_LM_LICENSE_FILE : Cadence license server (injected into subprocess env)
    """
    mode = os.getenv("FV_MCP_JG_MODE", "tclsh")
    bridge_tcl = _resolve_bridge_tcl()
    procs_dir = _resolve_procs_dir()
    work_dir = os.getenv("FV_MCP_WORK_DIR", str(bridge_tcl.parent))

    env_overrides: dict[str, str] = {}
    if lm := os.getenv("FV_MCP_LM_LICENSE_FILE"):
        env_overrides["LM_LICENSE_FILE"] = lm
    if jg_cmd := os.getenv("FV_MCP_JG_CMD"):
        env_overrides["JG_CMD"] = jg_cmd  # picked up by jg_run_script proc

    if mode == "tclsh":
        tcl_exe = os.getenv("FV_MCP_TCL_EXE", "tclsh")
        extra_args: list[str] = []
    elif mode == "jg_batch":
        tcl_exe = os.getenv("FV_MCP_JG_CMD", "jaspergold")
        extra_args = ["-batch", "-tcl"]
    elif mode == "jg_interactive":
        tcl_exe = os.getenv("FV_MCP_JG_CMD", "jaspergold")
        extra_args = ["-noenv", "-tcl"]
    else:
        raise ValueError(f"Unknown FV_MCP_JG_MODE: {mode!r}")

    logger.info(
        "Bridge config: exe=%s mode=%s extra_args=%s bridge_tcl=%s",
        tcl_exe, mode, extra_args, bridge_tcl,
    )

    return TCLBridge(
        tcl_exe=tcl_exe,
        bridge_tcl=bridge_tcl,
        procs_dir=procs_dir,
        extra_args=extra_args,
        env_overrides=env_overrides,
        cwd=work_dir,
    )


# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------

def _schema_to_mcp_input(schema_dict: dict) -> dict:
    """Convert the JSON schema stored in the TCL registry to MCP inputSchema."""
    # TCL stores schemas as JSON strings; they're already parsed by this point
    if isinstance(schema_dict, dict):
        return schema_dict
    return {"type": "object", "properties": {}}


async def serve() -> None:
    logger.info("Starting Formal Verification MCP Server")
    bridge = _build_bridge()

    # Start the TCL bridge subprocess
    await bridge.start()

    # Discover tools from the TCL registry
    tcl_tool_defs = await bridge.list_tools()
    logger.info("Discovered %d tools from TCL bridge", len(tcl_tool_defs))

    server = Server("fv-mcp-server")

    # ------------------------------------------------------------------
    # list_tools handler — returns dynamically discovered TCL tools
    # ------------------------------------------------------------------
    @server.list_tools()
    async def handle_list_tools() -> list[Tool]:
        tools = []
        for td in tcl_tool_defs:
            name = td.get("name", "")
            desc = td.get("description", "")
            schema = td.get("schema", {})
            if isinstance(schema, str):
                try:
                    schema = json.loads(schema)
                except json.JSONDecodeError:
                    schema = {}
            tools.append(
                Tool(
                    name=name,
                    description=desc,
                    inputSchema=schema or {"type": "object", "properties": {}},
                )
            )
        return tools

    # ------------------------------------------------------------------
    # call_tool handler — dispatches to TCL bridge
    # ------------------------------------------------------------------
    @server.call_tool()
    async def handle_call_tool(name: str, arguments: dict) -> list[types.TextContent]:
        logger.info("Tool call: %s args=%s", name, arguments)
        try:
            # Convert dict arguments to ordered list of string values
            # matching the TCL proc's positional parameter order.
            # The order follows the schema's "required" list first,
            # then remaining optional keys.
            schema = next(
                (td.get("schema", {}) for td in tcl_tool_defs
                 if td.get("name") == name),
                {},
            )
            if isinstance(schema, str):
                try:
                    schema = json.loads(schema)
                except json.JSONDecodeError:
                    schema = {}

            # Build positional args in schema property order
            props = schema.get("properties", {})
            required = schema.get("required", [])
            # required first, then optional alphabetically
            ordered_keys = required + sorted(
                k for k in props if k not in required
            )
            args = []
            for k in ordered_keys:
                if k in arguments:
                    args.append(str(arguments[k]))
                elif k in required:
                    raise ValueError(f"Missing required argument: {k}")
                # Optional args not provided are simply omitted — TCL
                # proc should have default values for them.

            result = await bridge.call(name, args)
            return [TextContent(type="text", text=str(result))]

        except Exception as exc:
            logger.error("Tool %s failed: %s", name, exc, exc_info=True)
            return [TextContent(type="text",
                                text=f"ERROR: {exc}")]

    # ------------------------------------------------------------------
    # Run the stdio transport loop
    # ------------------------------------------------------------------
    try:
        async with stdio_server() as (read_stream, write_stream):
            await server.run(read_stream, write_stream,
                             server.create_initialization_options())
    finally:
        await bridge.stop()


def main() -> None:
    asyncio.run(serve())


if __name__ == "__main__":
    main()
