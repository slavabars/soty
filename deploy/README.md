# Развёртывание relay-хоста Soty

`dtm_host` — это операторский узел «**relay + tracker**»:

- **relay** — хранит непрозрачные зашифрованные конверты и отдаёт их получателю, когда тот онлайн (офлайн-доставка). Содержимое он прочитать не может;
- **tracker** — по `PEER_LIST` знакомит устройства адресами, чтобы они соединялись напрямую (libp2p), минуя хост;
- **federation** — несколько хостов связываются флагами `--peer`/`--seed` и обмениваются конвертами (живой релей + догоняющая антиэнтропия).

Один хост уже вшит в приложение по умолчанию, так что офлайн-доставка работает «из коробки». Свой хост нужен, если вы хотите не зависеть от чужого оператора.

## Требования

- Linux x86-64, `libsqlite3` (Alma/RHEL: `dnf install -y sqlite-libs`; Debian/Ubuntu: `apt-get install -y libsqlite3-0`);
- `python3` — только для проверки (`--check` / `host_probe.py`);
- для nginx-варианта — установленный nginx;
- для системных вариантов — root/`sudo`; для `systemd-user` и `nohup` root не нужен.

Сам бинарь **не лежит в этом репозитории**: скачайте `dtm_host.bin` из раздела [Releases](https://github.com/slavabars/soty/releases) (это тот же файл, что `dtm_host.app`; GitHub не принимает расширение `.app` у файлов релиза) или соберите сами (`dart compile exe bin/dtm_host.dart -o dtm_host`).

## Быстрый запуск без установки

```bash
chmod +x dtm_host.bin
./dtm_host.bin --db ./host.db --listen 0.0.0.0 --port 3100
```

В лог печатается баннер с Ed25519-ключом и invite-ссылкой. Это подходит для теста; для постоянной работы используйте `deploy-host.sh`.

## Установка через `deploy-host.sh`

```bash
./deploy-host.sh --app ./dtm_host.bin --announce ws://relay.example.com:3100/ws
```

Скрипт копирует бинарь, рендерит конфиг выбранного рантайма из шаблонов в `systemd/`, `supervisor/`, `nohup/`, ставит его, запускает сервис и в конце печатает invite-ссылку с ключом. Все флаги — `./deploy-host.sh --help`; ключевые:

| Флаг | Смысл |
| --- | --- |
| `--ssh USER@HOST` | поставить на удалённый сервер по ssh (по умолчанию локально) |
| `--app PATH` | локальный бинарь (по умолчанию `./dtm_host.bin`) |
| `--runtime MODE` | `systemd-user` (умолч.), `systemd-system`, `supervisor`, `nohup`, `auto` |
| `--sudo` / `--no-sudo` | требовать root/sudo или явно запретить его |
| `--listen` / `--port` | адрес и порт (по умолчанию `0.0.0.0:3100`) |
| `--announce URL` | публичный `ws(s)://…` для баннера и федерации |
| `--peer SPEC` / `--seed SPEC` | пиры федерации (можно повторять) |
| `--nginx` | поставить `server{}` с WebSocket-прокси |
| `--bindir` / `--datadir` | каталоги бинаря и `host.db` |
| `--unit-only` | не заливать бинарь, только (пере)создать конфиг |
| `--print-config` | показать отрендеренные конфиги и выйти |
| `--check` | только проверить запущенный хост (см. ниже) |

Примеры:

```bash
# сервер, где есть root: системный systemd под отдельным пользователем, за nginx
./deploy-host.sh --ssh dtm@relay.example.com --runtime systemd-system \
    --nginx --announce wss://relay.example.com/soty-ws

# хостинг без root (как dcns.ru): shell-супервизор + cron @reboot, только localhost
./deploy-host.sh --runtime nohup --no-sudo --listen 127.0.0.1

# не думать о правах: auto выберет systemd-system / systemd-user / nohup
./deploy-host.sh --runtime auto

# связать с уже существующим хостом (федерация)
./deploy-host.sh --seed 'ws://relay1.example.com:3100/ws|<ed25519 релея1>'
```

## С sudo и без sudo

`deploy-host.sh` **не требует** root: он сам определяет права на целевом сервере (root / passwordless sudo / нет) и наличие systemd, и дальше всё зависит от выбранного `--runtime`:

- `systemd-user` и `nohup` — **без root вообще**; `sudo` не вызывается ни разу;
- `systemd-system` и `supervisor` — нужен root или `sudo` без пароля (иначе скрипт честно откажется и подскажет user-варианты);
- `--runtime auto` — выберет сам: `systemd-system`, если есть root/sudo и systemd, иначе `systemd-user`, иначе `nohup`;
- `--no-sudo` — запретить sudo принудительно (гарантированно без root);
- `--sudo` — наоборот, требовать root/sudo.

Проверка идёт на **самом сервере** (той же ssh-сессией), поэтому offline-флаги и логи читаются там же. Если `--nginx` запрошен без root, конфиг не пишется в `/etc/nginx`, а кладётся в `~/soty-server.conf` с инструкцией — на шаред- хостинге vhost принадлежит провайдеру.

### Рецепт «как на dcns.ru» (без root и без systemd)

```bash
./deploy-host.sh \
  --ssh user@dcns.ru \
  --runtime nohup --no-sudo \
  --listen 127.0.0.1 --port 3100 \
  --announce wss://price.dcns.ru/soty-ws \
  --nginx                       # конфиг приземлится в ~/soty-server.conf
```

Что получается: бинарь и скрипты в `~/local`, `host.db` и логи в `~/soty`, супервизор поднимается `nohup`/`setsid` и прописывается в `crontab @reboot`, а nginx-`location` вы добавляете в свой `server{}` с TLS (провайдерский) и перезагружаете nginx. Управление — `~/local/start.sh|stop.sh|status.sh`.


## Варианты запуска

| Рантайм | Root | Автозапуск | Где логи | Когда выбирать |
| --- | --- | --- | --- | --- |
| `systemd-user` | нет | `systemctl --user` (после логина / linger) | `journalctl --user -u soty-host` | свой сервер, обычный пользователь |
| `systemd-system` | да | systemd-юнит под `User=soty` | `journalctl -u soty-host` | сервер под управлением root, «всегда включён» |
| `supervisor` | да | supervisord | `<datadir>/host.log` | уже используются supervisor-ы |
| `nohup` | нет | скрипт-супервизор + cron `@reboot` | `<datadir>/host.log` | шаред-хостинг без systemd/root (dcns.ru) |

Каждому рантайму соответствует шаблон, который `deploy-host.sh` рендерит и кладёт рядом с `install.sh`:

- `systemd/soty-host.user.service`, `systemd/soty-host.system.service`
- `supervisor/soty-host.conf`
- `nohup/supervise.sh`, `nohup/start.sh`, `nohup/stop.sh`, `nohup/status.sh`

Для `systemd-user`, если сервис должен жить без активной сессии: `loginctl enable-linger "$USER"`.

Управление (для `nohup`-варианта команды лежат в `--bindir`):

```bash
systemctl --user restart soty-host      # или: sudo systemctl restart soty-host
sudo supervisorctl restart soty-host
"$BINDIR/start.sh"                      # nohup: start/restart
"$BINDIR/stop.sh"; "$BINDIR/status.sh"
```

## nginx как WebSocket-прокси

Хост отдаёт WebSocket по пути `/ws`. Если он слушает `127.0.0.1:3100`, а наружу должен смотреть через nginx — есть два готовых конфига.

**`nginx/soty-server.conf`** — самодостаточный `server{}` (его ставит `--nginx`):

```nginx
server {
    listen 80;
    server_name relay.example.com;
    location = /soty-ws {
        proxy_pass http://127.0.0.1:3100/ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

**`nginx/soty-location.conf`** — только `location`, чтобы вставить его в уже существующий `server{}` с вашим TLS:

```nginx
location = /soty-ws { proxy_pass http://127.0.0.1:3100/ws; /* … */ }
```

TLS (`wss://`) — отдельным `server{}` на 443; публичный адрес тогда `wss://relay.example.com/soty-ws`:

```nginx
server {
    listen 443 ssl;
    server_name relay.example.com;
    ssl_certificate     /etc/letsencrypt/live/relay.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.example.com/privkey.pem;
    include /etc/nginx/conf.d/soty-location.conf;
    location / { return 404; }
}
```

Обязательные детали:

- **`proxy_read_timeout 3600s`** — дефолт 60 с рвал бы простаивающую подписку каждую минуту;
- если в `server{}` для :80 стоит `return 301 https://…`, то `ws://` на 80 не заработает (rewrite-фаза раньше выбора `location`) — публичный адрес должен быть `wss://`;
- после правки: `nginx -t && nginx -s reload`.

## Федерация хостов

Хосты не обнаруживают друг друга сами — список задаёт оператор. Формат `--peer <spec>`: `"ws://host:3100/ws"` (без пина) или `"ws://host:3100/ws|ed25519hex"` (с пином; при несовпадении `WELCOME.identity` соединение рвётся — защита от подмены релея).

```bash
# хост 1
./dtm_host --db /srv/host1.db --listen 0.0.0.0 --port 3100 \
  --announce ws://relay1.example.com/ws \
  --peer "ws://relay2.example.com/ws|<relay2 ed25519>"

# хост 2 (симметрично!)
./dtm_host --db /srv/host2.db --listen 0.0.0.0 --port 3100 \
  --announce ws://relay2.example.com/ws \
  --peer "ws://relay1.example.com/ws|<relay1 ed25519>"
```

Федерация строится на **исходящих** линках — для полной связки каждый хост должен перечислить остальных. `--seed` — то же, но хост сразу принимает сеть пира за свою (для подключения нового узла к существующей сети).

Ключи пиров берутся из их баннеров (`ed25519 <hex>`) при первом запуске.

## Проверка хоста

`host_probe.py` делает тот же handshake, что и приложение (WebSocket upgrade + `HELLO` → `WELCOME`), и сверяет Ed25519-ключ с ожидаемым — то есть зелёный прогон означает, что устройство примет invite:

```bash
python3 host_probe.py ws://relay.example.com:3100/ws  <ed25519>
python3 host_probe.py wss://relay.example.com/soty-ws  <ed25519>
```

Через инсталлятор: `./deploy-host.sh --check --announce <url> --expect-ed <hex>`.

## Invite-ссылка

Баннер печатает invite, который вшивается в приложение или добавляется в настройках «Relay hosts»:

```
soty://host?addr=<urlencoded ws(s)://…>&pk=<ed25519 hex>
```

При сборке приложения адрес вшивается через `--dart-define=SOTY_BOOTSTRAP_HOST='ws://relay.example.com:3100/ws?identity=<ed25519>'` (им же пользуются e2e-сборки `soty_deviceA/B.apk`).

## Эксплуатация

- **Никогда не удаляйте `host.db`** при обновлении: Ed25519-ключ лежит в `host_state.ed_seed`, клиенты его пинят — новая БД = все пины отвалились. Обновление = заменить бинарь и перезапустить сервис.
- Логи — см. таблицу выше; `host.log` рядом с `host.db` для supervisor/nohup.
- Открывать наружу нужно только `--port` (или ничего, если стоит nginx).
- Хост хранит лишь зашифрованные конверты (окно релея + 30-дневный прунинг с подписанными Merkle-корнями) и таблицу трекера; плейнтекст и ключи пользователей — нет.

## Что может пойти не так

- `error: на сервере нет libsqlite3` — поставьте `sqlite-libs` / `libsqlite3-0`.
- Сервис не поднимается в `systemd-user` — `loginctl enable-linger`, затем `systemctl --user status soty-host`.
- **Остановка `nohup`-варианта идёт по pid-файлу** (`<datadir>/supervise.pid`), а бинарь ищется по заанкоренному `pkill -f '^<путь> '`: шаблон без `^` матчит любую команду, в тексте которой есть путь (включая сам install-скрипт) — на этом уже обжигались.
- `proxy_read_timeout` по умолчанию рвёт подписку — держите `3600s`.
- Реле не отвечает, но порт слушается — проверьте, что `--announce` совпадает с публичным URL, и прогоните `host_probe.py`.
