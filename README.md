AppleMAC-LED — ESP32-S3 macOS Status Lighting
=============================================

OVERVIEW
--------
AppleMAC-LED is a macOS status-light project built around an ESP32-S3 and a
WS2812B-compatible addressable LED strip.

The ESP32-S3 is connected to the Mac over USB Serial at 115200 baud. A macOS
background agent detects selected system activity and sends lighting commands to
the ESP32-S3.

This public version contains only:

  AppleMACled.ino   — ESP32-S3 LED firmware
  MacAgent/         — macOS background agent, installer and diagnostics
  README.txt        — this installation and wiring guide

No secondary controller firmware is required.

Main visual events include:
- normal slow color pulsing
- Finder copy / AirDrop activity
- Safari download activity
- App Store download/update activity
- ChatGPT / Codex activity
- Trash emptying notification
- Wi-Fi / Bluetooth connection notification
- optional system-audio-reactive LED modulation

The ESP32-S3 itself does not use Wi-Fi or BLE. Communication with the Mac is by
USB Serial only.


HARDWARE REQUIRED
-----------------
Minimum hardware:

- ESP32-S3 development board
- WS2812B-compatible 5 V addressable LED strip
- 20 LEDs by default
- 330–470 ohm resistor for the LED data line
- suitable regulated 5 V power supply for the LED strip
- USB data cable between the Mac and ESP32-S3

Recommended:
- 470–1000 uF electrolytic capacitor across the LED strip 5 V and GND input
- 74AHCT125 / 74HCT14 or another suitable 3.3 V -> 5 V logic-level shifter if
  the LED data cable is long or the strip is unreliable with 3.3 V data

For 20 WS2812B LEDs, size the 5 V supply with comfortable margin. A 5 V / 2 A
supply is a sensible starting point for this build.


WIRING
------
The current firmware uses:

  LED_PIN   = GPIO21
  LED_COUNT = 20

Connect the LED strip as follows:

  ESP32-S3 GPIO21 ---- 330–470 ohm ----> WS2812B DIN
  ESP32-S3 GND -------------------------> WS2812B GND
  External 5 V -------------------------> WS2812B +5V
  External PSU GND ---------------------> ESP32-S3 GND
  Mac USB ------------------------------> ESP32-S3 USB/data port

IMPORTANT:
- The ESP32-S3 and LED strip must share GND.
- Do not connect 5 V directly to an ESP32 GPIO.
- Do not power the LED strip through an ESP32 GPIO.
- Avoid back-feeding a development board from two power sources unless the
  board explicitly supports it.
- If your strip uses a different data pin or LED count, change LED_PIN and
  LED_COUNT near the top of AppleMACled.ino before flashing.


REQUIRED HARDWARE SELF-RESET
----------------------------
A hardware self-reset circuit on GPIO16 is REQUIRED for this project. It is a
core part of the USB recovery design and is used to recover automatically if
native USB CDC becomes stuck. Do not deploy the system without this circuit.

Original circuit:

  ESP32-S3 GPIO16 ---- 330 ohm ----> Gate of AO3400A N-MOSFET
  MOSFET Gate -------- 10 kOhm ----> GND
  MOSFET Source --------------------> GND
  MOSFET Drain ---------------------> ESP32-S3 EN / RST

GPIO16 HIGH turns the MOSFET on and pulls EN/RST low.

The hardware reset circuit is mandatory. The firmware contains a software-reset
fallback only as a last-resort safety path if the external reset circuit fails,
but this fallback is not considered a supported installation mode.

Do not use GPIO16 for another device. It is reserved for the mandatory
SELF_RESET_PIN circuit in AppleMACled.ino.


FLASHING THE ESP32-S3
---------------------
1. Install Arduino IDE.
2. Install the Espressif ESP32 board package.
3. Install the FastLED library.
4. Open AppleMACled.ino.
5. Select your exact ESP32-S3 board.
6. Select the correct USB mode for your board.

For an ESP32-S3 using native USB CDC, normally use:

  USB CDC On Boot: Enabled

For a board using an external USB-UART chip such as CP210x, CH9102 or CH343,
use the USB settings appropriate for that specific board.

7. Compile and upload the sketch.
8. Use Serial Monitor at 115200 baud for diagnostics if required.

If the macOS agent is already installed, release the serial port before flashing:

  CMD="$HOME/Library/Application Support/AppleMAC-LED/applemacled.command"
  "$CMD" usb-pause

After flashing:

  "$CMD" usb-resume


INSTALLING THE macOS AGENT
--------------------------
Requirements:

- macOS 13 or newer is recommended
- Python 3.9 or newer
- Apple Command Line Tools / clang
- Internet access during the first installation so Python packages can be
  installed into the private virtual environment

If Apple Command Line Tools are not installed:

  xcode-select --install

Then open Terminal and run:

  cd /path/to/AppleMACled/MacAgent
  chmod +x *.command
  ./install.command

The installer creates:

  ~/Applications/AppleMACLED Agent.app
  ~/Library/Application Support/AppleMAC-LED/
  ~/Library/Logs/AppleMAC-LED/
  ~/Library/LaunchAgents/com.applemacled.agent.plist

The LaunchAgent starts the background agent automatically after login.


macOS PERMISSIONS
-----------------
macOS may request permissions depending on which lighting features you use.

Accessibility
  Used to inspect limited Finder, Safari and App Store interface state for
  activity indicators.

Screen & System Audio Recording / Screen Recording
  Used only for the optional audio-reactive LED effect. No screen image is
  stored by the project.

Bluetooth
  Used only to detect a newly connected Bluetooth device and trigger the blue
  notification animation.

Downloads folder access
  May be requested for detecting active Safari downloads.

Location / Wi-Fi related permission
  macOS may request this while reading the current Wi-Fi connection state.

If you do not want the audio-reactive effect, you may deny the screen/system-
audio permission. The other LED functions can still operate.


VERIFYING THE INSTALLATION
--------------------------
After installation:

  CMD="$HOME/Library/Application Support/AppleMAC-LED/applemacled.command"

List detected serial ports:

  "$CMD" ports

Read the ESP32 status:

  "$CMD" status

Run the diagnostic helper from the repository:

  cd /path/to/AppleMACled/MacAgent
  ./diagnose.command

Follow the main log:

  tail -f "$HOME/Library/Logs/AppleMAC-LED/agent.log"

If Accessibility is enabled in System Settings but the diagnostic output still
shows axTrusted=false:

  ./repair_accessibility.command


MANUAL LIGHTING COMMANDS
------------------------
The installed command wrapper can be used for testing:

  CMD="$HOME/Library/Application Support/AppleMAC-LED/applemacled.command"

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

The background agent normally controls these effects automatically.


UNINSTALLING THE macOS AGENT
----------------------------
From the MacAgent directory:

  ./uninstall.command

This removes the LaunchAgent and the AppleMACLED Agent application.

Runtime files and logs are intentionally left in place. To remove them too:

  rm -rf "$HOME/Library/Application Support/AppleMAC-LED"
  rm -rf "$HOME/Library/Logs/AppleMAC-LED"


TROUBLESHOOTING
---------------
ESP32 does not appear in the port list
- Confirm that the USB cable supports data, not charging only.
- Try another USB port/cable.
- Check the board's USB CDC settings.
- Open Arduino IDE and verify that the board can be flashed normally.

LED strip does not light
- Confirm 5 V at the strip.
- Confirm common GND between the strip and ESP32-S3.
- Confirm DIN, not DOUT, is connected to GPIO21.
- Check the data resistor and LED direction arrows.
- Confirm LED_COUNT matches your strip segment.

LEDs flicker or show incorrect colors
- Add the recommended bulk capacitor near the strip input.
- Keep the data wire short.
- Use a proper 3.3 V -> 5 V logic-level shifter if needed.
- Make sure the 5 V supply is stable under load.

Agent cannot access the ESP32 because Arduino IDE is using the port
- Close Serial Monitor, or run:

    "$CMD" usb-pause

- Flash the board, then run:

    "$CMD" usb-resume

Agent reports Accessibility problems
- Run diagnose.command.
- Re-enable AppleMACLED Agent in System Settings -> Privacy & Security ->
  Accessibility.
- If required, run repair_accessibility.command.


SECURITY / PRIVACY NOTES
------------------------
- The Mac-to-ESP link is local USB Serial.
- The ESP32-S3 firmware does not connect to a Wi-Fi network.
- The repository contains no Wi-Fi password, API key or account credential.
- The agent uses local macOS state only for the lighting behaviors described in
  this document.
- Review source code before installing any software from a public repository.


CUSTOMIZATION
-------------
The main hardware values are near the top of AppleMACled.ino:

  LED_PIN
  LED_COUNT
  MAX_BRIGHTNESS
  PULSE_PERIOD_MS
  COLOR_HOLD_MS
  COLOR_FADE_MS

Individual animation timing and colors are also defined as constants in the
firmware and can be adjusted before compiling.
