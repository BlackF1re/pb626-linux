# Experimental E Ink preclear

Hardware baseline: installed bridge and worker from c40c8f325f3095e9846920dbb08b02726fbebe81, protocol pb626-epd-shm-3, indexed profile. No kernel or BT0 changes. Not intended for merge until physical test.

This isolated experiment builds the bridge for the exact installed userland, not main's newer renderer. The original binary remains intact. INIT runs in parallel with Matchbox and the first X11 capture happens after INIT returns. Only a successful INIT and the exact white state digest permit changing the first on-wire RESET into CLEAN. If INIT fails or the state is wrong, the script removes that state and uses the usual RESET. Manual and recovery resets are unchanged. The initial implementation and this packaging have not been validated on hardware.

GitHub Actions installs QEMU on its runner only, executes the existing ARM unit tests, builds a musl ARMv7 bridge, and uploads pb626-preclear-experiment containing install.ps1, transport.ps1, stage.sh, out/SHA256SUMS and binary/script/source outputs. No QEMU or compiler needed on the Windows host. Use only an artifact of this PR head with successful checks.

Restore original /usr/bin/pb626-xsession from /root/pb626-xsession.pre-order before installing. Keep indexed and profiling enabled in /sbin/pb626-native-desktop. Run install.ps1 -Mode Status -Port COM13, then -Mode Install only if preflight succeeds. After a cold boot, retrieve /run/pb626-desktop.log and stat /run/pb626-desktop/ready. Expect WHITE_VERIFIED and first wire=G; compare 5.962 s first and 7.022 s last update (prior indexed reboot, temperature interval 11). The original bridge is untouched. Restore the backup Xsession directly if anything fails; -Mode Rollback is also provided for a matching installation.

No private device data, factory waveform or raw boot images belong in this artifact.
