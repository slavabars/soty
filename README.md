# Soty (DTM) — сборка, запуск, федерация хостов

Soty — E2EE-мессенджер без сервера и аккаунта. Устройство (Flutter) общается
напрямую: mesh (BLE/Wi-Fi Direct) и libp2p. Хосты (`dtm_host`) — это
операторские relay+tracker узлы для офлайн-доставки и публичного
обнаружения. Проект состоит из двух пакетов:

| Каталог | Что это |
| --- | --- |
| `dtm_app/` | Android-приложение (`package:dtm_app`, applicationId `ru.dcns.soty`) |
| `host/` | Релейный хост + трекер (Dart CLI, без Flutter) |
| `scripts/` | Инсталлятор хоста на SSH-сервер (`deploy-host.sh`) |
| `build-artifacts/` | Готовые бинарники (не версионируются, воспроизводятся командами ниже) |

Среда сборки на этом хосте: Flutter 3.32.3 / Dart 3.8.1 в
`/home/bars/development/flutter`, JDK 17 (`/usr/lib/jvm/java-17-openjdk-amd64`).

### Установка хоста на свой SSH-сервер (инсталлятор)

`scripts/deploy-host.sh` делает всё, что требуется вручную: копирует
`dtm_host.app` по scp, проверяет наличие libsqlite3, кладёт бинарь в `~/local/`,
БД — в `~/soty/host.db`, поднимает user-systemd-сервис `soty-host.service`
(без root, автозапуск при логине) и в конце печатает invite-линк с ключом.

```bash
# 1) собрать бинарь (если ещё не собран)
cd host
dart compile exe bin/dtm_host.dart -o ../build-artifacts/dtm_host.app

# 2) установить на сервер. Без sshpass — передай пароль через SSH_ASKPASS:
cat > /tmp/askpass.sh <<'EOF'
#!/bin/sh
echo "ВАШ_ПАРОЛЬ"
EOF
chmod +x /tmp/askpass.sh
export SSH_ASKPASS=/tmp/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0

cd scripts
./deploy-host.sh --user dtm --host 85.198.75.50 \
  --listen 0.0.0.0 --port 3100 --app ../build-artifacts/dtm_host.app
```

Полезные флаги (`./deploy-host.sh --help`):

- `--unit-only` — не заливать бинарь (если уже на сервере), только создать unit;
- `--invite-json` — вывести результат как JSON (endpoint, ed25519, invite);
- `--name foo` — другое имя сервиса; `--listen/--port` — bind; `--no-restart` —
  без автоперезапуска (`Restart=no`);

Если ключ в SSH уже настроен (`ssh user@host` работает без пароля) —
инсталлятор просто вызывается со своими флагами, переменные `SSH_ASKPASS`
не нужны.

Требования к серверу: Linux x86_64, наличие `libsqlite3` (Alma/RHEL:
`dnf install -y sqlite-libs`; посмотреть: `ls /usr/lib64/libsqlite3.so.0`),
порт `--port` открыт в firewall, пользователь без рута (используется
systemd --user).

### Публичный хост (действующий)

Развёрнут на сервере `85.198.75.50`, пользователь `dtm`, как user-systemd-сервис
`soty-host.service` (без root, `~/.config/systemd/user/`, enabled + running).
Datadir: `~/soty/host.db`, бинарь `~/local/dtm_host.app`.
(переустановить/обновить его с этого хоста:
`cd scripts && ./deploy-host.sh --user dtm --host 85.198.75.50 --invite-json`)

Это релей №1 из двух. Любая пересборка `dtm_host.app` обязана обновлять
**оба** узла — см. следующий раздел и `scripts/deploy-relay2.sh`.

| Параметр | Значение |
| --- | --- |
| WebSocket | `ws://85.198.75.50:3100/ws` |
| Ed25519 (для пина) | `fad55cc762eda3f6cbc9c6522030ce8ec29e87143c9c78f452038d24143a4e82` |
| Invite-линк | `soty://host?addr=ws%3A%2F%2F85.198.75.50%3A3100%2Fws&pk=fad55cc762eda3f6cbc9c6522030ce8ec29e87143c9c78f452038d24143a4e82` |

Перезапуск сервиса: `systemctl --user restart soty-host.service`;
логи: `journalctl --user -u soty-host.service`.
При переустановке с этого хоста бинарь перезальётся автоматически;
если старый процесс держит файл (scp: dest open ... Failure) —
просто `systemctl --user restart soty-host.service` и повторить инсталлятор,
либо использовать `--unit-only`.

Эти сборки (`soty_deviceA.apk`, `soty_deviceB.apk`, `soty-release.apk`)
уже вшивают этот хост по умолчанию через `SOTY_BOOTSTRAP_HOST` (см. раздел 1).

### Второй публичный хост (релей #2, `price.dcns.ru`)

Действующий второй релей, federated с основным. Живёт на виртуальном хостинге
(eplanet), поэтому наружу смотрит только через TLS-прокси в nginx провайдера.

| Параметр | Значение |
| --- | --- |
| Сервер | `31.135.12.167` (`isp54.eplanet.host`), пользователь `u381225` |
| SSH | алиас `soty-relay2` (ключ `~/.ssh/id_rsa.1` уже в `authorized_keys`) |
| Реле слушает | `127.0.0.1:3100` (наружу не выставлено) |
| Публичный WebSocket | `wss://price.dcns.ru/soty-ws` (nginx vhost `price.dcns.ru`, путь `/soty-ws`) |
| Ed25519 (для пина) | `dba88ecc7cd8053f76ddbe9c29d0bf63bb24e6234ebcaf9c074dcb0a1ce4b014` |
| Invite-линк | `soty://host?addr=wss%3A%2F%2Fprice.dcns.ru%2Fsoty-ws&pk=dba88ecc7cd8053f76ddbe9c29d0bf63bb24e6234ebcaf9c074dcb0a1ce4b014` |
| Каталог на сервере | `~/dtm/`: `dtm_host.app`, `host.db`, `host.log`, `supervise.sh`, `start.sh`, `stop.sh`, `status.sh` |
| Федерация | `--seed ws://85.198.75.50:3100/ws\|fad55cc7…4e82`; основной хост узнал его сам из `NET` приветствия и хранит в `federated_hosts` |

**Обновление — вместе с основным релеем.** Любая пересборка `dtm_host.app`
обновляет оба узла, иначе они разойдутся по версии протокола:

```bash
cd /home/bars/code/message/host
dart compile exe bin/dtm_host.dart -o ../build-artifacts/dtm_host.app

cd /home/bars/code/message
./scripts/deploy-host.sh --user dtm --host 85.198.75.50 --invite-json  # релей #1
./scripts/deploy-relay2.sh                                              # релей #2
./scripts/deploy-relay2.sh --check                                      # только проверка
```

`deploy-relay2.sh` сам заливает бинарь, перезаливает скрипты, перезапускает,
сверяет Ed25519-ключ и долбит публичный `wss://` до зелёного `WELCOME`.
Ключи хостов не меняются: они лежат в `host_state.ed_seed` внутри `host.db`,
поэтому **никогда не удаляй `host.db` при обновлении** — иначе все клиенты
с пином отвалятся. Скрипт падает с `IDENTITY CHANGED`, если это всё-таки
случилось.

Проверка любого реле одним файлом (тот же handshake, что делает приложение):

```bash
python3 scripts/host_probe.py ws://85.198.75.50:3100/ws  fad55cc7…4e82
python3 scripts/host_probe.py wss://price.dcns.ru/soty-ws dba88ecc…b014
```

Особенности этой машины, из-за которых здесь не `deploy-host.sh`:

- **Нет sudo/systemctl/tmux.** Реле крутит шелл-супервизор
  `~/dtm/supervise.sh` (рестарт бинаря через 5 с), автозапуск после ребута —
  crontab `@reboot ~/dtm/start.sh`. Логи — `~/dtm/host.log`.
- **Из интернета открыты только 22/80/443.** 80/443 — nginx провайдера,
  занять их нельзя (`Permission denied` без root), а 3100 снаружи не
  доступен. Поэтому `--listen 127.0.0.1` + nginx-прокси.
- **`ws://` на 80 не работает:** в `server{}` для :80 стоит
  `return 301 https://$host:443$request_uri;`, rewrite-фаза отрабатывает
  раньше выбора location, поэтому публичный адрес реле — только `wss://`.
- **`proxy_read_timeout 3600s` обязателен:** дефолт 60 s рвал бы простаивающую
  подписку каждую минуту.
- **SSH-шлюз eplanet рвёт соединения** («Connection closed by … port 22»
  примерно в 1 из 3 попыток) — поэтому `deploy-relay2.sh` ретраит удалённые
  вызовы, а для ручной работы есть `/tmp/opencode/rsh.sh`.
- **В `pkill -f` нужен голый `dtm_host.app`:** в реальной командной строке
  процесса путь `./dtm_host.app`, так что шаблон вида `dtm/dtm_host.app`
  не срабатывает (на этом уже обожглись — `stop.sh` не останавливал реле).
- Конфиг nginx-прокси лежит в `scripts/soty-ws-nginx-location.conf`;
  полная замена конфига хоста — `/tmp/price.dcns.ru.nginx.conf` (если нужен).

Проверено e2e (эмуляторы A/B): сообщение B → релей #1 → federated-фан-аут
(`source=federated hops=1`) → релей #2 → A. Оба эмулятора подхватили релей #2
сами из `PEER_LIST` трекера, без ручного добавления.

---

## 1. Сборка приложения

```bash
export PATH="/home/bars/development/flutter/bin:$PATH"
cd dtm_app

flutter analyze --no-pub          # обязателен: No issues found
flutter test --no-pub             # 201 тест, зелёные

flutter build apk --debug --no-pub -t lib/main.dart
flutter build apk --release --no-pub -t lib/main.dart   # → build/app/outputs/flutter-apk/app-<mode>.apk
```

Полный регресс (analyze + все тесты + apk debug/release + aab): `scripts/build_all.sh`.

### Ловушка: shrinker вырезает ресурсы только в release

Flutter-плагин Gradle сам принудительно включает `isMinifyEnabled` и
`isShrinkResources` для build type `release` — перекрывая `android/app/build.gradle.kts`.
Resource shrinker видит только ссылки из XML и манифеста, поэтому ресурс, на
который ссылается только строка в Dart-коде, из релизного APK исчезает.

Именно так пропал звук уведомления: `RawResourceAndroidNotificationSound('soty_chime')`
имя ресурса текстом, `res/raw/soty_chime.ogg` вырезался, `show()` не публиковал
ничего. Debug-сборка при этом полностью исправна, поэтому проверять надо
именно release-артефакт:

```bash
# в релизном APK ресурс обязан быть
"$ANDROID_HOME/build-tools/36.0.0/aapt2" dump resources \
  build-artifacts/soty-release.apk | grep raw/soty_chime
```

Что-то, на что ссылается только Dart (звук уведомления, drawable-иконки),
держится в `android/app/src/main/res/raw/keep.xml`, подключённом в манифесте
через `android.shrinker.config`. Это проверяет `test/build/release_notification_resources_test.dart`.

Ещё следствие того же шринкера: канал уведомления, созданный сборкой без звука,
«молчачий» навсегда — importance и sound у канала Android иммутабельны. Поэтому
`LocalNotificationService.channelId` версионируется (`soty_messages_v3`), и
поднятие версии канала — единственный способ починить уже установленное
приложение.

### Полезные dart-define при сборке

- `SOTY_BOOTSTRAP_HOST` — вшитый по умолчанию хост, на который устройство
  коннектится при старте, если в настройках ничего нет. Принимает либо
  `ws://host:port/ws`, либо полный invite-линк (см. раздел 3):
  ```bash
  BS='soty://host?addr=ws%3A%2F%2F10.0.2.2%3A3100%2Fws&pk=0f5015…7d39'
  flutter build apk --debug --target-platform android-x64 --no-pub \
    --dart-define=SOTY_BOOTSTRAP_HOST="$BS" -t lib/main.dart
  ```
  Явный `ws://...` вшивается **без** пина: `WELCOME.identity` не проверяется.
  Для защиты от подмены хоста всегда вшивай полноценный `soty://host?...&pk=` —
  тогда `edPubKey` пинится (несовпадение ⇒ соединение рвётся).
- `SOTY_ADVERTISE_ADDR` — multiaddr, который устройство рекламирует трекерам
  (по нему другие устройства будут его напрямую диалить):
  ```bash
  --dart-define=SOTY_ADVERTISE_ADDR=/ip4/10.0.2.2/tcp/5011
  ```

### Запуск на эмуляторах (два устройства)

BLE в эмуляторе недоступен, поэтому крос-девайс-сценарии гоняются по p2p.
`P2PTransport` слушает фиксированный `/ip4/0.0.0.0/tcp/4010` — каждый порт
наружу пробрасывается через adb forward на уникальный номер.

```bash
emulator -avd Medium_Phone_API_36 -port 5554 -read-only -no-window \
  -gpu swiftshader_indirect -no-snapshot -no-audio -no-boot-anim &
emulator -avd Medium_Phone_API_36 -port 5556 -read-only -no-window \
  -gpu swiftshader_indirect -no-snapshot -no-audio -no-boot-anim &

# устройство A (5554) рекламирует /ip4/10.0.2.2/tcp/5012
adb -s emulator-5554 forward tcp:5012 tcp:4010
adb -s emulator-5554 install <deviceA.apk>
# устройство B (5556) рекламирует /ip4/10.0.2.2/tcp/5011
adb -s emulator-5556 forward tcp:5011 tcp:4010
adb -s emulator-5556 install <deviceB.apk>
```

Ключевое правило: **адрес рекламы A = тот forward-порт, который доходит до A**
(в примере `5012` на 5554), и наоборот. Номера портов могут быть любыми,
главное чтобы `SOTY_ADVERTISE_ADDR` каждого устройства совпадал с его
forward-портом, видимым у `10.0.2.2` (алиас хоста из эмулятора).

Рабочие раскладки (проверено в e2e шифрованные-конверты+decrypt):

| Устройство | emulator | forward | SOTY_ADVERTISE_ADDR |
| --- | --- | --- | --- |
| A | 5554 | `5012 → 4010` | `/ip4/10.0.2.2/tcp/5012` |
| B | 5556 | `5011 → 4010` | `/ip4/10.0.2.2/tcp/5011` |

После установки: онбординг → разрешение ·Nearby devices· → New chat с X25519
ключами друг друга (или через трекер, см. раздел 4). Логи транспортов смотрят
так: `adb -s emulator-5554 logcat -d | grep '\[p2p\]\|\[host\]'`.

Проверка статусов доставки/прочтения не требует тапов по интерфейсу:
debug-сборка открывает локальный send-hook, а статус каждого исходящего
конверта лежит в таблице `message_statuses` выгруженной БД (`0` queued,
`1` sent, `2` delivered, `3` read — монотонно возрастает):

```bash
adb -s emulator-5554 forward tcp:14701 tcp:4701
curl -X POST -d '{"to":"<x25519-hex>","text":"hello"}' \
  http://127.0.0.1:14701/
adb -s emulator-5556 exec-out run-as ru.dcns.soty cat files/dtm.sqlite \
  > /tmp/opencode/emu/b.sqlite
```

Чек о доставке (`d1`) отправляется всегда, о прочтении (`r1`) — только если
включена настройка «Чеки о прочтении» (Настройки → Сообщения, по умолчанию
включена). Подделку устройство отвергает: `d1`/`r1` засчитывается, только
если его подписант совпадает с получателем исходного конверта.
---

## 2. Сборка и запуск хоста

```bash
cd host
export PATH="/home/bars/development/flutter/bin:$PATH"

# тесты и статический анализ
flutter test --no-pub          # 31 тест (host не импортирует Flutter-UI, но pkg:dtm_app тянет flutter test)
flutter analyze --no-pub

# AOT-бинарник (имя вывода задаётся свободно через -o)
dart compile exe bin/dtm_host.dart -o build-artifacts/dtm_host.app
```

Запуск:

```bash
./build-artifacts/dtm_host.app --db /data/host.db --listen 0.0.0.0 --port 3100
```

| Флаг | По умолчанию | Смысл |
| --- | --- | --- |
| `--db <path>` | `host.db` | sqlite-файл в cwd (envelopes + tracker). Сохраняет host-ключ на перезапусках |
| `--listen <addr>` | `0.0.0.0` | адрес привязки |
| `--port <port>` | `3000` | TCP-порт; WS-эндпоинт — `ws://<listen>:<port>/ws` |
| `--announce <url>` | `ws://<listen>:<port>/ws` | публичный URL, пишется в баннер |
| `--peer <spec>` | — | пир-хост для федерации, повторяемый (см. раздел 3) |
| `--help` | — | usage |

При первом запуске в `--db` генерируется Ed25519-ключ. Он навсегда остаётся
в файле базы — перезапуск не меняет идентичность, пин клиентов не ломается.

Баннер печатает invite-линк, который можно вшивать клиентам
(см. `SOTY_BOOTSTRAP_HOST`):
```
soty://host?addr=ws%3A%2F%2F0.0.0.0%3A3100%2Fws&pk=0f5015571b161e176915703a1d9d7966eb21f37a4be3f7fbc4dd1b36a0ca7d39
```

На устройстве хост можно добавить не только через вшитый define, но и из
внутренних настроек „Relay hosts" (`soty://host`-ссылка или ввод адреса+ключа).
---

## 3. Зачем Linux-бинарь может называться `.exe` (или любым именем)

`dart compile exe` **на всех платформах** по умолчанию называет результат
`<имя-исходника>.exe` — это конвенция тулчейна, а не признак Windows.
Имя вывода полностью свободно: `-o dtm_host.app`, `-o dtm_host` и т.д.
Сам файл — нативный ELF независимо от суффикса:

```
$ file build-artifacts/dtm_host.app
ELF 64-bit LSB pie executable, x86-64, … for GNU/Linux 2.6.32, stripped
```

В этой инструкции хост называется `dtm_host.app`; `.exe` из ранних сборок —
тот же Linux-ELF, просто суффикс по умолчанию. Суффикс ни на что не влияет;
пересобрать под любым именем: `dart compile exe bin/dtm_host.dart -o <имя>`.

---

## 4. Федерация хостов: как опубликовать и связать узлы

Хосты **не обнаруживают друг друга сами** — список пиров задаёт оператор
флагом `--peer`. Федерация двухпутевая, каждый узел:
1. держит исходящие WebSocket-соединения к перечисленным пирам с экспоненциальными реконнектами;
2. гонит **живой релей** (получил `PUBLISH` → раздал пирам с `hops+1`,
   принимает и рассылает подписчикам) и
3. крутит **антиэнтропию** (`WANT{since}` → `HAVE` → `GET` → `ENVELOPES`),
   дотаскивая недостающие конверты, опубликованные до коннекта.

### Публикация: связка двух хостов

```bash
# хост 1 (публичный URL ws://relay1.example.com/ws), известный как релей+трекер
./dtm_host.app --db /srv/host1.db --listen 0.0.0.0 --port 3100 \
  --announce ws://relay1.example.com/ws \
  --peer "ws://relay2.example.com/ws|relay2_ed25519_pub_hex"

# хост 2
./dtm_host.app --db /srv/host2.db --listen 0.0.0.0 --port 3200 \
  --announce ws://relay2.example.com/ws \
  --peer "ws://relay1.example.com/ws|relay1_ed25519_pub_hex"
```

Формат `--peer <spec>`:
- `"ws://url/ws"` — просто адрес пира, без пина;
- `"ws://url/ws|pkHex"` — адрес + ожидаемый Ed25519-ключ пира. При
  несовпадении `WELCOME.identity` соединение с пиром рвётся (защита от
  подмены доверенного релея).

Ключи пиров берутся из их баннеров (`ed25519 <hex>`) при первом запуске.
Для полной связки **каждый из хостов должен перечислить остальных** —
федерация строится на исходящих линках; без симметричного `--peer` сообщение
дошло бы только в одну сторону.

### Топологии

- **Два хоста (полный меш)** — выше. Любое устройство, подключённое к любому
  из них, получает конверты, опубликованные на другом.
- **Кольцо/цепочка N хостов** — каждый пинится на соседей. Хопы считаются
  (`envelopes.hops`) и режутся потолком `hostGossipMaxHops`, поэтому очень
  длинные цепочки обрываются — на практике держи путь до получателя ≤ 2–3 хопов.
- **Хаб с периферийными узлами** — периферия пинится на хаб, хаб — на
  периферию (skew-star), либо периферия федератуется только с хабом.

### Трекер (дискавери пиров) — это тоже хост

Любой `dtm_host` умеет режим трекера по умолчанию: при `HELLO` он запоминает
`peerId`+адреса клиента в `known_peers` (TTL 24 ч), а по
`PEER_LIST_REQUEST` возвращает случайную выборку других известных устройств.
Клиент, получив список, импортирует пиров в p2p-книгу и **диалит напрямую**,
минуя хосты. То есть даже один хост, на который смотрят оба устройства, даёт
прямую доставку A→B. Когда пиров уже ≥ `trackerStopPeerListCount` (8),
устройство перестаёт спрашивать трекеров, но хосты-релеи остаются в пуле
для офлайн-доставки.

### Полезные факты для отладки федерации

- WS-фреймы — строгий UPPERCASE-JSON: `HELLO/WELCOME/SUBSCRIBE/PUBLISH/PUBLISHED/WANT/HAVE/GET/ENVELOPES/PEER_LIST_REQUEST/PEER_LIST`. Мусор ⇒ дроп соединения.
- Пин (`edPubKey`) проверяется на устройствах и между хостами до первого сообщения.
- Хосты хранят только релейный буфер зашифрованных конвертов (ограниченный
  окном) + tracker-таблицу; **плейнтекст и ключи не хранятся**.
- Объём и удержание настраиваются только в коде (`hostRelayWindowMs`,
  `hostRetentionMs`), в CLI их нет.

Быстрые проверки соединений: `ss -tnp | grep 3100`, лог `[host] *` в logcat
устройств, `select * from known_peers;` в `host.db`.

## 5. Фоновая работа и Google Play

Режим «работать в фоне» (как Telegram/WhatsApp): при сворачивании или
выключенном экране приложение не должно терять релей и меш-соединения.

- `SotyBackgroundService` (Android, `foregroundServiceType="connectedDevice|dataSync"`
  в манифесте) владеет `FlutterEngine` и держит процесс живым, пока Dart
  стартует транспорты. Стартует из переднего плана при запуске приложения,
  если настройка «Работа в фоне» включена (по умолчанию включена, ключ
  `soty.background`). `startForeground(..., CONNECTED_DEVICE)` — только
  connectedDevice (см. ограничения ниже).
- Постоянного wake lock нет: foreground-статус сам тормозит Doze. Проверка
  (два эмулятора, экран выкл., 4+ мин): процесс (`pidof`), прогресс жив;
  `dumpsys activity services ru.dcns.soty` → `isForeground=true`; TCP-сокет до
  релея тот же (`ss -tn`), `known_peers.last_seen` не меняется — соединение
  одно, без реконнектов. Живучесть WS поддерживают пинги `ws.pingInterval` =
  25 c (dart:io apply после `connect`, параметра в `connect` нет).
- Исключение из оптимизации батареи — только на явный запрос пользователя из
  настроек (раздел «Батарея»): `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` —
  restricted permission, поэтому без самостоятельного запроса при старте.
- Решения под Google Play (зафиксировано):
  1. Нет `BOOT_COMPLETED`-ресивера: на Android 15+ сервис из фона стартовать
     нельзя, старт только из activity/платформенного метода.
  2. `dataSync` на Android 15+ ограничен 6 часами — `onTimeout()` → `stopSelf()`.
     Поэтому манифест объявляет оба типа, а стартуем только как
     `CONNECTED_DEVICE` (BLE-меш-связь — легитимный connected-device use case).
  3. Фаза D (не реализовано, задокументировано): настоящее «всегда включено»
     на Play — тихий FCM-push через собственные релеи, который будит приложение
     при поступлении конверта; FGS остаётся для локального меша.
  4. Вендорные энергоменеджеры (Xiaomi, Samsung, EMUI и т.п.) могут душить
     фоновые процессы даже с FGS — в настройках вендора; включаем это в FAQ
     релиза.
- Сильная остановка (force-stop) убивает и сервис — это поведение Android,
  от него не спасает ни один FGS.