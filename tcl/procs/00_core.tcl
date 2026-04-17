#!/usr/bin/env tclsh
# =============================================================================
# core.tcl — Core utility procs (always loaded first due to 00_ prefix)
# These are generic helpers. Tool-specific procs go in separate files.
# =============================================================================

# ping — simple connectivity test
proc ping {} {
    return "pong"
}
::bridge::register_tool ping \
    "Ping the TCL bridge to verify the connection is alive. Returns 'pong'." \
    {{"type":"object","properties":{}}}

# get_env — safely read an env var (useful for checking license paths etc.)
proc get_env {var_name} {
    if {[info exists ::env($var_name)]} {
        return $::env($var_name)
    }
    return "(not set)"
}
::bridge::register_tool get_env \
    "Read an environment variable from the TCL bridge process." \
    {{"type":"object","properties":{"var_name":{"type":"string","description":"Environment variable name"}},"required":["var_name"]}}

# list_registered_tools — introspection
proc list_registered_tools {} {
    set names {}
    foreach entry $::bridge::tools {
        lappend names [lindex $entry 0]
    }
    return [join $names "\n"]
}
::bridge::register_tool list_registered_tools \
    "List all TCL procs registered as MCP tools in the bridge." \
    {{"type":"object","properties":{}}}
