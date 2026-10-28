"""Shared data code for Guacamole Panel and the guac CLI (OnePlus 7 Pro, mainline).

Reads sysfs directly. Everything here is plain Python (no GTK), so the CLI
works over SSH. Each *_values() function returns display text keyed like the
*_ROWS tables, so the panel and the CLI always show the same things.
"""
import glob
import json
import os
import shutil
import subprocess
import time

ROOT = os.environ.get("GUAC_ROOT", "")          # test hook: fake sysfs root
PSY = ROOT + "/sys/class/power_supply"
BAT = PSY + "/bq27411-0"
CHG = PSY + "/pm8150b-charger"
CHG_STATUS = ROOT + "/run/guacamole/chgctrl.json"
HELPER = "/usr/local/libexec/guacamole-helper"
SLEEP_TARGETS = ("sleep.target", "suspend.target", "hibernate.target",
                 "hybrid-sleep.target", "suspend-then-hibernate.target")
# Server mode (keep awake) also turns the screen off after this many seconds,
# in every Plasma power profile, and stops the screen locking itself; the
# user's own settings are saved and put back when server mode is turned off.
SERVER_SCREEN_OFF_S = 15
POWER_PROFILES = ("AC", "Battery", "LowBattery")
SERVER_SCREEN_KEYS = {
    "TurnOffDisplayWhenIdle": "true",
    "TurnOffDisplayIdleTimeoutSec": str(SERVER_SCREEN_OFF_S),
    "TurnOffDisplayIdleTimeoutWhenLockedSec": str(SERVER_SCREEN_OFF_S),
    # no dimming: every brightness fade is a burst of DSI commands, which
    # can collide with frame transfers on this panel
    "DimDisplayWhenIdle": "false",
}
# (file, groups, key, value) for every setting server mode changes
SERVER_SETTINGS = [("powerdevilrc", (p, "Display"), k, v)
                   for p in POWER_PROFILES for k, v in SERVER_SCREEN_KEYS.items()] + [
    ("kscreenlockerrc", ("Daemon",), "Autolock", "false"),
    ("kscreenlockerrc", ("Daemon",), "LockOnResume", "false"),
]
SCREEN_SAVE = os.path.expanduser("~/.config/guacamole/screen-before-server-mode.json")

BATTERY_ROWS = (("bstatus", "State"), ("volt", "Voltage"), ("curr", "Current"),
                ("power", "Battery power"), ("draw", "Phone draw"), ("btemp", "Temperature"),
                ("health", "Health"), ("cycles", "Charge cycles"), ("eta", "Estimate"))
CHARGER_ROWS = (("src", "Source"), ("icl", "Input limit"), ("policy", "Policy"),
                ("nextdeep", "Next deep cycle"))
HOTSPOT_ROWS = (("t_little", "CPU little cores"), ("t_big", "CPU big cores"),
                ("t_prime", "CPU prime core"), ("t_gpu", "GPU"), ("t_modem", "Modem"),
                ("t_wlan", "Wi-Fi"), ("t_mem", "Memory"), ("t_cam", "Camera"),
                ("t_bat", "Battery"), ("t_pmic", "Power chips (PMICs)"))
SYSTEM_ROWS = (("mem", "Memory"), ("swap", "Swap"), ("load", "Load"), ("uptime", "Uptime"),
               ("kernel", "Kernel"))
ETH_ROWS = (("eth", "Ethernet"), ("eth_ip", "IP address"), ("eth_speed", "Link speed"),
            ("eth_mac", "MAC address"), ("route", "Default route"))
WIFI_ROWS = (("ssid", "Network"), ("band", "Band"), ("signal", "Signal"), ("rate", "Link speed"),
             ("ip", "IP address"), ("mac", "MAC address"))
USBC_ROWS = (("roles", "Port role"), ("partner", "Connected"), ("dp", "DisplayPort"),
             ("contract", "Power contract"))


# ---------------------------------------------------------------- sysfs ----
def rd(path, default=None):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def rdi(path, default=None):
    try:
        return int(rd(path))
    except (TypeError, ValueError):
        return default


def sel(value):
    if value and "[" in value:
        return value[value.index("[") + 1:value.index("]")]
    return value


def fmt_temp(milli):
    return "—" if milli is None else "%.1f °C" % (milli / 1000)


def fmt_freq(khz):
    if not khz:
        return "—"
    return "%.2f GHz" % (khz / 1e6) if khz >= 1e6 else "%d MHz" % (khz / 1000)


def run(cmd, timeout=1.5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def thermal_zones():
    zones = {}
    for z in glob.glob(ROOT + "/sys/class/thermal/thermal_zone*"):
        t, v = rd(z + "/type"), rdi(z + "/temp")
        if t and v is not None:
            zones[t] = v
    return zones


def zmax(zones, *names):
    vals = [zones[n] for n in names if n in zones]
    return max(vals) if vals else None


def cpu_policies():
    out = []
    for p in sorted(glob.glob(ROOT + "/sys/devices/system/cpu/cpufreq/policy*"),
                    key=lambda s: int(s.rsplit("policy", 1)[1])):
        out.append({
            "cpus": rd(p + "/related_cpus", ""),
            "cur": rdi(p + "/scaling_cur_freq"), "max": rdi(p + "/scaling_max_freq"),
            "gov": rd(p + "/scaling_governor", "?"),
            "govs": (rd(p + "/scaling_available_governors", "") or "").split(),
        })
    return out


def cluster_name(cpus):
    first = cpus.split()[0] if cpus else "?"
    return {"0": "Little cores", "4": "Big cores", "7": "Prime core"}.get(first, "CPU") + \
        " (%s)" % cpus.replace(" ", ",")


def gpu_freq():
    for d in glob.glob(ROOT + "/sys/class/devfreq/*"):
        if "gpu" in d or "2c00000" in d:
            return rdi(d + "/cur_freq"), rdi(d + "/max_freq")
    return None, None


def remoteprocs():
    out = []
    for r in sorted(glob.glob(ROOT + "/sys/class/remoteproc/remoteproc*")):
        fw = os.path.basename(rd(r + "/firmware", "") or "")
        name = {"modem.mdt": "Modem (MPSS, also Wi-Fi)", "adsp.mdt": "Audio DSP (ADSP)",
                "cdsp.mdt": "Compute DSP (CDSP)", "slpi.mdt": "Sensor DSP (SLPI)"}.get(
                    fw, rd(r + "/name", os.path.basename(r)))
        out.append((name, rd(r + "/state", "?")))
    return out


def meminfo():
    m = {}
    for line in (rd(ROOT + "/proc/meminfo", "") or "").splitlines():
        k, _, v = line.partition(":")
        try:
            m[k] = int(v.split()[0])
        except (ValueError, IndexError):
            pass
    return m


def wifi_iface():
    """The Wi-Fi interface's name (wlan0 here), or None."""
    for path in sorted(glob.glob(ROOT + "/sys/class/net/*")):
        if os.path.isdir(path + "/wireless") or os.path.isdir(path + "/phy80211"):
            return os.path.basename(path)
    return None


def wifi_radio_off():
    """True when Wi-Fi is switched off (NetworkManager's radio switch or rfkill)."""
    return rfkill_state("wlan").startswith("Off") or run(["nmcli", "radio", "wifi"]).strip() == "disabled"


def wifi_info(iface=None):
    info = {}
    iface = iface or wifi_iface() or "wlan0"
    if rd(ROOT + "/sys/class/net/%s/operstate" % iface) != "up":
        info["ssid"] = "Off" if wifi_radio_off() else "Not connected"
        mac = rd(ROOT + "/sys/class/net/%s/address" % iface)
        if mac:
            info["mac"] = mac
        return info
    out = run(["iw", "dev", iface, "link"])
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("SSID:"):
            info["ssid"] = line[5:].strip()
        elif line.startswith("freq:"):
            try:
                f = float(line.split()[1])
                info["band"] = "%s GHz (%d MHz)" % ("5" if f > 4900 else "2.4", f)
            except (ValueError, IndexError):
                pass
        elif line.startswith("signal:"):
            info["signal"] = line[7:].strip()
        elif line.startswith("tx bitrate:"):
            info["bitrate"] = line[11:].strip().split(" MCS")[0]
        elif line.startswith("rx bitrate:"):
            # ath10k on the WCN3990 never reports a tx rate (NetworkManager's
            # Bitrate stays 0 too), so fall back to the receive rate
            info.setdefault("rx_bitrate", line[11:].strip().split(" VHT")[0].split(" HE")[0].split(" MCS")[0])
    if "bitrate" not in info and "rx_bitrate" in info:
        info["bitrate"] = info["rx_bitrate"] + " (receive)"
    if "Not connected" in out:
        info["ssid"] = "Not connected"
    ip = iface_ip(iface)
    if ip:
        info["ip"] = ip
    mac = rd(ROOT + "/sys/class/net/%s/address" % iface)
    if mac:
        info["mac"] = mac
    return info


def rfkill_state(kind):
    for r in glob.glob(ROOT + "/sys/class/rfkill/rfkill*"):
        if rd(r + "/type") == kind:
            if rdi(r + "/hard") == 1:
                return "Off (hardware)"
            return "Off" if rdi(r + "/soft") == 1 else "On"
    return "Not found"


def typec_info():
    port = ROOT + "/sys/class/typec/port0"
    if not os.path.isdir(port):
        return {}
    info = {"data": sel(rd(port + "/data_role", "")), "power": sel(rd(port + "/power_role", ""))}
    partner = port + "-partner"
    info["partner"] = os.path.isdir(partner)
    info["dp"] = "No"
    for alt in glob.glob(partner + "/port0-partner.*"):
        if rd(alt + "/svid", "").lower() == "ff01":
            info["dp"] = "Active" if rd(alt + "/active") == "yes" else "Offered by the dock, not active"
    for t in glob.glob(PSY + "/tcpm-source-psy-*"):
        if rdi(t + "/online") == 1:
            mv, ma = (rdi(t + "/voltage_now") or 0) // 1000, (rdi(t + "/current_max") or 0) // 1000
            info["contract"] = "%s %g V %g A" % (sel(rd(t + "/usb_type", "")) or "", mv / 1000, ma / 1000)
    return info


def backlight():
    for b in glob.glob(ROOT + "/sys/class/backlight/*"):
        return os.path.basename(b), rdi(b + "/brightness", 0), rdi(b + "/max_brightness", 0)
    return None, 0, 0


def screen_on():
    """False while the desktop has blanked the panel (bl_power != 0); the panel
    then rejects brightness changes."""
    for b in glob.glob(ROOT + "/sys/class/backlight/*"):
        return rdi(b + "/bl_power", 0) == 0
    return None


def no_suspend():
    """'on' when every sleep target is masked, 'off' when none is, else 'partly'."""
    states = run(["systemctl", "is-enabled"] + list(SLEEP_TARGETS)).split()
    masked = sum(s.startswith("masked") for s in states)
    if not states:
        return "unknown"
    return "on" if masked == len(SLEEP_TARGETS) else "off" if masked == 0 else "partly"


SWAP_FILE = "/swapfile"
SWAP_SIZES = ("off", "1", "2", "4", "8")       # GB, what the helper accepts


def swap_info():
    """{'file_gb': size of /swapfile in GB or None, 'total'/'used': bytes of
    all active swap, 'swappiness': int}"""
    m = meminfo()
    size = None
    for line in (rd(ROOT + "/proc/swaps", "") or "").splitlines()[1:]:
        f = line.split()
        if f and f[0] == SWAP_FILE:
            size = round(int(f[2]) / 1048576)
    return {"file_gb": size, "total": m.get("SwapTotal", 0) * 1024,
            "used": (m.get("SwapTotal", 0) - m.get("SwapFree", 0)) * 1024,
            "swappiness": rdi(ROOT + "/proc/sys/vm/swappiness")}


def swap_text(s=None):
    s = s or swap_info()
    if not s["total"]:
        return "off"
    return "%s, %.1f of %.1f GB used (swappiness %s)" % (
        "%d GB swap file" % s["file_gb"] if s["file_gb"] else "on",
        s["used"] / 2**30, s["total"] / 2**30, s["swappiness"])


def disk_usage(path="/"):
    """(used bytes, total bytes) of the filesystem holding path."""
    try:
        st = os.statvfs(ROOT + path)
    except OSError:
        return None, None
    total = st.f_blocks * st.f_frsize
    return total - st.f_bavail * st.f_frsize, total


def net_counters(iface):
    """(rx bytes, tx bytes) since the interface came up, or (None, None)."""
    base = ROOT + "/sys/class/net/%s/statistics/" % iface
    return rdi(base + "rx_bytes"), rdi(base + "tx_bytes")


def iface_ip(iface):
    addr = run(["ip", "-4", "-o", "addr", "show", "dev", iface]).split()
    return addr[addr.index("inet") + 1].split("/")[0] if "inet" in addr else None


# interfaces that are the phone's own links (not Docker bridges, veths, the
# modem's rmnet or Wi-Fi Direct)
_SKIP_IFACES = ("lo", "docker", "br-", "veth", "rmnet", "p2p", "dummy", "tun", "wg")


def default_iface():
    """The interface of the IPv4 default route with the lowest metric, or None."""
    best = None
    for line in run(["ip", "-4", "route", "show", "default"]).splitlines():
        f = line.split()
        if "dev" not in f:
            continue
        metric = int(f[f.index("metric") + 1]) if "metric" in f else 0
        if best is None or metric < best[0]:
            best = (metric, f[f.index("dev") + 1])
    return best[1] if best else None


def net_interfaces():
    """The phone's network links in display order (default route first, then
    wired, Wi-Fi, USB): [{name, kind ('wired'/'wifi'/'usb'), label, up,
    ips, speed, mac, default, wifi}]. Wi-Fi is listed even when it is off
    (up False) so the monitors can say so; other links only while they have
    a carrier."""
    default = default_iface()
    addrs = {}
    for line in run(["ip", "-4", "-o", "addr", "show"]).splitlines():
        f = line.split()
        if len(f) > 3 and f[2] == "inet":
            addrs.setdefault(f[1], []).append(("dynamic" not in f, f[3].split("/")[0]))
    # the DHCP address first (a fixed extra address, if any, is listed first
    # by the kernel)
    addrs = {k: [ip for _, ip in sorted(v, key=lambda a: a[0])] for k, v in addrs.items()}
    out = []
    for path in sorted(glob.glob(ROOT + "/sys/class/net/*")):
        name = os.path.basename(path)
        if name.startswith(_SKIP_IFACES):
            continue
        wifi = os.path.isdir(path + "/wireless") or os.path.isdir(path + "/phy80211")
        usb = name == "usb0" or rd(path + "/address", "").startswith("02:66:00")
        up = rd(path + "/operstate") == "up" or (rdi(path + "/carrier") == 1 and rd(path + "/operstate") != "down")
        if not up and not wifi:
            continue
        i = {"name": name, "kind": "wifi" if wifi else "usb" if usb else "wired", "up": up,
             "ips": addrs.get(name, []), "mac": rd(path + "/address"), "default": name == default,
             "speed": None, "wifi": None}
        i["label"] = {"wifi": "Wi-Fi", "usb": "USB link", "wired": "Ethernet"}[i["kind"]]
        if i["kind"] == "wired":
            sp = rdi(path + "/speed")
            if sp and sp > 0:
                i["speed"] = ("%g Gb/s" % (sp / 1000) if sp >= 1000 else "%d Mb/s" % sp) + \
                    ("" if rd(path + "/duplex") in (None, "full") else " half duplex")
        elif wifi:
            i["wifi"] = wifi_info(name) if up else {}
        out.append(i)
    order = {"wired": 1, "wifi": 2, "usb": 3}
    out.sort(key=lambda i: (not i["default"], order[i["kind"]], i["name"]))
    return out


def iface_text(i):
    """One line describing a link, e.g. 'Ethernet enu1  192.168.1.20  1 Gb/s'."""
    if i["kind"] == "wifi" and not i["up"]:
        return "Wi-Fi off"
    parts = ["%s %s" % (i["label"], i["name"]), ", ".join(i["ips"]) or "no address"]
    if i["kind"] == "wired" and i["speed"]:
        parts.append(i["speed"])
    if i["kind"] == "wifi":
        w = i["wifi"] or {}
        parts += [w.get("ssid", "not connected")] + [w[k] for k in ("band", "signal") if w.get(k)]
    return "  ·  ".join(parts) + ("  (default)" if i["default"] else "")


def primary_ip():
    """The phone's main LAN address: the default-route interface's, else any."""
    ifs = net_interfaces()
    for i in ifs:
        if i["ips"] and i["kind"] != "usb":
            return i["ips"][0]
    return None


def lan_counters(ifs=None):
    """{iface: (rx bytes, tx bytes)} of the phone's links that are up."""
    return {i["name"]: net_counters(i["name"]) for i in (ifs or net_interfaces()) if i["up"]}


def counter_rates(prev, now, counters):
    """{iface: (rx B/s, tx B/s)} between a previous (time, counters) and now."""
    rates = {}
    if prev and isinstance(prev[1], dict) and now > prev[0]:
        dt = now - prev[0]
        for name, (rx, tx) in counters.items():
            p = prev[1].get(name)
            if p and None not in (rx, tx, p[0], p[1]) and rx >= p[0] and tx >= p[1]:
                rates[name] = ((rx - p[0]) / dt, (tx - p[1]) / dt)
    return rates


def failed_units():
    return [line.split()[0] for line in run(["systemctl", "--failed", "--no-legend", "--plain"]).splitlines()
            if line.strip()]


def hostname():
    return rd(ROOT + "/etc/hostname") or os.uname().nodename


# ----------------------------------------------- server-mode screen off ----
def _session_env():
    env = dict(os.environ)
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/%d/bus" % os.getuid())
    return env


def _kcfg(tool, cfile, groups, key, *extra):
    cmd = [tool, "--file", cfile]
    for g in groups:
        cmd += ["--group", g]
    cmd += ["--key", key] + list(extra)
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5, env=_session_env())
    except (OSError, subprocess.SubprocessError):
        return None


def _setting_id(cfile, groups, key):
    return "%s:%s:%s" % (cfile, "/".join(groups), key)


def _load_saved():
    try:
        with open(SCREEN_SAVE) as f:
            saved = json.load(f)
    except (OSError, ValueError):
        return None
    # first version saved {"AC": {key: value}, ...} (powerdevil only)
    if any(isinstance(v, dict) for v in saved.values()):
        saved = {_setting_id("powerdevilrc", (p, "Display"), k): v
                 for p, keys in saved.items() if isinstance(keys, dict) for k, v in keys.items()}
    return saved


def _bus_call(*args):
    try:
        subprocess.run(["busctl", "--user", "call"] + list(args), capture_output=True,
                       timeout=5, env=_session_env())
    except (OSError, subprocess.SubprocessError):
        pass


def server_screen(on):
    """Apply (on) or undo (off) the server-mode desktop settings for the
    current user: Plasma turns the screen off after SERVER_SCREEN_OFF_S
    seconds without dimming, and the screen does not lock itself (no
    auto-lock, no lock on resume). powerdevil and the screen locker are told
    to reload. Returns a short status text. Does nothing for root."""
    if os.geteuid() == 0:
        return "screen settings skipped (run as the desktop user, not root)"
    if not shutil.which("kwriteconfig6"):
        return "screen settings skipped (no kwriteconfig6: not a Plasma desktop)"
    if on:
        saved = _load_saved() or {}
        for cfile, groups, key, _ in SERVER_SETTINGS:
            sid = _setting_id(cfile, groups, key)
            if sid not in saved:      # keep the value from before server mode
                r = _kcfg("kreadconfig6", cfile, groups, key)
                saved[sid] = (r.stdout.strip() or None) if r else None
        os.makedirs(os.path.dirname(SCREEN_SAVE), exist_ok=True)
        with open(SCREEN_SAVE, "w") as f:
            json.dump(saved, f, indent=1)
        for cfile, groups, key, value in SERVER_SETTINGS:
            _kcfg("kwriteconfig6", cfile, groups, key, value)
        text = "turns off after %d s, no lock screen" % SERVER_SCREEN_OFF_S
    else:
        saved = _load_saved() or {}
        for cfile, groups, key, _ in SERVER_SETTINGS:
            v = saved.get(_setting_id(cfile, groups, key))
            if v is None:
                # fine here: there is no /etc/xdg layer for these files. Where
                # one exists, --delete writes a "key[$d]" marker that hides it.
                _kcfg("kwriteconfig6", cfile, groups, key, "--delete")
            else:
                _kcfg("kwriteconfig6", cfile, groups, key, v)
        try:
            os.remove(SCREEN_SAVE)
        except OSError:
            pass
        text = "timeout and lock screen back to your own settings"
    _bus_call("org.kde.Solid.PowerManagement", "/org/kde/Solid/PowerManagement",
              "org.kde.Solid.PowerManagement", "reparseConfiguration")
    _bus_call("org.freedesktop.ScreenSaver", "/ScreenSaver", "org.kde.screensaver", "configure")
    return text


# ---------------------------------------------------------- phone draw ----
def phone_draw(st=None):
    """The phone's own power draw: {'w', 'live', 'age_s', 'charge_w', 'source'}.
    While the battery discharges (unplugged, input suspended, or chgctrl's
    calibration window) the battery power *is* the phone's draw: live, exact,
    source "battery". On the charger, guacamole-chgctrl estimates it from the
    charger's input sensor times a factor it calibrates against the battery
    every few hours: live, source "charger" (about +-15 %). If chgctrl has no
    fresh value, its last one is used, with its age. charge_w is the power
    going into the battery."""
    ua, uv = rdi(BAT + "/current_now"), rdi(BAT + "/voltage_now")
    p = None if ua is None or uv is None else ua * uv / 1e12      # + charging
    if p is not None and p < -0.05:
        return {"w": round(-p, 3), "live": True, "age_s": 0, "charge_w": 0.0, "source": "battery"}
    st = (charger_status() if st is None else st) or {}
    w, at = st.get("draw_w"), st.get("draw_at") or 0
    age = int(time.time()) - at if w is not None else None
    return {"w": w, "live": bool(w is not None and st.get("draw_live") and age < 60), "age_s": age,
            "charge_w": None if p is None else round(max(p, 0.0), 3), "source": st.get("draw_source")}


def draw_text(d=None):
    d = d or phone_draw()
    if d["w"] is None:
        return "not measured yet (needs a minute on the charger hold or on battery)"
    if d["live"]:
        return "≈ %.2f W (estimated from the charger)" % d["w"] if d.get("source") == "charger" else \
            "%.2f W" % d["w"]
    a = d["age_s"] or 0
    age = "just now" if a < 90 else "%d min ago" % (a // 60) if a < 5400 else "%.0f h ago" % (a / 3600)
    return "≈ %.2f W (last %s, %s)" % (d["w"], "estimated from the charger" if d.get("source") == "charger"
                                       else "measured on battery", age)


# --------------------------------------------------------- display text ----
def battery_values():
    v = {}
    cap = rdi(BAT + "/capacity")
    v["capacity"] = cap
    v["bstatus"] = rd(BAT + "/status")
    uv, ua = rdi(BAT + "/voltage_now"), rdi(BAT + "/current_now")
    v["volt"] = None if uv is None else "%.2f V" % (uv / 1e6)
    v["curr"] = None if ua is None else "%+d mA" % (ua / 1000)
    if uv is not None and ua is not None:
        p = uv * ua / 1e12
        v["power"] = ("%.2f W into the battery" % p if p > 0.05 else
                      "%.2f W from the battery" % -p if p < -0.05 else "0 W")
    else:
        v["power"] = None
    v["draw"] = draw_text()
    t = rdi(BAT + "/temp")
    v["btemp"] = None if t is None else "%.1f °C" % (t / 10)
    full, design = rdi(BAT + "/charge_full"), rdi(BAT + "/charge_full_design")
    v["health"] = ("%d %% (%d of %d mAh)" % (full * 100 // design, full // 1000, design // 1000)
                   if full and design else None)
    v["cycles"] = rdi(BAT + "/cycle_count")
    v["eta"] = None
    for prop, label in (("time_to_full_now", "full in"), ("time_to_empty_now", "empty in")):
        s = rdi(BAT + "/" + prop)
        if s:
            v["eta"] = "%s %d h %02d min" % (label, s // 3600, s % 3600 // 60)
            break
    return v


def charger_status():
    """The charge service's status file, or None when the service is not running."""
    try:
        with open(CHG_STATUS) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def charger_values(st):
    if st is None:
        return {"src": "charge service not running", "icl": None, "policy": None, "nextdeep": None}
    icl = st.get("input_current_limit_uA") or 0
    nd = st.get("next_deep") or 0
    return {
        "src": st.get("source_label"),
        "icl": "%g A" % (icl / 1e6) if st.get("source") != "none" and icl else None,
        "policy": st.get("reason"),
        "nextdeep": time.strftime("%a %d %b, %H:%M", time.localtime(nd)) if nd else "off",
    }


def hotspot_values(z=None):
    z = thermal_zones() if z is None else z
    bt = rdi(BAT + "/temp")
    return {
        "t_little": fmt_temp(zmax(z, *["cpu%d-thermal" % i for i in range(4)])),
        "t_big": fmt_temp(zmax(z, *["cpu%d-%s-thermal" % (i, s) for i in (4, 5, 6) for s in ("top", "bottom")])),
        "t_prime": fmt_temp(zmax(z, "cpu7-top-thermal", "cpu7-bottom-thermal")),
        "t_gpu": fmt_temp(zmax(z, "gpu-top-thermal", "gpu-bottom-thermal")),
        "t_modem": fmt_temp(zmax(z, "modem-thermal", "modem-vec-thermal", "modem-scl-thermal")),
        "t_wlan": fmt_temp(zmax(z, "wlan-thermal")),
        "t_mem": fmt_temp(zmax(z, "mem-thermal")),
        "t_cam": fmt_temp(zmax(z, "camera-thermal")),
        "t_bat": None if bt is None else "%.1f °C" % (bt / 10),
        "t_pmic": fmt_temp(zmax(z, "pm8150-thermal", "pm8150b-thermal", "pm8150l-thermal")),
    }


def system_values():
    v = {}
    pols = cpu_policies()
    v["cpus"] = [(cluster_name(p["cpus"]), "%s / %s" % (fmt_freq(p["cur"]), fmt_freq(p["max"])))
                 for p in pols]
    v["gov"] = pols[0]["gov"] if pols else None
    v["govs"] = pols[0]["govs"] if pols else []
    cur, mx = gpu_freq()
    v["gpu"] = "%d / %d MHz" % (cur / 1e6, mx / 1e6) if cur and mx else "idle / not loaded"
    m = meminfo()
    v["mem"] = None
    if m.get("MemTotal"):
        used = m["MemTotal"] - m.get("MemAvailable", 0)
        v["mem"] = "%.1f of %.1f GB used" % (used / 1048576, m["MemTotal"] / 1048576)
    sw = swap_info()
    v["swap"] = swap_text(sw)
    v["swap_gb"] = sw["file_gb"]
    v["load"] = " ".join((rd(ROOT + "/proc/loadavg", "") or "").split()[:3])
    up = rd(ROOT + "/proc/uptime")
    v["uptime"] = None
    if up:
        s = int(float(up.split()[0]))
        v["uptime"] = "%d d %d h %02d min" % (s // 86400, s % 86400 // 3600, s % 3600 // 60)
    v["kernel"] = os.uname().release
    v["dsps"] = remoteprocs()
    v["nosuspend"] = no_suspend()
    return v


def conn_values():
    w = wifi_info()
    tc = typec_info()
    name, cur, mx = backlight()
    ifs = net_interfaces()
    eth = next((i for i in ifs if i["kind"] == "wired"), None)
    dflt = next((i for i in ifs if i["default"]), None)
    return {
        "eth": "%s (%s)" % ("Connected", eth["name"]) if eth else "Not connected",
        "eth_ip": ", ".join(eth["ips"]) if eth else None, "eth_speed": eth["speed"] if eth else None,
        "eth_mac": eth["mac"] if eth else None,
        "route": "%s %s" % (dflt["label"], dflt["name"]) if dflt else "none",
        "ssid": w.get("ssid", "Not connected"), "band": w.get("band"), "signal": w.get("signal"),
        "rate": w.get("bitrate"), "ip": w.get("ip"), "mac": w.get("mac"),
        "bt": rfkill_state("bluetooth"),
        "roles": "%s, %s" % (tc["data"], tc["power"]) if tc else "no USB-C port found",
        "partner": ("Yes" if tc.get("partner") else "No") if tc else None,
        "dp": tc.get("dp") if tc.get("partner") else None,
        "contract": tc.get("contract"),
        "brightness": max(1, round(cur * 100 / mx)) if name and mx else None,
        "screen": {True: "on", False: "off"}.get(screen_on()),
    }


# ------------------------------------------------- server monitor cards ----
MONITOR_CARDS = (("server", "Server"), ("battery", "Battery"), ("cpu", "Processor"),
                 ("memory", "Memory"), ("storage", "Storage"), ("network", "Network"),
                 ("thermal", "Temperature"))
# buttons shown on a card (a card lists them in its "actions"): name -> (label,
# confirmation), run as guacamole-helper troubleshoot NAME. None in this kit;
# the monitor draws them if an action is added here and in the helper.
CARD_ACTIONS = {}


def human_bytes(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            return ("%.0f %s" if unit in ("B", "KB") else "%.1f %s") % (n, unit)
        n /= 1000.0


def human_rate(bps):
    return "—" if bps is None else human_bytes(bps) + "/s"


def monitor_cards(prev_net=None):
    """The Server Monitor's cards.
    Returns (header, cards, prev_net): header is {clock, date, host, uptime};
    cards maps each MONITOR_CARDS key to {value, details, fraction, state,
    actions} (state ok/warn/bad/None, fraction 0..1 or None, actions a list
    of CARD_ACTIONS names); a card with no data is left out. Pass the
    returned prev_net back in on the next call for the network rates."""
    s = system_values()
    header = {"clock": time.strftime("%H:%M"), "date": time.strftime("%a %d %b"),
              "host": hostname(), "uptime": s["uptime"] or "—"}
    cards = {}

    def card(key, value, details="", fraction=None, state=None, actions=()):
        cards[key] = {"value": value, "details": details, "fraction": fraction, "state": state,
                      "actions": list(actions)}

    failed = failed_units()
    mode = s["nosuspend"]
    card("server", "Keep awake on" if mode == "on" else "Keep awake %s" % mode,
         ("All services running" if not failed else
          "%d failed: %s" % (len(failed), ", ".join(failed[:4]))) +
         ("\nScreen off after %d s, no lock screen" % SERVER_SCREEN_OFF_S if mode == "on" else ""),
         state="ok" if mode == "on" and not failed else "warn")

    b = battery_values()
    st = charger_status()
    ch = charger_values(st)
    d = phone_draw(st)
    cap = b["capacity"]
    # what the battery itself does (the charger estimate is not battery power)
    flow = ("+%.2f W charging" % d["charge_w"] if d["charge_w"] else
            "-%.2f W" % d["w"] if d["live"] and d.get("source") == "battery" else "0 W")
    card("battery", "—" if cap is None else "%d %%" % cap,
         "%s  ·  %s  ·  %s\nPhone draw: %s\n%s" % (b["bstatus"] or "—", flow, b["btemp"] or "—",
                                                   draw_text(d), ch["policy"] or ch["src"] or ""),
         fraction=None if cap is None else cap / 100,
         state=None if cap is None else "bad" if cap < 20 else "warn" if cap < 40 else "ok")

    load = (s["load"] or "").split()
    hs = hotspot_values()
    card("cpu", "load %s" % (load[0] if load else "—"),
         "%s (1, 5, 15 min)\n%s\nGPU %s" % (" ".join(load) or "—",
                                            "\n".join("%s  %s" % t for t in s["cpus"]), s["gpu"]),
         state="ok" if not load or float(load[0]) < 4 else "warn")

    m = meminfo()
    if m.get("MemTotal"):
        used = (m["MemTotal"] - m.get("MemAvailable", 0)) * 1024
        total = m["MemTotal"] * 1024
        card("memory", "%.0f %%" % (used * 100 / total),
             "%s of %s used\nSwap: %s" % (human_bytes(used), human_bytes(total), s["swap"]),
             fraction=used / total, state="ok" if used / total < 0.85 else "warn")

    used, total = disk_usage("/")
    if total:
        card("storage", "%s free" % human_bytes(total - used),
             "%s of %s used on /" % (human_bytes(used), human_bytes(total)),
             fraction=used / total, state="ok" if used / total < 0.9 else "warn")

    # one line per link (default route first), with its own ↓/↑ rates
    ifs = net_interfaces()
    now = time.monotonic()
    counters = lan_counters(ifs)
    rates = counter_rates(prev_net, now, counters)
    prev_net = (now, counters)
    lines = []
    for i in ifs:
        lines.append(iface_text(i))
        if i["up"] and i["kind"] != "usb":
            r = rates.get(i["name"], (None, None))
            lines.append("    ↓ %s   ↑ %s" % (human_rate(r[0]), human_rate(r[1])))
    main = next((i for i in ifs if i["default"]), None)
    card("network", main["ips"][0] if main and main["ips"] else "no network",
         "\n".join(lines) or "No network links",
         state="ok" if main else "bad")

    z = thermal_zones()
    if z:
        name = max(z, key=z.get)
        hot = z[name]
        card("thermal", fmt_temp(hot),
             "hottest: %s\nCPU big %s  ·  battery %s" % (name, hs["t_big"], hs["t_bat"] or "—"),
             state="ok" if hot < 50000 else "warn" if hot < 65000 else "bad")
    return header, cards, prev_net


# ---------------------------------------------------------- root helper ----
def helper_cmd(args):
    """How to run the root helper from a terminal: directly as root, through
    sudo when it needs no password, otherwise pkexec (asks in the terminal)."""
    args = [str(a) for a in args]
    if os.geteuid() == 0:
        return [HELPER] + args
    if shutil.which("sudo"):
        try:
            if subprocess.run(["sudo", "-n", "true"], capture_output=True, timeout=5).returncode == 0:
                return ["sudo", "-n", HELPER] + args
        except (OSError, subprocess.SubprocessError):
            pass
    return ["pkexec", HELPER] + args
