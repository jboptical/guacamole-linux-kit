#!/bin/sh
# Run ON THE PHONE as root. Speaker + microphone audio for the OnePlus 7 Pro.
# The kernel and device tree side is already in place (QDSP6 ADSP, WCD9340 on
# SLIMbus, two NXP TFA9874 speaker amps on QUAT_MI2S); what is missing is the
# ALSA UCM profile that tells PipeWire which mixer routes to switch on. These
# are guacamole_nura's verified UCM files (device-oneplus-guacamole).
#
# CAUTION: there is no speaker protection yet (stock Android limits the amps
# using feedback from the DSP). Keep the volume moderate, especially for long
# playback at full volume.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

install -d /usr/share/alsa/ucm2/conf.d/sm8150 /usr/share/alsa/ucm2/OnePlus/guacamole
cat > "/usr/share/alsa/ucm2/conf.d/sm8150/OnePlus 7 Pro.conf" <<'UCM'
# Use case configuration for the OnePlus 7 Pro

Syntax 4

SectionUseCase."HiFi" {
	File "/OnePlus/guacamole/HiFi.conf"
	Comment "HiFi playback and capture"
}
UCM
cat > /usr/share/alsa/ucm2/OnePlus/guacamole/HiFi.conf <<'UCM'
# Speaker and microphone routes for the OnePlus 7 Pro
#
# The phone has no headphone jack and the WCD9340 line outputs are not used
# for the loudspeakers. Both speakers are NXP TFA9874 amplifiers (I2C 0x34 top
# / earpiece, 0x35 bottom) fed by QUATERNARY_MI2S_RX, matching the OxygenOS
# mixer_paths_tavil.xml "speaker" path (QUAT_MI2S_RX, two channels, S24_LE).
#
# Playback is MultiMedia1 on PCM 0, capture is MultiMedia2 on PCM 1. They must
# stay on separate front ends: a capture PCM is only openable once its front end
# is joined to SLIMBUS_0_TX, and a sound server probes the PCM before applying
# any use-case sequence.
#
# Capture follows the OxygenOS "handset-mic" -> "amic4" path: AMIC4 on the
# shared AMIC4_5 mux, ADC4, decimator 0, SLIM TX0 (biased by MIC BIAS1 via the
# device tree audio-routing).

SectionVerb {
	EnableSequence [
		cset "name='QUAT_MI2S_RX Audio Mixer MultiMedia1' 1"
		cset "name='AMIC4_5 SEL' AMIC4"
		cset "name='CDC_IF TX0 MUX' DEC0"
		cset "name='AIF1_CAP Mixer SLIM TX0' 1"
		cset "name='MultiMedia2 Mixer SLIMBUS_0_TX' 1"
	]

	DisableSequence [
		cset "name='QUAT_MI2S_RX Audio Mixer MultiMedia1' 0"
		cset "name='MultiMedia2 Mixer SLIMBUS_0_TX' 0"
		cset "name='AIF1_CAP Mixer SLIM TX0' 0"
		cset "name='CDC_IF TX0 MUX' ZERO"
	]

	Value {
		TQ "HiFi"
	}
}

SectionDevice."Speaker" {
	Comment "Internal speakers"

	Value {
		PlaybackPriority 200
		PlaybackPCM "hw:${CardId},0"
		PlaybackChannels 2
	}
}

SectionDevice."Mic" {
	Comment "Internal microphone"

	EnableSequence [
		cset "name='ADC MUX0' AMIC"
		cset "name='AMIC MUX0' ADC4"
		cset "name='ADC4 Volume' 20"
		cset "name='DEC0 Volume' 96"
	]

	DisableSequence [
		cset "name='AMIC MUX0' ZERO"
		cset "name='ADC4 Volume' 0"
		cset "name='DEC0 Volume' 84"
	]

	Value {
		CapturePriority 200
		CapturePCM "hw:${CardId},1"
		CaptureChannels 1
	}
}
UCM

# Booted through UEFI (U-Boot provides SMBIOS), ASoC names the card after the
# DMI data ("oneplus-OnePlus7Pro-...") instead of "OnePlus 7 Pro", and UCM
# looks for conf.d/<driver>/<long name>.conf. Link the profile under that name.
LN=$(sed -n '2s/^[[:space:]]*//; 2s/[[:space:]]*$//; 2p' /proc/asound/cards 2>/dev/null || true)
if [ -n "$LN" ] && [ "$LN" != "OnePlus 7 Pro" ]; then
  ln -sfn "OnePlus 7 Pro.conf" "/usr/share/alsa/ucm2/conf.d/sm8150/$LN.conf"
  echo "UCM profile also linked as conf.d/sm8150/$LN.conf"
fi

if command -v pacman >/dev/null; then pacman -S --needed --noconfirm alsa-utils >/dev/null || true; fi
echo "== sound cards"; cat /proc/asound/cards
CARD=$(awk '/OnePlus 7 Pro/ {print $1; exit}' /proc/asound/cards)
if [ -z "$CARD" ]; then
  echo "WARNING: no 'OnePlus 7 Pro' sound card found (is the ADSP running? dmesg | grep -i -E 'q6|adsp|wcd|tfa')"
elif ! command -v alsaucm >/dev/null; then
  echo "card $CARD found; install alsa-utils to check the UCM profile (alsaucm) and test (speaker-test)"
else
  echo "== UCM verbs/devices for card $CARD"
  alsaucm -c "hw:$CARD" list _verbs || true
  alsaucm -c "hw:$CARD" set _verb HiFi list _devices || true
fi
echo
echo "Done. As your normal user, restart the sound server:"
echo "  systemctl --user restart wireplumber pipewire pipewire-pulse"
echo "then pick 'Speaker' in the volume applet and test with: speaker-test -c2 -twav -l1"
