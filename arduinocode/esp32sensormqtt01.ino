#include <WiFi.h>
#include <WiFiClient.h>
#include <PubSubClient.h>
#include <WiFiManager.h>  // https://github.com/tzapu/WiFiManager
#include <Preferences.h>  // NVS (flash)
#include <SimpleTimer.h>
#include <DHT.h>

// ===== DHT Sensor (เปลี่ยนพิน/ประเภทได้ตามการต่อจริง) =====
#define DHTPIN 4      // ขา DATA ของ DHT ต่อที่ GPIO4 (ปรับได้)
#define DHTTYPE DHT11 // ถ้าใช้ DHT22 ให้เปลี่ยนเป็น DHT22

// ===== (ทางเลือก) ปุ่มเรียก Config Portal เมื่อกดค้างตอนบูต =====
#define CONFIG_PIN 0  // ปุ่ม BOOT ของ ESP32 ส่วนใหญ่คือ GPIO0

// ================== Globals ==================
WiFiClient espClient;
PubSubClient mqtt(espClient);
SimpleTimer timer;
Preferences prefs;        // เก็บ config
DHT dht(DHTPIN, DHTTYPE); // อินสแตนซ์ DHT

// คีย์ใน NVS
const char* NVS_NS        = "settings";
const char* KEY_MQTT_HOST = "mqtt_host";
const char* KEY_MQTT_PORT = "mqtt_port";
const char* KEY_MQTT_USER = "mqtt_user";
const char* KEY_MQTT_PASS = "mqtt_pass";
const char* KEY_MQTT_TOPIC= "mqtt_topic";

// บัฟเฟอร์ค่า MQTT (สำหรับฟอร์ม WiFiManager)
char buf_mqtt_host[64] = "";
char buf_mqtt_port[8]  = "1883";
char buf_mqtt_user[40] = "";
char buf_mqtt_pass[40] = "";
char buf_mqtt_topic[40]= "dht11sensor";

// ฟังก์ชันล่วงหน้า
void startConfigPortalIfNeeded(bool force = false);
void loadConfigFromNVS();
void saveConfigToNVS();
void connectMQTT();
void readDHT_and_publish();

// ================== SETUP ==================
void setup() {
  Serial.begin(9600);
  delay(100);

  pinMode(CONFIG_PIN, INPUT_PULLUP);
  dht.begin();

  // โหลดค่าจาก NVS (ถ้ามี)
  loadConfigFromNVS();

  // เงื่อนไขเปิด Config Portal:
  // 1) กดปุ่ม CONFIG_PIN ค้างตอนบูต ~3 วิ, หรือ
  // 2) ยังไม่มี mqtt_host
  bool bootButtonHeld = (digitalRead(CONFIG_PIN) == LOW);
  unsigned long t0 = millis();
  while (bootButtonHeld && (millis() - t0 < 3000)) {
    if (digitalRead(CONFIG_PIN) != LOW) {
      bootButtonHeld = false;
      break;
    }
    delay(10);
  }
  bool needPortal = bootButtonHeld || (strlen(buf_mqtt_host) == 0);

  startConfigPortalIfNeeded(needPortal);

  // ตั้งค่า MQTT server/port จากบัฟเฟอร์
  mqtt.setServer(buf_mqtt_host, atoi(buf_mqtt_port));

  // อ่านและส่งทุก 5 วินาที
  timer.setInterval(5000L, readDHT_and_publish);

  Serial.println("System ready.");
}

// ================== LOOP ==================
void loop() {
  if (WiFi.status() != WL_CONNECTED) {
    // WiFiManager จะช่วย reconnect ให้อยู่แล้ว
  }

  if (!mqtt.connected()) {
    connectMQTT();
  }
  mqtt.loop();
  timer.run();
}

// ================== WiFiManager & NVS ==================
void startConfigPortalIfNeeded(bool force) {
  WiFiManager wm;
  wm.setDebugOutput(true);  // debug ใน Serial

  // เพิ่มฟิลด์ custom สำหรับ MQTT
  WiFiManagerParameter p_mqtt_host("mqtt_host", "MQTT host (IP/hostname)", buf_mqtt_host, sizeof(buf_mqtt_host));
  WiFiManagerParameter p_mqtt_port("mqtt_port", "MQTT port (e.g. 1883)", buf_mqtt_port, sizeof(buf_mqtt_port));
  WiFiManagerParameter p_mqtt_user("mqtt_user", "MQTT user (optional)", buf_mqtt_user, sizeof(buf_mqtt_user));
  WiFiManagerParameter p_mqtt_pass("mqtt_pass", "MQTT password (optional)", buf_mqtt_pass, sizeof(buf_mqtt_pass));
  WiFiManagerParameter p_mqtt_topic("mqtt_topic", "MQTT topic", buf_mqtt_topic, sizeof(buf_mqtt_topic));

  wm.addParameter(&p_mqtt_host);
  wm.addParameter(&p_mqtt_port);
  wm.addParameter(&p_mqtt_user);
  wm.addParameter(&p_mqtt_pass);
  wm.addParameter(&p_mqtt_topic);

  // เมื่อกด "Save" ในพอร์ทัล จะเรียก callback นี้
  wm.setSaveConfigCallback([&]() {
    // ดึงค่าจากฟอร์มเก็บลงบัฟเฟอร์
    strncpy(buf_mqtt_host, p_mqtt_host.getValue(), sizeof(buf_mqtt_host));
    strncpy(buf_mqtt_port, p_mqtt_port.getValue(), sizeof(buf_mqtt_port));
    strncpy(buf_mqtt_user, p_mqtt_user.getValue(), sizeof(buf_mqtt_user));
    strncpy(buf_mqtt_pass, p_mqtt_pass.getValue(), sizeof(buf_mqtt_pass));
    strncpy(buf_mqtt_topic, p_mqtt_topic.getValue(), sizeof(buf_mqtt_topic));
    saveConfigToNVS();
  });

  bool ok;
  if (force) {
    Serial.println("\n[WiFiManager] Starting Config Portal...");
    // AP ชื่อ ESP32_Config, รหัสผ่าน 12345678 (ปรับได้)
    ok = wm.startConfigPortal("ESP32_Config", "0814111142");
  } else {
    // ลองเชื่อมต่อ WiFi ที่เคยบันทึกไว้ก่อน
    ok = wm.autoConnect("ESP32_Config", "0814111142");
  }

  if (!ok) {
    Serial.println("[WiFiManager] Failed to connect or config timeout. Rebooting...");
    delay(2000);
    ESP.restart();
  } else {
    Serial.println("[WiFiManager] WiFi connected.");
    // กันกรณี user เพิ่งกรอกใหม่ ให้ save อีกครั้ง (ถ้า callback ยังไม่ยิง)
    if (strlen(buf_mqtt_host) == 0) {
      strncpy(buf_mqtt_host, p_mqtt_host.getValue(), sizeof(buf_mqtt_host));
      strncpy(buf_mqtt_port, p_mqtt_port.getValue(), sizeof(buf_mqtt_port));
      strncpy(buf_mqtt_user, p_mqtt_user.getValue(), sizeof(buf_mqtt_user));
      strncpy(buf_mqtt_pass, p_mqtt_pass.getValue(), sizeof(buf_mqtt_pass));
      strncpy(buf_mqtt_topic, p_mqtt_topic.getValue(), sizeof(buf_mqtt_topic));
      saveConfigToNVS();
    }
  }
}

void loadConfigFromNVS() {
  prefs.begin(NVS_NS, true);  // read-only
  String host = prefs.getString(KEY_MQTT_HOST, "");
  String port = prefs.getString(KEY_MQTT_PORT, "1883");
  String user = prefs.getString(KEY_MQTT_USER, "");
  String pass = prefs.getString(KEY_MQTT_PASS, "");
  String topic= prefs.getString(KEY_MQTT_TOPIC, "dht11sensor");
  prefs.end();

  strncpy(buf_mqtt_host, host.c_str(), sizeof(buf_mqtt_host));
  strncpy(buf_mqtt_port, port.c_str(), sizeof(buf_mqtt_port));
  strncpy(buf_mqtt_user, user.c_str(), sizeof(buf_mqtt_user));
  strncpy(buf_mqtt_pass, pass.c_str(), sizeof(buf_mqtt_pass));
  strncpy(buf_mqtt_topic, topic.c_str(), sizeof(buf_mqtt_topic));
}

void saveConfigToNVS() {
  prefs.begin(NVS_NS, false);  // write
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

  // topic สถานะ: "<topic>/status"
  char availTopic[80];
  snprintf(availTopic, sizeof(availTopic), "%s/status", buf_mqtt_topic);

  while (!mqtt.connected()) {
    Serial.print("[MQTT] Connecting to ");
    Serial.print(buf_mqtt_host);
    Serial.print(":");
    Serial.print(buf_mqtt_port);
    Serial.print(" ... ");

    // clientId กันชนกันเล็กน้อย
    String clientId = "ESP32Client-" + String((uint32_t)ESP.getEfuseMac(), HEX);

    bool ok;
    if (strlen(buf_mqtt_user) > 0) {
      // มี user/pass → ใช้ overload ที่มี LWT
      ok = mqtt.connect(
        clientId.c_str(),
        buf_mqtt_user, buf_mqtt_pass,
        availTopic,  // willTopic
        1,           // willQos
        true,        // willRetain
        "offline"    // willMessage
      );
    } else {
      // ไม่มี auth → ใช้ overload ที่มี LWT (ไม่มี user/pass)
      ok = mqtt.connect(
        clientId.c_str(),
        availTopic,  // willTopic
        1,           // willQos
        true,        // willRetain
        "offline"    // willMessage
      );
    }

    if (ok) {
      Serial.println("connected.");

      // Birth message: แจ้งว่า online (retain = true)
      mqtt.publish(availTopic, "online", true);

      // (ถ้าต้องการ) subscribe topic ควบคุม/สั่งงานที่นี่
      // mqtt.subscribe("dht11sensor/cmd");
    } else {
      Serial.print("failed, rc=");
      Serial.print(mqtt.state());
      Serial.println(" retry in 3s");
      delay(3000);
    }
  }
}

// ================== งานหลัก: อ่าน DHT + ส่ง MQTT ==================
void readDHT_and_publish() {
  // อ่านค่าจริงจัง: DHT อาจอ่านพลาดได้ ให้ลองซ้ำเล็กน้อย
  float h = NAN, t = NAN;
  for (int i = 0; i < 3; i++) {
    h = dht.readHumidity();
    t = dht.readTemperature(); // องศา C
    if (!isnan(h) && !isnan(t)) break;
    delay(50);
  }

  if (isnan(h) || isnan(t)) {
    Serial.println("DHT read failed.");
    return;
  }

  // (ทางเลือก) คำนวณ heat index องศา C
  float hic = dht.computeHeatIndex(t, h, false);

  Serial.printf("DHT Data | Hum: %.1f %% | Temp: %.1f C | HeatIndex: %.1f C\n", h, t, hic);

  if (mqtt.connected()) {
    // ส่ง JSON ไป Topic ที่ตั้งค่าไว้ พร้อม retain
    char payload[160];
    snprintf(payload, sizeof(payload),
             "{\"hum\":%.1f,\"temp\":%.1f,\"heatindex\":%.1f}",
             h, t, hic);
    mqtt.publish(buf_mqtt_topic, payload, true);
  }
}
