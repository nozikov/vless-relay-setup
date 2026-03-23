# VLESS Reality Relay — Self-Hosted Encrypted Tunnel

Двухзвенный зашифрованный туннель с TLS 1.3 маскировкой. Автоматическое развёртывание на два VPS-сервера.

🇬🇧 [English](README.en.md)

## Как это работает

![Архитектура](./docs/architecture.svg)

Relay-нода обеспечивает сетевую сегментацию: клиент подключается к ближайшему серверу, а выход в интернет идёт через удалённый.

![Сравнение: один хоп и два хопа](./docs/vpn_relay_comparison.svg)

Такая архитектура даёт:

- **Устойчивость** — если exit-нода недоступна, достаточно заменить её в одном месте, клиенты ничего не заметят
- **Сегментация** — разделение точки входа и выхода: метаданные разнесены по разным хопам
- **Низкий латенси** — клиент подключается к географически ближайшему серверу

### SelfSteal SNI (опционально)

Стандартный режим маскирует трафик под обращение к чужому домену (например, microsoft.com), но IP-адрес сервера не принадлежит этому домену. SelfSteal устраняет это несоответствие: вы указываете свой домен, и сервер хостит на нём реальный сайт через Caddy.

![SelfSteal: сравнение](./docs/selfsteal-comparison.svg)

SelfSteal полностью опциональный — если не хотите настраивать домен, просто нажмите Enter при установке. Если включён, Caddy также проксирует панель управления и подписки.

![Архитектура с SelfSteal](./docs/selfsteal-architecture.svg)

### CDN Fallback (опционально)

Резервный маршрут через Cloudflare CDN. Если прямой путь к серверу недоступен, трафик идёт через CDN — наблюдатель видит IP Cloudflare, а не вашего сервера.

![CDN: сравнение](./docs/cdn-comparison.svg)

CDN Fallback поддерживает два режима. В асимметричном — исходящий трафик идёт через CDN, а входящий напрямую (быстрее). В симметричном — весь трафик через CDN (максимальная устойчивость). Оба профиля доступны через подписку.

![Архитектура с CDN](./docs/cdn-architecture.svg)

CDN Fallback требует SelfSteal (нужен Caddy) и отдельный домен, подключённый к Cloudflare. Настройка Cloudflare — ручная (инструкция выводится при установке).

### DNS-фильтрация

Exit-нода использует AdGuard DNS для фильтрации рекламы и трекеров на уровне DNS. Клиентам ничего настраивать не нужно.

![DNS-фильтрация](./docs/dns-filtering.svg)

### Возможности

- **VLESS + XTLS-Reality** — протокол с TLS 1.3, минимальным оверхедом и SNI-маскировкой
- **Многоуровневый CDN Fallback** — резервные маршруты через Cloudflare с асимметричным режимом
- **Адаптивная защита соединений** — рандомизация размеров пакетов, ротация соединений, мультиплексирование
- **3X-UI панель** — веб-интерфейс для управления пользователями, лимитами трафика и мониторинга
- **Подписки** — автоматическое обновление конфигурации на клиентских устройствах
- **SSH hardening + fail2ban + UFW** — автоматическая настройка безопасности серверов
- **Backup / Rollback** — резервные копии при каждом обновлении с автоматическим откатом при ошибке

## Требования

- **2 VPS-сервера** с Ubuntu 24.04 LTS (минимум 1 CPU, 512 MB RAM)
  - Relay — ближайший к клиентам сервер для минимального латенси
  - Exit — удалённый сервер (другой регион или страна)
- **SSH-ключи** настроены для доступа к обоим серверам (скрипт отключает вход по паролю)
- **Домен** (опционально) — для подписок и/или SelfSteal режима
- **Домен для CDN Fallback** (опционально) — отдельный домен, подключённый к Cloudflare (бесплатный план). Требует SelfSteal

> **Важно:** SSH-ключи должны быть настроены до запуска скриптов.

## Подготовка

### SSH-ключи

```bash
# 1. Создать ключ (если ещё нет)
ssh-keygen -t ed25519

# 2. Скопировать ключ на сервер (повторить для каждого)
ssh-copy-id root@<IP-сервера>
```

После этого `ssh root@<IP>` должен пускать без пароля.

### Домен (опционально)

Если планируете использовать SelfSteal, настройте DNS A-записи **до запуска** скриптов:

| Запись | Назначение | Куда указывает |
|--------|-----------|----------------|
| `exit.example.com` | SelfSteal на exit-ноде | IP exit-сервера |
| `example.com` | SelfSteal на relay-ноде (основной домен) | IP relay-сервера |
| `panel.example.com` | Панель управления через Caddy | IP relay-сервера |
| `sub.example.com` | Подписки через Caddy | IP relay-сервера |

Без SelfSteal — достаточно одной A-записи на relay для подписок.

## Установка

![Шаги установки](./docs/installation-flow.svg)

> Всегда начинайте с exit-сервера — relay-серверу нужны его данные.

### Шаг 1. Exit-сервер

```bash
apt-get update && apt-get install -y git
git clone https://github.com/nozikov/vless-relay-setup.git && cd vless-relay-setup
chmod +x scripts/*.sh scripts/lib/*.sh
sudo ./scripts/setup.sh exit
```

> **Повторный запуск:** если exit уже настроен, скрипт предложит `update-exit`. Для переустановки: `--force`. Для пропуска SSH hardening: `--skip-ssh`.

Скрипт запросит настройки:

```
3X-UI panel port [34821]:              ← Enter для случайного порта
3X-UI panel secret path [a8Kx...]:     ← Enter для случайного пути
Admin username [admin]:                ← имя администратора
Admin password:                        ← пароль (не отображается)
Custom SSH port (Enter for default 22): ← порт SSH
Domain for SelfSteal SNI (Enter to skip): ← домен или Enter
```

При включении SelfSteal скрипт дополнительно установит Caddy, выпустит SSL-сертификат и предложит выбрать контент для сайта. Также спросит про CDN Fallback:

```
CDN domain for Cloudflare (Enter to skip): ← домен для CDN или Enter
```

Если указать CDN-домен, скрипт настроит CDN-маршрут через Caddy. В конце выведет инструкцию по настройке Cloudflare.

В конце скрипт выведет параметры подключения — **сохраните их** для настройки relay:

```
  Exit server IP:       185.x.x.x
  Exit UUID:            a1b2c3d4-...
  Exit Reality pubkey:  AbCdEfGh...
  Exit Reality shortId: 1a2b3c4d
  Exit Reality SNI:     exit.example.com
  Exit XHTTP path:     xK9mP2vL
```

Эти значения также сохраняются в `/root/exit-server-info.txt`.

### Шаг 2. Relay-сервер

```bash
apt-get update && apt-get install -y git
git clone https://github.com/nozikov/vless-relay-setup.git && cd vless-relay-setup
chmod +x scripts/*.sh scripts/lib/*.sh
sudo ./scripts/setup.sh relay
```

> **Повторный запуск:** `--force` для переустановки (все ключи будут пересозданы). `--skip-ssh` для пропуска SSH hardening.

Скрипт запросит параметры exit-сервера (из шага 1), затем настройки панели и (опционально) SelfSteal:

```
Exit server IP:                ← из шага 1
Exit server UUID:              ← из шага 1
...
Domain for SelfSteal SNI (Enter to skip): ← домен или Enter
```

При включении SelfSteal дополнительно:

```
Domain for 3X-UI panel (e.g. panel.example.com): ← поддомен для панели
Domain for subscriptions (Enter to skip):        ← поддомен для подписок
```

Без SelfSteal — скрипт спросит только домен для подписок (опционально).

### Шаг 3. Добавление пользователей

Откройте панель relay-сервера: `https://<relay-ip>:<port>/<path>/`

1. **Inbounds** → найдите инбаунд → **+ Add Client**
2. Укажите email (имя), лимиты трафика и срок действия
3. Скопируйте subscription-ссылку для пользователя

### Шаг 4. Настройка клиента

Передайте пользователю subscription-ссылку. В приложении: **Подписки → Добавить → Обновить → Подключиться**.

| Платформа | Приложение | Где скачать |
|-----------|-----------|------------|
| iOS | Streisand | [App Store](https://apps.apple.com/app/streisand/id6450534064) |
| Android | v2rayNG | [GitHub](https://github.com/2dust/v2rayNG) |
| Windows | v2rayN | [GitHub](https://github.com/2dust/v2rayN) |
| macOS | V2BOX | [App Store](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) |

## Структура проекта

![Структура проекта](./docs/project-structure.svg)

## Управление

### Обновление конфигурации

```bash
cd ~/vless-relay-setup && git pull

# Exit-сервер
sudo ./scripts/setup.sh update-exit

# Relay-сервер
sudo ./scripts/setup.sh update-relay
```

Ключи, UUID, клиенты и статистика **сохраняются**. Обновляется только шаблон конфигурации. Перед обновлением создаётся резервная копия с автоматическим откатом при ошибке.

При CDN Fallback `update-relay` автоматически синхронизирует CDN-ссылку с текущим exit UUID. Если UUID exit-сервера изменился — достаточно запустить `update-relay`, и подписки обновятся. Пользователям нужно только нажать "Обновить" в приложении.

Для обновления бинарников (XRAY, 3X-UI, Caddy) добавьте `--upgrade`:

```bash
sudo ./scripts/setup.sh update-exit --upgrade
sudo ./scripts/setup.sh update-relay --upgrade
```

### Удаление

```bash
sudo ./scripts/setup.sh uninstall           # с подтверждением
sudo ./scripts/setup.sh uninstall --force    # без подтверждения
sudo ./scripts/setup.sh uninstall --purge-certs  # удалить и SSL-сертификаты
```

SSH-ключи и `sshd_config` не удаляются — доступ к серверу сохраняется.

### Сервисы

```bash
# Exit-сервер
systemctl restart xray && systemctl status xray
journalctl -u xray -f

# Relay-сервер
x-ui restart && x-ui status
x-ui log
```

## Флаги командной строки

| Флаг | Где работает | Описание |
|------|-------------|----------|
| `--force` | setup, uninstall | Пропустить guard-проверку / подтверждение |
| `--skip-ssh` | setup, update | Не менять конфигурацию SSH |
| `--upgrade` | update | Обновить бинарники (XRAY, 3X-UI, Caddy) |
| `--purge-certs` | uninstall | Удалить SSL-сертификаты и acme.sh |

## Безопасность

| Компонент | Описание |
|-----------|----------|
| SSH | Только ключевая аутентификация, пароли отключены, опциональная смена порта |
| fail2ban | Блокировка IP после 3 неудачных попыток SSH на 1 час |
| UFW | Открыты только необходимые порты (SSH, 443, панель) |
| 3X-UI | Случайный порт + секретный URL-путь |
| Reality | TLS 1.3 с маскировкой SNI под легитимный домен |
| SelfSteal | Реальный сайт на вашем домене — полное соответствие SNI, IP, сертификата |
| Routing | Блокировка доступа к приватным подсетям (RFC 1918) через туннель |
| DNS | AdGuard DNS — фильтрация рекламы и трекеров |

## Устранение неполадок

**Логи установки:**
```bash
ls -la /var/log/vpn-setup-*.log
cat "$(ls -t /var/log/vpn-setup-*.log | head -1)"
```

**Не удаётся подключиться:**
```bash
# Exit
systemctl status xray
journalctl -u xray --no-pager -n 50

# Relay
x-ui status
x-ui log
```

**Не открывается панель:**
```bash
x-ui status
ufw status
```

**Потерял данные exit-сервера:**
```bash
cat /root/exit-server-info.txt
```

**HTTP 500 при добавлении клиента:**
```bash
# Проверить шаблон xray в 3X-UI
sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='xrayTemplateConfig';" | jq '.api'
# Если null — запустите update:
sudo ./scripts/setup.sh update-relay
```

## License

MIT
