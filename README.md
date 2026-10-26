# Soty (DTM) — E2EE-мессенджер без сервера

Soty — децентрализованный текстовый мессенджер с end-to-end шифрованием.
Устройства общаются напрямую: офлайн — через mesh (BLE / Wi-Fi Direct), онлайн —
через libp2p. Аккаунтов и центрального сервера нет. Релейные хосты
(`dtm_host`) — это операторские узлы для офлайн-доставки зашифрованных
конвертов и публичного обнаружения пиров (tracker). Плейнтекст и ключи на
хостах не хранятся.

## Что лежит в этом репозитории

| Путь | Что это |
| --- | --- |
| `README.md` | Описание проекта и инструкция по деплою релей-хостов |
| `scripts/install-relay.sh` | Установка на Linux: автоопределение дистрибутива, root или пользователь |
| `scripts/install-relay-macos.sh` | Установка на macOS через Docker/Colima (без admin) |
| `scripts/install-relay-windows.ps1` | Установка на Windows через Docker Desktop (без admin) |
| `scripts/deploy-host.sh` | Установка/обновление релея на обычном Linux-сервере по SSH (systemd --user) |
| `scripts/deploy-relay2.sh` | Установка/обновление релея на shared-хостинге (shell-супервизор + nginx) |
| `scripts/host_probe.py` | Проверка живого релея тем же handshake, что делает приложение |
| `scripts/soty-ws-nginx-location.conf` | nginx location для WebSocket-прокси релея |

Исходного кода приложения здесь нет. Готовые дистрибутивы (Android APK/AAB,
Linux-десктоп, бинарник `dtm_host`) публикуются только в
[Releases](https://github.com/slavabars/soty/releases). Репозиторий намеренно
содержит только описание проекта и средства деплоя релей-хостов.

## Как устроена федерация

- `dtm_host` принимает WebSocket-подключения по пути `/ws` и хранит
  зашифрованные конверты в SQLite. Клиенты получают офлайн-сообщения, когда
  снова подключаются.
- Любой `dtm_host` одновременно работает трекером: запоминает адреса клиентов
  и по запросу отдаёт список пиров, чтобы устройства могли соединяться напрямую.
- Хосты объединяются в федерацию флагами `--peer` / `--seed`: гоняют живой
  релей и антиэнтропию (догоняют пропущенные конверты). Для двусторонней
  доставки каждый узел должен знать остальных (или выучить их из `NET`).
- Идентичность хоста — Ed25519-ключ, который генерируется при первом запуске и
  хранится в `host.db`. Клиенты пинят этот ключ, поэтому **базу при обновлении
  удалять нельзя**.

## Требования к серверу релея

- Linux x86_64 — основной вариант (root или обычный пользователь).
- macOS (Intel/Apple Silicon) и Windows — только через Docker: готовый
  `dtm_host.bin` собран под Linux x86_64. Установщики сами собирают маленький
  контейнер `debian:bookworm-slim` с `libsqlite3` и запускают релей.
- `libsqlite3` на Linux (Alma/RHEL: `dnf install -y sqlite-libs`;
  Debian/Ubuntu: `apt-get install -y libsqlite3-0`). Установщик Linux ставит
  зависимость сам, если запущен от root.
- Системный `systemctl --user` (для релея #1) **или** nginx + cron (для
  shared-хостинга, релей #2). Если systemd нет, Linux-установщик использует
  shell-супервизор + `@reboot` в crontab.
- Открытый порт (обычно 3100) либо TLS-прокси в nginx на 80/443.
- Бинарник `dtm_host` из раздела Releases. В релизе он называется
  `dtm_host.bin`; переименовывать не нужно — установщики делают это сами.

## Быстрая установка на машине релея

Установщики скачивают актуальный `dtm_host.bin` из GitHub Releases,
проверяют SHA-256 по GitHub API, ставят зависимости и запускают сервис.
Повторный запуск обновляет бинарник, **`host.db` не трогается**, поэтому
Ed25519-идентичность и пины клиентов сохраняются.

Linux — автоопределение дистрибутива (apt/dnf/yum/pacman/zypper) и
архитектуры. Нужен glibc x86_64; для Alpine/musl и ARM готового
бинарника нет. Root-режим ставит system-сервис от пользователя `soty`;
пользовательский режим — `systemd --user`, а если его нет, супервизор в
`~/.local/share/soty`:

```bash
# системная установка
curl -fsSL https://raw.githubusercontent.com/slavabars/soty/main/scripts/install-relay.sh \
  | sudo bash -s -- --port 3100 --announce wss://relay.example.com/soty-ws

# без root
curl -fsSL https://raw.githubusercontent.com/slavabars/soty/main/scripts/install-relay.sh \
  | bash -s -- --port 3100 --announce wss://relay.example.com/soty-ws
```

macOS — Docker Desktop или Colima, всё работает без admin. Если Docker ещё
нет, поставьте его этим же скриптом через Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/slavabars/soty/main/scripts/install-relay-macos.sh \
  | bash -s -- --install-docker --port 3100 \
      --announce wss://relay.example.com/soty-ws
```

Windows — Docker Desktop, без admin, если Docker уже стоит:

```powershell
$dst = "$env:TEMP\install-relay-windows.ps1"
iwr https://raw.githubusercontent.com/slavabars/soty/main/scripts/install-relay-windows.ps1 -UseBasicParsing -OutFile $dst
powershell -ExecutionPolicy Bypass -File $dst -Port 3100 -Announce wss://relay.example.com/soty-ws
# поставить Docker Desktop (нужен PowerShell от администратора):
powershell -ExecutionPolicy Bypass -File $dst -InstallDocker
```

Полезные флаги Linux/macOS (Windows — аналогичные параметры `-Port`,
`-Announce`, `-Peer`, `-Version`, `-Uninstall`, `-Purge`):

| Флаг | Значение |
| --- | --- |
| `--port`, `--listen` | порт и адрес bind (default `3100`, `0.0.0.0`) |
| `--announce` | публичный `ws://…/ws` или `wss://…` для invite |
| `--peer SPEC` | пир федерации, можно повторять |
| `--version X.Y.Z+N` | конкретная версия вместо latest |
| `--url URL` | прямой URL на `dtm_host.bin` |
| `--no-verify` | не проверять SHA-256 |
| `--no-service` | только скачать/установить, без запуска |
| `--uninstall [--purge]` | удалить сервис; `--purge` — вместе с `host.db` |

После установки скрипт печатает `ed25519` и готовую invite-ссылку. На Linux
root-режим: `systemctl status soty-host`, `journalctl -u soty-host -f`; без
root: `systemctl --user status soty-host` (включите
`loginctl enable-linger $USER`). На macOS/Windows: `docker logs -f soty-host`.

## Релей #1 — обычный Linux-сервер (systemd --user)

`scripts/deploy-host.sh` копирует бинарник по SSH, проверяет `libsqlite3`,
кладёт его в `~/local/`, базу — в `~/soty/host.db`, создаёт и запускает
user-systemd-сервис `soty-host.service` и печатает invite-ссылку.

```bash
# бинарник из Releases
mkdir -p build-artifacts
curl -L -o build-artifacts/dtm_host.app \
  https://github.com/slavabars/soty/releases/latest/download/dtm_host.bin
chmod +x build-artifacts/dtm_host.app

# пароль по SSH без sshpass — через SSH_ASKPASS:
cat > /tmp/askpass.sh <<'EOF'
#!/bin/sh
echo "ВАШ_ПАРОЛЬ"
EOF
chmod +x /tmp/askpass.sh
export SSH_ASKPASS=/tmp/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0

./scripts/deploy-host.sh \
  --user dtm --host 85.198.75.50 \
  --listen 0.0.0.0 --port 3100 \
  --app build-artifacts/dtm_host.app
```

Если SSH-ключ уже настроен, `SSH_ASKPASS` не нужен.

Флаги `deploy-host.sh`:

| Флаг | Значение |
| --- | --- |
| `--user`, `--host` | SSH-пользователь и сервер (обязательны) |
| `--app PATH` | локальный бинарник (по умолчанию `../build-artifacts/dtm_host.app`) |
| `--listen`, `--port` | адрес и порт bind (по умолчанию `0.0.0.0:3100`) |
| `--name` | имя systemd-юнита (по умолчанию `soty-host`) |
| `--remote-dir` | каталог бинарника (по умолчанию `~/local`) |
| `--unit-only` | только пересоздать юнит, не заливать бинарник |
| `--no-restart` | не перезапускать сервис |
| `--invite-json` | вывести endpoint/ed25519/invite как JSON |

После установки:

```bash
ssh dtm@85.198.75.50 'systemctl --user status soty-host'
ssh dtm@85.198.75.50 'journalctl --user -u soty-host -n 50 --no-pager'
```

Чтобы user-сервис не останавливался после выхода из SSH, включите lingering
(один раз, от root): `loginctl enable-linger dtm`.

Invite-ссылка выглядит так:

```text
soty://host?addr=ws%3A%2F%2F85.198.75.50%3A3100%2Fws&pk=<ed25519-hex>
```

Её можно вшивать в приложение или импортировать в настройках «Relay hosts».
Ключ `ed25519` в invite обязателен: без него клиент не пинит релей.

## Релей #2 — shared-хостинг за nginx (TLS, без systemd)

На хостинге без root и systemctl релей слушает только `127.0.0.1:3100`, а
наружу смотрит через nginx как `wss://`. Процесс держит shell-супервизор
(`supervise.sh` + crontab `@reboot`). Скрипт `deploy-relay2.sh` всё это
раскладывает, перезапускает и проверяет.

```bash
./scripts/deploy-relay2.sh --check   # только проверить, без заливки
./scripts/deploy-relay2.sh           # обновить, перезапустить, проверить
```

Параметры по умолчанию (зашиты в скрипт): SSH-алиас `soty-relay2`, каталог
`~/dtm/`, публичный адрес `wss://price.dcns.ru/soty-ws`, seed на релей #1 и
ожидаемый Ed25519. Переопределить бинарник/ключ:

```bash
./scripts/deploy-relay2.sh --app build-artifacts/dtm_host.app
./scripts/deploy-relay2.sh --expect-ed <hex>
```

Скрипт падает с `IDENTITY CHANGED`, если Ed25519 в `host.log` не совпал с
ожидаемым: значит клиенты с пином отвалятся, обновление нужно остановить.
`host.db` не трогается никогда.

### nginx для релея #2

Готовый конфиг: `scripts/soty-ws-nginx-location.conf`. Положить в
`/etc/nginx/vhosts-resources/price.dcns.ru/soty-ws.conf` (этот include уже
подключён в обоих `server{}` провайдера) и выполнить `nginx -t && nginx -s
reload`.

```nginx
location = /soty-ws {
    proxy_pass http://127.0.0.1:3100/ws;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
```

Типовой `server{}` с TLS-терминацией:

```nginx
server {
    listen 443 ssl http2;
    server_name relay.example.com;

    ssl_certificate     /etc/letsencrypt/live/relay.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.example.com/privkey.pem;

    location = /soty-ws {
        proxy_pass http://127.0.0.1:3100/ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}

server {
    listen 80;
    server_name relay.example.com;
    return 301 https://$host$request_uri;
}
```

Почему так:

- `proxy_read_timeout 3600s` обязателен: дефолтные 60 s рвут простаивающую
  подписку каждую минуту.
- `proxy_http_version 1.1` + `Upgrade`/`Connection` включают WebSocket.
- Если :80 отвечает редиректом на :443, публичный адрес релея должен быть
  только `wss://`; `ws://` на :80 работать не будет.
- Если релей выключен, прокси вернёт 502 — сам сайт при этом не страдает.

## Федерация релеев

Релей #2 уже стартует с `--seed` на релей #1. Основной узел узнаёт адрес
второго из `NET`-приветствия и хранит его в таблице `federated_hosts`.
Для произвольной топологии хосты запускают так:

```bash
# хост 1
./dtm_host.app --db /srv/host1.db --listen 0.0.0.0 --port 3100 \
  --announce ws://relay1.example.com/ws \
  --peer "ws://relay2.example.com/ws|<ed25519-relay2>"

# хост 2
./dtm_host.app --db /srv/host2.db --listen 0.0.0.0 --port 3100 \
  --announce ws://relay2.example.com/ws \
  --peer "ws://relay1.example.com/ws|<ed25519-relay1>"
```

- `--peer ws://url/ws` — без пина; `--peer "ws://url/ws|hex"` — с пином
  Ed25519. Несовпадение `WELCOME.identity` рвёт соединение.
- `--seed` — алиас `--peer` для «уже работающего» узла.
- Федерация строится на исходящих линках. Для полного меша каждый узел должен
  перечислить остальных; длинные цепочки ограничены потолком хопов, поэтому
  держите путь до получателя ≤ 2–3 хопов.
- Ключи хостов берутся из их баннеров (`ed25519 <hex>`) и не меняются, пока
  живёт `host.db`.

## Проверка релея

`host_probe.py` выполняет тот же WebSocket-handshake и проверяет Ed25519:

```bash
python3 scripts/host_probe.py \
  ws://85.198.75.50:3100/ws \
  fad55cc762eda3f6cbc9c6522030ce8ec29e87143c9c78f452038d24143a4e82

python3 scripts/host_probe.py \
  wss://price.dcns.ru/soty-ws \
  dba88ecc7cd8053f76ddbe9c29d0bf63bb24e6234ebcaf9c074dcb0a1ce4b014
```

Ожидаемый результат — `WELCOME` с тем же ключом. Для релея #2 то же самое
делает `./scripts/deploy-relay2.sh --check`.

## Обновление релеев

1. Проще всего повторить установщик на каждой машине: он скачает свежий
   `dtm_host.bin`, проверит SHA-256 и перезапустит сервис. `host.db` при этом
   не меняется, Ed25519-идентичность сохраняется:

```bash
# Linux
sudo ./scripts/install-relay.sh --announce wss://relay.example.com/soty-ws
# macOS
./scripts/install-relay-macos.sh --announce wss://relay.example.com/soty-ws
# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File .\install-relay-windows.ps1 -Announce wss://relay.example.com/soty-ws
```

2. Либо обновите по SSH старыми скриптами:

```bash
./scripts/deploy-host.sh --user dtm --host 85.198.75.50 --invite-json
./scripts/deploy-relay2.sh
```

3. Обновите **оба** узла, иначе они разойдутся по версии протокола, и
   проверьте каждый через `host_probe.py` / `--check`.

## Эксплуатация и безопасность

- Не удаляйте `host.db`: в нём Ed25519-ключ и история. Потеря базы =
  `IDENTITY CHANGED` и недействительные пины у всех клиентов.
- Релей хранит только зашифрованные конверты в ограниченном окне и
  tracker-таблицу; ключи и плейнтекст недоступны.
- TLS обязателен для публичного релея вне локальной сети. Используйте
  `wss://` и пин Ed25519 в invite-ссылке.
- Логи релея #1: `journalctl --user -u soty-host`; релея #2:
  `~/dtm/host.log` и `~/dtm/status.sh`.
- Перезапуск релея #1: `systemctl --user restart soty-host`; релея #2:
  `~/dtm/start.sh` (или `stop.sh`).
