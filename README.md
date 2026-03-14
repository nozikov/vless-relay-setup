# Self-hosted Relay VPN

Двухзвенный VPN с маскировкой трафика под обычный HTTPS (VLESS + XTLS-Reality). Автоматическая установка на два VPS-сервера.

## Как это работает

```
┌─────────────┐        ┌─────────────────────┐        ┌─────────────────────┐       ┌──────────┐
│ Пользователь│        │   Relay-сервер (RU) │        │   Exit-сервер (NL)  │       │ Интернет │
│  (клиент)   │────────│                     │────────│                     │───────│          │
│             │ VLESS  │  3X-UI xray         │ VLESS  │  XRAY inbound       │       │          │
│  v2rayNG /  │ Reality│  inbound :443       │ Reality│  ↓                  │ HTTP/ │  google  │
│  Streisand  │  TCP   │  ↓                  │ XHTTP  │  XRAY outbound ─────│──TLS──│  youtube │
│             │  :443  │  outbound → exit ───│──:443──│                     │       │  ...     │
└─────────────┘        └─────────────────────┘        └─────────────────────┘       └──────────┘
    Телефон/ПК          Россия                         Европа / другая страна
```

**Зачем два сервера?**
- Relay в России — близко к пользователю, быстрый отклик, IP не заблокирован
- Exit за рубежом — выход в интернет с иностранным IP
- Между ними зашифрованный туннель VLESS + Reality + XHTTP (устойчив к DPI-блокировкам)

**Что такое Reality?**
XTLS-Reality маскирует VPN-трафик под обычное TLS-соединение к легитимному сайту (например, microsoft.com). Для внешнего наблюдателя трафик выглядит как обычный HTTPS.

## Требования

- **2 VPS-сервера** с Ubuntu 24.04 LTS (минимум 1 CPU, 512 MB RAM, любой хостинг-провайдер)
  - Один сервер в России (relay) — желательно ближайший к вам регион, чтобы пинг был минимальным
  - Один сервер за рубежом (exit) — Нидерланды, Германия, Финляндия и т.д.
- **Домен** (опционально) — нужен для подписок (автообновление конфига клиентов). VPN работает и без домена, просто подписки будут недоступны
- **SSH-ключи** настроены для доступа к обоим серверам (см. раздел "Подготовка" ниже)

> **Важно:** SSH-ключи должны быть настроены ДО запуска скриптов, потому что скрипт отключает вход по паролю.

## Подготовка

### SSH-ключи

Скрипт отключает вход по паролю, поэтому SSH-ключи — обязательный шаг. Если SSH-ключи у вас уже настроены (вы заходите на сервер без ввода пароля), переходите к следующему разделу.

**На вашем компьютере** (не на сервере):

```bash
# 1. Создать ключ (если ещё нет)
ssh-keygen -t ed25519

# 2. Скопировать ключ на сервер (повторить для каждого сервера)
ssh-copy-id root@<IP-адрес-сервера>
```

После этого `ssh root@<IP>` должен пускать без пароля.

### Домен (опционально)

Домен нужен только для подписок — механизма, который позволяет клиентским приложениям автоматически получать обновлённый конфиг VPN. Если вы настраиваете VPN для себя и нескольких знакомых, можно обойтись без домена.

Если домен нужен — подойдёт любой дешёвый домен (или поддомен имеющегося). A-запись настраивается после развёртывания relay-сервера.

## Пошаговое развёртывание

### Шаг 1. Настройка exit-сервера

> Всегда начинайте с exit-сервера, потому что relay-серверу нужны его данные для подключения.

Подключитесь к exit-серверу по SSH и выполните:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/nozikov/vless-relay-setup.git && cd vless-relay-setup
chmod +x scripts/*.sh scripts/lib/*.sh
sudo ./scripts/setup.sh exit
```

Скрипт запросит настройки панели управления:

```
=== Configuration ===
3X-UI panel port [34821]:          ← Enter (или свой порт)
3X-UI panel secret path [a8Kx...]: ← Enter (или свой путь)
Admin username [admin]:            ← Enter (или своё имя)
Admin password:                    ← введите пароль (не отображается при вводе)
```

Затем скрипт автоматически:
- Обновит систему и установит зависимости
- Установит XRAY-core
- Выберет лучший Reality-сайт для маскировки
- Сгенерирует ключи и UUID
- Установит 3X-UI панель
- Настроит файрвол и fail2ban

В конце выведет данные для relay-сервера — **сохраните их**:

```
-------------------------------------------
  Values for RELAY server setup:
-------------------------------------------
  Exit server IP:       185.x.x.x
  Exit server port:     443
  Exit UUID:            a1b2c3d4-e5f6-7890-abcd-ef1234567890
  Exit Reality pubkey:  AbCdEfGhIjKlMnOpQrStUvWxYz1234567890abc
  Exit Reality shortId: 1a2b3c4d
  Exit Reality SNI:     www.microsoft.com
  Exit XHTTP path:     xK9mP2vL
-------------------------------------------
```

Эти значения также сохраняются на сервере в файле `/root/exit-server-info.txt`.

### Шаг 2. Настройка relay-сервера

Подключитесь к relay-серверу по SSH и выполните:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/nozikov/vless-relay-setup.git && cd vless-relay-setup
chmod +x scripts/*.sh scripts/lib/*.sh
sudo ./scripts/setup.sh relay
```

Скрипт запросит данные exit-сервера — **вставьте значения из шага 1**:

```
=== Exit Server Connection Details ===
Enter the values from exit server setup:

Exit server IP:                ← 185.x.x.x
Exit server port [443]:        ← Enter
Exit server UUID:              ← a1b2c3d4-e5f6-7890-abcd-ef1234567890
Exit server Reality public key: ← AbCdEfGhIjKlMnOpQrStUvWxYz1234567890abc
Exit server Reality short ID:  ← 1a2b3c4d
Exit server Reality SNI:       ← www.microsoft.com
Exit server XHTTP path:       ← xK9mP2vL
```

Затем запросит настройки панели и (опционально) домен:

```
=== Relay Configuration ===
3X-UI panel port [41532]:                              ← Enter (или свой порт)
3X-UI panel secret path [xK9m...]:                     ← Enter (или свой путь)
Admin username [admin]:                                ← Enter
Admin password:                                        ← введите пароль
Domain for subscriptions, optional, Enter to skip:     ← домен или Enter чтобы пропустить
```

Скрипт автоматически:
- Установит XRAY-core и сгенерирует Reality-ключи для relay
- Установит и настроит 3X-UI панель
- Если указан домен: настроит подписки и выпустит SSL-сертификат
- Создаст VLESS Reality inbound (порт 443) с маршрутизацией на exit-сервер
- Создаст пользователя по умолчанию
- Настроит файрвол и fail2ban

В конце выведет:

```
  Panel:     https://91.x.x.x:41532/xK9m.../

  Subscriptions:
  Base URL:  https://vpn.example.com:41533/aB3d.../
  Default:   https://vpn.example.com:41533/aB3d.../f0e1d2c3b4a59687

  DNS: set A-record vpn.example.com → 91.x.x.x
```

### Шаг 3. Настройка DNS (если указан домен)

В панели управления вашего домена создайте A-запись:

```
vpn.example.com → 91.x.x.x  (IP вашего relay-сервера)
```

Если вы пропустили домен на шаге 2 — этот шаг не нужен.

### Шаг 4. Добавление пользователей

Откройте панель relay-сервера: `https://<relay-ip>:<port>/<path>/`

1. **Inbounds** → найдите инбаунд (название вида "Москва → Амстердам") → нажмите **+ Add Client**
2. Укажите email (имя пользователя), лимиты трафика и срок действия
3. Нажмите **Add Client**
4. Если подписки настроены — скопируйте subscription-ссылку для пользователя

### Шаг 5. Настройка клиента

Передайте пользователю subscription-ссылку (или конфиг вручную). Он вставляет её в приложение — и VPN работает.

| Платформа | Приложение | Где скачать |
|-----------|-----------|------------|
| iOS | Streisand | [App Store](https://apps.apple.com/app/streisand/id6450534064) |
| Android | v2rayNG | [GitHub](https://github.com/2dust/v2rayNG) |
| Windows | v2rayN | [GitHub](https://github.com/2dust/v2rayN) |
| macOS | V2BOX | [App Store](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) |

В приложении: **Подписки** → **Добавить** → вставить ссылку → **Обновить** → **Подключиться**.

## Структура проекта

```
scripts/
├── setup.sh           # Точка входа: ./setup.sh [exit|relay|update-exit|update-relay|uninstall]
├── setup-exit.sh      # Настройка exit-сервера
├── setup-relay.sh     # Настройка relay-сервера
├── update-exit.sh     # Обновление exit-сервера без переустановки
├── update-relay.sh    # Обновление relay-сервера без переустановки
├── uninstall.sh       # Удаление всех VPN-компонентов
└── lib/
    ├── common.sh      # Общие функции (логирование, ввод, валидация)
    ├── security.sh    # Безопасность (SSH, UFW, fail2ban)
    ├── reality.sh     # Подбор Reality-сайта и генерация ключей
    ├── xray.sh        # Установка и конфигурация XRAY-core
    ├── 3xui.sh        # Установка и настройка 3X-UI панели
    └── verify.sh      # Проверки после установки (сервисы, порты, связь)
```

## Управление

### Добавление/удаление пользователей

Через 3X-UI панель на relay-сервере: `https://<relay-ip>:<port>/<path>/`

1. **Inbounds** → найдите ваш инбаунд → **+ Add Client**
2. Укажите email (имя), лимиты трафика и срок действия
3. Скопируйте subscription-ссылку для пользователя

Для удаления: нажмите **×** рядом с клиентом.

### Перезапуск сервисов

```bash
# Exit-сервер — XRAY (системный сервис)
systemctl restart xray
systemctl status xray

# Relay-сервер — 3X-UI (управляет своим xray-процессом)
x-ui restart
x-ui status
```

### Просмотр логов

```bash
# Exit-сервер
journalctl -u xray -f

# Relay-сервер
x-ui log
tail -f /var/log/xray/access.log
```

### Обновление конфигурации

Если вы изменили скрипты (например, обновили шаблон конфига) и хотите применить изменения на работающих серверах — не нужно переустанавливать. Достаточно подтянуть свежий код и запустить update:

```bash
cd ~/vless-relay-setup && git pull

# Exit-сервер — обновить конфиг XRAY, security, apt upgrade
sudo ./scripts/setup.sh update-exit

# Relay-сервер — обновить xray-шаблон в 3X-UI, security, apt upgrade
sudo ./scripts/setup.sh update-relay
```

Ключи, UUID, клиенты, подписки и статистика трафика **сохраняются** — обновляется только шаблон конфигурации из кода.

Для обновления бинарников (XRAY, 3X-UI) добавьте флаг `--upgrade`:

```bash
sudo ./scripts/setup.sh update-exit --upgrade
sudo ./scripts/setup.sh update-relay --upgrade
```

### Удаление

Для полной очистки сервера (удаляет 3X-UI, XRAY, fail2ban, UFW):

```bash
sudo ./scripts/setup.sh uninstall
```

SSL-сертификаты и acme.sh **сохраняются** по умолчанию (чтобы при повторной установке не упереться в rate-limit Let's Encrypt). Для полного удаления вместе с сертификатами:

```bash
sudo ./scripts/setup.sh uninstall --purge-certs
```

Для автоматической очистки без подтверждения:

```bash
sudo ./scripts/setup.sh uninstall --force
```

SSH-ключи и `sshd_config` **не удаляются** — доступ к серверу сохраняется.

## Безопасность

| Компонент | Что настроено |
|-----------|--------------|
| SSH | Только ключевая аутентификация, пароли отключены |
| fail2ban | Блокировка IP после 3 неудачных попыток на 1 час |
| UFW | Открыты только нужные порты: SSH, XRAY (443), панель, подписки |
| 3X-UI | Доступ по случайному порту + секретному URL-пути |
| Reality | Трафик неотличим от обычного TLS (маскировка под легитимный сайт) |
| SSL | Автоматический сертификат Let's Encrypt для домена подписок |

## Устранение неполадок

**Не могу подключиться к VPN:**
```bash
# Exit-сервер: проверить что XRAY запущен
systemctl status xray
journalctl -u xray --no-pager -n 50

# Relay-сервер: проверить 3X-UI и его xray
x-ui status
x-ui log
```

**Не открывается панель 3X-UI:**
```bash
# Проверить статус
x-ui status

# Проверить что порт открыт в файрволе
ufw status
```

**Потерял данные exit-сервера:**
```bash
# Данные сохранены на exit-сервере
cat /root/exit-server-info.txt
```

**HTTP 500 при добавлении клиента:**

Если после ручного `x-ui restart` перестали добавляться клиенты, возможно 3X-UI стёр `api`/`stats`/`policy` из xray-шаблона при рестарте:
```bash
# Проверить наличие api в шаблоне
sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='xrayTemplateConfig';" | jq '.api'
# Если null — запустите update для восстановления шаблона:
# sudo ./scripts/setup.sh update-relay
```
