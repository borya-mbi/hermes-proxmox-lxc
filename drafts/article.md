# Практичний гайд: деплой Hermes у Proxmox VE + LXC + vmbr1 NAT + Nginx Proxy Manager

_Автор: Borys Moyseenko_  
_Дата: 22 березня 2026_

## Для кого цей гайд і який результат очікується

Цей посібник для інженера, який хоче розгорнути [Hermes Agent](https://hermes-agent.nousresearch.com/) у Proxmox VE без окремого VLAN, у приватній мережі за `vmbr1`, з NAT на самому Proxmox-host і з зовнішнім HTTP/HTTPS через окремий LXC контейнер `Nginx Proxy Manager`.

Після виконання кроків ми отримуємо:

- golden template для LXC;
- один або кілька приватних Hermes-контейнерів;
- окремий `Nginx Proxy Manager LXC` як reverse proxy front door;
- NAT і DNAT у `/etc/network/interfaces` хоста Proxmox;
- домени і SSL на рівні NPM;
- Hermes як `systemd`-сервіс у кожному LXC.

Чому ця схема має сенс: Hermes — це persistent agent, який зберігає пам'ять, сесії, skills і контекст між запусками. Для нього важливі стабільне сховище, передбачувана мережа і нормальна ізоляція. Unprivileged LXC на Proxmox дає баланс між вартістю, керованістю і безпекою.

## Головна архітектурна ідея

Модель така:

```text
Internet
  |
Public IP on vmbr0
  |
Proxmox host
  |- vmbr0 -> uplink / public network
  |- vmbr1 -> 192.168.10.1/24
  |
  |- NPM LXC     -> 192.168.10.10
  |- Hermes 931  -> 192.168.10.31
  |- Hermes 932  -> 192.168.10.32
  |- Hermes 933  -> 192.168.10.33
```

Тобто відповідальність розділена так:

- Proxmox host відповідає за `vmbr0`, `vmbr1`, NAT і DNAT;
- `Nginx Proxy Manager` відповідає за `80/443`, домени, SSL і reverse proxy;
- Hermes-контейнери не виставляються напряму назовні і лишаються внутрішніми upstream-сервісами.

## Про DHCP

Чистий `Proxmox VE` не є DHCP-сервером "з коробки". Самого `/etc/network/interfaces` недостатньо, щоб він автоматично почав роздавати DHCP-адреси контейнерам.

Тому в цьому проєкті як базовий і надійний варіант закладено **статичні приватні IP**:

- `vmbr1` як внутрішня мережа;
- `192.168.10.1` як gateway;
- Hermes-контейнери отримують передбачувані адреси;
- NPM LXC теж має окремий приватний IP;
- назовні все йде через NAT на `vmbr0`.

Якщо згодом потрібен реальний DHCP, його варто додавати окремим сервісом на кшталт `dnsmasq` або `isc-dhcp-server`, але не ускладнювати цим базовий процес розгортання.

## Звідки береться Nginx Proxy Manager

Окремий LXC з `Nginx Proxy Manager` зручно піднімати helper script-ом із екосистеми `tteck/community-scripts` для Proxmox VE, а далі використовувати NPM як єдиний вхідний reverse proxy для веб-сервісів.

У цьому проєкті ми **не** автоматизуємо встановлення NPM всередині цього репозиторію, бо він розглядається як уже наявний окремий інфраструктурний контейнер. Тому ми:

- враховуємо його IP у конфігах;
- генеруємо DNAT-правила саме на нього;
- готуємо окремий план proxy-host записів для UI NPM.

## Передумови

До старту має бути готово:

- Proxmox-host із доступом до `pct`;
- `vmbr0` для публічної мережі;
- `vmbr1` для приватної підмережі;
- Debian 12 LXC template;
- окремий NPM LXC у тій самій приватній мережі;
- репозиторій Hermes або інший реальний install artifact;
- список доменів, які повинні йти через NPM до Hermes.

Якщо ви розгортаєте саме upstream [Hermes Agent](https://hermes-agent.nousresearch.com/), а не власний форк, офіційний quick install зараз такий:

```bash
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
```

За офіційною документацією [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent), це no-prerequisites installer для Linux, macOS і WSL2: він сам добирає Python 3.11 та інші залежності. У цьому каркасі ми все одно лишаємо `HERMES_INSTALL_CMD` і `HERMES_START_CMD` параметризованими, щоб однаково підтримувати upstream Hermes, внутрішній форк або кастомну збірку.

## Структура проєкту

Уже підготовлені такі артефакти:

- `README.md`
- `deploy/hermes-lxc.env`
- `deploy/hermes.env`
- `deploy/authorized_keys.example`
- `deploy/port-forwards.tsv`
- `deploy/npm-proxy-hosts.tsv`
- `scripts/create_golden_template.sh`
- `scripts/deploy_hermes.sh`
- `scripts/deploy_single_ct.sh`
- `scripts/bootstrap_hermes.sh`
- `scripts/generate_interfaces_nat_snippet.sh`
- `scripts/generate_npm_proxy_plan.sh`
- `scripts/health_check.sh`
- `scripts/update_hermes.sh`
- `scripts/cleanup.sh`
- `systemd/hermes-agent.service.tpl`
- `templates/proxmox_interfaces.vmbr1-nat.example`

## Старт із робочої директорії

Після клонування репозиторію на Proxmox-host:

```bash
cd /opt/deploy-hermes
bash scripts/init_local_config.sh
chmod +x scripts/*.sh scripts/lib/*.sh
```

Скрипт створить локальні draft-файли:

- `deploy/hermes-lxc.env`
- `deploy/hermes.env`
- `deploy/authorized_keys`
- `deploy/port-forwards.tsv`
- `deploy/npm-proxy-hosts.tsv`
- `deploy/container-notes.tsv`

## Базові параметри у `deploy/hermes-lxc.env`

Найважливіші поля:

```bash
TEMPLATE_CTID=9300
TEMPLATE_IMAGE=local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst
STORAGE=local-lvm

BRIDGE=vmbr1
HOST_WAN_IF=vmbr0
HOST_PUBLIC_IP=203.0.113.1

PRIVATE_SUBNET_CIDR=192.168.10.0/24
PRIVATE_GATEWAY=192.168.10.1
PRIVATE_PREFIX_LENGTH=24
STATIC_IP_PREFIX=192.168.10
STATIC_IP_START=31
IP_CONFIG=static

NPM_LXC_IP=192.168.10.10
NPM_HTTP_PORT=80
NPM_HTTPS_PORT=443
NPM_ADMIN_PORT=81
BASE_DOMAIN=yourdomain.com
PRIMARY_PUBLIC_DOMAIN=agent.yourdomain.com
PRIMARY_PUBLIC_CTID=931
NPM_ADMIN_DOMAIN=npm.yourdomain.com
ADMIN_DOMAIN_PREFIX=adm
HERMES_PUBLIC_PORT=8080
HERMES_ADMIN_PORT=8081
HERMES_HTTP_HEALTH_PATH=/

START_CTID=931
COUNT=1
NAME_PREFIX=hermes

CT_MEMORY=2048
CT_SWAP=512
CT_CORES=2
CT_ROOTFS_SIZE=8
CT_ONBOOT=1

PORT_FORWARD_FILE=deploy/port-forwards.tsv
NPM_PROXY_HOSTS_FILE=deploy/npm-proxy-hosts.tsv
AUTHORIZED_KEYS_FILE=deploy/authorized_keys
STORAGE_FREE_BUFFER_GB=2
LOCAL_HERMES_ENV_FILE=deploy/hermes.env
SYSTEMD_TEMPLATE_FILE=systemd/hermes-agent.service.tpl
```

Окремо важливо:

- `CT_UNPRIVILEGED=1` лишається стандартним і рекомендованим режимом для цього каркаса;
- `PRIMARY_PUBLIC_CTID` фіксує контейнер, який реально обслуговує `agent.yourdomain.com`;
- `AUTHORIZED_KEYS_FILE` - опційний локальний файл для SSH public keys;
- `HERMES_HTTP_HEALTH_PATH` використовується в розширеному `health-check` для внутрішнього HTTP probe.

## Ключові змінні, які реально впливають на експлуатацію

| Змінна | Де | Призначення |
| --- | --- | --- |
| `TEMPLATE_CTID` | `hermes-lxc.env` | CTID golden template |
| `STORAGE` | `hermes-lxc.env` | storage Proxmox для clone/rootfs |
| `BRIDGE` | `hermes-lxc.env` | Linux bridge для контейнерів |
| `PRIVATE_GATEWAY` | `hermes-lxc.env` | gateway приватної мережі `vmbr1` |
| `NPM_LXC_IP` | `hermes-lxc.env` | приватний IP контейнера Nginx Proxy Manager |
| `PRIMARY_PUBLIC_DOMAIN` | `hermes-lxc.env` | кореневий публічний домен |
| `PRIMARY_PUBLIC_CTID` | `hermes-lxc.env` | контейнер, на який дивиться `PRIMARY_PUBLIC_DOMAIN` |
| `ADMIN_DOMAIN_PREFIX` | `hermes-lxc.env` | префікс керуючих доменів, тут `adm` |
| `AUTHORIZED_KEYS_FILE` | `hermes-lxc.env` | локальний файл із SSH public keys |
| `HERMES_HTTP_HEALTH_PATH` | `hermes-lxc.env` | шлях для HTTP probe в `health_check.sh --http` |
| `HERMES_REPO_URL` | `hermes-lxc.env` | Git-джерело Hermes |
| `HERMES_INSTALL_CMD` | `hermes-lxc.env` | команда встановлення залежностей/app |
| `HERMES_START_CMD` | `hermes-lxc.env` | команда запуску Hermes |
| `OPENAI_API_KEY` | `hermes.env` | ключ моделі, локальний секрет |
| `HERMES_LISTEN_PORT` | `hermes.env` | внутрішній порт основного HTTP endpoint |
| `HERMES_ADMIN_LISTEN_PORT` | `hermes.env` | внутрішній порт admin/UI endpoint |
| `TELEGRAM_BOT_TOKEN` | `hermes.env` | токен бота від @BotFather (опціонально) |
| `TELEGRAM_ALLOWED_USER_IDS` | `hermes.env` | ID користувачів, яким дозволено доступ (опціонально) |


## Обчислення статичних IP

У цьому каркасі IP вираховується через:

- `STATIC_IP_PREFIX=192.168.10`
- `STATIC_IP_START=31`
- `START_CTID=931`

Отже:

- CT `931` -> `192.168.10.31`
- CT `932` -> `192.168.10.32`
- CT `933` -> `192.168.10.33`

Це зручно для документації, підтримки, reverse proxy та швидкої діагностики.

## Мінімальний runtime env для Hermes

У `deploy/hermes.env` лежать уже runtime-змінні самого агента:

```bash
OPENAI_API_KEY=replace-me
HERMES_MODEL=gpt-5.4-mini
HERMES_LOG_LEVEL=info
HERMES_LISTEN_HOST=0.0.0.0
HERMES_LISTEN_PORT=8080
HERMES_ADMIN_LISTEN_PORT=8081
HERMES_WORK_ROOT=/var/lib/hermes/work
HERMES_DATA_ROOT=/var/lib/hermes/data
HERMES_OUTPUT_ROOT=/var/lib/hermes/output
```

## Аутентифікація: OpenAI OAuth та OpenRouter

Якщо у вас немає платного API-ключа, або ви хочете мінімізувати витрати на старті, Hermes підтримує два основні "безкоштовні" або лояльні шляхи:

### 1. OpenAI OAuth (Моделі gpt-4o-mini)
OpenAI дозволяє використовувати деякі моделі через механізм пристроїв (Device Flow):
1. Не вказуйте `OPENAI_API_KEY` у `deploy/hermes.env`.
2. Задайте модель: `HERMES_MODEL=gpt-4o-mini`.
3. Після деплою перегляньте логи: `pct exec 931 -- journalctl -u hermes-agent -f`.
4. Знайдіть URL та код, перейдіть у браузер і підтвердіть доступ. Hermes автоматично отримає токен.

### 2. OpenRouter (Рекомендовано для старту)
Спільнота часто рекомендує [OpenRouter](https://openrouter.ai/) як найбільш гнучкий варіант. Він дає доступ до сотень моделей через один API-ключ, включаючи повністю безкоштовні варіанти через маршрут `openrouter/free`.
- У `deploy/hermes.env` вкажіть ваш ключ: `OPENAI_API_KEY=sk-or-v1-...`
- Вкажіть базу: `OPENAI_BASE_URL=https://openrouter.ai/api/v1`
- Виберіть модель, наприклад: `HERMES_MODEL=openrouter/free` або `google/gemini-2.0-flash-lite-preview-02-05:free`.

## Messaging Gateway та Telegram Threads

Hermes працює через месенджери; у цьому розділі ми розглянемо **Telegram** та **WhatsApp**.

### 1. Швидкий старт (Telegram)
1. Створіть бота через **@BotFather** (отримайте API Token буквально за хвилину).
2. Ініціалізуйте шлюз прямо в контейнері:
   ```bash
   pct exec 931 -- hermes gateway setup
   ```
3. Додайте токен у `deploy/hermes.env`: `TELEGRAM_BOT_TOKEN=...`.

### 2. Архітектура: Гілки (Threads) як окремі сесії
Найсильніша сторона роботи в групах Telegram — це використання **Threads**. 
- **Ізоляція контексту:** Кожна гілка автоматично стає окремою сесією. В одній гілці Hermes може бути вашим DevOps-інженером, в іншій — дослідником ринку. 
- **Багатозадачність:** Ви можете вести 5-10 проектів одночасно в межах однієї групи, і агент триматиме нитку розмови для кожного окремо.
- **Персоналізації:** Використовуйте команду `/personality` (наприклад, `/personality technical`), щоб задати специфічний стиль поведінки саме для цієї гілки.

### 3. Технічні нюанси та Troubleshooting
- **idle_timeout:** За замовчуванням сесія триває 120 хвилин. Для серйозних проектів цього замало. Ви можете змінити це значення у файлі `~/.hermes/gateway.json`.
- **Нічний ресет:** О 4 ранку контекст гілок (тимчасова історія) обнуляється для очищення пам'яті моделі, проте всі важливі факти, які агент витягнув під час розмови, залишаються у довготривалій пам'ятті (`MEMORY.md`).

### 4. Безпека
- **Ніколи** не ставте `GATEWAY_ALLOW_ALL_USERS=true` для бота, який має доступ до термінала вашого LXC.
- **DM Pairing:** Замість ручного прописування ID у `TELEGRAM_ALLOWED_USER_IDS`, використовуйте динамічне схвалення: `hermes pairing approve telegram <code>`.


## Збереження стану між сесіями

Для експлуатації важливо розуміти, що Hermes має не лише runtime-процес, а й локальний state.

- **Persistent memory:** Факти зберігаються в `MEMORY.md` і `USER.md`. 
- **Memory Nudges:** Агент автоматично аналізує контекст кожні **10 повідомлень (turns)**, щоб знайти нові факти для збереження.
- **SQLite State:** Сесії зберігаються у локальній базі SQLite з підтримкою FTS5 для швидкого пошуку по історії.
- **Обмеження:** Коли пам'ять наближається до лімітів, агент не росте безмежно, а консолідує або замінює записи.
- **Security Scan:** Перед будь-яким записом у файлову систему (`USER.md` або `MEMORY.md`), Hermes виконує перевірку на наявність prompt injections та невидимих символів.

## SOUL.md, AGENTS.md та procedural memory

Hermes уміє не лише пам'ятати факти, а й накопичувати робочі прийоми (skills).

- **SOUL.md:** Відповідає за загальну особистість (personality) та тон агента.
- **AGENTS.md:** Специфічний файл контексту, який автоматично зчитується кожної сесії. Це ідеальне місце для збереження **архітектурних рішень** або конвенцій коду, специфічних саме для цього конкретного LXC-контейнера.
- **Skills:** Живуть у `~/.hermes/skills/` і автоматично стають slash-командами. Агент може сам створювати нові skills після виконання нетривіальних задач (зазвичай 5+ tool calls).

## Доменна схема за замовчуванням

Для цього каркаса одразу закладена доменна схема навколо `yourdomain.com`:

- `agent.yourdomain.com` -> головний портал (точка входу, реклама, авторизація);
- `agent-931.yourdomain.com`, `agent-932.yourdomain.com`, `agent-933.yourdomain.com` -> індивідуальні чат-сторінки Hermes для кожного користувача/LXC;
- `adm-931.yourdomain.com`, `adm-932.yourdomain.com`, `adm-933.yourdomain.com` -> окремі керуючі сторінки Hermes для кожного LXC;
- `npm.yourdomain.com` -> опційний домен для UI `Nginx Proxy Manager`.

Важливий нюанс: **один і той самий FQDN не підходить для всіх керуючих сторінок різних LXC одночасно**. Тому найпрактичніша схема для NPM - це один кореневий домен для порталу (`agent.yourdomain.com`) і окремі піддомени для чату та адмінки кожного контейнера.
Для фіксації порталу використовується `PORTAL_CTID=930`. Для фіксації головного агента (якщо потрібно) — `PRIMARY_PUBLIC_CTID`.

## Публічні порт-форварди на NPM

Файл `deploy/port-forwards.tsv` описує **не прямий вхід у Hermes**, а зовнішні публічні порти, які повинні приходити на `Nginx Proxy Manager LXC`:

```text
# public_port<TAB>proto<TAB>target<TAB>target_port<TAB>description
80	tcp	npm	80	NPM public HTTP
443	tcp	npm	443	NPM public HTTPS
# 81	tcp	npm	81	NPM admin UI (expose only if really needed)
```

Тут `target=npm` означає: використовуй `NPM_LXC_IP` із `deploy/hermes-lxc.env`.

## Proxy Hosts для NPM

Файл `deploy/npm-proxy-hosts.tsv` описує вже не NAT на хості, а те, що потрібно створити в самому UI `Nginx Proxy Manager`:

```text
# domain<TAB>scheme<TAB>target<TAB>target_port<TAB>websocket<TAB>description
agent.yourdomain.com	http	930	80	true	Main Portal gateway
agent-931.yourdomain.com	http	931	8080	true	Hermes chat UI for CT 931
adm-931.yourdomain.com	http	931	8081	true	Hermes admin UI for CT 931
# npm.yourdomain.com	http	npm	81	false	NPM admin UI (optional)
```

Поле `target` може бути:

- CTID Hermes-контейнера;
- або прямий приватний IP.

Скрипт сам розгортає CTID у відповідну адресу `192.168.10.X`.

## Генерація стандартного набору доменів

Щоб не набивати `deploy/npm-proxy-hosts.tsv` вручну, можна згенерувати його з `deploy/hermes-lxc.env`:

```bash
bash scripts/generate_default_domains.sh
```

Скрипт бере:

- `PRIMARY_PUBLIC_DOMAIN`;
- `PRIMARY_PUBLIC_CTID`;
- `BASE_DOMAIN`;
- `ADMIN_DOMAIN_PREFIX`;
- `START_CTID`;
- `COUNT`;
- `HERMES_PUBLIC_PORT`;
- `HERMES_ADMIN_PORT`.

У базовому сценарії краще тримати `COUNT=1` і розгортати контейнери по одному. Для першого контейнера:

```text
agent.yourdomain.com -> 930:80
agent-931.yourdomain.com -> 931:8080
adm-931.yourdomain.com -> 931:8081
```

Коли додаємо другий або третій контейнер, файл краще не перезаписувати, а доповнювати:

```bash
bash scripts/generate_default_domains.sh --append 932
bash scripts/generate_default_domains.sh --append 933
```

Тоді `agent.yourdomain.com` залишиться прив'язаним до `PORTAL_CTID`, а в файл будуть додані лише:

```text
agent-932.yourdomain.com -> 932:8080
adm-932.yourdomain.com -> 932:8081
agent-933.yourdomain.com -> 933:8080
adm-933.yourdomain.com -> 933:8081
```

Після генерації файл можна за потреби вручну підправити або одразу використати як чернетку для внесення Proxy Host записів у NPM.

## Security baseline

Базові рішення по безпеці тут такі:

- LXC за замовчуванням запускається як unprivileged контейнер через `CT_UNPRIVILEGED=1`;
- локальні секрети та робочі файли з `deploy/` винесені з git через `.gitignore`;
- `deploy/authorized_keys` також не комітиться і може містити локальні SSH public keys;
- якщо потрібен реальний SSH-доступ у контейнер, треба або мати `openssh-server` у template, або додати його в `HERMES_APT_PACKAGES`;
- на рівні Proxmox варто окремо увімкнути `PVE Firewall` і фільтрувати небажані входи до DNAT/NPM.

Практичне правило: `npm.yourdomain.com` з портом `81` краще не публікувати зовні без потреби. Для admin UI NPM безпечніше використовувати VPN, jump host або доступ із довірених IP через firewall.


## Ізоляція та безпека (LXC vs Docker)

У нашому проекті **LXC** виступає як глобальна "пісочниця", що ізолює весь процес Hermes від хост-системи Proxmox. 

Проте важливо розуміти нюанс налаштування `TERMINAL_BACKEND` всередині самого Hermes:
- **Default (local):** Hermes виконує команди безпосередньо в оточенні, де він запущений (у нашому випадку — всередині LXC). При цьому він застосовує внутрішні перевірки на небезпечні команди (наприклад, блокує `rm -rf`).
- **Container Backend (docker, singularity тощо):** Якщо ви налаштуєте Hermes на використання суб-контейнерів для виконання коду, він **автоматично пропускає** перевірку на небезпечні команди. Агент вважає, що оскільки код і так у докері, то контейнер сам є достатньою межею безпеки.

## Preflight

Після редагування:

- `deploy/hermes-lxc.env`
- `deploy/hermes.env`
- `deploy/port-forwards.tsv`
- `deploy/npm-proxy-hosts.tsv`

виконати:

```bash
bash scripts/preflight_check.sh
```

Скрипт перевіряє:

- наявність `pct`;
- наявність env-файлів;
- наявність шаблона `systemd` unit;
- чи не лишився placeholder у `HERMES_REPO_URL`;
- валідність ключових IPv4/port полів;
- чи вільний діапазон CTID;
- який IP закладений для NPM;
- чи лишився `CT_UNPRIVILEGED=1`;
- чи є локальний `authorized_keys`;
- які мережеві параметри будуть застосовані.

## Шаблон `/etc/network/interfaces`

У проєкті є:

- `templates/proxmox_interfaces.vmbr1-nat.example`

Він показує базову схему:

- `vmbr0` з public IP;
- `vmbr1` з `192.168.10.1/24`;
- `ip_forward`;
- `POSTROUTING MASQUERADE`;
- базові `FORWARD`-правила;
- місце для вставки згенерованих DNAT-рядків.

## Генерація NAT/DNAT snippet для Proxmox

Скрипт:

```bash
bash scripts/generate_interfaces_nat_snippet.sh
```

друкує готові рядки для `/etc/network/interfaces`.

Він включає:

- `sysctl -w net.ipv4.ip_forward=1`
- `POSTROUTING MASQUERADE`
- `FORWARD` для виходу з `vmbr1` назовні;
- `FORWARD` для зворотного трафіку;
- `PREROUTING DNAT` з public IP на NPM LXC;
- `post-down` cleanup.

### Приклад результату

```text
post-up sysctl -w net.ipv4.ip_forward=1
post-up iptables -t nat -A POSTROUTING -s '192.168.10.0/24' -o vmbr0 -j MASQUERADE
post-up iptables -A FORWARD -i vmbr1 -o vmbr0 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
post-up iptables -A FORWARD -i vmbr0 -o vmbr1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
post-up iptables -t nat -A PREROUTING -i vmbr0 -p tcp -d 203.0.113.1 --dport 80 -j DNAT --to-destination 192.168.10.10:80
post-up iptables -A FORWARD -i vmbr0 -o vmbr1 -p tcp -d 192.168.10.10 --dport 80 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
```

## Генерація плану для NPM

Скрипт:

```bash
bash scripts/generate_npm_proxy_plan.sh
```

друкує таблицю для ручного внесення в `Nginx Proxy Manager`:

- domain;
- scheme;
- Forward Hostname / IP;
- Forward Port;
- чи потрібно вмикати Websocket Support;
- короткий опис.

Це зручно, бо NPM зазвичай адмініструють через UI, а не через bash automation.

## Підготовка golden template

```bash
bash scripts/create_golden_template.sh
```

Скрипт:

- створює базовий Debian 12 CT;
- підключає його до `vmbr1`;
- задає статичний IP або DHCP, залежно від `IP_CONFIG`;
- ставить базові пакети для Hermes;
- очищає `machine-id`;
- переводить контейнер у template.

Dry-run:

```bash
DRY_RUN=1 bash scripts/create_golden_template.sh
```

### Крок 0. Мережа хоста

Якщо `vmbr1` ще не налаштований або не має NAT:

1. Згенерувати snippet: `bash scripts/generate_interfaces_nat_snippet.sh`
2. Вставити згенеровані рядки у `/etc/network/interfaces` під секцію `vmbr1`
3. Застосувати: `ifreload -a` або перезавантажити networking
4. Перевірити: `iptables -t nat -S | grep MASQUERADE`

### Крок 1. Заповнити конфіги

Обов'язково перевірити:

- `HERMES_REPO_URL`
- `HERMES_REPO_REF`
- `HERMES_INSTALL_CMD`
- `HERMES_START_CMD`
- секрети в `deploy/hermes.env`

### Крок 2. Переглянути dry-run

```bash
DRY_RUN=1 bash scripts/deploy_single_ct.sh 931
```

> [!NOTE]
> За замовчуванням у [hermes-lxc.env](deploy/hermes-lxc.env) задано `DRY_RUN=1` — це safe default. Для реального деплою передавайте `DRY_RUN=0` як префікс (як у Кроці 3). Не змінюйте значення у файлі, щоб випадковий запуск скрипта без префікса лишався безпечним.

### Крок 3. Розгорнути контейнер

```bash
DRY_RUN=0 bash scripts/deploy_single_ct.sh 931
```

## Що робить `scripts/deploy_hermes.sh`

`scripts/deploy_single_ct.sh` - це базова обгортка для повсякденного сценарію "один контейнер за раз".
`scripts/deploy_hermes.sh` лишається нижчим рівнем для випадків, коли справді потрібно пройти діапазон CTID.

Для кожного CTID:

- клонує template;
- задає CPU, RAM, swap, `onboot`;
- налаштовує `net0` як:
  - `bridge=vmbr1`
  - `ip=192.168.10.X/24`
  - `gw=192.168.10.1`
  - унікальний `hwaddr`
- запускає контейнер;
- пушить bootstrap-файли;
- виконує bootstrap;
- перевіряє `systemctl is-active hermes-agent`;
- записує підсумок у `deploy/container_info.tsv`;
- невдалі CT додає в `deploy/failed_ctids.txt`.

Скрипт не конфігурує NPM напряму. Він лише підготовлює внутрішній Hermes upstream, який потім проксіюється через NPM.

## Що робить bootstrap у контейнері

Скрипт `scripts/bootstrap_hermes.sh`:

1. Встановлює базові пакети.
2. Створює системного користувача `hermes`.
3. Створює каталоги app/config/state/logs.
4. Клонує або оновлює репозиторій Hermes.
5. Виконує `HERMES_INSTALL_CMD`.
6. Копіює env-файл у `HERMES_ENV_FILE`.
7. Генерує `systemd` unit із шаблона.
8. Створює стартовий wrapper.
9. Виконує `systemctl enable --now hermes-agent`.

Якщо `deploy/authorized_keys` заповнений, bootstrap також встановить його як `authorized_keys` у контейнер. Це лише доставка ключів; для реального SSH-входу в контейнер має бути доступний `openssh-server`.

## Доступ до приватного Git-репозиторію Hermes

Є два практичні варіанти:

1. HTTPS + token у `HERMES_REPO_URL`.
2. SSH-доступ, якщо template або bootstrap уже мають потрібний deploy key і `known_hosts`.

Для цього посібника перший варіант простіший. Якщо потрібен другий, краще не змішувати його з `deploy/authorized_keys`: цей файл призначений для входу в контейнер, а не для доступу контейнера до зовнішнього Git.

## Локальна перевірка після Quick Start

### Health-check

```bash
bash scripts/health_check.sh 931 1 --http
```

Очікуваний результат:

```text
CTID    Status   IP             Service
931     running  192.168.10.31  active  http:200
```

### Перевірка Hermes напряму

```bash
pct exec 931 -- systemctl status hermes-agent --no-pager
pct exec 931 -- journalctl -u hermes-agent -n 100 --no-pager
pct exec 931 -- ip -4 -br addr show eth0
```

### Quick CLI: вхід і логи

Замість окремих скриптів — нативні команди Proxmox:

```bash
# Увійти до контейнера
pct enter 931

# Переглянути логи сервісу (останні 100 рядків + follow)
pct exec 931 -- journalctl -u hermes-agent -n 100 -f --no-pager
```

### Перевірка зв'язки через NPM

Після того як у NPM створений Proxy Host:

```bash
curl -I http://agent.yourdomain.com
curl -k -I https://agent.yourdomain.com
```

## Покрокове розширення

Базовий production-сценарій тут інкрементний:

1. Підняти перший контейнер: `DRY_RUN=0 bash scripts/deploy_single_ct.sh 931`
2. Додати його керуючий домен: `bash scripts/generate_default_domains.sh`
3. Підняти другий контейнер: `DRY_RUN=0 bash scripts/deploy_single_ct.sh 932`
4. Додати його керуючий домен: `bash scripts/generate_default_domains.sh --append 932`
5. Підняти третій контейнер: `DRY_RUN=0 bash scripts/deploy_single_ct.sh 933`
6. Додати його керуючий домен: `bash scripts/generate_default_domains.sh --append 933`

При цьому:

- `COUNT=1` може залишатися значенням за замовчуванням;
- `PRIMARY_PUBLIC_CTID=931` утримує `agent.yourdomain.com` на головному контейнері;
- нові LXC просто отримують наступні IP: `192.168.10.32`, `192.168.10.33` і так далі;
- для кожного нового контейнера в NPM додається окремий `adm-<ctid>.yourdomain.com`.

## Регулярні операції

### Health-check

```bash
bash scripts/health_check.sh
```

### Запуск контейнерів

```bash
bash scripts/start_containers.sh
```

### Зупинка контейнерів

```bash
bash scripts/stop_containers.sh
```

### Оновлення Hermes

```bash
DRY_RUN=0 bash scripts/update_hermes.sh
```

### Операції самого Hermes

```bash
hermes model
hermes --continue
```

Для довгих діалогів корисно також пам'ятати про `/compress`: за офіційною документацією Hermes стискає контекст автоматично при `threshold: 0.85`, але команду стиснення можна викликати і вручну.

### Notes у Proxmox

```bash
DRY_RUN=0 bash scripts/set_container_notes.sh
```

## Post-deploy validation

Перевірити службові файли:

```bash
cat deploy/container_info.tsv
cat deploy/failed_ctids.txt
```

Потім перевірити сервіс:

```bash
pct exec 931 -- systemctl is-active hermes-agent
pct exec 931 -- journalctl -u hermes-agent -n 100 --no-pager
```

І мережеву частину:

```bash
curl http://192.168.10.31:8080
curl -H 'Host: agent.yourdomain.com' http://203.0.113.1
```

Перша команда тестує Hermes напряму у приватній мережі, друга - вхідний шлях через NPM з правильним `Host` header.

## Troubleshooting

### Контейнер не має приватної IP

```bash
pct exec 931 -- ip -4 -br addr show eth0
pct config 931
```

Типові причини:

- помилка в `STATIC_IP_PREFIX`;
- неправильний `PRIVATE_GATEWAY`;
- bridge не `vmbr1`;
- контейнер створений зі старим env.

### Усередині контейнера немає коректного маршруту

```bash
pct exec 931 -- ip route
pct exec 931 -- ip -4 -br addr show eth0
```

Тут потрібно побачити default route через `192.168.10.1` і адресу з мережі `192.168.10.0/24`. Якщо цього немає, проблема не в Hermes і не в NPM, а в `net0`, `vmbr1` або gateway-конфігурації контейнера.

### NAT назовні не працює

На Proxmox-host:

```bash
iptables -t nat -S
iptables -S FORWARD
sysctl net.ipv4.ip_forward
```

Типові причини:

- немає `MASQUERADE` для `192.168.10.0/24`;
- `ip_forward=0`;
- бракує `FORWARD` правил;
- outbound interface не `vmbr0`;
- правила в `/etc/network/interfaces` вставлені не туди.

### Зовнішній порт не відкривається

Перевірити:

- чи є рядок у `deploy/port-forwards.tsv`;
- чи заново згенерований snippet;
- чи застосований він у `/etc/network/interfaces`;
- чи NPM LXC реально слухає `80/443`.

### Домен відкривається, але NPM віддає 502

Це вже проблема не Proxmox NAT, а зв'язки `NPM -> Hermes`.

Перевірити:

```bash
curl http://192.168.10.31:8080
```

У самому NPM звірити:

- `Forward Hostname / IP`;
- `Forward Port`;
- `Scheme`;
- `Websockets Support`.

### Bootstrap падає на git clone

```bash
pct exec 931 -- bash -lc 'git ls-remote "$HERMES_REPO_URL"'
```

Типові причини:

- placeholder у `HERMES_REPO_URL`;
- немає виходу назовні;
- немає DNS;
- приватний репозиторій вимагає токен або ключі.

### Агент зависає на небезпечній команді

Якщо здається, що Hermes "завмер" на кроці з `rm -rf`, destructive SQL або подібній дії, це може бути не зависання, а очікування command approval. Для Hermes це штатний захисний механізм.

У CLI це виглядає як очікування рішення користувача. У gateway-сценарії схвалення теж має проходити через відповідний messaging flow.

### Здається, що агент почав забувати контекст

Тут варто перевірити три різні механізми:

- **Bounded memory:** Файли `MEMORY.md` та `USER.md` мають ліміти. Старі факти можуть витіснятися новими.
- **Session Resume:** Використовуйте `hermes --continue` для відновлення сесії.
- **Memory Flush (Compression):** За замовчуванням механізм стиснення спрацьовує при заповненні 50% ліміту контексту моделі (або при `threshold: 0.85`). При стисненні агент залишає 3 перші та 4 останні повідомлення для збереження "нитки" розмови, решта стискається.

### Hermes не стартує як сервіс

```bash
pct exec 931 -- systemctl status hermes-agent --no-pager
pct exec 931 -- journalctl -u hermes-agent -n 100 --no-pager
```

Найчастіші причини:

- помилка в `HERMES_START_CMD`;
- не поставилися залежності через `HERMES_INSTALL_CMD`;
- у `deploy/hermes.env` не вистачає ключових змінних.

## Rollback і відновлення

Щоб зупинити і видалити невдалі або непотрібні CT:

```bash
DRY_RUN=0 bash scripts/cleanup.sh
```

Або явно вказати CTID:

```bash
DRY_RUN=0 bash scripts/cleanup.sh 931 932
```

Recovery flow:

1. Виправити `deploy/hermes-lxc.env`, `deploy/hermes.env`, `deploy/port-forwards.tsv` або `deploy/npm-proxy-hosts.tsv`.
2. Заново прогнати `bash scripts/preflight_check.sh`.
3. Переглянути план через `DRY_RUN=1 bash scripts/deploy_single_ct.sh <ctid>`.
4. Повторити реальний deploy.

## Definition of Done

- Є робочі draft-файли `deploy/hermes-lxc.env`, `deploy/hermes.env`, `deploy/port-forwards.tsv`, `deploy/npm-proxy-hosts.tsv`.
- Схема без окремого VLAN задокументована.
- Hermes-контейнери працюють у приватній мережі `vmbr1`.
- NPM LXC врахований як єдиний вхідний HTTP/HTTPS proxy layer.
- DNAT на Proxmox веде на NPM, а не напряму на Hermes.
- Для NPM є окремий план proxy-host записів.
- Hermes працює як `systemd`-сервіс.
- Є health-check, update і rollback.
