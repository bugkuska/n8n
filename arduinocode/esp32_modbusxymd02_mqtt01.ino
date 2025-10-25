// ================== ESP32 + XY-MD02 (Modbus RTU Auto-Direction) + MQTT ==================
#include <WiFi.h>
#include <WiFiClient.h>
#include <PubSubClient.h>
#include <WiFiManager.h>
#include <Preferences.h>
#include <SimpleTimer.h>
#include <ModbusMaster.h>

// -------------------- RS-485 (UART2) --------------------
#define RS485_RX 16   // RO → ESP32 RX2
#define RS485_TX 17   // DI → ESP32 TX2

// -------------------- Device / LED --------------------
#define CONFIG_PIN 0   // ปุ่ม BOOT ใช้เปิด Config Portal
#define LED_PIN    2   // LED แสดงสถานะ MQTT

// -------------------- Globals --------------------
WiFiClient espClient;
PubSubClient mqtt(espClient);
SimpleTimer timer;
Preferences prefs;

// Modbus
ModbusMaster node;
const uint8_t SLAVE_ID = 1;

// NVS keys
const char* NVS_NS         = "settings";
const char* KEY_MQTT_HOST  = "mqtt_host";
const char* KEY_MQTT_PORT  = "mqtt_port";
const char* KEY_MQTT_USER  = "mqtt_user";
const char* KEY_MQTT_PASS  = "mqtt_pass";
const char* KEY_MQTT_TOPIC = "mqtt_topic";

// WiFiManager buffers
char buf_mqtt_host[64] = "";
char buf_mqtt_port[8]  = "1883";
char buf_mqtt_user[40] = "";
char buf_mqtt_pass[40] = "";
char buf_mqtt_topic[40]= "xy-md02";

// Poll interval (ms)
volatile unsigned long gInterval = 5000;

void startConfigPortalIfNeeded(bool force = false);
void loadConfigFromNVS();
void saveConfigToNVS();
void connectMQTT();
void readXY_and_publish();
void updateLed() { digitalWrite(LED_PIN, mqtt.connected() ? HIGH : LOW); }

// ================== SETUP ==================
void setup() {
  Serial.begin(115200);
  delay(200);

  pinMode(CONFIG_PIN, INPUT_PULLUP);
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  // UART2 สำหรับ RS-485 Auto-direction
  Serial2.begin(9600, SERIAL_8N1, RS485_RX, RS485_TX);

  // Modbus Master
  node.begin(SLAVE_ID, Serial2);
  node.setTimeout(200);   // ms

  // โหลด MQTT config
  loadConfigFromNVS();

  // ตรวจสอบว่าต้องเปิด Config Portal หรือไม่
  bool bootButtonHeld = (digitalRead(CONFIG_PIN) == LOW);
  unsigned long t0 = millis();
  while (bootButtonHeld && (millis() - t0 < 3000)) {
    if (digitalRead(CONFIG_PIN) != LOW) { bootButtonHeld = false; break; }
    delay(10);
  }
  bool needPortal = bootButtonHeld || (strlen(buf_mqtt_host) == 0);
  startConfigPortalIfNeeded(needPortal);

  mqtt.setServer(buf_mqtt_host, atoi(buf_mqtt_port));

  // ตั้งเวลาอ่านทุก 5 วินาที
  timer.setInterval(gInterval, readXY_and_publish);

  Serial.println("System ready.");
}

// ================== LOOP ==================
void loop() {
  if (!mqtt.connected()) connectMQTT();
  mqtt.loop();
  updateLed();
  timer.run();
}

// ================== WiFiManager + NVS ==================
void startConfigPortalIfNeeded(bool force) {
  WiFiManager wm;
  wm.setDebugOutput(true);

  WiFiManagerParameter p_mqtt_host("mqtt_host", "MQTT host (IP/hostname)", buf_mqtt_host, sizeof(buf_mqtt_host));
  WiFiManagerParameter p_mqtt_port("mqtt_port", "MQTT port", buf_mqtt_port, sizeof(buf_mqtt_port));
  WiFiManagerParameter p_mqtt_user("mqtt_user", "MQTT user", buf_mqtt_user, sizeof(buf_mqtt_user));
  WiFiManagerParameter p_mqtt_pass("mqtt_pass", "MQTT pass", buf_mqtt_pass, sizeof(buf_mqtt_pass));
  WiFiManagerParameter p_mqtt_topic("mqtt_topic", "MQTT topic", buf_mqtt_topic, sizeof(buf_mqtt_topic));

  wm.addParameter(&p_mqtt_host);
  wm.addParameter(&p_mqtt_port);
  wm.addParameter(&p_mqtt_user);
  wm.addParameter(&p_mqtt_pass);
  wm.addParameter(&p_mqtt_topic);

  wm.setSaveConfigCallback([&]() {
    strncpy(buf_mqtt_host, p_mqtt_host.getValue(), sizeof(buf_mqtt_host));
    strncpy(buf_mqtt_port, p_mqtt_port.getValue(), sizeof(buf_mqtt_port));
    strncpy(buf_mqtt_user, p_mqtt_user.getValue(), sizeof(buf_mqtt_user));
    strncpy(buf_mqtt_pass, p_mqtt_pass.getValue(), sizeof(buf_mqtt_pass));
    strncpy(buf_mqtt_topic, p_mqtt_topic.getValue(), sizeof(buf_mqtt_topic));
    saveConfigToNVS();
  });

  bool ok = force
    ? wm.startConfigPortal("ESP32_Config", "0814111142")
    : wm.autoConnect("ESP32_Config", "0814111142");

  if (!ok) {
    Serial.println("[WiFiManager] Failed or timeout. Rebooting...");
    delay(2000);
    ESP.restart();
  }
}

void loadConfigFromNVS() {
  prefs.begin(NVS_NS, true);
  String host  = prefs.getString(KEY_MQTT_HOST, "");
  String port  = prefs.getString(KEY_MQTT_PORT, "1883");
  String user  = prefs.getString(KEY_MQTT_USER, "");
  String pass  = prefs.getString(KEY_MQTT_PASS, "");
  String topic = prefs.getString(KEY_MQTT_TOPIC, "xy-md02");
  prefs.end();

  strncpy(buf_mqtt_host, host.c_str(), sizeof(buf_mqtt_host));
  strncpy(buf_mqtt_port, port.c_str(), sizeof(buf_mqtt_port));
  strncpy(buf_mqtt_user, user.c_str(), sizeof(buf_mqtt_user));
  strncpy(buf_mqtt_pass, pass.c_str(), sizeof(buf_mqtt_pass));
  strncpy(buf_mqtt_topic, topic.c_str(), sizeof(buf_mqtt_topic));
}

void saveConfigToNVS() {
  prefs.begin(NVS_NS, false);
  prefs.putString(KEY_MQTT_HOST, buf_mqtt_host);
  prefs.putString(KEY_MQTT_PORT, buf_mqtt_port);
  prefs.putString(KEY_MQTT_USER, buf_mqtt_user);
  prefs.putString(KEY_MQTT_PASS, buf_mqtt_pass);
  prefs.putString(KEY_MQTT_TOPIC, buf_mqtt_topic);
  prefs.end();
  Serial.println("[NVS] Config saved.");
}

// ================== MQTT ==================
void connectMQTT() {
  if (WiFi.status() != WL_CONNECTED) return;

  char availTopic[96];
  snprintf(availTopic, sizeof(availTopic), "%s/status", buf_mqtt_topic);

  while (!mqtt.connected()) {
    Serial.printf("[MQTT] Connecting to %s:%s ... ", buf_mqtt_host, buf_mqtt_port);
    String clientId = "ESP32-" + String((uint32_t)ESP.getEfuseMac(), HEX);

    bool ok;
    if (strlen(buf_mqtt_user) > 0) {
      ok = mqtt.connect(clientId.c_str(), buf_mqtt_user, buf_mqtt_pass,
                        availTopic, 1, true, "offline");
    } else {
      ok = mqtt.connect(clientId.c_str(), availTopic, 1, true, "offline");
    }

    if (ok) {
      Serial.println("connected.");
      mqtt.publish(availTopic, "online", true);
      updateLed();
    } else {
      Serial.printf("failed, rc=%d. retry in 3s\n", mqtt.state());
      updateLed();
      delay(3000);
    }
  }
}

// ================== Read XY-MD02 & Publish ==================
void readXY_and_publish() {
  uint8_t rc = node.readInputRegisters(0x0001, 2); // 0x0001=Temp, 0x0002=Humi

  if (rc == node.ku8MBSuccess) {
    float tempC = ((int16_t)node.getResponseBuffer(0)) / 10.0f;
    float humi  = ((int16_t)node.getResponseBuffer(1)) / 10.0f;
    Serial.printf("XY-MD02 | Temp: %.1f°C | Humi: %.1f%%RH\n", tempC, humi);

    if (mqtt.connected()) {
      char payload[128];
      snprintf(payload, sizeof(payload),
               "{\"temp\":%.1f,\"hum\":%.1f}", tempC, humi);
      mqtt.publish(buf_mqtt_topic, payload, true);
    }
  } else {
    Serial.printf("Modbus read failed. rc=%u\n", rc);
  }

  updateLed();
}
