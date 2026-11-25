# Persistent early reset

Install only on tested Early Preclear (58f8e9a). The existing async worker
/usr/bin/pb626-epd-preclear-v2 is reused. New bridge starts just before xinit,
after input discovery and Xauthority generation. INIT runs asynchronously
while Xorg starts; bridge waits for the client-spawn marker before XOpenDisplay,
then awaits INIT acknowledgement before submitting any pixels. Desktop is
spawned immediately after WM, ahead of applets and keyboard; no artificial
widget wait. First desktop completeness remains to be measured.

The wrapper owns the bridge process, xsession owns Matchbox clients and
monitors bridge survival. Lock fd inherited across fork/exec prevents an
overlap of persistent workers on respawn. Existing launchers, binaries and
early scripts remain intact. Rollback restores early launcher and must be
followed by a cold boot before another experiment. No raw eMMC/kernel changes.

This combines worker reuse and client scheduling. Not an isolated benchmark.
Trace follows actual first-frame follow-up transitions. Compare early first
ready 5.419, final initial ACK 6.853, async ready 6.152 with no startup
follow-up. User prioritizes first fully drawn desktop, not widget activity.
CI build and shell checks do not verify device lifecycle or display timing.
