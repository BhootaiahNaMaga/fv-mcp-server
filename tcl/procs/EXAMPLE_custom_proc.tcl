#!/usr/bin/env tclsh
# =============================================================================
# EXAMPLE_custom_proc.tcl
#
# Template for adding your own custom tools.
# Copy this file, rename it (keep the .tcl extension), and add your procs.
# The bridge automatically sources every .tcl file in the procs/ directory.
#
# Pattern
# -------
# 1. Write a regular TCL proc.
# 2. Call ::bridge::register_tool to expose it as an MCP tool.
#    Parameters:
#      - name        : must match the proc name exactly
#      - description : shown to the AI agent (be precise — the agent reads this)
#      - schema      : JSON Schema string describing the proc's arguments
#
# The MCP server passes arguments POSITIONALLY in the order they appear in
# the schema's "required" list (required first) then optional keys.
# Make sure your proc's parameter list matches that order.
# =============================================================================

# ---------------------------------------------------------------------------
# Example 1 — A simple custom constraint helper
# ---------------------------------------------------------------------------
proc jg_add_assume {signal_name constraint_expr} {
    # This would add a JasperGold assume property at runtime.
    # In a real JG shell this calls: assume -name <sig> {<expr>}
    if {[info commands assume] ne ""} {
        assume -name ${signal_name}_assume $constraint_expr
        return "Assume '$signal_name' added: $constraint_expr"
    } else {
        # Dev mode — just echo
        return "\[DEV\] Would run: assume -name ${signal_name}_assume {$constraint_expr}"
    }
}
::bridge::register_tool jg_add_assume \
    "Add a JasperGold assume constraint for a signal. Useful for restricting the proof space." \
    {{"type":"object","properties":{"signal_name":{"type":"string","description":"Signal name (used as the assume property name suffix)"},"constraint_expr":{"type":"string","description":"TCL/SVA expression for the assume, e.g. {clk == 1'b1}"}},"required":["signal_name","constraint_expr"]}}


# ---------------------------------------------------------------------------
# Example 2 — Read and return a log file excerpt (useful for CEX debugging)
# ---------------------------------------------------------------------------
proc read_log_tail {log_file_path {lines "50"}} {
    if {![file exists $log_file_path]} {
        error "Log file not found: $log_file_path"
    }
    set n [expr {int($lines)}]
    set fh [open $log_file_path r]
    set content [read $fh]
    close $fh
    set all_lines [split $content "\n"]
    set total [llength $all_lines]
    set start [expr {max(0, $total - $n)}]
    return [join [lrange $all_lines $start end] "\n"]
}
::bridge::register_tool read_log_tail \
    "Return the last N lines of a JasperGold log file. Useful for diagnosing failures." \
    {{"type":"object","properties":{"log_file_path":{"type":"string","description":"Absolute path to the .log file"},"lines":{"type":"string","description":"Number of lines to return from the end (default 50)"}},"required":["log_file_path"]}}


# ---------------------------------------------------------------------------
# Example 3 — Write a TCL snippet to disk and run it in JG batch mode
# (Useful when the agent wants to generate and execute a custom script)
# ---------------------------------------------------------------------------
proc jg_exec_snippet {tcl_snippet {script_name "agent_snippet"}} {
    global env
    set work [expr {[info exists env(FV_MCP_WORK_DIR)] ? $env(FV_MCP_WORK_DIR) : "/tmp"}]
    set out_file [file join $work "${script_name}.tcl"]
    set fh [open $out_file w]
    puts $fh $tcl_snippet
    close $fh

    # Delegate to the existing jg_run_script proc
    return [jg_run_script $out_file]
}
::bridge::register_tool jg_exec_snippet \
    "Write a TCL snippet to a temp file and execute it in JasperGold batch mode. The agent can generate arbitrary JG commands this way." \
    {{"type":"object","properties":{"tcl_snippet":{"type":"string","description":"Complete JasperGold TCL script content to execute"},"script_name":{"type":"string","description":"Base filename for the temp script (no extension, default: agent_snippet)"}},"required":["tcl_snippet"]}}
