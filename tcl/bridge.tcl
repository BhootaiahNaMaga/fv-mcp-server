#!/usr/bin/env tclsh
# =============================================================================
# FV MCP Bridge — TCL-side of the Python<->TCL stdio bridge
#
# Protocol:
#   Python sends a single JSON line to stdin:
#     {"id": "<uuid>", "proc": "<proc_name>", "args": [...]}
#   TCL responds with a single JSON line to stdout:
#     {"id": "<uuid>", "status": "ok",    "result": "<output>"}
#     {"id": "<uuid>", "status": "error", "error":  "<message>"}
#
# All user TCL procs live in procs/ and are sourced at startup.
# =============================================================================

package require json       ;# tcllib - for parsing incoming JSON
package require json::write ;# tcllib - for generating outgoing JSON

# ---------------------------------------------------------------------------
# Minimal JSON helpers (fallback if tcllib json not available)
# ---------------------------------------------------------------------------
proc ::bridge::json_escape {s} {
    # Escape backslashes, double-quotes, and control chars for JSON strings
    set s [string map {\\ \\\\ \" \\\" \n \\n \r \\r \t \\t} $s]
    return $s
}

proc ::bridge::make_response {id status args} {
    # args: either {result <val>} or {error <val>}
    set key   [lindex $args 0]
    set val   [lindex $args 1]
    set val_e [::bridge::json_escape $val]
    return "\{\"id\":\"$id\",\"status\":\"$status\",\"$key\":\"$val_e\"\}"
}

# ---------------------------------------------------------------------------
# Parse a minimal JSON object — handles the subset we need:
#   {"id":"...", "proc":"...", "args":["a","b",...]}
# Uses regexp; avoids external package dependency for robustness.
# ---------------------------------------------------------------------------
proc ::bridge::parse_request {line} {
    # Extract id
    if {![regexp {"id"\s*:\s*"([^"]*)"} $line -> req_id]} {
        error "missing id"
    }
    # Extract proc name
    if {![regexp {"proc"\s*:\s*"([^"]*)"} $line -> proc_name]} {
        error "missing proc"
    }
    # Extract args array — grab everything between the outer [ ]
    set arg_list {}
    if {[regexp {"args"\s*:\s*\[([^\]]*)\]} $line -> raw_args]} {
        # Split on commas outside quotes (simple — procs should use simple args)
        foreach token [split $raw_args ,] {
            set token [string trim $token]
            # Strip surrounding quotes if present
            if {[regexp {^"(.*)"$} $token -> inner]} {
                lappend arg_list $inner
            } elseif {$token ne ""} {
                lappend arg_list $token
            }
        }
    }
    return [list $req_id $proc_name $arg_list]
}

# ---------------------------------------------------------------------------
# Source all user proc files
# ---------------------------------------------------------------------------
proc ::bridge::load_procs {procs_dir} {
    foreach f [glob -nocomplain -directory $procs_dir *.tcl] {
        puts stderr "\[bridge\] Loading proc file: $f"
        source $f
    }
}

# ---------------------------------------------------------------------------
# Registry: keep track of which procs are exposed as MCP tools
# Call  ::bridge::register_tool <name> <description> <param_schema_json>
# from inside your proc files to declare a tool.
# ---------------------------------------------------------------------------
namespace eval ::bridge::registry {}
set ::bridge::tools {}        ;# list of {name desc schema}

proc ::bridge::register_tool {name description {schema "{}"}} {
    lappend ::bridge::tools [list $name $description $schema]
    puts stderr "\[bridge\] Registered tool: $name"
}

# Expose the tool list (called by Python at startup via __list_tools__)
proc ::bridge::__list_tools__ {} {
    set parts {}
    foreach entry $::bridge::tools {
        lassign $entry name desc schema
        lappend parts "\{\"name\":\"[::bridge::json_escape $name]\",\"description\":\"[::bridge::json_escape $desc]\",\"schema\":$schema\}"
    }
    return "\[[join $parts ,]\]"
}

# ---------------------------------------------------------------------------
# Main event loop
# ---------------------------------------------------------------------------
proc ::bridge::main {procs_dir} {
    ::bridge::load_procs $procs_dir

    # Flush on every write so Python receives responses immediately
    fconfigure stdout -buffering line
    fconfigure stdin  -buffering line

    puts stderr "\[bridge\] Ready — waiting for requests on stdin"

    while {[gets stdin line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} continue

        if {[catch {::bridge::parse_request $line} parsed]} {
            # Cannot even parse — send a generic error with id "null"
            puts "\{\"id\":\"null\",\"status\":\"error\",\"error\":\"parse error: [::bridge::json_escape $parsed]\"\}"
            continue
        }

        lassign $parsed req_id proc_name proc_args

        # Special built-in: list tools
        if {$proc_name eq "__list_tools__"} {
            set result [::bridge::__list_tools__]
            puts "\{\"id\":\"$req_id\",\"status\":\"ok\",\"result\":$result\}"
            continue
        }

        # Dispatch to the named proc
        if {[catch {uplevel #0 $proc_name {*}$proc_args} output]} {
            set resp [::bridge::make_response $req_id error error $output]
        } else {
            set resp [::bridge::make_response $req_id ok result $output]
        }
        puts $resp
    }

    puts stderr "\[bridge\] stdin closed — exiting"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
set script_dir [file dirname [info script]]
set procs_dir  [file join $script_dir procs]
::bridge::main $procs_dir
