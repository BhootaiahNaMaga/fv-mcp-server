"""
test_bridge_protocol.py

Smoke tests that verify the TCL bridge protocol without needing JasperGold.
Runs the bridge with plain tclsh.

Usage:
    cd fv-mcp-server
    python -m pytest tests/ -v
"""

import asyncio
import json
from pathlib import Path

import pytest

# Locate bridge.tcl relative to this test file
ROOT = Path(__file__).parent.parent
BRIDGE_TCL = ROOT / "tcl" / "bridge.tcl"
PROCS_DIR  = ROOT / "tcl" / "procs"


@pytest.fixture
async def bridge():
    """Start a bridge subprocess using plain tclsh."""
    import sys
    from src.fv_mcp.tcl_bridge import TCLBridge

    b = TCLBridge(
        tcl_exe="tclsh",
        bridge_tcl=BRIDGE_TCL,
        procs_dir=PROCS_DIR,
    )
    await b.start()
    yield b
    await b.stop()


@pytest.mark.asyncio
async def test_ping(bridge):
    result = await bridge.call("ping")
    assert result == "pong"


@pytest.mark.asyncio
async def test_list_tools(bridge):
    tools = await bridge.list_tools()
    names = [t["name"] for t in tools]
    assert "ping" in names
    assert "jg_analyze" in names
    assert "jg_prove" in names


@pytest.mark.asyncio
async def test_get_env_unset(bridge):
    result = await bridge.call("get_env", ["NONEXISTENT_VAR_12345"])
    assert result == "(not set)"


@pytest.mark.asyncio
async def test_list_registered_tools(bridge):
    result = await bridge.call("list_registered_tools")
    assert "ping" in result
    assert "jg_run_script" in result


@pytest.mark.asyncio
async def test_error_handling(bridge):
    """Calling a non-existent proc should return an error, not crash."""
    with pytest.raises(RuntimeError, match="does_not_exist"):
        await bridge.call("does_not_exist", [])


@pytest.mark.asyncio
async def test_parallel_calls(bridge):
    """Multiple concurrent calls should all resolve correctly."""
    results = await asyncio.gather(*[bridge.call("ping") for _ in range(10)])
    assert all(r == "pong" for r in results)
