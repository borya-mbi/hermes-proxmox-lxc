# Практичний гайд: Multi-User деплой Hermes у Proxmox VE (v2)

_Автор: Borys Moyseenko_  
_Дата: 27 березня 2026_

## Для кого цей гайд

Цей посібник описує перехід до професійної DevOps архітектури розгортання [Hermes Agent](https://hermes-agent.nousresearch.com/). Замість моделі "один контейнер - один агент", ми переходимо до моделі **Multi-User LXC**. 

Це дозволяє запускати десятки незалежних інстансів Hermes та Claude Code на одному Proxmox хості, забезпечуючи ізоляцію даних, контроль ресурсів (cgroups) та зручний DTAP workflow через гілки Git.

## Нова архітектурна модель

Ми використовуємо один потужний LXC контейнер для кількох користувачів. Кожен користувач має свій ізольований home-директорій, власні API-ключі та окремий systemd-сервіс.

```text
Proxmox Host (IP: 203.0.113.12)
  |
  |- vmbr1 (Private Network: 192.168.10.1/24)
  |
  |- [LXC 931] (IP: 192.168.10.31) - Hermes Multi-User Node
       |- User: user1 (Prod) -> Service: hms@user1.service
       |- User: user2 (Prod) -> Service: hms@user2.service
       |- User: dev-user (Dev) -> Service: hms@dev-user.service
```

## Про DHCP та мережу

Ми продовжуємо використовувати статичні IP для контейнерів у мережі `vmbr1`. Це гарантує, що Nginx Proxy Manager завжди знайде потрібний upstream без додаткових сервісів discovery.

Приклад конфігурації мережі в `hermes-lxc.env`:
```bash
PRIVATE_SUBNET_CIDR=192.168.10.0/24
PRIVATE_GATEWAY=192.168.10.1
STATIC_IP_PREFIX=192.168.10
STATIC_IP_START=31
```

## Nginx Proxy Manager (NPM)

NPM залишається єдиною точкою входу для HTTP/HTTPS трафіку. Він направляє запити на IP контейнера, а далі Linux всередині контейнера розподіляє трафік між користувачами через різні порти (якщо активовано Web UI) або через Telegram вебхуки.

## Передумови

- Proxmox хост із налаштованим `vmbr1` та NAT.
- Debian 12 LXC template.
- Власний форк репозиторію `NousResearch/hermes-agent` на GitHub.
- API ключі Anthropic (для Claude Code) та Google Gemini / OpenRouter (для Hermes).

## Користувачі та середовища (DTAP)

Ми розділяємо користувачів на дві групи:
1. **Production (PROD)**: Використовують стабільну гілку (наприклад, `main`). Оновлюються через повну реінсталяцію бінарника.
2. **Development (DEV)**: Використовують експериментальну гілку (наприклад, `custom-features`). Оновлюються для швидкого тестування змін відповідної гілки.

Логіка керується змінними в `deploy/hermes-lxc.env`:
```bash
HERMES_PROD_USERS="user1 user2"
HERMES_DEV_USERS="dev-user"
HERMES_PROD_BRANCH=main
HERMES_DEV_BRANCH=custom-features
```

## Структура проєкту v2

- `scripts/lib/common.sh` - Спільні функції та парсинг env.
- `scripts/bootstrap_hermes.sh` - Скрипт повної підготовки контейнера.
- `scripts/upgrade_prod.sh` - Безпечне оновлення з бекапом та версіонуванням.
- `scripts/sync_configs.sh` - Розумна синхронізація шаблонів через `envsubst`.
- `systemd/hms@.service` - Template unit для всіх користувачів.

## Старт із робочої директорії

Клонуйте репозиторій автоматизації на Proxmox хост:
```bash
git clone https://github.com/your-username/hermes-proxmox-lxc.git /root/deploy-hermes
cd /root/deploy-hermes
# Створіть локальні конфіги з шаблонів одним скриптом
bash scripts/init_local_config.sh
```

## Базові параметри hermes-lxc.env

Відредагуйте `deploy/hermes-lxc.env`, вказавши власний форк:
```bash
HERMES_FORK_OWNER=my-github-nick
HERMES_FORK_REPO=hermes-agent
INSTALL_CLAUDE_CODE=true
CT_MEMORY=4096  # Збільшено для кількох користувачів
CT_CORES=4
```

## Per-user конфігурація

Кожен користувач має свою папку `~/.hermes/`, де лежать два критичних файли:
1. **.env**: API ключі та секрети.
2. **config.yaml**: Налаштування провайдерів, моделей та кастомний системний промпт.

Приклад `config.yaml` з підтримкою кастомних провайдерів:
```yaml
model:
  default: models/gemini-2.5-flash-lite
  provider: custom:google-m2
custom_providers:
  - name: google-m1
    base_url: https://generativelanguage.googleapis.com/v1beta/openai/
    api_key: ${GOOGLE_API_KEY_1}
  - name: google-m2
    base_url: https://generativelanguage.googleapis.com/v1beta/openai/
    api_key: ${GOOGLE_API_KEY_2}
  - name: google-m3
    base_url: https://generativelanguage.googleapis.com/v1beta/openai/
    api_key: ${GOOGLE_API_KEY_3}
```

## Claude Code: Per-user встановлення

Якщо ввімкнено `INSTALL_CLAUDE_CODE=true`, скрипт встановить Node.js v22 та виконає `npm install -g @anthropic-ai/claude-code` для кожного користувача. 
Використовується локальний префікс `~/.local`, тому користувачі не конфліктують між собою.

**Важливо**: Після деплою кожен користувач має виконати вхід:
```bash
su - user1 -c 'claude login'
```

Якщо команда видає помилку про відсутність TTY (`not a tty`), слід зайти в контейнер безпосередньо через `lxc console` або через SSH під конкретним користувачем для первинної авторизації.

## Безпека multi-user середовища

1. **Ізоляція прав**: Всі home-директорії мають `chmod 700`. Користувач `user1` не може зазирнути в пам'ять `user2`.
2. **Обмеження ресурсів**: Через systemd template ми задаємо жорсткі ліміти:
   - `MemoryMax=1.5G`
   - `CPUQuota=150%`
3. **Sudoers**: Файл `/etc/sudoers.d/hermes-users` дозволяє користувачам керувати **тільки своїм** сервісом:
   ```bash
   # Дозволено для користувача user1:
   sudo systemctl restart hms@user1.service
   ```
4. **Log Rotation**: Journald обмежено до 500MB, щоб логи багатьох агентів не переповнили диск.
5. **Ізоляція портів**: Кожен користувач отримує унікальний порт (наприклад, user1=8080, user2=8081), що запобігає конфліктам при одночасній роботі декількох агентів.

## Аутентифікація

Ми рекомендуємо використовувати `OpenRouter` як надійний fallback. У `deploy/hermes-user.env` вкажіть ваш ключ:
```bash
OPENAI_API_KEY=sk-or-v1-...
OPENAI_BASE_URL=https://openrouter.ai/api/v1
```

## Тимчасові файли та синхронізація

Скрипт `scripts/sync_configs.sh` використовує `envsubst` тільки для обраних змінних (наприклад, `$TG_CHANNEL_ID`). Це критично важливо, щоб випадково не стерти API ключі, які можуть містити символ гратки або долара.

Команда для синхронізації:
```bash
bash scripts/sync_configs.sh 931 user1
```

## Systemd template units

Ми використовуємо магію `%i` у назві сервісу. Файл `systemd/hms@.service` автоматично підставляє ім'я користувача всюди: від робочої директорії до назви процесу.

Команди керування:
```bash
systemctl status hms@user1.service
journalctl -u hms@user1.service -f
```

## Health-check

Новий скрипт моніторингу показує реальне споживання ресурсів кожним користувачем:
```bash
bash scripts/health_check.sh 931 1
```
Результат:
```text
CTID     User         Status     Service    Memory     CPU
931      user1        running    active     145MB      0.5%
931      dev-user     running    active     410MB      12.0%
```

## Регулярні операції

### Оновлення Prod
Використовуйте `upgrade_prod.sh`. Для багатокористувацьких контейнерів (v2) ми використовуємо двоетапний процес:
1. **Shared Bootstrap**: Файл `deploy/hermes-user.env` слугує шаблоном для першого запуску всіх користувачів.
2. **Individual Partitioning**: Після деплою адміністратор може зайти в контейнер і змінити `TG_CHANNEL_ID` у `~/.hermes/.env` конкретного користувача, після чого виконати `sync_configs.sh` для застосування змін.
Він зробить бекап бінарника, `hermes.db`, `.env` та `config.yaml` перед оновленням. У разі невдалого старту - автоматичний відкат:
```bash
bash scripts/upgrade_prod.sh 931 user1
```

### Додавання нового користувача
Якщо потрібно додати ще одного агента в існуючий контейнер:
```bash
bash scripts/add_user.sh 931 new-user
```

### Rollback
Якщо оновлення пройшло невдало:
```bash
bash scripts/rollback_user.sh 931 user1 20260327_210000
```

## Security Baseline v2

- **ProtectControlGroups=yes**: Забороняє агенту змінювати власні ліміти ресурсів.
- **ProtectSystem=full**: Робить `/etc` та `/usr` для агента доступними тільки для читання.
- **NoNewPrivileges=true**: Запобігає підвищенню прав через SUID бінарники.
