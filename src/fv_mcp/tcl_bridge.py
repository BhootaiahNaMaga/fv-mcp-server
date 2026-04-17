"""
tcl_bridge.py — Manages the persistent TCL subprocess (the bridge).

The bridge process is a single, long-lived tclsh (or jaspergold -tcl) that
keeps all state (loaded files, proved properties, etc.) across multiple calls.

Communication protocol (newline-delimited JSON over stdin/stdout):
  Request  → {"id": "<uuid>", "proc": "<name>", "args": ["a", "b"]}
  Response ← {"id": "<uuid>", "status": "ok",    "result": "<output>"}
  Response ← {"id": "<uuid>", "status": "error", "error":  "<msg>"}
"""

import asyncio
import json
import logging
import os
import uuid
from pathlib import Path
from typing import Any

logger = logging.getLogger("fv_mcp.bridge")


class TCLBridge:
    """Manages a persistent TCL subprocess and dispatches JSON-RPC calls."""

    def __init__(self, tcl_exe: str, bridge_tcl: Path, procs_dir: Path,
                 extra_args: list[str] | None = None,
                 env_overrides: dict[str, str] | None = None,
                 cwd: str | None = None):
        """
        Parameters
        ----------
        tcl_exe : str
            Path/name of the TCL interpreter to launch.
            Examples:
              - "tclsh"                    — plain TCL shell (for development)
              - "/tools/jg/bin/jaspergold" — JasperGold binary
              - "jg_shell"                 — Cadence jg_shell alias
        bridge_tcl : Path
            Absolute path to tcl/bridge.tcl
        procs_dir : Path
            Directory containing the *.tcl proc files (tcl/procs/)
        extra_args : list[str]
            Additional CLI arguments inserted before bridge_tcl.
            For JasperGold: ["-tcl"] or ["-batch", "-tcl"]
        env_overrides : dict
            Extra env vars injected into the subprocess.
        cwd : str
            Working directory for the subprocess. Defaults to procs_dir parent.
        """
        self.tcl_exe = tcl_exe
        self.bridge_tcl = bridge_tcl
        self.procs_dir = procs_dir
        self.extra_args = extra_args or []
        self.env_overrides = env_overrides or {}
        self.cwd = cwd or str(bridge_tcl.parent)

        self._process: asyncio.subprocess.Process | None = None
        self._lock = asyncio.Lock()
        self._pending: dict[str, asyncio.Future] = {}
        self._reader_task: asyncio.Task | None = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def start(self) -> None:
        """Launch the TCL subprocess and begin reading its stdout."""
        if self._process and self._process.returncode is None:
            return  # Already running

        env = os.environ.copy()
        env.update(self.env_overrides)

        cmd = [self.tcl_exe] + self.extra_args + [str(self.bridge_tcl)]
        logger.info("Launching TCL bridge: %s", " ".join(cmd))

        self._process = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
            cwd=self.cwd,
        )
        self._reader_task = asyncio.create_task(self._read_loop())
        logger.info("TCL bridge started (pid=%d)", self._process.pid)

    async def stop(self) -> None:
        """Gracefully terminate the TCL subprocess."""
        if self._process and self._process.returncode is None:
            try:
                self._process.stdin.close()         # type: ignore[union-attr]
                await asyncio.wait_for(self._process.wait(), timeout=5)
            except Exception:
                self._process.kill()
        if self._reader_task:
            self._reader_task.cancel()

    # ------------------------------------------------------------------
    # Call a TCL proc
    # ------------------------------------------------------------------

    async def call(self, proc_name: str, args: list[str] | None = None) -> str:
        """Send a request to the bridge and await the response."""
        await self._ensure_running()

        req_id = str(uuid.uuid4())
        payload = json.dumps({"id": req_id, "proc": proc_name,
                               "args": args or []})

        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict] = loop.create_future()
        self._pending[req_id] = future

        async with self._lock:
            line = (payload + "\n").encode()
            self._process.stdin.write(line)          # type: ignore[union-attr]
            await self._process.stdin.drain()         # type: ignore[union-attr]

        response = await asyncio.wait_for(future, timeout=600)

        if response.get("status") == "ok":
            return response.get("result", "")
        else:
            raise RuntimeError(response.get("error", "Unknown TCL error"))

    # ------------------------------------------------------------------
    # Get the tool list from the bridge
    # ------------------------------------------------------------------

    async def list_tools(self) -> list[dict]:
        """Ask the bridge which procs are registered as MCP tools."""
        raw = await self.call("__list_tools__")
        try:
            tools = json.loads(raw)
        except json.JSONDecodeError:
            logger.warning("Could not parse tool list JSON: %s", raw)
            tools = []
        return tools

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    async def _ensure_running(self) -> None:
        if self._process is None or self._process.returncode is not None:
            logger.warning("TCL bridge not running — restarting")
            await self.start()

    async def _read_loop(self) -> None:
        """Background task: read stdout lines and resolve pending futures."""
        assert self._process and self._process.stdout
        stderr_task = asyncio.create_task(self._log_stderr())
        try:
            async for raw_line in self._process.stdout:
                line = raw_line.decode(errors="replace").strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    logger.warning("Non-JSON from TCL bridge: %s", line)
                    continue

                req_id = data.get("id")
                if req_id and req_id in self._pending:
                    fut = self._pending.pop(req_id)
                    if not fut.done():
                        fut.set_result(data)
                else:
                    logger.debug("Unmatched bridge message: %s", line)
        except asyncio.CancelledError:
            pass
        finally:
            stderr_task.cancel()

    async def _log_stderr(self) -> None:
        assert self._process and self._process.stderr
        try:
            async for raw_line in self._process.stderr:
                logger.debug("[TCL stderr] %s",
                             raw_line.decode(errors="replace").rstrip())
        except asyncio.CancelledError:
            pass
