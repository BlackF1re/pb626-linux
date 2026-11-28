# GUI smoke test, no real privileged calls or host system changes.
rename exec real_exec
proc exec {args} {
    if {[lindex $args 0] eq "/usr/bin/timeout"} {set args [lrange $args 4 end]}
    if {[lindex $args 0] eq "/usr/bin/doas"} {
        switch [lindex $args 2] {
            desktop-status {return "PB626_BUTTONS=pages\nPB626_EPD_GRAY_PROFILE=photo\nPB626_EPD_TONE=cie-lstar\nPB626_EPD_GAMMA=1.2\nPB626_UI_DPI=144\nPB626_PANEL_SIZE=56\nPB626_TITLEBAR_SIZE=48"}
            desktop-display - desktop-buttons - desktop-idle - desktop-hold - desktop-dpi - desktop-appearance {
                set ::lastSave [lrange $args 2 end-1]
                return ""
            }
            light-status {return "1 37"}
            power-key-status {return "ignore"}
            led-status {return "on"}
            button-bindings-status {return "Left none none Right none none Home none none Menu refresh none"}
            battery-status {return "10 3"}
            sd-status {return "No external SD card detected"}
            default {error "unexpected privileged operation"}
        }
    }
    if {[lindex $args 0] eq "timedatectl" && [lindex $args 1] eq "list-timezones"} {return "Etc/UTC\nEurope/Berlin"}
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
if {$::uiDpi ne "144"} {error "Application DPI not restored"}
set ::uiDpi 120
desktopApply dpi
if {$::lastSave ne {desktop-dpi 120}} {error "Application DPI not saved"}
if {$::panelSize ne "56" || $::titlebarSize ne "48"} {error "Panel sizes not restored"}
set ::panelSize 64
set ::titlebarSize 56
desktopApply appearance
if {$::lastSave ne {desktop-appearance 64 56}} {error "Panel sizes not saved"}
desktopApply keys
if {[lindex $::lastSave 0] ne "desktop-buttons"} {error "Button save overwrites other tabs"}
set ::holdMs 750
desktopApply hold
if {$::lastSave ne {desktop-hold 750}} {error "Hold duration not saved"}
desktopApply display
if {[lindex $::lastSave 0] ne "desktop-display" || !$::restartNeeded} {error "Display save failed"}
if {[.tabs.display.canvas.body.gray.label cget -anchor] ne "w"} {error "Setting label must align left"}
if {![winfo exists .header.icon] || ![winfo exists .tabs.display.canvas.body.rendering]} {error "Settings visual hierarchy missing"}
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
buttonSettings
setBindingKey Right
if {[.bindings.short.select cget -textvariable] ne "::bindAction(3)"} {error "Wrong gesture target"}
set ::bindAction(3) Page_Down
setBindingKey Left
if {$::bindAction(0) ne "Left" || $::bindAction(3) ne "Page_Down"} {error "Gesture state was lost"}
destroy .bindings
batterySettings
set ::batteryWarn 5
set ::batteryCritical 7
.battery.save invoke
if {![winfo exists .battery] || $::batteryMessage ne "Choose a warning threshold above shutdown."} {error "Invalid battery policy accepted"}
destroy .battery
storageSummary
if {$::storageText ne "No external SD card detected"} {error "Storage status not shown"}
timezoneDialog
set ::zoneFilter Berlin
timezoneFilter
if {[.timezone.list size] != 1 || [.timezone.list get 0] ne "Europe/Berlin"} {error "Timezone filtering failed"}
destroy .timezone
destroy .
exit 0
