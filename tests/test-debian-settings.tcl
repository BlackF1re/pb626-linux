# GUI smoke test, no real privileged calls or host system changes.
rename exec real_exec
proc exec {args} {
    if {[lindex $args 0] eq "/usr/bin/timeout"} {set args [lrange $args 4 end]}
    if {[lindex $args 0] eq "/usr/bin/doas"} {
        switch [lindex $args 2] {
            desktop-status {return "PB626_BUTTONS=pages\nPB626_EPD_GRAY_PROFILE=photo\nPB626_EPD_TONE=cie-lstar\nPB626_EPD_GAMMA=1.2"}
            desktop-display - desktop-buttons - desktop-idle {
                set ::lastSave [lrange $args 2 end-1]
                return ""
            }
            light-status {return "1 37"}
            power-key-status {return "ignore"}
            led-status {return "on"}
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
if {[.tabs.display.canvas.body.brightness cget -resolution] != 1} {exit 1}
if {$::tone ne "cie-lstar" || $::gamma ne "1.2"} {error "Tone/gamma not restored"}
desktopApply keys
if {[lindex $::lastSave 0] ne "desktop-buttons"} {error "Button save overwrites other tabs"}
desktopApply display
if {[lindex $::lastSave 0] ne "desktop-display" || !$::restartNeeded} {error "Display save failed"}
wm geometry . 640x480
.tabs select .tabs.power
update
set canvas .tabs.power.canvas
lassign [$canvas yview] top bottom
if {$bottom >= 1.0} {error "Power settings should scroll in compact geometry"}
$canvas yview moveto 1.0
update
lassign [$canvas yview] top bottom
if {$top <= 0.0 || $bottom < 0.99} {error "Cannot reach final power settings"}
puts "Debian settings UI loaded with five tabs, persistent values and compact scrolling"
destroy .
exit 0
