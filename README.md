# AppleMAC-LED — ESP32-S3 macOS status lighting

AppleMAC-LED is a macOS status-light project built around an ESP32-S3 and a
WS2812B-compatible addressable LED strip. The ESP32-S3 connects to the Mac over
USB Serial at 115200 baud. A background agent detects selected local system
activity, sends lighting commands, and streams system-audio levels for the
music-reactive overlay.

The ESP32-S3 firmware does not use Wi-Fi or Bluetooth. All Mac-to-ESP
communication is local USB Serial.

## Public project contents

```text
AppleMACled.ino     ESP32-S3 LED firmware
firmware/           Prebuilt complete 4 MB flash image
MacAgent/           macOS agent, installer, uninstaller, and diagnostics
README.md           Installation and wiring guide
```

No secondary controller firmware is required. This public version deliberately
excludes clock correction, temperature and fan reporting, network provisioning,
and macOS media-key control.

Lighting events include:

- normal slow color pulsing;
- Finder copy and AirDrop activity;
- Safari download activity;
- App Store download/update activity;
- ChatGPT and Codex activity;
- Trash emptying notification;
- Wi-Fi and Bluetooth connection notification;
- system-audio-reactive music visualization.

## Hardware

Required:

- ESP32-S3 development board with at least 4 MB of flash;
- WS2812B-compatible 5 V addressable LED strip, 20 LEDs by default;
- 330–470 ohm resistor on the LED data line;
- regulated 5 V LED power supply;
- USB data cable between the Mac and ESP32-S3;
- AO3400A N-channel MOSFET, 330 ohm resistor, and 10 kOhm resistor for the
  mandatory GPIO16 hardware self-reset circuit.

Recommended:

- 470–1000 uF electrolytic capacitor across the LED strip's 5 V and GND input;
- 74AHCT125, 74HCT14, or another suitable 3.3 V to 5 V logic-level shifter if
  the data cable is long or the strip is unreliable with 3.3 V data.

For 20 WS2812B LEDs, a 5 V / 2 A supply is a sensible starting point. Always
allow adequate current margin for your chosen brightness and LED count.

## Wiring

The firmware defaults are:

```cpp
LED_PIN   = GPIO21
LED_COUNT = 20
```

Connect the strip as follows:

```text
ESP32-S3 GPIO21 ---- 330–470 ohm ----> WS2812B DIN
ESP32-S3 GND -------------------------> WS2812B GND
External 5 V -------------------------> WS2812B +5V
External PSU GND ---------------------> ESP32-S3 GND
Mac USB ------------------------------> ESP32-S3 USB/data port
```

Important:

- The ESP32-S3 and LED strip must share GND.
- Never connect 5 V directly to an ESP32 GPIO.
- Never power the LED strip through an ESP32 GPIO.
- Avoid back-feeding a development board from two power sources unless its
  documentation explicitly allows it.
- Change `LED_PIN` and `LED_COUNT` near the top of `AppleMACled.ino` if your
  hardware differs.

## Mandatory hardware self-reset

The GPIO16 hardware self-reset circuit is a required part of USB recovery. It
lets the firmware recover automatically if native USB CDC becomes stuck.

```text
ESP32-S3 GPIO16 ---- 330 ohm ----> Gate of AO3400A N-MOSFET
MOSFET Gate -------- 10 kOhm ----> GND
MOSFET Source --------------------> GND
MOSFET Drain ---------------------> ESP32-S3 EN / RST
```

GPIO16 HIGH turns the MOSFET on and pulls EN/RST low. The firmware includes a
software-reset fallback only as a last-resort safety path if the external circuit
fails. Do not use GPIO16 for another device.

## Flashing the ESP32-S3

1. Install Arduino IDE.
2. Install the Espressif ESP32 board package.
3. Install the FastLED library.
4. Open `AppleMACled.ino`.
5. Select the exact ESP32-S3 board and port.
6. Select the Flash Size, Partition Scheme, and USB settings described below.
7. Compile and upload the sketch.
8. Use Serial Monitor at 115200 baud for diagnostics if needed.

### Flash and partition settings

The minimum verified flash size is **4 MB**. The exported 4 MB reference build
uses 472,096 bytes of a 1,310,720-byte application slot (about 36%).

Verified minimum configuration for `ESP32S3 Dev Module`:

```text
Flash Size: 4MB (32Mb)
Partition Scheme: Default 4MB with spiffs (1.2MB APP/1.5MB SPIFFS)
USB Mode: Hardware CDC and JTAG
USB CDC On Boot: Enabled
```

The selected Flash Size and Partition Scheme must target the same physical
flash capacity. For example:

- a 4 MB board or 4 MB Flash Size setting requires a 4 MB partition scheme;
- an 8 MB board with Flash Size set to 8 MB requires an 8 MB partition scheme.

Do not combine an 8 MB partition scheme with Flash Size set to 4 MB. That
mismatch prevents the ESP32-S3 from booting and produces errors such as
`partition ... exceeds flash chip size 0x400000`.

Enable `Erase All Flash Before Sketch Upload` for the first public-firmware
upload and whenever changing the Flash Size or Partition Scheme. It can be
disabled again after the new partition table has been installed successfully.

### Prebuilt merged image

`firmware/AppleMACled_4MB_merged.bin` is the complete verified 4 MB flash image.
It contains the bootloader, partition table, boot application selector, and
AppleMAC-LED firmware in one file. Flash this merged image at address `0x0`;
do not write it at the application-only address `0x10000`.

Example with `esptool` (replace the port with the ESP32-S3 port on your Mac):

```bash
esptool --chip esp32s3 --port /dev/cu.usbmodemXXXX erase-flash
esptool --chip esp32s3 --port /dev/cu.usbmodemXXXX write-flash \
  0x0 firmware/AppleMACled_4MB_merged.bin
```

SHA-256:

```text
007dab0b861696accb23caa6a7dafd76be202f998fa530cad0d74a3390aa55b6
```

The merged image uses the verified 4 MB partition layout and the first 4 MB of
flash. Boards with larger physical flash can also run it, but users who compile
from source should always match Flash Size and Partition Scheme as described
above.

For native ESP32-S3 USB CDC, `USB CDC On Boot: Enabled` is normally required.
For a board using an external USB-UART chip such as CP210x, CH9102, or CH343,
use the settings specified by that board's documentation.

If the macOS agent is already installed, release the serial port before
flashing:

```bash
CMD="$HOME/Library/Application Support/AppleMAC-LED/applemacled.command"
"$CMD" usb-pause
```

After flashing:

```bash
"$CMD" usb-resume
```

## Installing the macOS agent

Requirements:

- macOS 13 or newer is recommended;
- Python 3.9 or newer;
- Apple Command Line Tools and `clang`;
- internet access during the first installation so dependencies can be
  installed into the project's private virtual environment.

Install Command Line Tools if needed:

```bash
xcode-select --install
```

Then open Terminal in the public project and run:

```bash
cd /path/to/AppleMACled/MacAgent
chmod +x *.command
./install.command
```

The installer creates:

```text
~/Applications/AppleMACLED Agent.app
~/Library/Application Support/AppleMAC-LED/
~/Library/Logs/AppleMAC-LED/
~/Library/LaunchAgents/com.applemacled.agent.plist
```

The LaunchAgent starts the background agent automatically after login.

### Permission sequence

Every installation resets the privacy permissions for the current signed
`com.applemacled.agent` application. The installer then requests and verifies
them one at a time in this order:

1. **Accessibility** — inspects limited Finder, Safari, and App Store interface
   state for activity indicators.
2. **Downloads folder** — detects active Safari downloads.
3. **Screen & System Audio Recording / Screen Recording** — measures audio
   levels for music-reactive lighting. No screen image is stored.
4. **Bluetooth** — detects newly connected Bluetooth devices for the blue
   notification animation.

The installer waits until macOS confirms the current permission before moving
to the next stage, with a short delay between stages. It does not open all
permission windows at once. Complete every stage; installation intentionally
does not skip an unverified permission.

Keep the Terminal window open until the installer prints its success message.
Rows of dots mean that it is waiting for macOS or for the user; do not launch a
second copy of `install.command` while it is waiting.

During the Screen & System Audio Recording stage, macOS may say that the agent
must be restarted. Choose **Later**, return to Terminal, and press Return after
the permission switch is enabled. The installer safely restarts only its helper
process and verifies the permission before continuing to Bluetooth.

If `AppleMACLED Agent` does not immediately appear in the Accessibility list,
close and reopen that Privacy & Security section. The installer remains on the
same stage until the permission is visible and verified.

## Verifying the installation

Define the installed command wrapper:

```bash
CMD="$HOME/Library/Application Support/AppleMAC-LED/applemacled.command"
```

List detected serial ports and read the ESP32 status:

```bash
"$CMD" ports
"$CMD" status
```

Run the diagnostic helper:

```bash
cd /path/to/AppleMACled/MacAgent
./diagnose.command
```

Follow the main log:

```bash
tail -f "$HOME/Library/Logs/AppleMAC-LED/agent.log"
```

All installer, agent, diagnostic, and firmware log messages are in English. If
a permission appears enabled in System Settings but diagnostics report it as
unavailable, rerun `./install.command` and complete the verified sequence again.

## Manual lighting commands

The installed wrapper supports:

```bash
"$CMD" status
"$CMD" reboot
"$CMD" snake-on
"$CMD" snake-off
"$CMD" copy-on
"$CMD" copy-off
"$CMD" chatgpt-on
"$CMD" chatgpt-off
"$CMD" appstore-on
"$CMD" appstore-off
"$CMD" trash-flash
"$CMD" system-blue
```

The background agent normally controls these effects automatically.

## Uninstalling

From the `MacAgent` directory:

```bash
./uninstall.command
```

This removes the LaunchAgent and `AppleMACLED Agent.app`. Runtime files and logs
are intentionally preserved. To remove those as well:

```bash
rm -rf "$HOME/Library/Application Support/AppleMAC-LED"
rm -rf "$HOME/Library/Logs/AppleMAC-LED"
```

## Troubleshooting

### ESP32 does not appear in the port list

- Confirm that the USB cable supports data, not charging only.
- Try another USB port or cable.
- Check the board's USB CDC settings.
- Open Arduino IDE and verify that the board can be flashed normally.

### LED strip does not light

- Confirm 5 V at the strip and a common GND with the ESP32-S3.
- Confirm DIN, not DOUT, is connected to GPIO21.
- Check the data resistor and LED direction arrows.
- Confirm that `LED_COUNT` matches the strip segment.

### LEDs flicker or show incorrect colors

- Add the recommended bulk capacitor near the strip input.
- Keep the data wire short.
- Use a proper 3.3 V to 5 V logic-level shifter if needed.
- Make sure the 5 V supply is stable under load.

### Arduino IDE is using the port

Close Serial Monitor, or run `"$CMD" usb-pause`. After flashing, run
`"$CMD" usb-resume`.

### The agent reports a permission problem

Run `./diagnose.command`, then rerun `./install.command` and complete each
permission stage when prompted.

## Security and privacy

- The Mac-to-ESP link is local USB Serial.
- The ESP32-S3 firmware does not connect to a Wi-Fi network.
- The repository contains no Wi-Fi password, API key, or account credential.
- The installer builds the native application locally from the included source
  and applies a local ad-hoc signature; it does not download a prebuilt agent.
- The agent reads local macOS state only for the lighting behaviors documented
  above.
- Review source code before installing any software from a public repository.

## Customization

The main hardware and animation values are near the top of `AppleMACled.ino`:

```text
LED_PIN
LED_COUNT
MAX_BRIGHTNESS
PULSE_PERIOD_MS
COLOR_HOLD_MS
COLOR_FADE_MS
```

Individual animation timings and colors are also defined as constants in the
firmware and can be adjusted before compiling.
