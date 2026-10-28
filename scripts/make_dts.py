#!/usr/bin/env python3
"""Build a U-Boot/EFI-ready OnePlus 7 Pro DTS from the guacamole_nura flat DTS.
Applies the reserved-memory fixes and ABL board IDs from guacamole_nura's
patch_dtb.py, and adds a simple-framebuffer in /chosen for U-Boot's console."""
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()

def sub(old, new):
    global t
    assert old in t, "pattern not found: " + old[:60]
    t = t.replace(old, new, 1)

# Give the splash framebuffer region a compatible: U-Boot maps compatible-less
# no-map regions as FAULT, so drawing to (or debugging via) it would abort.
sub("memory@9c000000 {\n\t\t\treg = <0x00 0x9c000000 0x00 0x2400000>;\n\t\t\tno-map;",
    "memory@9c000000 {\n\t\t\tcompatible = \"qcom,cont-splash-region\";\n\t\t\treg = <0x00 0x9c000000 0x00 0x2400000>;\n\t\t\tno-map;")
# xbl_aop_mem moves to 0x85e00000 (stock). Size 0x100000 so it ends where the
# aop/cmd-db regions start (same union, but no overlap: U-Boot's LMB rejects
# overlapping reservations with -EEXIST).
sub("memory@85d00000 {\n\t\t\treg = <0x00 0x85d00000 0x00 0x140000>;",
    "memory@85e00000 {\n\t\t\treg = <0x00 0x85e00000 0x00 0x100000>;")
sub("memory@86200000 {\n\t\t\treg = <0x00 0x86200000 0x00 0x3900000>;",
    "memory@86200000 {\n\t\t\treg = <0x00 0x86200000 0x00 0x5500000>;")
rm_end = """\t\tmemory@f2901000 {
\t\t\tcompatible = "qcom,rmtfs-mem";
\t\t\treg = <0x00 0xf2901000 0x00 0x200000>;
\t\t\tno-map;
\t\t\tqcom,client-id = <0x01>;
\t\t\tqcom,vmid = <0x0f>;
\t\t};
\t};"""
extra = rm_end[:-4] + """
\t\tbootloader_log_mem@9fff7000 { reg = <0x00 0x9fff7000 0x00 0x9000>; no-map; };
\t\tcdsp_sec_regions@a4c00000 { compatible = "removed-dma-pool"; no-map; reg = <0x00 0xa4c00000 0x00 0x3c00000>; };
\t\tramoops@a9800000 { compatible = "ramoops"; reg = <0x00 0xa9800000 0x00 0x400000>; record-size = <0x40000>; console-size = <0x40000>; ftrace-size = <0x40000>; pmsg-size = <0x200000>; };
\t\tparam_mem@ac200000 { reg = <0x00 0xac200000 0x00 0x100000>; no-map; };
\t\tmtp_mem@ac300000 { reg = <0x00 0xac300000 0x00 0xb00000>; no-map; };
\t};"""
sub(rm_end, extra)
sub('\tmodel = "OnePlus 7 Pro";\n', '\tmodel = "OnePlus 7 Pro";\n'
    '\tqcom,msm-id = <0x153 0x20000>, <0x169 0x20000>;\n'
    '\tqcom,board-id = <0x08 0x00>;\n')
sub("\tchosen {\n\t};", """\tchosen {
\t\t#address-cells = <0x02>;
\t\t#size-cells = <0x02>;
\t\tranges;
\t\tstdout-path = "framebuffer0";

\t\tframebuffer0: framebuffer@9c000000 {
\t\t\tcompatible = "simple-framebuffer";
\t\t\treg = <0x00 0x9c000000 0x00 0x1123800>;
\t\t\twidth = <1440>;
\t\t\theight = <3120>;
\t\t\tstride = <5760>;
\t\t\tformat = "a8r8g8b8";
\t\t};
\t};""")

# U-Boot's regulator uclass needs a unique regulator-name per regulator; it falls
# back to the node name, so ldo1 on PMIC a and ldo1 on PMIC c collide and
# initr_dm fails. Name every RPMh regulator: its label if it has one,
# else vreg_<node>_<pmic-id>.
import re
def name_rpmh_regulators(text):
    out, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        m = re.match(r"^(\t+)[\w-]*rpmh-regulators \{$", line)
        if not m:
            i += 1
            continue
        ind = m.group(1)
        child = ind + "\t"
        pmic = "x"
        i += 1
        while i < len(lines) and lines[i] != ind + "};":
            l = lines[i]
            mm = re.match(r'^\t+qcom,pmic-id = "(\w+)";', l)
            if mm:
                pmic = mm.group(1)
            cm = re.match("^" + child + r"(?:([\w-]+): )?([\w-]+) \{$", l)
            out.append(l)
            if cm:
                # look ahead in this child node for an existing regulator-name
                j, has = i + 1, False
                while lines[j] != child + "};":
                    has |= "regulator-name" in lines[j]
                    j += 1
                if not has:
                    nm = cm.group(1) or "vreg_%s_%s" % (cm.group(2), pmic)
                    out.append(child + '\tregulator-name = "%s";' % nm)
            i += 1
    return "\n".join(out)

t = name_rpmh_regulators(t)

# USB PHY supplies (HS PHY: L5A pll, L2A 3.3V, L12A 1.8V; QMP PHY: L3C). U-Boot's
# PHY drivers never enable their supplies; after a cold boot from the boot
# partition (no ABL fastboot session) they are off and the DWC3 gadget times
# out ("failed to enable ep0out", -110). regulator-boot-on makes U-Boot turn
# them on at probe.
for _n in ("vreg_ldo5_a", "vreg_ldo2_a", "vreg_ldo12_a", "vreg_ldo3_c"):
    _m = re.search(r'\n(\t+)regulator-name = "%s";' % _n, t)
    assert _m, _n
    t = t.replace(_m.group(0), _m.group(0) + "\n" + _m.group(1) + "regulator-boot-on;", 1)

# Vol Down on the 7 Pro is PM8150 GPIO 7 (needs power-source = <1>), not the
# PON RESIN input (that's the 7T Pro). Keep resin disabled, and use the labels
# U-Boot's qcom-phone.env expects ("Volume Down" opens the boot menu when held).
sub('label = "volume_up";', 'label = "Volume Up";')
sub('label = "volume_down";', 'label = "Volume Down";')

# Volume keys: request the PMIC GPIO pull-up (GPIO_ACTIVE_LOW | GPIO_PULL_UP).
# U-Boot otherwise configures the pins with no pull and the keys float.
sub("gpios = <0xd4 6 1>;", "gpios = <0xd4 6 0x11>;")
sub("gpios = <0xd4 7 1>;", "gpios = <0xd4 7 0x11>;")

open(dst, "w").write(t)
print("wrote", dst)
