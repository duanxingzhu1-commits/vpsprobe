#!/usr/bin/env python3
"""Small Linux VPSProbe agent. Python 3.9+, standard library only."""
import argparse
import json
import os
import platform
import socket
import time
import urllib.error
import urllib.request
from pathlib import Path

CONFIG = Path(os.environ.get("VPSPROBE_AGENT_CONFIG", "/etc/vpsprobe/agent.json"))


def request(url, data, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, json.dumps(data).encode(), headers)
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.load(response)


def cpu_times():
    fields = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
    nums = [int(x) for x in fields]
    idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
    return sum(nums), idle


def cpu_percent(before, after):
    total = after[0] - before[0]
    return round((1 - (after[1] - before[1]) / total) * 100, 1) if total > 0 else 0


def memory_percent():
    fields = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        fields[key] = int(value.strip().split()[0])
    total = fields["MemTotal"]
    return round((total - fields["MemAvailable"]) / total * 100, 1)


def disk_percent():
    stats = os.statvfs("/")
    total = stats.f_blocks * stats.f_frsize
    available = stats.f_bavail * stats.f_frsize
    return round((total - available) / total * 100, 1) if total else 0


def net_bytes():
    rx = tx = 0
    for line in Path("/proc/net/dev").read_text().splitlines()[2:]:
        name, values = line.split(":", 1)
        if name.strip() == "lo":
            continue
        fields = values.split()
        rx += int(fields[0])
        tx += int(fields[8])
    return rx, tx


def probe(target, port):
    start = time.monotonic()
    try:
        with socket.create_connection((target, port), timeout=3):
            return True, round((time.monotonic() - start) * 1000, 1)
    except OSError:
        return False, None


def register(base, code, name):
    result = request(base + "/api/agent/register", {"code": code, "name": name})
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps({"hub": base, "token": result["token"], "name": name}) + "\n")
    CONFIG.chmod(0o600)
    print("Agent registered. Configuration saved to", CONFIG)


def run(once=False):
    config = json.loads(CONFIG.read_text())
    hub, token = config["hub"].rstrip("/"), config["token"]
    target = os.environ.get("VPSPROBE_PROBE_HOST", "1.1.1.1")
    port = int(os.environ.get("VPSPROBE_PROBE_PORT", "443"))
    previous_cpu = cpu_times()
    previous_net = net_bytes()
    previous_time = time.monotonic()
    time.sleep(1)
    while True:
        try:
            current_cpu = cpu_times()
            current_net = net_bytes()
            current_time = time.monotonic()
            duration = max(current_time - previous_time, 0.001)
            ok, latency = probe(target, port)
            data = {
                "cpu": cpu_percent(previous_cpu, current_cpu),
                "memory": memory_percent(), "disk": disk_percent(),
                "rx_bytes": current_net[0], "tx_bytes": current_net[1],
                "rx_rate": max(0, current_net[0] - previous_net[0]) / duration,
                "tx_rate": max(0, current_net[1] - previous_net[1]) / duration,
                "probe_ok": ok, "latency_ms": latency,
                "os_info": platform.platform(),
            }
            request(hub + "/api/agent/report", data, token)
            print(f"reported: CPU {data['cpu']}%, memory {data['memory']}%, probe {'ok' if ok else 'failed'}", flush=True)
            previous_cpu, previous_net, previous_time = current_cpu, current_net, current_time
        except (OSError, ValueError, KeyError, urllib.error.URLError) as exc:
            print(f"report failed: {type(exc).__name__}: {exc}", flush=True)
        if once:
            break
        time.sleep(30)


def diagnose():
    config = json.loads(CONFIG.read_text())
    hub = config["hub"].rstrip("/")
    target = os.environ.get("VPSPROBE_PROBE_HOST", "1.1.1.1")
    port = int(os.environ.get("VPSPROBE_PROBE_PORT", "443"))
    print("VPSProbe 本机诊断")
    print("机器名称:", config.get("name", "未设置"))
    print("面板地址:", hub)
    try:
        req = urllib.request.Request(hub + "/health")
        start = time.monotonic()
        with urllib.request.urlopen(req, timeout=5) as response:
            healthy = json.load(response).get("ok") is True
        print("面板连接:", "正常" if healthy else "响应异常", f"({(time.monotonic()-start)*1000:.0f} ms)")
    except (OSError, ValueError, urllib.error.URLError) as exc:
        print("面板连接: 失败", type(exc).__name__)
    ok, latency = probe(target, port)
    print(f"探测目标: {target}:{port}")
    print("TCP 探测:", f"正常 ({latency} ms)" if ok else "失败")
    print("本机资源:", f"1 分钟负载 {os.getloadavg()[0]:.2f}, 内存 {memory_percent():.1f}%, 磁盘 {disk_percent():.1f}%")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    reg = sub.add_parser("register")
    reg.add_argument("--hub", required=True)
    reg.add_argument("--code", required=True)
    reg.add_argument("--name", default=socket.gethostname())
    run_parser = sub.add_parser("run")
    run_parser.add_argument("--once", action="store_true")
    sub.add_parser("diagnose")
    args = parser.parse_args()
    if args.command == "register":
        register(args.hub.rstrip("/"), args.code, args.name)
    elif args.command == "diagnose":
        diagnose()
    else:
        run(args.once)


if __name__ == "__main__":
    main()
