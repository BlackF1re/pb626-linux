# No display is needed to check Tcl source completeness.
if {![llength $argv]} {error "Supply Tcl scripts to check"}
foreach path $argv {
    set fd [open $path r]
    set body [read $fd]
    close $fd
    if {![info complete $body]} {error "Incomplete Tcl source: $path"}
    puts "Tcl syntax complete: $path"
}
