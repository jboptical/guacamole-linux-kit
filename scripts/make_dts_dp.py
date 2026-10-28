#!/usr/bin/env python3
"""Add USB-C DisplayPort alternate mode wiring to the OnePlus 7 Pro DTS.

Input: the DTS written by make_dts.py.  Output: a DTS for a Linux-only DTB that
systemd-boot loads with a `devicetree` line (U-Boot keeps its own DTB).

The 7 Pro routes USB-C like Qualcomm's SM8150 HDK, so this follows the upstream
sm8150-hdk.dts wiring:
  - PM8150B Type-C connector advertises DP alt mode (svid 0xff01, DFP_D,
    pin assignments C/D/E) and gets port@2 (SBU lines) -> FSA4480
  - FSA4480 SBU/audio switch at i2c@890000 0x42 (address from the stock DT)
    as mode- and orientation-switch for the AUX channel on SBU1/SBU2
  - mdss_dp enabled, 2 lanes (pin assignment D: DP x2 + USB 3 to the dock)
The rest of the graph (DPU intf -> mdss_dp -> QMP combo PHY port@2, PHY
port@0 <-> connector SuperSpeed port) already exists in the base DTS.

  make_dts_dp.py IN.dts OUT.dts
"""
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()

SBU_EP, FSA_EP = 0x7f01, 0x7f02
for p in (SBU_EP, FSA_EP):
    assert "phandle = <%#x>;" % p not in t, "phandle %#x in use" % p


def sub(old, new):
    global t
    assert t.count(old) == 1, "pattern not found once: " + old[:70]
    t = t.replace(old, new, 1)


# 1. connector: DP alt mode + SBU port
sub("\t\t\t\t\t\top-sink-microwatt = <0xe4e1c0>;\n",
    "\t\t\t\t\t\top-sink-microwatt = <0xe4e1c0>;\n\n"
    "\t\t\t\t\t\taltmodes {\n"
    "\t\t\t\t\t\t\tdisplayport {\n"
    "\t\t\t\t\t\t\t\tsvid = /bits/ 16 <0xff01>;\n"
    "\t\t\t\t\t\t\t\tvdo = <0x00001c46>;\n"
    "\t\t\t\t\t\t\t};\n"
    "\t\t\t\t\t\t};\n")
con_p1 = ("\t\t\t\t\t\t\tport@1 {\n"
          "\t\t\t\t\t\t\t\treg = <0x01>;\n\n"
          "\t\t\t\t\t\t\t\tendpoint {\n"
          "\t\t\t\t\t\t\t\t\tremote-endpoint = <0x532>;\n"
          "\t\t\t\t\t\t\t\t\tphandle = <0x533>;\n"
          "\t\t\t\t\t\t\t\t};\n"
          "\t\t\t\t\t\t\t};\n")
sub(con_p1, con_p1 +
    "\n\t\t\t\t\t\t\tport@2 {\n"
    "\t\t\t\t\t\t\t\treg = <0x02>;\n\n"
    "\t\t\t\t\t\t\t\tendpoint {\n"
    "\t\t\t\t\t\t\t\t\tremote-endpoint = <%#x>;\n"
    "\t\t\t\t\t\t\t\t\tphandle = <%#x>;\n"
    "\t\t\t\t\t\t\t\t};\n"
    "\t\t\t\t\t\t\t};\n" % (FSA_EP, SBU_EP))

# 2. FSA4480 on the speaker-amp I2C bus (after the two TFA9874 nodes)
amp = ("\t\t\t\tspeaker_bottom: audio-codec@35 {\n"
       "\t\t\t\t\tcompatible = \"nxp,tfa9874\";\n"
       "\t\t\t\t\treg = <0x35>;\n"
       "\t\t\t\t\t#sound-dai-cells = <0x00>;\n"
       "\t\t\t\t};\n")
sub(amp, amp +
    "\n\t\t\t\ttypec-mux@42 {\n"
    "\t\t\t\t\tcompatible = \"fcs,fsa4480\";\n"
    "\t\t\t\t\treg = <0x42>;\n"
    "\t\t\t\t\tmode-switch;\n"
    "\t\t\t\t\torientation-switch;\n\n"
    "\t\t\t\t\tport {\n"
    "\t\t\t\t\t\tendpoint {\n"
    "\t\t\t\t\t\t\tremote-endpoint = <%#x>;\n"
    "\t\t\t\t\t\t\tphandle = <%#x>;\n"
    "\t\t\t\t\t\t};\n"
    "\t\t\t\t\t};\n"
    "\t\t\t\t};\n" % (SBU_EP, FSA_EP))

# 3. DisplayPort controller on, 2 lanes out to the QMP combo PHY
sub("\t\t\t\tpower-domains = <0x6f 0x06>;\n\t\t\t\tstatus = \"disabled\";\n",
    "\t\t\t\tpower-domains = <0x6f 0x06>;\n\t\t\t\tstatus = \"okay\";\n")
sub("\t\t\t\t\t\t\tremote-endpoint = <0xc7>;\n\t\t\t\t\t\t\tphandle = <0xb0>;\n",
    "\t\t\t\t\t\t\tremote-endpoint = <0xc7>;\n\t\t\t\t\t\t\tdata-lanes = <0x00 0x01>;\n\t\t\t\t\t\t\tphandle = <0xb0>;\n")

open(dst, "w").write(t)
print("wrote", dst)
