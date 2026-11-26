# GUI smoke test, no real privileged calls or host system changes.
rename exec real_exec
proc exec {args} {
    if {[lindex $args 0] eq "/usr/bin/doas"} {
        switch [lindex $args 2] {
            desktop-status {return "PB626_BUTTONS=pages\nPB626_EPD_GRAY_PROFILE=photo"}
            light-status {return "1 37"}
            power-key-status {return "ignore"}
            default {error "unexpected privileged operation"}
        }
    }
    return ""
}
# Fail the process instead of opening a modal error dialog on CI.
proc bgerror {msg} {puts stderr $msg; exit 1}
if {[catch {source display/pb626-debian-settings; update} msg]} {
    puts stderr $::errorInfo
    exit 1
}
if {[llength [.tabs tabs]] != 5 || $::level != 37 || $::buttons ne "pages" || $::gray ne "photo"} {
    puts stderr "Settings UI state mismatch"
    exit 1
}
if {[.tabs.display.brightness cget -resolution] != 1} {exit 1}
puts "Debian settings UI loaded with five tabs and persistent values"
destroy .
exit 0
