#!/usr/bin/env python3
"""On-demand PB626 diagnostics. Default is read-only; no daemon or qualification changes."""
import argparse
import datetime
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import statistics
import struct
import subprocess
import tempfile
import time

SCHEMA = 1
MODES = ("reset", "full", "partial", "du", "a2", "du4")
WAVEFORM = "/lib/firmware/pb626/default.wbf"

def read(path):
    try:
        return Path(path).read_text(errors="replace").strip()
    except OSError:
        return None

def command(args, timeout=15, env=None):
    if not shutil.which(args[0]):
        return {"status": "unavailable", "reason": "missing " + args[0]}
    start = time.monotonic()
    try:
        p = subprocess.run(args, capture_output=True, text=True, errors="replace",
                           timeout=timeout, env=env)
        return {"status": "ok" if p.returncode == 0 else "error",
                "returncode": p.returncode, "seconds": time.monotonic()-start,
                "stdout": p.stdout, "stderr": p.stderr}
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"status": "error", "reason": str(e)}

def attributes(pattern, fields):
    return {p: {f: read(Path(p)/f) for f in fields}
            for p in sorted(glob.glob(pattern))}

def snapshot():
    files = ("/proc/uptime", "/proc/meminfo", "/proc/stat", "/proc/interrupts",
             "/proc/diskstats", "/proc/vmstat", "/proc/swaps", "/proc/modules",
             "/proc/pressure/cpu", "/proc/pressure/memory", "/proc/pressure/io",
             "/proc/net/dev", "/sys/block/zram0/mm_stat",
             "/sys/power/state", "/sys/power/mem_sleep", "/sys/power/pm_test")
    d = {"files": {p: read(p) for p in files}}
    for pattern, fields in [
        ("/sys/class/power_supply/*", "type present online status capacity voltage_now current_now power_now charge_now energy_now"),
        ("/sys/class/thermal/thermal_zone*", "type temp"),
        ("/sys/class/hwmon/hwmon*", "name temp1_input"),
        ("/sys/class/backlight/*", "brightness actual_brightness max_brightness bl_power"),
        ("/sys/class/leds/*", "brightness max_brightness trigger"),
        ("/sys/class/rtc/rtc*", "name date time since_epoch wakealarm"),
        ("/sys/class/input/event*/device", "name capabilities/key capabilities/abs"),
        ("/sys/class/video4linux/video*", "name"),
        ("/sys/class/mmc_host/mmc*/mmc*:*", "type name"),
        ("/sys/class/block/mmcblk*", "size ro stat"),
        ("/sys/class/net/*", "operstate carrier speed"),
        ("/sys/class/rfkill/rfkill*", "type soft hard"),
        ("/sys/devices/system/cpu/cpu*/cpufreq", "scaling_cur_freq scaling_min_freq scaling_max_freq scaling_governor scaling_available_frequencies scaling_available_governors"),
        ("/sys/devices/system/cpu/cpu*/cpuidle/state*", "name latency residency usage time disable"),
        ("/sys/bus/usb/devices/*", "idVendor idProduct speed power/control power/runtime_status power/runtime_active_time power/runtime_suspended_time power/wakeup"),
        ("/sys/class/video4linux/video*/device/power", "control runtime_status runtime_active_time runtime_suspended_time autosuspend_delay_ms"),
        ("/sys/bus/i2c/devices/*", "name power/runtime_status power/wakeup pb626_boot_source pb626_external_present"),
        ("/sys/class/regulator/regulator*", "name state microvolts num_users"),
        ("/sys/power/suspend_stats", "success fail failed_freeze failed_prepare failed_suspend failed_resume last_failed_dev last_failed_errno"),
        ("/sys/fs/cgroup/pb626.slice*", "memory.current memory.low memory.events cpu.stat"),
        ("/sys/fs/cgroup/pb626.slice/*", "memory.current memory.low memory.events cpu.stat"),
    ]:
        d[pattern] = attributes(pattern, fields.split())
    d["PSS_KiB"] = {}
    for p in glob.glob("/proc/[0-9]*/smaps_rollup"):
        s = read(p)
        m = re.search(r"^Pss:\s+(\d+)", s or "", re.M)
        if m:
            name = read(Path(p).parent/"comm")
            d["PSS_KiB"][Path(p).parent.name] = {"name": name, "pss": int(m[1])}
    d["wakeup_sources"] = read("/sys/kernel/debug/wakeup_sources")
    return d

def boot():
    return {
        "systemd_analyze": command(["systemd-analyze", "time"]),
        "critical_chain": command(["systemd-analyze", "critical-chain"]),
        "units": command(["systemd-analyze", "blame"]),
        "timestamps": command(["systemctl", "show", "--property=KernelTimestampMonotonic,UserspaceTimestampMonotonic,FinishTimestampMonotonic"]),
        "desktop": command(["systemctl", "show", "pb626-desktop.service", "--property=ActiveState,ActiveEnterTimestampMonotonic,ExecMainStartTimestampMonotonic"]),
        "renderer_journal": command(["journalctl", "-b", "-u", "pb626-desktop.service", "-o", "short-monotonic", "--no-pager", "-n", "200"]),
        "limit": "Kernel-relative timestamps; power-button/BootROM/SPL time needs host or external measurement."
    }

def profile_rows(log):
    return [{k: int(v) if v.isdecimal() else v
             for k, v in re.findall(r"(\w+)=([^\s]+)", line)}
            for line in log.splitlines() if line.startswith("epd: ")]

def pgm(path, pattern):
    w, h = 758, 1024
    if pattern == "black":
        data = bytes(w*h)
    elif pattern == "white":
        data = bytes([255])*(w*h)
    else:
        levels = 4 if pattern == "four" else 16
        row = bytes((x*levels//w)*255//(levels-1) for x in range(w))
        data = row*h
    path.write_bytes(f"P5\n{w} {h}\n255\n".encode()+data)

def panel(rounds):
    # Do not stop or restart the desktop automatically: exclusive ownership
    # is enforced by the existing renderer's flock. Leave recovery to operator.
    if os.geteuid() != 0:
        return {"status": "blocked", "reason": "root required"}
    if not Path(WAVEFORM).is_file() or not Path("/dev/video0").exists():
        return {"status": "unavailable", "reason": "panel or calibrated WBF missing"}
    active = command(["systemctl", "show", "pb626-desktop.service", "-p", "ActiveState", "--value"])
    if active.get("stdout", "").strip() != "inactive":
        return {"status": "blocked", "reason": "stop pb626-desktop.service using USB console first"}
    env = dict(os.environ, PB626_EPD_PROFILE="1", PB626_EPD_RENDER="indexed", PB626_EPD_FAST_MODE="du")
    env.pop("PB626_EPD_PREFILL", None)
    rows = []
    with tempfile.TemporaryDirectory(prefix="pb626-diag-") as tmp:
        paths = {}
        for name in ("black", "white", "four", "gray"):
            paths[name] = Path(tmp)/f"{name}.pgm"
            pgm(paths[name], name)
        # INIT establishes known white; DU to black and A2 to white are
        # strictly binary. DU4 targets 0/5/10/15; GL16 target includes gray.
        sequence = [("reset", None), ("du", "black"), ("a2", "white"),
                    ("du4", "four"), ("partial", "gray"), ("full", "gray")]
        for i in range(rounds):
            for mode, target in sequence:
                args = ["pb626-epd", WAVEFORM, mode]
                if target:
                    args.append(str(paths[target]))
                r = command(args, timeout=90, env=env)
                r.update(round=i+1, mode=mode, target=target,
                         profile=profile_rows(r.get("stderr", "")))
                r["scan_ack"] = any(row.get("mode") == mode and "scans" in row
                                    for row in r["profile"])
                rows.append(r)
                if r["status"] != "ok" or not r["scan_ack"]:
                    return {"status": "error", "samples": rows,
                            "reason": "stopped on failed or unacknowledged scan; inspect before restarting desktop"}
    summary = {}
    for mode in MODES:
        samples = [row["scan_total_us"] for r in rows for row in r["profile"]
                   if row.get("mode") == mode and "scan_total_us" in row]
        if samples:
            summary[mode] = {"min_us": min(samples), "median_us": statistics.median(samples),
                             "max_us": max(samples), "count": len(samples)}
    return {"status": "ok", "samples": rows, "summary": summary,
            "limit": "physical scanout ACK, not optical response/ghosting; one-shot cold controller overhead included separately in seconds"}

def cpu_test():
    data = b"\x5a"*(1024*1024)
    start = time.monotonic()
    count = 0
    while time.monotonic()-start < 2:
        hashlib.sha256(data).digest()
        count += 1
    elapsed = time.monotonic()-start
    return {"seconds": elapsed, "sha256_MiB_s": count/elapsed,
            "limit": "single-thread SHA256 through Python/OpenSSL, not general CPU score"}

def storage():
    results = {}
    # Only enumerate whole MMC disks; bounded direct reads, no writes,
    # no filesystem cache dropping, never probe arbitrary device paths.
    for p in sorted(glob.glob("/sys/class/block/mmcblk*")):
        name = Path(p).name
        if not re.fullmatch(r"mmcblk\d+", name):
            continue
        size = read(Path(p)/"size")
        if not size or not size.isdecimal() or int(size) < 65536:
            results[name] = {"status": "unavailable", "reason": "less than 32 MiB"}
            continue
        r = command(["dd", f"if=/dev/{name}", "of=/dev/null", "bs=1M", "count=32", "iflag=direct,fullblock"], timeout=30)
        if r["status"] == "ok":
            r["MiB_s"] = 32/r["seconds"]
        results[name] = r
    return results

def battery_sample(seconds):
    samples = []
    start = time.monotonic()
    while True:
        supplies = attributes("/sys/class/power_supply/*", "type status online voltage_now current_now power_now capacity".split())
        samples.append({"elapsed_s": time.monotonic()-start, "supplies": supplies})
        if time.monotonic()-start >= seconds:
            break
        time.sleep(min(2, max(0, seconds-(time.monotonic()-start))))
    # Current sign conventions depend on driver; retain raw samples.
    return {"samples": samples, "limit": "instantaneous kernel telemetry, not calibrated input energy"}

def sleep_test():
    if os.geteuid() or not Path("/etc/pb626/suspend-qualified").exists():
        return {"status": "blocked", "reason": "root and existing hardware qualification required"}
    mode = read("/sys/power/mem_sleep") or ""
    pmtest = read("/sys/power/pm_test") or "[none]"
    if "[s2idle]" not in mode or "[none]" not in pmtest:
        return {"status": "blocked", "reason": "requires selected s2idle and pm_test none"}
    before = read("/sys/power/suspend_stats/success")
    start, awake = time.clock_gettime(time.CLOCK_BOOTTIME), time.monotonic()
    r = command(["systemctl", "start", "suspend.target"], timeout=180)
    r["boottime_delta_s"] = time.clock_gettime(time.CLOCK_BOOTTIME)-start
    r["monotonic_delta_s"] = time.monotonic()-awake
    r["estimated_suspended_s"] = max(0, r["boottime_delta_s"]-r["monotonic_delta_s"])
    r["journal"] = command(["journalctl", "-b", "-u", "systemd-suspend.service", "-o", "short-monotonic", "-n", "40", "--no-pager"])
    r["success_counter_before"] = before
    after = read("/sys/power/suspend_stats/success")
    r["success_counter_after"] = after
    r["confirmed"] = bool(before and after and before.isdecimal() and after.isdecimal() and int(after) > int(before))
    if r["status"] == "ok" and not r["confirmed"]:
        r["status"] = "unconfirmed"
    r["limit"] = "systemd unit completion plus kernel counters; no forced wake or optical verification"
    return r

def input_test(seconds):
    devices = {}
    counts = {}
    try:
        for p in glob.glob("/dev/input/event*"):
            try:
                fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                continue
            devices[fd] = p
            counts[p] = {}
        fmt = struct.Struct("@llHHi")
        end = time.monotonic()+seconds
        while devices and time.monotonic() < end:
            ready, _, _ = select.select(list(devices), [], [], max(0, end-time.monotonic()))
            for fd in ready:
                try:
                    data = os.read(fd, fmt.size*32)
                except BlockingIOError:
                    continue
                if not data:
                    os.close(fd)
                    del devices[fd]
                    continue
                for _, _, kind, code, _ in fmt.iter_unpack(data):
                    key = f"{kind}:{code}"
                    d = counts[devices[fd]]
                    d[key] = d.get(key, 0)+1
    finally:
        for fd in devices:
            os.close(fd)
    return {"event_counts": counts, "limit": "operator must exercise buttons/touch; no event values or key text captured"}

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--interval", type=int, default=10, choices=range(1, 121), metavar="SECONDS")
    p.add_argument("--bench", action="store_true", help="bounded CPU and read-only MMC tests")
    p.add_argument("--panel", type=int, choices=range(1, 6), metavar="ROUNDS", help="changes screen; requires stopped desktop")
    p.add_argument("--input", type=int, choices=range(1, 61), metavar="SECONDS")
    p.add_argument("--ping", help="explicit IP or hostname for network latency")
    p.add_argument("--suspend", action="store_true", help="qualified s2idle only; operator wakes device")
    a = p.parse_args()
    # Never overwrite an existing report and keep it private; reports contain
    # local system logs. Reserve output before starting tests.
    fd = os.open(a.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as out:
        d = {"schema": SCHEMA, "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "kernel": os.uname().release, "boot": boot(), "before": snapshot(),
             "battery": battery_sample(a.interval)}
        if a.bench:
            d["cpu"] = cpu_test()
            d["storage"] = storage()
        if a.panel:
            d["panel"] = panel(a.panel)
        if a.input:
            d["input"] = input_test(a.input)
        if a.ping:
            if a.ping.startswith("-"):
                p.error("invalid ping destination")
            d["network"] = command(["ping", "-c", "5", "-W", "2", a.ping], timeout=20)
        if a.suspend:
            d["sleep"] = sleep_test()
        d["after"] = snapshot()
        json.dump(d, out, ensure_ascii=False, indent=2)
        out.write("\n")
    print(a.output)

if __name__ == "__main__":
    main()
