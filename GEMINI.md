# GEMINI.md — Конституция и мастер-бэклог проекта «Маяк» (`p2p_mesh`)

Ты работаешь над автономным, бессерверным P2P & BLE Mesh мессенджером **«Маяк»** (`com.mayak.mesh.p2p_mesh`) для **Android** и **Windows PC**.
Репозиторий: `https://github.com/lasaniaden/Mayak-messenger`
Язык общения с пользователем и релиз-ноутов: **русский**.

---

## 1. Технический стек и жёстко зафиксированные версии

- **Flutter / Dart:** `Flutter 3.27.1` / `Dart 3.6.0` (синхронизировано с `.github/workflows/build.yml`).
- **Аудио:** `flutter_soloud: 3.2.7` (`lib/mayak_media_rtc.dart`). **НЕ обновлять до `>=3.3.0`** — они требуют Dart 3.7+ (`ffi >=2.1.4`) и сломают сборку.
- **Звонки (WebRTC):** `flutter_webrtc: 0.12.11` (`lib/mayak_media_rtc.dart`). **НЕ обновлять до `1.6.3+`** — там используется `onSurfaceCleanup()` из Flutter 3.29+, что ломает компиляцию Android на Flutter 3.27.1.
- **Android SDK / NDK:** `minSdk = 24`, `ndkVersion = "27.0.12077973"`, зеркало Google Maven Central + кэш Gradle в `build.yml`.
- **Ключевые файлы:**
  - `lib/main.dart` — UI-слой.
  - `lib/mesh_engine.dart` — сетевой движок (TCP LAN, UDP Hole Punch, BLE Nearby, файлы, рация PTT, звонки).
  - `lib/mayak_dht.dart` — клиент Mainline DHT (BEP-5/42/43 `ro=1`/44, CIDR-фильтр против Scaleway/GlobalTeleHost, кэш 120 узлов, 61-символьный Crockford Base32 Маяк-ID, приватные суточные слоты, DHT PEX).
  - `lib/mayak_media_rtc.dart` — `MayakSoLoudPlayer` (`loadMem` в RAM, без блокировок папки) и `MayakWebRtcController`.
  - `scripts/patch_win_tray.py` — патч Win32-трея и Single-Instance Mutex с ожиданием `--updated` (до 6с).
  - `test/mesh_core_test.dart` — unit-тесты (прогоняются в CI перед сборкой).
  - `.github/workflows/build.yml` — сборка Android APK + Windows ZIP и публикация в GitHub Releases.

---

## 2. Неприкосновенные правила («Конституция Маяка»)

1. **Zero-Server / Zero-VPN / Zero-Auth:** никаких центральных серверов, никаких VPN-прокси, никакой регистрации по телефону или email. Сквозное шифрование (E2EE) включено всегда по умолчанию.
2. **Чистота перед Dr.Web и Windows Defender:**
   - **НИКОГДА не добавлять `.bat` файлы** ни в репозиторий, ни в релизные архивы, ни в `build.yml`.
   - **НИКОГДА не запускать `powershell.exe`, `cmd.exe` или `csc.exe`** из Windows-приложения. Автообновление работает исключительно на чистом Dart ZIP-декодере с переименованием файлов в `*.old` на NTFS; воспроизведение аудио — исключительно через `flutter_soloud`.
3. **Чистота перед Google Play Protect:**
   - **НИКОГДА не добавлять разрешения** `REQUEST_INSTALL_PACKAGES`, `RECEIVE_BOOT_COMPLETED`, `SYSTEM_ALERT_WINDOW`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. Они должны быть удалены через `tools:node="remove"` в `AndroidManifest.xml` (и не дублироваться в обычных `<uses-permission>`).
   - **НИКОГДА не использовать `--obfuscate`** для Android APK.
4. **Фиксированный Android Keystore:**
   - Не менять встроенный релизный ключ `mayak_release.jks` в `.github/workflows/build.yml` и сохранять автоинкремент `--build-number`, чтобы обновления ставились поверх старых версий без удаления данных.
5. **Скрытая админ-консоль:**
   - Пароль: `mayak#admin#2026` (в коде хранить только SHA-256 хеш, **ноль** текстовых подсказок в UI).
   - Вход: *Настройки → О приложении → 3 тапа по логотипу → 2 тапа по версии*.
6. **Чистота интерфейса и README:**
   - Не перегружать UI и `README.md` перечислениями криптографических алгоритмов — достаточно короткой формулировки *«Сквозное шифрование»*.
7. **Дисциплина релизов:**
   - При каждом обновлении синхронно менять версию во всех 4 местах:
     1. `lib/mesh_engine.dart` (`currentAppVersion`)
     2. `pubspec.yaml` (`version: X.Y.Z+BUILD`)
     3. `.github/workflows/build.yml` (`--build-name=X.Y.Z` и `--build-number`)
     4. `RELEASE_NOTES.md` (на русском языке)
   - На каждый хотфикс обязательно повышать patch-версию.
   - Внутри однострочников `python3 -c '...'` в `.github/workflows/build.yml` **никогда** не использовать неэкранированные одинарные кавычки `'`.

---

## 3. Инженерные стандарты (защита от регрессий)

- **Обязательная проверка после каждой правки:**
  ```bash
  flutter analyze --no-fatal-infos --no-fatal-warnings
  flutter test
  ```
  Не считать задачу выполненной, пока анализ и все тесты не пройдут чисто. При добавлении новой логики (парсинг, протоколы, дедупликация) дописывать тест в `test/mesh_core_test.dart`.
- **WebRTC на Android (защита от EGL-краша):** при завершении звонка в `disposeSession()` всегда **сначала** обнулять `localRenderer.srcObject = null` и `remoteRenderer.srcObject = null`, вызывать `onStateChanged()`, ждать `120 мс`, и только потом останавливать треки и вызывать `.dispose()` на `MediaStream` / `RTCPeerConnection`.
- **Парсинг адресов:** всегда использовать `MeshEngine.parseEndpoint()` и `MeshEngine.isPrivateLanIpv4()`. Запрещено делать `split(':')` напрямую по `lastAddress` / `extUdp` (ломает `udp:IP:PORT` и IPv6).
- **Приватность и дедупликация:**
  - Запрещено автоматически копировать чужие контакты из `peer_sync` в адресную книгу.
  - Все входящие сообщения строго дедуплицировать по `msgId`.
  - Не дублировать пакет по UDP/BLE, если он уже отправлен пиру по живому TCP.
- **Передача больших файлов:** лимит чанков в `_handleIncomingFileChunk` не ниже `500000`, TCP-watchdog не должен рвать соединение во время активного скачивания/отдачи файла.

---

## 4. Дорожная карта (Мастер-бэклог)

### Этап 1. Полировка v3.2.x (текущий этап)
- [ ] Добавить кнопки **«Прочитать»** и **«Ответить»** (`RemoteInput`) в Android-уведомления (`MainActivity.kt` в `build.yml`).
- [ ] Дошлифовать стабильность по полевым логам ПК + планшет (LAN) и 3 телефонов (4G).
- [ ] Постепенно разбить монолиты `mesh_engine.dart` и `main.dart` на небольшие модули (`calls_service.dart`, `file_transfer.dart`, `ptt_service.dart`, `transport_tcp_udp.dart`).

### Этап 2. Новые функции (до редизайна)
- [ ] **Система позывных `позывной#ТЕГ`:**
  - Экран первого входа, жёсткий запрет на `#`, `@` и пробелы в имени.
  - Постоянный 4-символьный тег (Crockford Base32), привязанный к ключу узла.
  - Глобальный поиск по DHT + тумблер приватности (скрыть из поиска).
  - Асинхронные заявки в друзья с лёгким PoW, голосовой SPAKE2, функция «Познакомить друзей».
- [ ] **Нативный деинсталлятор Windows** (без `.bat`!) в папке релиза и в Настройках.
- [ ] Добровольные Windows-релеи и автономные каналы без роутера.

### Этап 3. Полный редизайн UI
- **Обязательное условие:** перед началом редизайна выдать пользователю **полный список всех экранов и диалогов** приложения, чтобы он нарисовал концепты, и затем реализовать дизайн **1:1** по его макетам.

### Этап 4. Переход на единое Rust-ядро (`v4.0` — `libmayak_core`)
- Мост: `flutter_rust_bridge` v2.
- Транспорт и файлы: `quinn` (QUIC) + `aws-lc-rs`, верифицированный стриминг `bao-tree` (16 КБ `.obao4`) с докачкой видео.
- Звук: `miniaudio` + `libopus` + `opusfile`.
- Звонки через ТСПУ на 4G: `flutter_webrtc` с Rust Loopback Bridge поверх QUIC/маскированного UDP.
- Фон 24/7 на Android (включая Samsung One UI после смахивания из Recents): нативный Kotlin `MayakCoreService` (`remoteMessaging` Foreground Service).
