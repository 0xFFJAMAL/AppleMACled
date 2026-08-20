/*
  AppleMAC-LED USB Serial — ESP32-S3 + WS2812B
  LED data: GPIO21
  LED count: 20

  The Mac and ESP32-S3 communicate only through USB Serial at 115200 baud.
  The macOS agent sends lighting commands and the system-audio level used by
  the music overlay. The firmware does not use Wi-Fi or Bluetooth.

  Protocol:
  Mac -> ESP: CMD:<COMMAND>\n
  ESP -> Mac: RSP:<RESPONSE>\n

  At startup the ESP shows the white recovery animation and waits for the USB
  agent. The agent sends WAIT and then OK after the link is established.

  USB CDC configuration depends on the board connection:
  - external USB-UART (CH343/CH9102/CP210x): USB CDC On Boot disabled;
  - native ESP32-S3 USB: USB CDC On Boot enabled.

  The GPIO16 hardware self-reset circuit is required for USB recovery.
  Requires the FastLED library.
*/

#include <FastLED.h>
#include <esp_task_wdt.h>
#include <esp_idf_version.h>
#include <esp_system.h>
#include <esp_attr.h>
#include <math.h>
#include <Preferences.h>

#if defined(ARDUINO_USB_MODE) && ARDUINO_USB_MODE && \
    defined(ARDUINO_USB_CDC_ON_BOOT) && ARDUINO_USB_CDC_ON_BOOT
  #include <HWCDC.h>
  #define APPLEMACLED_NATIVE_HWCDC 1
#else
  #define APPLEMACLED_NATIVE_HWCDC 0
#endif

#define LED_PIN       21
#define LED_COUNT     20
#define LED_TYPE      WS2812B
#define COLOR_ORDER   GRB
#define FRAME_MS      20

constexpr uint32_t LOOP_WATCHDOG_TIMEOUT_MS = 10000UL;

CRGB leds[LED_COUNT];

constexpr uint8_t  MAX_BRIGHTNESS  = 250;
constexpr uint8_t  MIN_BRIGHTNESS  = 0;
constexpr uint32_t PULSE_PERIOD_MS = 10000UL;
constexpr uint32_t COLOR_HOLD_MS   = 300000UL;
constexpr uint32_t COLOR_FADE_MS   = 15000UL;
constexpr uint16_t DOWNLOAD_SNAKE_STEP_MS = 45;
constexpr uint8_t  DOWNLOAD_SNAKE_TAIL    = 10;
constexpr uint32_t SNAKE_COMMAND_TIMEOUT_MS = 12000UL;
constexpr uint16_t COPY_SNAKE_STEP_MS       = 40;
constexpr uint8_t  COPY_SNAKE_TAIL          = 10;
constexpr uint16_t COPY_SNAKE_PAUSE_MS      = 100;
constexpr uint8_t  COPY_BACKGROUND_LEVEL    = 30;
constexpr uint8_t  COPY_HEAD_BRIGHTNESS     = 255;
constexpr uint8_t  COPY_TAIL_MIN_BRIGHTNESS = 22;
const CRGB COPY_SNAKE_COLOR = CRGB(135, 255, 45);
constexpr uint16_t CHATGPT_SNAKE_STEP_MS       = 38;
constexpr uint8_t  CHATGPT_SNAKE_TAIL          = 10;
constexpr uint16_t CHATGPT_SNAKE_PAUSE_MS      = 100;
constexpr uint8_t  CHATGPT_BACKGROUND_LEVEL    = 34;
constexpr uint8_t  CHATGPT_HEAD_BRIGHTNESS     = 255;
constexpr uint8_t  CHATGPT_TAIL_MIN_BRIGHTNESS = 24;
const CRGB CHATGPT_SNAKE_COLOR = CRGB(255, 105, 0);
constexpr uint16_t APPSTORE_SNAKE_STEP_MS       = 40;
constexpr uint8_t  APPSTORE_SNAKE_TAIL          = 10;
constexpr uint16_t APPSTORE_SNAKE_PAUSE_MS      = 100;
constexpr uint8_t  APPSTORE_BACKGROUND_LEVEL    = 24;
constexpr uint8_t  APPSTORE_HEAD_BRIGHTNESS     = 255;
constexpr uint8_t  APPSTORE_TAIL_MIN_BRIGHTNESS = 22;
constexpr uint8_t  TRASH_FLASH_COUNT  = 3;
constexpr uint16_t TRASH_FLASH_ON_MS  = 220;
constexpr uint16_t TRASH_FLASH_OFF_MS = 160;
const CRGB TRASH_FLASH_COLOR = CRGB(255, 0, 0);
constexpr uint16_t SYSTEM_BLUE_SNAKE_STEP_MS        = 38;
constexpr uint8_t  SYSTEM_BLUE_SNAKE_TAIL           = 10;
constexpr uint8_t  SYSTEM_BLUE_BACKGROUND_LEVEL     = 24;
constexpr uint8_t  SYSTEM_BLUE_HEAD_BRIGHTNESS      = 255;
constexpr uint8_t  SYSTEM_BLUE_TAIL_MIN_BRIGHTNESS  = 20;
constexpr uint16_t SYSTEM_BLUE_AFTER_SNAKE_PAUSE_MS = 0;
constexpr uint8_t  SYSTEM_BLUE_FLASH_COUNT          = 0;
constexpr uint16_t SYSTEM_BLUE_FLASH_ON_MS           = 220;
constexpr uint16_t SYSTEM_BLUE_FLASH_OFF_MS          = 160;
const CRGB SYSTEM_BLUE_COLOR = CRGB(0, 105, 255);
constexpr uint32_t AUDIO_PACKET_TIMEOUT_MS = 1200UL;
constexpr uint16_t AUDIO_BEAT_FLASH_MS = 125;
constexpr uint8_t  AUDIO_MIN_VISIBLE_LEVEL = 7;
constexpr uint8_t  AUDIO_FLICKER_MIN_SCALE = 0;
constexpr uint8_t  AUDIO_FLICKER_LEVEL_GATE = 44;
constexpr uint8_t  AUDIO_FLICKER_PEAK_GATE = 58;
constexpr uint8_t  AUDIO_FLICKER_LEVEL_RANGE = 210;
constexpr uint8_t  AUDIO_FLICKER_PEAK_RANGE = 60;
constexpr uint8_t  AUDIO_FLICKER_BEAT_BOOST = 50;
constexpr uint8_t  WAIT_BACKGROUND_BRIGHTNESS = 28;
constexpr uint8_t  WAIT_HEAD_BRIGHTNESS       = 250;
constexpr uint16_t WAIT_SNAKE_STEP_MS          = 65;
constexpr uint8_t  WAIT_SNAKE_TAIL             = 10;
constexpr uint8_t  WAIT_PULSE_MIN_BRIGHTNESS   = 10;
constexpr uint8_t  WAIT_PULSE_MAX_BRIGHTNESS   = 175;
constexpr uint32_t RESULT_PULSE_MS = 2400UL;
constexpr uint32_t USB_SERIAL_BAUD = 115200;
constexpr size_t USB_COMMAND_MAX = 4096;
constexpr size_t USB_CDC_RX_BUFFER_SIZE = 4096;
constexpr size_t USB_CDC_TX_BUFFER_SIZE = 1024;
constexpr uint32_t USB_CDC_TX_TIMEOUT_MS = 35UL;
constexpr uint32_t USB_BUS_RESET_CONFIRM_MS = 18000UL;
constexpr uint8_t SELF_RESET_PIN = 16;
constexpr uint8_t SELF_RESET_ACTIVE_LEVEL = HIGH;
constexpr uint8_t SELF_RESET_IDLE_LEVEL = LOW;
constexpr uint32_t SELF_RESET_FALLBACK_MS = 600UL;
constexpr uint32_t USB_RECOVERY_POLL_MS = 250UL;
constexpr uint32_t USB_RECOVERY_INITIAL_GRACE_MS = 15000UL;
constexpr uint32_t USB_RECOVERY_LOOP_PULSE_MS = 18000UL;
constexpr uint32_t USB_RECOVERY_LOOP_SNAKE_MS =
  static_cast<uint32_t>(LED_COUNT) * WAIT_SNAKE_STEP_MS;
constexpr uint32_t USB_RECOVERY_RESET_ARM_DELAY_MS = 250UL;
constexpr char USB_RECOVERY_NVS_NAMESPACE[] = "amled_usbrec";
constexpr char USB_RECOVERY_NVS_PENDING_KEY[] = "pending";
char usbCommandBuffer[USB_COMMAND_MAX];
size_t usbCommandLength = 0;
bool usbHostSeen = false;
bool usbEverConnected = false;
uint32_t usbLastActivityAt = 0;
String usbLastStatus = "BOOTING";
volatile bool usbCdcBusResetEventPending = false;
volatile bool usbCdcTrafficEventPending = false;
bool usbCdcPhysicalPlugged = false;
bool usbCdcConnected = false;
bool usbCdcBusResetSuspected = false;
uint32_t usbCdcBusResetSuspectedAt = 0;
uint32_t usbCdcBusResetEventCount = 0;
uint32_t usbCdcBusResetRecoveredCount = 0;
bool usbRecoveryAwaitingHandshake = true;
uint32_t usbRecoveryCycleStartedAt = 0;
uint32_t usbRecoveryLastActionAt = 0;
uint32_t usbRecoveryLastPollAt = 0;
uint8_t usbRecoverySoftReinitCount = 0;
Preferences usbRecoveryPreferences;
bool usbRecoveryPreferencesReady = false;
bool usbRecoveryLoopActive = false;
esp_reset_reason_t startupResetReason = ESP_RST_UNKNOWN;
bool loopWatchdogActive = false;
bool restartPending = false;
bool restartPendingIsUsbRecovery = false;
bool restartPendingUseHardwareReset = false;
uint32_t restartAt = 0;
uint8_t audioLevel = 0;
uint8_t audioPeak = 0;
uint32_t audioLastPacketAt = 0;
uint32_t audioBeatUntil = 0;
uint32_t audioLastSequence = 0;
bool audioSequenceInitialized = false;
bool audioStreamActive = false;

const CRGB palette[] = {
  CRGB(255, 255, 255),
  CRGB(135, 220, 255),
  CRGB(0,   190, 255),
  CRGB(0,   255, 205),
  CRGB(35,  75,  255),
  CRGB(145, 65,  255),
  CRGB(255, 165, 20),
  CRGB(255, 90,  0),
  CRGB(255, 30,  0)
};

constexpr uint8_t COLOR_COUNT = sizeof(palette) / sizeof(palette[0]);

enum AnimationMode : uint8_t {
  MODE_WAITING_FOR_MAC,
  MODE_RESULT_PULSE,
  MODE_NORMAL
};

enum NetworkDecision : uint8_t {
  DECISION_NONE,
  DECISION_OK,
  DECISION_NC
};

AnimationMode animationMode = MODE_WAITING_FOR_MAC;
NetworkDecision lastDecision = DECISION_NONE;
CRGB resultPulseColor = CRGB::Black;
uint32_t resultPulseStartedAt = 0;

volatile bool downloadSnakeRequested = false;
volatile bool copySnakeRequested = false;
volatile bool chatgptSnakeRequested = false;
volatile bool appStoreSnakeRequested = false;
volatile uint32_t downloadSnakeHeartbeatAt = 0;
volatile uint32_t copySnakeHeartbeatAt = 0;
volatile uint32_t chatgptSnakeHeartbeatAt = 0;
volatile uint32_t appStoreSnakeHeartbeatAt = 0;
volatile bool trashFlashActive = false;
volatile uint32_t trashFlashStartedAt = 0;

volatile bool systemBlueSequenceActive = false;
volatile uint8_t systemBluePendingCount = 0;
volatile uint32_t systemBlueSequenceStartedAt = 0;

void feedLoopWatchdog();

void scheduleRestart(
  uint32_t delayMs = 1000,
  bool usbRecoveryRestart = false,
  bool useHardwareReset = false
) {
  restartPending = true;
  restartPendingIsUsbRecovery = usbRecoveryRestart;
  restartPendingUseHardwareReset = useHardwareReset;
  restartAt = millis() + delayMs;
}

void setupSelfResetHardware() {
  digitalWrite(SELF_RESET_PIN, SELF_RESET_IDLE_LEVEL);
  pinMode(SELF_RESET_PIN, OUTPUT);
  digitalWrite(SELF_RESET_PIN, SELF_RESET_IDLE_LEVEL);
}

void initializeUsbRecoveryPersistentState() {
  usbRecoveryPreferencesReady = usbRecoveryPreferences.begin(
    USB_RECOVERY_NVS_NAMESPACE,
    false
  );

  if (!usbRecoveryPreferencesReady) {
    usbRecoveryLoopActive = false;
    return;
  }

  usbRecoveryLoopActive = usbRecoveryPreferences.getBool(
    USB_RECOVERY_NVS_PENDING_KEY,
    false
  );

  if (usbRecoveryPreferences.isKey("attempt")) {
    usbRecoveryPreferences.remove("attempt");
  }
}

void setUsbRecoveryLoopActive(bool active) {
  if (usbRecoveryLoopActive == active) {
    return;
  }

  usbRecoveryLoopActive = active;
  if (usbRecoveryPreferencesReady) {
    usbRecoveryPreferences.putBool(USB_RECOVERY_NVS_PENDING_KEY, active);
  }
}

void clearUsbRecoveryPersistentState() {
  setUsbRecoveryLoopActive(false);
}

bool prepareUsbRecoveryHardwareReset() {
  setUsbRecoveryLoopActive(true);
  delay(35);
  return true;
}

bool performHardwareSelfReset(bool usbRecoveryReset) {
  if (usbRecoveryReset) {
    prepareUsbRecoveryHardwareReset();
  } else {
    clearUsbRecoveryPersistentState();
  }
  digitalWrite(SELF_RESET_PIN, SELF_RESET_ACTIVE_LEVEL);
  delay(SELF_RESET_FALLBACK_MS);
  digitalWrite(SELF_RESET_PIN, SELF_RESET_IDLE_LEVEL);
  delay(20);
  ESP.restart();

  while (true) {
    delay(1000);
  }

  return true;
}

void feedLoopWatchdog() {
  if (loopWatchdogActive) {
    esp_task_wdt_reset();
  }
}

void setupLoopWatchdog() {
  esp_err_t configResult = ESP_FAIL;

#if ESP_IDF_VERSION_MAJOR >= 5
  esp_task_wdt_config_t watchdogConfig = {};
  watchdogConfig.timeout_ms = LOOP_WATCHDOG_TIMEOUT_MS;
  watchdogConfig.idle_core_mask = 0;
  watchdogConfig.trigger_panic = true;
  configResult = esp_task_wdt_reconfigure(&watchdogConfig);
  if (configResult == ESP_ERR_INVALID_STATE) {
    configResult = esp_task_wdt_init(&watchdogConfig);
  }
#else
  configResult = esp_task_wdt_init(
    LOOP_WATCHDOG_TIMEOUT_MS / 1000UL,
    true
  );
  if (configResult == ESP_ERR_INVALID_STATE) {
    configResult = ESP_OK;
  }
#endif

  if (configResult != ESP_OK) {
    Serial.printf("Loop watchdog init failed: %d\n", static_cast<int>(configResult));
    return;
  }

  const esp_err_t addResult = esp_task_wdt_add(nullptr);
  if (addResult == ESP_OK || addResult == ESP_ERR_INVALID_ARG) {
    loopWatchdogActive = true;
    esp_task_wdt_reset();
    Serial.printf(
      "Loop watchdog active: %lu ms\n",
      static_cast<unsigned long>(LOOP_WATCHDOG_TIMEOUT_MS)
    );
  } else {
    Serial.printf("Loop watchdog add failed: %d\n", static_cast<int>(addResult));
  }
}

void sendUsbResponse(const String& status) {
  usbLastStatus = status;
  Serial.print("RSP:");
  Serial.println(status);
}

const char* decisionName() {
  switch (lastDecision) {
    case DECISION_OK: return "OK";
    case DECISION_NC: return "NC";
    default: return "NONE";
  }
}

const char* resetReasonName(esp_reset_reason_t reason) {
  switch (reason) {
    case ESP_RST_POWERON: return "POWERON";
    case ESP_RST_EXT: return "EXTERNAL";
    case ESP_RST_SW: return "SOFTWARE";
    case ESP_RST_PANIC: return "PANIC";
    case ESP_RST_INT_WDT: return "INT_WDT";
    case ESP_RST_TASK_WDT: return "TASK_WDT";
    case ESP_RST_WDT: return "WDT";
    case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
    case ESP_RST_BROWNOUT: return "BROWNOUT";
    case ESP_RST_SDIO: return "SDIO";
    default: return "UNKNOWN";
  }
}

uint8_t clampAudioByte(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return static_cast<uint8_t>(value);
}

bool audioSignalFresh(uint32_t now) {
  if (audioLastPacketAt == 0) return false;
  if (now - audioLastPacketAt > AUDIO_PACKET_TIMEOUT_MS) return false;
  return audioStreamActive;
}

uint8_t calculateAudioFlickerScale(uint32_t now) {
  if (!audioSignalFresh(now)) {
    return 255;
  }

  const uint8_t gatedLevel =
    audioLevel <= AUDIO_FLICKER_LEVEL_GATE
      ? 0
      : map(
          audioLevel,
          AUDIO_FLICKER_LEVEL_GATE + 1,
          255,
          0,
          AUDIO_FLICKER_LEVEL_RANGE
        );
  const uint8_t gatedPeak =
    audioPeak <= AUDIO_FLICKER_PEAK_GATE
      ? 0
      : map(
          audioPeak,
          AUDIO_FLICKER_PEAK_GATE + 1,
          255,
          0,
          AUDIO_FLICKER_PEAK_RANGE
        );
  uint8_t flickerScale = qadd8(
    AUDIO_FLICKER_MIN_SCALE,
    qadd8(gatedLevel, gatedPeak)
  );
  if (now < audioBeatUntil) {
    flickerScale = qadd8(flickerScale, AUDIO_FLICKER_BEAT_BOOST);
  }
  return flickerScale;
}

void clearAudioOverlayState() {
  audioLevel = 0;
  audioPeak = 0;
  audioLastPacketAt = 0;
  audioBeatUntil = 0;
  audioSequenceInitialized = false;
  audioStreamActive = false;
}

bool updateAudioFromUsbCommand(const String& command) {
  unsigned long sequenceValue = 0;
  int levelValue = 0;
  int peakValue = 0;
  int beatValue = 0;
  int activeValue = -1;

  const int parsedFields = sscanf(
      command.c_str(),
      "AUDIO:%lu:%d:%d:%d:%d",
      &sequenceValue,
      &levelValue,
      &peakValue,
      &beatValue,
      &activeValue
    );
  if (parsedFields < 4) {
    return false;
  }

  const uint32_t sequence = static_cast<uint32_t>(sequenceValue);
  if (
    audioSequenceInitialized &&
    static_cast<int32_t>(sequence - audioLastSequence) <= 0
  ) {
    return true;
  }

  const uint32_t now = millis();
  audioLastSequence = sequence;
  audioSequenceInitialized = true;
  audioLevel = clampAudioByte(levelValue);
  audioPeak = clampAudioByte(peakValue);
  audioStreamActive = parsedFields >= 5
    ? activeValue != 0
    : (
        audioLevel >= AUDIO_MIN_VISIBLE_LEVEL ||
        audioPeak >= AUDIO_MIN_VISIBLE_LEVEL ||
        beatValue != 0
      );
  audioLastPacketAt = now;
  if (beatValue != 0) {
    audioBeatUntil = now + AUDIO_BEAT_FLASH_MS;
  }
  return true;
}

void applyAudioOverlay(uint32_t now) {
  if (!audioSignalFresh(now)) {
    return;
  }

  const uint8_t flickerScale = calculateAudioFlickerScale(now);
  for (uint8_t i = 0; i < LED_COUNT; i++) {
    leds[i].nscale8_video(flickerScale);
  }
}

String buildUsbStatus() {
  String status = usbHostSeen ? "USB:CONNECTED" : "USB:WAITING";
  status += "|FW:PUBLIC_1.0";

  status += "|DECISION:";
  status += decisionName();
  if (animationMode == MODE_WAITING_FOR_MAC) {
    status += "|MODE:WAITING";
  } else if (animationMode == MODE_RESULT_PULSE) {
    status += "|MODE:RESULT";
  } else {
    status += "|MODE:NORMAL";
  }
  status += downloadSnakeRequested ? "|SNAKE:ON" : "|SNAKE:OFF";
  status += copySnakeRequested ? "|COPY:ON" : "|COPY:OFF";
  status += chatgptSnakeRequested ? "|CHATGPT:ON" : "|CHATGPT:OFF";
  status += appStoreSnakeRequested ? "|APPSTORE:ON" : "|APPSTORE:OFF";
  status += audioSignalFresh(millis()) ? "|AUDIO:ON" : "|AUDIO:OFF";
#if APPLEMACLED_NATIVE_HWCDC
  status += usbCdcPhysicalPlugged ? "|USB_PHY:ON" : "|USB_PHY:OFF";
  status += usbCdcConnected ? "|USB_CDC:ON" : "|USB_CDC:OFF";
  status += usbRecoveryAwaitingHandshake ? "|RECOVERY:WAIT" : "|RECOVERY:OK";
  status += "|RST:";
  status += resetReasonName(startupResetReason);
  status += "|BUSRST:";
  status += String(usbCdcBusResetEventCount);
  status += "/";
  status += String(usbCdcBusResetRecoveredCount);
  status += usbCdcBusResetSuspected ? "|BUSPEND:ON" : "|BUSPEND:OFF";
  status += "|REINIT:";
  status += String(usbRecoverySoftReinitCount);
  status += usbRecoveryLoopActive
    ? "|HARD:CONTINUOUS|CYCLE:PULSE_SNAKE"
    : "|HARD:CONTINUOUS|CYCLE:INITIAL";
  status += "|SELFRESET:GPIO16";
  status += usbRecoveryPreferencesReady ? ":NVS_OK" : ":NVS_ERR";
#endif
  return status;
}

void sendCurrentUsbStatus() {
  sendUsbResponse(buildUsbStatus());
}

void triggerDecision(NetworkDecision decision) {
  lastDecision = decision;
  downloadSnakeRequested = false;
  copySnakeRequested = false;
  chatgptSnakeRequested = false;
  appStoreSnakeRequested = false;
  downloadSnakeHeartbeatAt = 0;
  copySnakeHeartbeatAt = 0;
  chatgptSnakeHeartbeatAt = 0;
  appStoreSnakeHeartbeatAt = 0;
  resultPulseColor = decision == DECISION_OK
    ? CRGB(0, 255, 45)
    : CRGB(255, 0, 0);
  resultPulseStartedAt = millis();
  animationMode = MODE_RESULT_PULSE;
}

uint32_t waitModeStartedAt = 0;
uint32_t waitLastFrameAt = 0;
int32_t waitSnakeHead = 0;

void enterWaitingMode() {
  lastDecision = DECISION_NONE;
  downloadSnakeRequested = false;
  copySnakeRequested = false;
  chatgptSnakeRequested = false;
  appStoreSnakeRequested = false;
  downloadSnakeHeartbeatAt = 0;
  copySnakeHeartbeatAt = 0;
  chatgptSnakeHeartbeatAt = 0;
  appStoreSnakeHeartbeatAt = 0;
  const uint32_t now = millis();
  waitModeStartedAt = now;
  waitSnakeHead = 0;
  waitLastFrameAt = 0;
  animationMode = MODE_WAITING_FOR_MAC;
  CRGB background = CRGB::White;
  background.nscale8_video(WAIT_BACKGROUND_BRIGHTNESS);
  fill_solid(leds, LED_COUNT, background);
  FastLED.show();
}

void updateWaitingAnimation() {
  const uint32_t now = millis();
  if (now - waitLastFrameAt < FRAME_MS) {
    return;
  }
  waitLastFrameAt = now;
  const uint32_t elapsed = now - waitModeStartedAt;
  if (!usbRecoveryLoopActive) {
    const float progress = min(
      1.0f,
      static_cast<float>(elapsed) /
      static_cast<float>(USB_RECOVERY_INITIAL_GRACE_MS)
    );
    const float wave = (1.0f - cosf(progress * TWO_PI)) * 0.5f;
    const uint8_t brightness = static_cast<uint8_t>(
      WAIT_PULSE_MIN_BRIGHTNESS +
      wave * (WAIT_PULSE_MAX_BRIGHTNESS - WAIT_PULSE_MIN_BRIGHTNESS)
    );

    CRGB white = CRGB::White;
    white.nscale8_video(brightness);
    fill_solid(leds, LED_COUNT, white);
    FastLED.show();
    return;
  }

  if (elapsed < USB_RECOVERY_LOOP_PULSE_MS) {
    const float progress =
      static_cast<float>(elapsed) /
      static_cast<float>(USB_RECOVERY_LOOP_PULSE_MS);
    const float wave = (1.0f - cosf(progress * TWO_PI)) * 0.5f;
    const uint8_t brightness = static_cast<uint8_t>(
      WAIT_PULSE_MIN_BRIGHTNESS +
      wave * (WAIT_PULSE_MAX_BRIGHTNESS - WAIT_PULSE_MIN_BRIGHTNESS)
    );
    CRGB white = CRGB::White;
    white.nscale8_video(brightness);
    fill_solid(leds, LED_COUNT, white);
    FastLED.show();
    return;
  }

  const uint32_t snakeElapsed = elapsed - USB_RECOVERY_LOOP_PULSE_MS;
  const uint32_t rawStep = snakeElapsed / WAIT_SNAKE_STEP_MS;
  const uint32_t clampedStep = min(
    rawStep,
    static_cast<uint32_t>(LED_COUNT - 1)
  );
  waitSnakeHead = static_cast<int32_t>(clampedStep);

  CRGB background = CRGB::White;
  background.nscale8_video(WAIT_BACKGROUND_BRIGHTNESS);
  fill_solid(leds, LED_COUNT, background);

  for (uint8_t tailIndex = 0; tailIndex < WAIT_SNAKE_TAIL; tailIndex++) {
    int32_t pixel = waitSnakeHead - tailIndex;
    while (pixel < 0) {
      pixel += LED_COUNT;
    }
    pixel %= LED_COUNT;

    const int tailRange = WAIT_SNAKE_TAIL > 1 ? WAIT_SNAKE_TAIL - 1 : 1;
    const uint8_t brightness = map(
      tailIndex,
      0,
      tailRange,
      WAIT_HEAD_BRIGHTNESS,
      38
    );

    CRGB tailColor = CRGB::White;
    tailColor.nscale8_video(brightness);
    leds[pixel] += tailColor;
  }

  FastLED.show();
}

void updateResultPulse() {
  const uint32_t now = millis();
  const uint32_t elapsed = now - resultPulseStartedAt;

  if (elapsed >= RESULT_PULSE_MS) {
    animationMode = MODE_NORMAL;
    return;
  }

  const float progress =
    static_cast<float>(elapsed) / static_cast<float>(RESULT_PULSE_MS);
  const float wave = sinf(progress * PI);  // 0 -> 1 -> 0
  const uint8_t brightness = static_cast<uint8_t>(wave * MAX_BRIGHTNESS);

  CRGB output = resultPulseColor;
  output.nscale8_video(brightness);
  fill_solid(leds, LED_COUNT, output);
  FastLED.show();
}

uint8_t currentColorIndex = 0;
uint8_t nextColorIndex = 1;
uint32_t colorCycleStartedAt = 0;
uint32_t normalLastFrameAt = 0;

int32_t downloadSnakeHead = 0;
uint32_t downloadSnakeLastStepAt = 0;

int32_t copySnakeHead = 0;
uint32_t copySnakeLastStepAt = 0;
uint32_t copySnakePauseUntil = 0;
bool copySnakePaused = false;

int32_t chatgptSnakeHead = 0;
uint32_t chatgptSnakeLastStepAt = 0;
uint32_t chatgptSnakePauseUntil = 0;
bool chatgptSnakePaused = false;

int32_t appStoreSnakeHead = 0;
uint32_t appStoreSnakeLastStepAt = 0;
uint32_t appStoreSnakePauseUntil = 0;
bool appStoreSnakePaused = false;

void resetNormalAnimation() {
  currentColorIndex = COLOR_COUNT > 1
    ? 1 + static_cast<uint8_t>(esp_random() % (COLOR_COUNT - 1))
    : 0;
  nextColorIndex = (currentColorIndex + 1) % COLOR_COUNT;
  colorCycleStartedAt = millis();
  normalLastFrameAt = 0;
  downloadSnakeHead = 0;
  downloadSnakeLastStepAt = millis();
  copySnakeHead = 0;
  copySnakeLastStepAt = millis();
  copySnakePauseUntil = 0;
  copySnakePaused = false;
  chatgptSnakeHead = 0;
  chatgptSnakeLastStepAt = millis();
  chatgptSnakePauseUntil = 0;
  chatgptSnakePaused = false;
  appStoreSnakeHead = 0;
  appStoreSnakeLastStepAt = millis();
  appStoreSnakePauseUntil = 0;
  appStoreSnakePaused = false;
  downloadSnakeHeartbeatAt = 0;
  copySnakeHeartbeatAt = 0;
  chatgptSnakeHeartbeatAt = 0;
  appStoreSnakeHeartbeatAt = 0;
}

CRGB getCurrentColor(uint32_t now) {
  const uint32_t fullStageMs = COLOR_HOLD_MS + COLOR_FADE_MS;
  uint32_t elapsed = now - colorCycleStartedAt;

  while (elapsed >= fullStageMs) {
    currentColorIndex = nextColorIndex;
    nextColorIndex = (nextColorIndex + 1) % COLOR_COUNT;
    colorCycleStartedAt += fullStageMs;
    elapsed = now - colorCycleStartedAt;
  }

  if (elapsed < COLOR_HOLD_MS) {
    return palette[currentColorIndex];
  }

  const uint32_t fadeElapsed = elapsed - COLOR_HOLD_MS;
  const uint8_t amount = static_cast<uint8_t>(
    (fadeElapsed * 255UL) / COLOR_FADE_MS
  );

  return blend(palette[currentColorIndex], palette[nextColorIndex], amount);
}

uint8_t getPulseBrightness(uint32_t now) {
  const uint32_t elapsed = now - colorCycleStartedAt;
  const float phase =
    (static_cast<float>(elapsed % PULSE_PERIOD_MS) /
     static_cast<float>(PULSE_PERIOD_MS)) * TWO_PI;

  const float wave = (cosf(phase) + 1.0f) * 0.5f;

  return static_cast<uint8_t>(
    MIN_BRIGHTNESS + wave * (MAX_BRIGHTNESS - MIN_BRIGHTNESS)
  );
}

void renderPulse(const CRGB& baseColor, uint8_t brightness) {
  CRGB output = baseColor;
  output.nscale8_video(brightness);
  fill_solid(leds, LED_COUNT, output);
}

void advanceDownloadSnake(uint32_t now) {
  while (now - downloadSnakeLastStepAt >= DOWNLOAD_SNAKE_STEP_MS) {
    downloadSnakeLastStepAt += DOWNLOAD_SNAKE_STEP_MS;
    downloadSnakeHead = (downloadSnakeHead + 1) % LED_COUNT;
  }
}

void renderDownloadSnake(const CRGB& baseColor, uint8_t pulseBrightness) {
  CRGB background = baseColor;
  uint8_t backgroundBrightness = pulseBrightness / 10;
  if (backgroundBrightness < 3) {
    backgroundBrightness = 3;
  }
  background.nscale8_video(backgroundBrightness);
  fill_solid(leds, LED_COUNT, background);

  for (uint8_t tailIndex = 0;
       tailIndex < DOWNLOAD_SNAKE_TAIL;
       tailIndex++) {
    int32_t pixel = downloadSnakeHead - tailIndex;
    while (pixel < 0) {
      pixel += LED_COUNT;
    }
    pixel %= LED_COUNT;

    const int tailRange =
      DOWNLOAD_SNAKE_TAIL > 1 ? DOWNLOAD_SNAKE_TAIL - 1 : 1;
    const uint8_t tailBrightness = map(
      tailIndex,
      0,
      tailRange,
      MAX_BRIGHTNESS,
      8
    );

    CRGB pixelColor = baseColor;
    pixelColor.nscale8_video(tailBrightness);
    leds[pixel] += pixelColor;
  }
}

void resetCopySnakePass(uint32_t now) {
  copySnakeHead = 0;
  copySnakeLastStepAt = now;
  copySnakePaused = false;
}

void advanceCopySnake(uint32_t now) {
  if (copySnakePaused) {
    if (static_cast<int32_t>(now - copySnakePauseUntil) >= 0) {
      resetCopySnakePass(now);
    }
    return;
  }

  while (now - copySnakeLastStepAt >= COPY_SNAKE_STEP_MS) {
    copySnakeLastStepAt += COPY_SNAKE_STEP_MS;
    copySnakeHead++;

    if (copySnakeHead >= LED_COUNT + COPY_SNAKE_TAIL) {
      copySnakePaused = true;
      copySnakePauseUntil = now + COPY_SNAKE_PAUSE_MS;
      break;
    }
  }
}

void renderCopySnake(const CRGB& baseColor) {
  (void)baseColor;
  CRGB background = COPY_SNAKE_COLOR;
  background.nscale8_video(COPY_BACKGROUND_LEVEL);
  fill_solid(leds, LED_COUNT, background);
  if (copySnakePaused) {
    return;
  }

  for (uint8_t tailIndex = 0; tailIndex < COPY_SNAKE_TAIL; tailIndex++) {
    const int32_t pixel = copySnakeHead - tailIndex;
    if (pixel < 0 || pixel >= LED_COUNT) {
      continue;
    }

    const int tailRange = COPY_SNAKE_TAIL > 1 ? COPY_SNAKE_TAIL - 1 : 1;
    const uint8_t tailBrightness = map(
      tailIndex,
      0,
      tailRange,
      COPY_HEAD_BRIGHTNESS,
      COPY_TAIL_MIN_BRIGHTNESS
    );

    CRGB pixelColor = COPY_SNAKE_COLOR;
    pixelColor.nscale8_video(tailBrightness);
    leds[pixel] += pixelColor;
  }
}

void resetChatGPTSnakePass(uint32_t now) {
  chatgptSnakeHead = 0;
  chatgptSnakeLastStepAt = now;
  chatgptSnakePaused = false;
}

void advanceChatGPTSnake(uint32_t now) {
  if (chatgptSnakePaused) {
    if (static_cast<int32_t>(now - chatgptSnakePauseUntil) >= 0) {
      resetChatGPTSnakePass(now);
    }
    return;
  }

  while (now - chatgptSnakeLastStepAt >= CHATGPT_SNAKE_STEP_MS) {
    chatgptSnakeLastStepAt += CHATGPT_SNAKE_STEP_MS;
    chatgptSnakeHead++;

    if (chatgptSnakeHead >= LED_COUNT + CHATGPT_SNAKE_TAIL) {
      chatgptSnakePaused = true;
      chatgptSnakePauseUntil = now + CHATGPT_SNAKE_PAUSE_MS;
      break;
    }
  }
}

void renderChatGPTSnake() {
  CRGB background = CHATGPT_SNAKE_COLOR;
  background.nscale8_video(CHATGPT_BACKGROUND_LEVEL);
  fill_solid(leds, LED_COUNT, background);

  if (chatgptSnakePaused) {
    return;
  }

  for (uint8_t tailIndex = 0; tailIndex < CHATGPT_SNAKE_TAIL; tailIndex++) {
    const int32_t pixel = chatgptSnakeHead - tailIndex;
    if (pixel < 0 || pixel >= LED_COUNT) {
      continue;
    }

    const int tailRange = CHATGPT_SNAKE_TAIL > 1 ? CHATGPT_SNAKE_TAIL - 1 : 1;
    const uint8_t tailBrightness = map(
      tailIndex,
      0,
      tailRange,
      CHATGPT_HEAD_BRIGHTNESS,
      CHATGPT_TAIL_MIN_BRIGHTNESS
    );

    CRGB pixelColor = CHATGPT_SNAKE_COLOR;
    pixelColor.nscale8_video(tailBrightness);
    leds[pixel] += pixelColor;
  }
}

CRGB getAuroraColor(uint8_t phase) {
  const CRGB green = CRGB(0, 255, 150);
  const CRGB cyan = CRGB(0, 210, 255);
  const CRGB blue = CRGB(45, 90, 255);
  const CRGB violet = CRGB(180, 55, 255);

  if (phase < 64) {
    return blend(green, cyan, phase * 4);
  }
  if (phase < 128) {
    return blend(cyan, blue, (phase - 64) * 4);
  }
  if (phase < 192) {
    return blend(blue, violet, (phase - 128) * 4);
  }
  return blend(violet, green, (phase - 192) * 4);
}

void resetAppStoreSnakePass(uint32_t now) {
  appStoreSnakeHead = 0;
  appStoreSnakeLastStepAt = now;
  appStoreSnakePaused = false;
}

void advanceAppStoreSnake(uint32_t now) {
  if (appStoreSnakePaused) {
    if (static_cast<int32_t>(now - appStoreSnakePauseUntil) >= 0) {
      resetAppStoreSnakePass(now);
    }
    return;
  }

  while (now - appStoreSnakeLastStepAt >= APPSTORE_SNAKE_STEP_MS) {
    appStoreSnakeLastStepAt += APPSTORE_SNAKE_STEP_MS;
    appStoreSnakeHead++;
    if (appStoreSnakeHead >= LED_COUNT + APPSTORE_SNAKE_TAIL) {
      appStoreSnakePaused = true;
      appStoreSnakePauseUntil = now + APPSTORE_SNAKE_PAUSE_MS;
      break;
    }
  }
}

void renderAppStoreSnake(uint32_t now) {
  const uint8_t movement = static_cast<uint8_t>((now / 22UL) & 0xFF);
  for (uint16_t pixel = 0; pixel < LED_COUNT; pixel++) {
    CRGB background = getAuroraColor(
      static_cast<uint8_t>(movement + pixel * (256 / LED_COUNT))
    );
    background.nscale8_video(APPSTORE_BACKGROUND_LEVEL);
    leds[pixel] = background;
  }

  if (appStoreSnakePaused) {
    return;
  }

  for (uint8_t tailIndex = 0; tailIndex < APPSTORE_SNAKE_TAIL; tailIndex++) {
    const int32_t pixel = appStoreSnakeHead - tailIndex;
    if (pixel < 0 || pixel >= LED_COUNT) {
      continue;
    }

    const int tailRange = APPSTORE_SNAKE_TAIL > 1 ? APPSTORE_SNAKE_TAIL - 1 : 1;
    const uint8_t brightness = map(
      tailIndex,
      0,
      tailRange,
      APPSTORE_HEAD_BRIGHTNESS,
      APPSTORE_TAIL_MIN_BRIGHTNESS
    );
    CRGB color = getAuroraColor(
      static_cast<uint8_t>(movement + pixel * (256 / LED_COUNT) + tailIndex * 8)
    );
    color.nscale8_video(brightness);
    leds[pixel] += color;
  }
}

void startSystemBlueSequence() {
  systemBlueSequenceStartedAt = millis();
  systemBlueSequenceActive = true;
}

void queueSystemBlueSequence() {
  if (trashFlashActive || systemBlueSequenceActive) {
    if (systemBluePendingCount < 4) {
      systemBluePendingCount++;
    }
    return;
  }
  startSystemBlueSequence();
}

void triggerTrashFlash() {
  if (systemBlueSequenceActive) {
    systemBlueSequenceActive = false;
    if (systemBluePendingCount < 4) {
      systemBluePendingCount++;
    }
  }
  trashFlashStartedAt = millis();
  trashFlashActive = true;
}

bool updateTrashFlashOverlay() {
  if (!trashFlashActive) {
    return false;
  }

  const uint32_t now = millis();
  const uint32_t cycleMs = TRASH_FLASH_ON_MS + TRASH_FLASH_OFF_MS;
  const uint32_t totalMs = static_cast<uint32_t>(TRASH_FLASH_COUNT) * cycleMs;
  const uint32_t elapsed = now - trashFlashStartedAt;

  if (elapsed >= totalMs) {
    trashFlashActive = false;
    FastLED.clear(true);
    return false;
  }

  const uint32_t phase = elapsed % cycleMs;
  if (phase < TRASH_FLASH_ON_MS) {
    fill_solid(leds, LED_COUNT, TRASH_FLASH_COLOR);
  } else {
    fill_solid(leds, LED_COUNT, CRGB::Black);
  }
  FastLED.show();
  return true;
}

bool updateSystemBlueOverlay() {
  if (trashFlashActive) {
    return false;
  }

  if (!systemBlueSequenceActive) {
    if (systemBluePendingCount == 0) {
      return false;
    }
    systemBluePendingCount--;
    startSystemBlueSequence();
  }

  const uint32_t now = millis();
  const uint32_t elapsed = now - systemBlueSequenceStartedAt;
  const uint32_t snakeSteps =
    static_cast<uint32_t>(LED_COUNT) + SYSTEM_BLUE_SNAKE_TAIL;
  const uint32_t snakeDuration =
    snakeSteps * SYSTEM_BLUE_SNAKE_STEP_MS;
  const uint32_t flashCycle =
    SYSTEM_BLUE_FLASH_ON_MS + SYSTEM_BLUE_FLASH_OFF_MS;
  const uint32_t totalDuration =
    snakeDuration
    + SYSTEM_BLUE_AFTER_SNAKE_PAUSE_MS
    + static_cast<uint32_t>(SYSTEM_BLUE_FLASH_COUNT) * flashCycle;

  if (elapsed >= totalDuration) {
    systemBlueSequenceActive = false;
    FastLED.clear(true);
    if (systemBluePendingCount > 0) {
      systemBluePendingCount--;
      startSystemBlueSequence();
      return true;
    }
    return false;
  }

  if (elapsed < snakeDuration) {
    CRGB background = SYSTEM_BLUE_COLOR;
    background.nscale8_video(SYSTEM_BLUE_BACKGROUND_LEVEL);
    fill_solid(leds, LED_COUNT, background);

    const int32_t head =
      static_cast<int32_t>(elapsed / SYSTEM_BLUE_SNAKE_STEP_MS);
    for (uint8_t tailIndex = 0;
         tailIndex < SYSTEM_BLUE_SNAKE_TAIL;
         tailIndex++) {
      const int32_t pixel = head - tailIndex;
      if (pixel < 0 || pixel >= LED_COUNT) {
        continue;
      }

      const int tailRange =
        SYSTEM_BLUE_SNAKE_TAIL > 1 ? SYSTEM_BLUE_SNAKE_TAIL - 1 : 1;
      const uint8_t brightness = map(
        tailIndex,
        0,
        tailRange,
        SYSTEM_BLUE_HEAD_BRIGHTNESS,
        SYSTEM_BLUE_TAIL_MIN_BRIGHTNESS
      );

      CRGB pixelColor = SYSTEM_BLUE_COLOR;
      pixelColor.nscale8_video(brightness);
      leds[pixel] += pixelColor;
    }
  } else if (
    elapsed < snakeDuration + SYSTEM_BLUE_AFTER_SNAKE_PAUSE_MS
  ) {
    fill_solid(leds, LED_COUNT, CRGB::Black);
  } else {
    const uint32_t flashElapsed =
      elapsed - snakeDuration - SYSTEM_BLUE_AFTER_SNAKE_PAUSE_MS;
    const uint32_t flashPhase = flashElapsed % flashCycle;
    if (flashPhase < SYSTEM_BLUE_FLASH_ON_MS) {
      fill_solid(leds, LED_COUNT, SYSTEM_BLUE_COLOR);
    } else {
      fill_solid(leds, LED_COUNT, CRGB::Black);
    }
  }

  FastLED.show();
  return true;
}

void updateNormalAnimation() {
  const uint32_t now = millis();
  if (now - normalLastFrameAt < FRAME_MS) {
    return;
  }
  normalLastFrameAt = now;
  if (
    appStoreSnakeRequested &&
    now - appStoreSnakeHeartbeatAt >= SNAKE_COMMAND_TIMEOUT_MS
  ) {
    appStoreSnakeRequested = false;
    appStoreSnakePaused = false;
    Serial.println("APPSTORE snake watchdog: OFF");
  }

  if (
    chatgptSnakeRequested &&
    now - chatgptSnakeHeartbeatAt >= SNAKE_COMMAND_TIMEOUT_MS
  ) {
    chatgptSnakeRequested = false;
    chatgptSnakePaused = false;
    Serial.println("CHATGPT snake watchdog: OFF");
  }

  if (
    copySnakeRequested &&
    now - copySnakeHeartbeatAt >= SNAKE_COMMAND_TIMEOUT_MS
  ) {
    copySnakeRequested = false;
    copySnakePaused = false;
    Serial.println("COPY snake watchdog: OFF");
  }

  if (
    downloadSnakeRequested &&
    now - downloadSnakeHeartbeatAt >= SNAKE_COMMAND_TIMEOUT_MS
  ) {
    downloadSnakeRequested = false;
    Serial.println("DOWNLOAD snake watchdog: OFF");
  }

  const CRGB currentColor = getCurrentColor(now);
  const uint8_t pulseBrightness = getPulseBrightness(now);

  if (appStoreSnakeRequested) {
    advanceAppStoreSnake(now);
    renderAppStoreSnake(now);
  } else if (chatgptSnakeRequested) {
    advanceChatGPTSnake(now);
    renderChatGPTSnake();
  } else if (copySnakeRequested) {
    advanceCopySnake(now);
    renderCopySnake(currentColor);
  } else if (downloadSnakeRequested) {
    advanceDownloadSnake(now);
    renderDownloadSnake(currentColor, pulseBrightness);
  } else {
    renderPulse(currentColor, pulseBrightness);
  }

  applyAudioOverlay(now);
  FastLED.show();
}


void processUsbCommand(String command) {
  command.trim();
  if (command.isEmpty()) return;

  if (command.startsWith("CMD:")) {
    command.remove(0, 4);
    command.trim();
  }
  if (command.isEmpty()) return;

  if (usbCdcBusResetSuspected) {
    usbCdcBusResetSuspected = false;
    usbCdcBusResetSuspectedAt = 0;
    usbCdcBusResetRecoveredCount++;
  }

  usbHostSeen = true;
  usbEverConnected = true;
  usbLastActivityAt = millis();
  usbRecoveryAwaitingHandshake = false;
  usbRecoveryCycleStartedAt = 0;
  usbRecoveryLastActionAt = 0;
  usbRecoverySoftReinitCount = 0;

  clearUsbRecoveryPersistentState();
  if (restartPending && restartPendingIsUsbRecovery) {
    restartPending = false;
    restartPendingIsUsbRecovery = false;
    restartPendingUseHardwareReset = false;
  }
#if APPLEMACLED_NATIVE_HWCDC
  usbCdcPhysicalPlugged = Serial.isPlugged();
  usbCdcConnected = true;
#endif

  if (command.startsWith("AUDIO:")) {
    updateAudioFromUsbCommand(command);
    return;
  }

  if (command.equalsIgnoreCase("AUDIO_CLEAR")) {
    clearAudioOverlayState();
    sendUsbResponse("AUDIO_CLEAR");
    return;
  }

  if (command.equalsIgnoreCase("HELLO")) {
    clearAudioOverlayState();
    sendUsbResponse("HELLO:APPLEMAC_LED_USB:1");
    return;
  }

  if (command.equalsIgnoreCase("STATUS")) {
    sendCurrentUsbStatus();
    return;
  }

  if (command.equalsIgnoreCase("PING")) {
    sendUsbResponse("PONG");
    return;
  }

  String normalized = command;
  normalized.toUpperCase();

  if (normalized == "WAIT") {
    enterWaitingMode();
    sendUsbResponse("WAIT");
    return;
  }

  if (normalized == "OK") {
    triggerDecision(DECISION_OK);
    resetNormalAnimation();
    sendUsbResponse("OK");
    return;
  }

  if (normalized == "NC") {
    triggerDecision(DECISION_NC);
    resetNormalAnimation();
    sendUsbResponse("NC");
    return;
  }

  if (normalized == "SNAKE_ON") {
    const uint32_t commandAt = millis();
    if (!downloadSnakeRequested) downloadSnakeLastStepAt = commandAt;
    downloadSnakeRequested = true;
    downloadSnakeHeartbeatAt = commandAt;
    sendUsbResponse("SNAKE_ON");
    return;
  }

  if (normalized == "SNAKE_OFF") {
    downloadSnakeRequested = false;
    downloadSnakeHeartbeatAt = 0;
    sendUsbResponse("SNAKE_OFF");
    return;
  }

  if (normalized == "COPY_ON") {
    const uint32_t commandAt = millis();
    if (!copySnakeRequested) resetCopySnakePass(commandAt);
    copySnakeRequested = true;
    copySnakeHeartbeatAt = commandAt;
    sendUsbResponse("COPY_ON");
    return;
  }

  if (normalized == "COPY_OFF") {
    copySnakeRequested = false;
    copySnakeHeartbeatAt = 0;
    copySnakePaused = false;
    sendUsbResponse("COPY_OFF");
    return;
  }

  if (normalized == "CHATGPT_ON") {
    const uint32_t commandAt = millis();
    if (!chatgptSnakeRequested) resetChatGPTSnakePass(commandAt);
    chatgptSnakeRequested = true;
    chatgptSnakeHeartbeatAt = commandAt;
    sendUsbResponse("CHATGPT_ON");
    return;
  }

  if (normalized == "CHATGPT_OFF") {
    chatgptSnakeRequested = false;
    chatgptSnakeHeartbeatAt = 0;
    chatgptSnakePaused = false;
    sendUsbResponse("CHATGPT_OFF");
    return;
  }

  if (normalized == "APPSTORE_ON") {
    const uint32_t commandAt = millis();
    if (!appStoreSnakeRequested) resetAppStoreSnakePass(commandAt);
    appStoreSnakeRequested = true;
    appStoreSnakeHeartbeatAt = commandAt;
    sendUsbResponse("APPSTORE_ON");
    return;
  }

  if (normalized == "APPSTORE_OFF") {
    appStoreSnakeRequested = false;
    appStoreSnakeHeartbeatAt = 0;
    appStoreSnakePaused = false;
    sendUsbResponse("APPSTORE_OFF");
    return;
  }

  if (normalized == "TRASH_FLASH") {
    triggerTrashFlash();
    sendUsbResponse("TRASH_FLASH");
    return;
  }

  if (normalized == "SYSTEM_BLUE") {
    queueSystemBlueSequence();
    sendUsbResponse("SYSTEM_BLUE");
    return;
  }

  if (normalized == "REBOOT") {
    sendUsbResponse("REBOOTING:HARD_GPIO16");
    scheduleRestart(900, false, true);
    return;
  }

  sendUsbResponse("ERROR:UNKNOWN_COMMAND");
}

void processUsbSerial() {
  while (Serial.available() > 0) {
    const char incoming = static_cast<char>(Serial.read());

    if (incoming == '\r') continue;
    if (incoming == '\n') {
      if (usbCommandLength > 0) {
        usbCommandBuffer[usbCommandLength] = '\0';
        processUsbCommand(String(usbCommandBuffer));
        usbCommandLength = 0;
      }
      continue;
    }

    if (usbCommandLength + 1 < USB_COMMAND_MAX) {
      usbCommandBuffer[usbCommandLength++] = incoming;
    } else {
      usbCommandLength = 0;
      sendUsbResponse("ERROR:COMMAND_TOO_LONG");
    }
  }
}

#if APPLEMACLED_NATIVE_HWCDC
static void usbCdcEventCallback(
  void* arg,
  esp_event_base_t eventBase,
  int32_t eventId,
  void* eventData
) {
  (void)arg;
  (void)eventData;
  if (eventBase != ARDUINO_HW_CDC_EVENTS) return;

  if (eventId == ARDUINO_HW_CDC_BUS_RESET_EVENT) {
    usbCdcBusResetEventPending = true;
  } else if (
    eventId == ARDUINO_HW_CDC_CONNECTED_EVENT ||
    eventId == ARDUINO_HW_CDC_RX_EVENT
  ) {
    usbCdcTrafficEventPending = true;
  }
}
#endif

void initializeUsbSerialTransport(bool forceReenumeration) {
#if APPLEMACLED_NATIVE_HWCDC
  if (forceReenumeration) {
    Serial.flush();
    Serial.end();
    feedLoopWatchdog();
    delay(160);
  }

  Serial.setRxBufferSize(USB_CDC_RX_BUFFER_SIZE);
  Serial.setTxBufferSize(USB_CDC_TX_BUFFER_SIZE);
  Serial.setTxTimeoutMs(USB_CDC_TX_TIMEOUT_MS);
  Serial.onEvent(usbCdcEventCallback);
  Serial.begin(USB_SERIAL_BAUD);

  if (forceReenumeration) {
    delay(220);
    feedLoopWatchdog();
  }

  usbCdcPhysicalPlugged = Serial.isPlugged();
  usbCdcConnected = Serial.isConnected();
#else
  (void)forceReenumeration;
  Serial.begin(USB_SERIAL_BAUD);
#endif
}

void clearUsbDrivenStateForReconnect() {
  usbCommandLength = 0;
  usbHostSeen = false;
  usbLastActivityAt = 0;
  lastDecision = DECISION_NONE;

  downloadSnakeRequested = false;
  copySnakeRequested = false;
  chatgptSnakeRequested = false;
  appStoreSnakeRequested = false;
  downloadSnakeHeartbeatAt = 0;
  copySnakeHeartbeatAt = 0;
  chatgptSnakeHeartbeatAt = 0;
  appStoreSnakeHeartbeatAt = 0;
  copySnakePaused = false;
  chatgptSnakePaused = false;
  appStoreSnakePaused = false;
  clearAudioOverlayState();

  enterWaitingMode();
}

void beginUsbRecoveryCycle(uint32_t now) {
  if (!usbRecoveryAwaitingHandshake) {
    clearUsbDrivenStateForReconnect();
  }
  usbRecoveryAwaitingHandshake = true;
  if (usbRecoveryCycleStartedAt == 0) {
    usbRecoveryCycleStartedAt = now;
  }
}

void processUsbRecovery() {
#if !APPLEMACLED_NATIVE_HWCDC
  return;
#else
  const uint32_t now = millis();
  if (now - usbRecoveryLastPollAt < USB_RECOVERY_POLL_MS) return;
  usbRecoveryLastPollAt = now;

  if (usbCdcBusResetEventPending) {
    usbCdcBusResetEventPending = false;
    usbCdcBusResetEventCount++;
    if (!usbCdcBusResetSuspected) {
      usbCdcBusResetSuspected = true;
      usbCdcBusResetSuspectedAt = now;
    }
  }

  const bool plugged = Serial.isPlugged();
  const bool connected = Serial.isConnected();

  if (usbCdcTrafficEventPending) {
    usbCdcTrafficEventPending = false;
    usbCdcConnected = true;
    if (usbCdcBusResetSuspected) {
      usbCdcBusResetSuspected = false;
      usbCdcBusResetSuspectedAt = 0;
      usbCdcBusResetRecoveredCount++;
    }
  } else {
    usbCdcConnected = connected;
  }

  if (usbCdcPhysicalPlugged != plugged) {
    usbCdcPhysicalPlugged = plugged;
    usbCdcConnected = connected;
    usbCdcBusResetSuspected = false;
    usbCdcBusResetSuspectedAt = 0;
    beginUsbRecoveryCycle(now);
  }

  if (
    usbCdcBusResetSuspected &&
    now - usbCdcBusResetSuspectedAt >= USB_BUS_RESET_CONFIRM_MS
  ) {
    const uint32_t suspectedAt = usbCdcBusResetSuspectedAt;
    usbCdcBusResetSuspected = false;
    usbCdcBusResetSuspectedAt = 0;
    usbCdcConnected = connected;
    beginUsbRecoveryCycle(suspectedAt);
  }

  if (!usbRecoveryAwaitingHandshake) return;

  if (usbRecoveryCycleStartedAt == 0) {
    usbRecoveryCycleStartedAt = now;
  }

  (void)plugged;

  const uint32_t cycleElapsed = now - usbRecoveryCycleStartedAt;
  const uint32_t restartDelay = usbRecoveryLoopActive
    ? USB_RECOVERY_LOOP_PULSE_MS + USB_RECOVERY_LOOP_SNAKE_MS
    : USB_RECOVERY_INITIAL_GRACE_MS;

  if (
    cycleElapsed >= restartDelay &&
    !restartPending
  ) {
    scheduleRestart(USB_RECOVERY_RESET_ARM_DELAY_MS, true, true);
  }
#endif
}



void setup() {
  setupSelfResetHardware();
  startupResetReason = esp_reset_reason();
  initializeUsbRecoveryPersistentState();
  initializeUsbSerialTransport(false);
  delay(300);
  FastLED.addLeds<LED_TYPE, LED_PIN, COLOR_ORDER>(leds, LED_COUNT)
         .setCorrection(TypicalLEDStrip);
  FastLED.setBrightness(255);
  FastLED.clear(true);
  resetNormalAnimation();
  enterWaitingMode();
  setupLoopWatchdog();
  Serial.println();
  Serial.printf(
    "Reset reason: %s (%d)\n",
    resetReasonName(startupResetReason),
    static_cast<int>(startupResetReason)
  );
  Serial.printf(
    "USB continuous recovery cycle: %s\n",
    usbRecoveryLoopActive ? "PULSE_SNAKE" : "INITIAL"
  );
  Serial.println("AppleMAC-LED public firmware 1.0 started");
  Serial.println("USB Serial transport: active, 115200 baud");
  Serial.println("Waiting for USB agent WAIT/OK");
  sendUsbResponse("BOOT:APPLEMAC_LED_USB:1:GPIO16_SELF_RESET=1:CONTINUOUS=1");
}

void loop() {
  feedLoopWatchdog();

  processUsbSerial();
  processUsbRecovery();

  if (updateTrashFlashOverlay()) {
    delay(1);
    return;
  }

  if (updateSystemBlueOverlay()) {
    delay(1);
    return;
  }

  switch (animationMode) {
    case MODE_WAITING_FOR_MAC:
      updateWaitingAnimation();
      break;

    case MODE_RESULT_PULSE:
      updateResultPulse();
      if (animationMode == MODE_NORMAL) {
        resetNormalAnimation();
      }
      break;

    case MODE_NORMAL:
      updateNormalAnimation();
      break;
  }

  if (restartPending && static_cast<int32_t>(millis() - restartAt) >= 0) {
    const bool useHardwareReset = restartPendingUseHardwareReset;
    const bool usbRecoveryReset = restartPendingIsUsbRecovery;

    if (useHardwareReset) {
      if (!performHardwareSelfReset(usbRecoveryReset)) {
        restartPending = false;
        restartPendingIsUsbRecovery = false;
        restartPendingUseHardwareReset = false;
        return;
      }
    }

    restartPending = false;
    restartPendingIsUsbRecovery = false;
    restartPendingUseHardwareReset = false;
    delay(20);
    ESP.restart();
  }

  feedLoopWatchdog();
  delay(1);
}
