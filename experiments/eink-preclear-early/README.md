# Early reset experiment

Test from the installed asynchronous v2 (6490fae). The native launcher and
desktop wrapper are byte-checked against the operator's hashes. No new
binary is compiled: reuse the tested v1 bridge and original worker. This
deliberately isolates an earlier reset launch using the already verified
white-state handoff; it reintroduces two renderer processes. A persistent
early worker is a separate follow-up if this schedule is beneficial.

Reset starts in the alternate desktop wrapper before input discovery and
xinit. The original wrapper and current async xsession/binaries are kept
untouched. The new session launches Matchbox while the reset is running and
waits for an atomically published RAM-only result after reset exit. Verify
white hash before permitting the v1 bridge to skip its first reset. On
failure invalidate state and use ordinary reset; missing marker aborts
rather than allowing concurrent V4L2 owners. The wrapper waits for the
reset job on exit. No waveform, kernel, raw eMMC or loader changes.

Install with -Mode Status / Install -Port COM13. Rollback restores
/root/pb626-native-desktop.pre-early, returning to async v2. No need to roll
back v2 first. Cold boot and collect ready/profile. Look for preclear-early
begin, WHITE, clients_started, WHITE_VERIFIED and first wire=G. Confirm
the first desktop is complete and distinguish widget refresh from further
desktop rendering. Baseline async ready 6.152 s, first ACK 6.145140 s.
CI validates generation, shell syntax and manifest only; hardware timing
and failure paths remain untested.
