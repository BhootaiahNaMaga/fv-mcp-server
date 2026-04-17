#!/usr/bin/env tclsh
# =============================================================================
# jg_tools.tcl — JasperGold-specific MCP tool procs
#
# These procs are called by the MCP server and execute JasperGold TCL commands.
# They assume the JasperGold TCL shell (jg_shell / jaspergold -tcl) has been
# launched by the MCP server and its stdin/stdout is wired to this bridge.
#
# If you are running in "jg_shell" mode (interactive TCL inside JasperGold),
# you can call native JG commands like analyze, elaborate, prove, etc. directly.
# If you are running as a plain tclsh calling jaspergold via subprocess,
# adapt the "run_jg_cmd" helper at the bottom.
#
# USAGE:
#   - Add your own procs below
#   - Call ::bridge::register_tool <name> <description> <schema> after each one
# =============================================================================

# ---------------------------------------------------------------------------
# Helper: detect whether we are inside a JasperGold shell
# ---------------------------------------------------------------------------
proc is_jg_shell {} {
    return [expr {[info commands analyze] ne ""}]
}

# ---------------------------------------------------------------------------
# jg_analyze — run the analyze command on one or more HDL files
# ---------------------------------------------------------------------------
proc jg_analyze {files_csv {defines ""} {top ""}} {
    # files_csv : comma-separated list of RTL files
    # defines   : space-separated list of +define+FOO=BAR
    # top       : optional top-level module name

    set files [split $files_csv ,]

    if {[is_jg_shell]} {
        # --- Native JasperGold TCL context ---
        set cmd_parts [list analyze -sv09]
        foreach def [split $defines " "] {
            if {$def ne ""} { lappend cmd_parts -define $def }
        }
        foreach f $files {
            lappend cmd_parts [string trim $f]
        }
        if {[catch {uplevel #0 $cmd_parts} out]} {
            error "analyze failed: $out"
        }
        return "analyze complete: $out"
    } else {
        # --- External jaspergold invocation via batch TCL ---
        return [run_jg_cmd "analyze -sv09 [join $files { }]"]
    }
}
::bridge::register_tool jg_analyze \
    "Run JasperGold analyze on RTL source files. Parses and compiles HDL." \
    {{"type":"object","properties":{"files_csv":{"type":"string","description":"Comma-separated list of RTL/SV file paths"},"defines":{"type":"string","description":"Space-separated define tokens e.g. RESET_VAL=1 DEBUG"},"top":{"type":"string","description":"Top-level module name (optional)"}},"required":["files_csv"]}}

# ---------------------------------------------------------------------------
# jg_elaborate — elaborate the design
# ---------------------------------------------------------------------------
proc jg_elaborate {{top ""} {generics ""}} {
    if {[is_jg_shell]} {
        set cmd_parts [list elaborate]
        if {$top ne ""}      { lappend cmd_parts -top $top }
        if {$generics ne ""} { lappend cmd_parts {*}[split $generics " "] }
        if {[catch {uplevel #0 $cmd_parts} out]} {
            error "elaborate failed: $out"
        }
        return "elaborate complete: $out"
    } else {
        set cmd "elaborate"
        if {$top ne ""} { append cmd " -top $top" }
        return [run_jg_cmd $cmd]
    }
}
::bridge::register_tool jg_elaborate \
    "Run JasperGold elaborate to build the formal model after analyze." \
    {{"type":"object","properties":{"top":{"type":"string","description":"Top module name"},"generics":{"type":"string","description":"Generic/parameter overrides (space-separated)"}}}}

# ---------------------------------------------------------------------------
# jg_prove — prove all or specific properties
# ---------------------------------------------------------------------------
proc jg_prove {{property_pattern "*"} {depth "20"} {engine "auto"}} {
    if {[is_jg_shell]} {
        set cmd_parts [list prove -property $property_pattern -depth $depth]
        if {$engine ne "auto"} { lappend cmd_parts -engine $engine }
        if {[catch {uplevel #0 $cmd_parts} out]} {
            error "prove failed: $out"
        }
        return $out
    } else {
        return [run_jg_cmd "prove -property {$property_pattern} -depth $depth"]
    }
}
::bridge::register_tool jg_prove \
    "Run formal proof on JasperGold properties. Optionally filter by name pattern." \
    {{"type":"object","properties":{"property_pattern":{"type":"string","description":"Property name glob pattern, default '*' for all"},"depth":{"type":"string","description":"Proof depth bound (default 20)"},"engine":{"type":"string","description":"Proof engine: auto, bdd, ternary, sharpSAT (default auto)"}}}}

# ---------------------------------------------------------------------------
# jg_get_status — get proof status of all properties
# ---------------------------------------------------------------------------
proc jg_get_status {} {
    if {[is_jg_shell]} {
        if {[catch {get_property_list -include_status true} props]} {
            # Fallback: use report
            if {[catch {report -property} rpt]} {
                error "Could not get status: $rpt"
            }
            return $rpt
        }
        set lines {}
        foreach p $props {
            set name   [lindex $p 0]
            set status [lindex $p 1]
            lappend lines "$name : $status"
        }
        return [join $lines "\n"]
    } else {
        return [run_jg_cmd "report -property"]
    }
}
::bridge::register_tool jg_get_status \
    "Get the proof status of all properties in the current JasperGold session." \
    {{"type":"object","properties":{}}}

# ---------------------------------------------------------------------------
# jg_get_cex — get counterexample trace for a failing property
# ---------------------------------------------------------------------------
proc jg_get_cex {property_name} {
    if {[is_jg_shell]} {
        if {[catch {
            visualize -property $property_name -source
        } cex]} {
            error "CEX retrieval failed: $cex"
        }
        return $cex
    } else {
        return [run_jg_cmd "visualize -property {$property_name} -source"]
    }
}
::bridge::register_tool jg_get_cex \
    "Retrieve the counterexample (waveform trace) for a failing JasperGold property." \
    {{"type":"object","properties":{"property_name":{"type":"string","description":"Exact property name that failed"}},"required":["property_name"]}}

# ---------------------------------------------------------------------------
# jg_set_engine — switch proof engine
# ---------------------------------------------------------------------------
proc jg_set_engine {engine} {
    set valid {aba bdd ic3 incr pdr sharpSAT ternary}
    if {$engine ni $valid} {
        error "Unknown engine '$engine'. Valid: [join $valid {, }]"
    }
    if {[is_jg_shell]} {
        set_engine_mode -$engine
        return "Engine set to $engine"
    } else {
        return [run_jg_cmd "set_engine_mode -$engine"]
    }
}
::bridge::register_tool jg_set_engine \
    "Switch the JasperGold proof engine (aba, bdd, ic3, pdr, sharpSAT, ternary)." \
    {{"type":"object","properties":{"engine":{"type":"string","description":"Engine name"}},"required":["engine"]}}

# ---------------------------------------------------------------------------
# jg_source_tcl — source an arbitrary TCL script in the JG session
# Used by the agent to apply custom constraint / setup scripts
# ---------------------------------------------------------------------------
proc jg_source_tcl {tcl_file_path} {
    if {![file exists $tcl_file_path]} {
        error "File not found: $tcl_file_path"
    }
    if {[is_jg_shell]} {
        if {[catch {source $tcl_file_path} out]} {
            error "source failed: $out"
        }
        return "Sourced $tcl_file_path\n$out"
    } else {
        return [run_jg_cmd "source {$tcl_file_path}"]
    }
}
::bridge::register_tool jg_source_tcl \
    "Source a TCL script file inside the active JasperGold session." \
    {{"type":"object","properties":{"tcl_file_path":{"type":"string","description":"Absolute path to the .tcl script to source"}},"required":["tcl_file_path"]}}

# ---------------------------------------------------------------------------
# jg_run_script — run a full JG TCL script from scratch (batch mode)
# Launches jaspergold as a subprocess, feeds the script, returns output.
# ---------------------------------------------------------------------------
proc jg_run_script {tcl_file_path {extra_args ""}} {
    global env
    if {![file exists $tcl_file_path]} {
        error "Script not found: $tcl_file_path"
    }
    # Use JG_CMD env var if set, else default to 'jaspergold'
    set jg_cmd [expr {[info exists env(JG_CMD)] ? $env(JG_CMD) : "jaspergold"}]
    set cmd [list $jg_cmd -batch -tcl $tcl_file_path]
    if {$extra_args ne ""} { lappend cmd {*}[split $extra_args " "] }

    if {[catch {exec {*}$cmd 2>@1} out]} {
        # exec throws on non-zero exit; $out still has stdout+stderr
        return "JG exited non-zero:\n$out"
    }
    return $out
}
::bridge::register_tool jg_run_script \
    "Launch JasperGold in batch mode with a given TCL script and return the output." \
    {{"type":"object","properties":{"tcl_file_path":{"type":"string","description":"Absolute path to the JasperGold TCL script"},"extra_args":{"type":"string","description":"Additional CLI args to jaspergold (space-separated)"}},"required":["tcl_file_path"]}}

# ---------------------------------------------------------------------------
# Helper: run a single command in an already-running JG shell subprocess
# (Only needed if the bridge itself is NOT running inside jg_shell)
# ---------------------------------------------------------------------------
proc run_jg_cmd {cmd} {
    # This is a placeholder — in practice, if you launch the bridge.tcl
    # directly inside "jaspergold -tcl bridge.tcl", all JG native commands
    # are available at the global namespace and this proc is never called.
    error "run_jg_cmd: not in a JG shell and no external subprocess configured. Use jg_run_script instead."
}
