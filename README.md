# deploy-hermes

Інструментарій для автоматизованого деплою [Hermes Agent](https://hermes-agent.nousresearch.com/) ([GitHub](https://github.com/NousResearch/hermes-agent)) у середовищі Proxmox VE + LXC.

## Архітектура та принципи розгортання

- у репозиторії зберігаються лише шаблони та скрипти;
- локальні секрети й робочі параметри живуть у `deploy/*.env`;
- деплой виконується з Proxmox-host через `pct`;
- мережа побудована без окремого VLAN: приватна підмережа за `vmbr1`, статичні IP контейнерів, NAT на самому Proxmox і зовнішній HTTP/HTTPS через окремий `Nginx Proxy Manager LXC`;
- доменна схема за замовчуванням побудована навколо `yourdomain.com`: головний портал-маршрутизатор `agent.yourdomain.com`, персональні чати `agent-<ctid>.yourdomain.com`, керуючі сторінки `adm-<ctid>.yourdomain.com`;
- `PORTAL_CTID` фіксує, який саме контейнер обслуговує вхідний портал `agent.yourdomain.com`;
- базовий робочий сценарій інкрементний: один контейнер за раз через `deploy_single_ct.sh`, а не масовий деплой діапазону;
- специфіка реального запуску Hermes не захардкоджена в коді, а задається параметрами `HERMES_INSTALL_CMD` і `HERMES_START_CMD`.

## Що вже є в проєкті

- `drafts/article.md` — чернетка майбутньої статті в стилі проєкту.
- `deploy/` - приклади локальних конфігів і службових таблиць.
- `scripts/` - bash-скрипти для template, деплою, health-check, update і cleanup.
- `deploy/authorized_keys.example` - локальний draft для SSH public keys, якщо потрібен доступ у контейнер.
- `systemd/hermes-agent.service.tpl` - шаблон unit-файла для контейнера.
- `templates/proxmox_interfaces.vmbr1-nat.example` - шаблон мережевої конфігурації хоста Proxmox.
- `deploy/npm-proxy-hosts.tsv` - чернетка proxy-host записів для Nginx Proxy Manager.

## Рекомендована послідовність дій

1. На Proxmox-host клонувати репозиторій.
2. Підготувати середовище: запустити `bash scripts/init_local_config.sh`.
3. Заповнити локальні змінні в `deploy/hermes-lxc.env` та `deploy/hermes.env`.
4. (Опційно) Додати SSH-ключі в `deploy/authorized_keys` та налаштувати прокід портів у `deploy/port-forwards.tsv`.
5. Згенерувати доменну схему для майбутнього проксі: `bash scripts/generate_default_domains.sh`.
6. Перевірити готовність конфігурації: `bash scripts/preflight_check.sh`.
7. Підготувати мережу хоста: згенерувати NAT-правила (`bash scripts/generate_interfaces_nat_snippet.sh`) та додати їх у `/etc/network/interfaces`.
8. Створити golden template контейнера: `bash scripts/create_golden_template.sh`.
9. Розгорнути перший агент: перевірити через `DRY_RUN=1 bash scripts/deploy_single_ct.sh 931`, потім запустити реально `DRY_RUN=0 ...`.
10. Налаштувати доступ: згенерувати план (`bash scripts/generate_npm_proxy_plan.sh`) та додати Proxy Hosts у UI Nginx Proxy Manager.
11. Перевірити працездатність: `bash scripts/health_check.sh 931 1 --http`.
12. Для розширення (scale): згенерувати новий домен (`bash scripts/generate_default_domains.sh --append 932`) та розгорнути наступний контейнер.

## Що потрібно підставити вручну

- URL або доступ до репозиторію Hermes.
- Команду встановлення залежностей.
- Команду реального запуску Hermes.
- Змінні середовища на кшталт API-ключів, моделі, робочих директорій.
- Публічний IP хоста Proxmox.
- Приватний IP контейнера `Nginx Proxy Manager`.
- Список доменів, які NPM має проксувати на Hermes.

## Мінімальний набір локальних файлів

- `deploy/hermes-lxc.env`
- `deploy/hermes.env`
- `deploy/authorized_keys` (опційно)
- `deploy/port-forwards.tsv`
- `deploy/npm-proxy-hosts.tsv`
- `deploy/container-notes.tsv` (опційно)

## Безпека

- За замовчуванням використовується `CT_UNPRIVILEGED=1`. Це має лишатися стандартом, якщо немає конкретної причини запускати privileged LXC.
- У файлі `deploy/hermes-lxc.env` за замовчуванням встановлено `DRY_RUN=1`. Це захисний механізм. Для реальних дій використовуйте префікс `DRY_RUN=0` у командному рядку. Не змінюйте це значення безпосередньо у файлі конфігурації.
- Локальні секрети й ключі винесені в `deploy/` і виключені з git через [.gitignore](.gitignore): `deploy/hermes.env`, `deploy/hermes-lxc.env`, `deploy/authorized_keys` та інші робочі файли.
- `deploy/authorized_keys` лише встановлює ключі в контейнер. Для реального SSH-доступу всередині контейнера має бути доступний `openssh-server`.
- Обмежте доступ до зовнішніх DNAT/HTTP-входів через `PVE Firewall` на рівні Datacenter/Node/CT (обов'язково для портів керування, наприклад `npm.yourdomain.com:81`).

## Операції

- Вхід у контейнер: `pct enter 931`
- Перегляд логів сервісу (останні 100 рядків + follow): `pct exec 931 -- journalctl -u hermes-agent -n 100 -f --no-pager`
- Розширений health-check з HTTP probe: `bash scripts/health_check.sh 931 1 --http`
- Зупинити і видалити контейнери: `DRY_RUN=0 bash scripts/cleanup.sh [<ctid> ...]`

## Приватний Git

- **HTTPS**: Додайте Personal Access Token в `HERMES_REPO_URL` або налаштуйте credential helper у template.
- **SSH**: Додайте розгортальний (deploy) ключ у template або доставте його через bootstrap-процес. `deploy/authorized_keys` використовується виключно для входу в контейнер, а не для Git.

## Troubleshooting

- Перевірка маршрутизації в контейнері: `pct exec 931 -- ip route` та `pct exec 931 -- ip -4 -br addr show eth0`.
- Перевірка конфігурацій: `bash scripts/preflight_check.sh` (файли, IPv4, порти, `CT_UNPRIVILEGED`, вільні CTID).

## Важливо

Каркас відокремлює інфраструктуру від внутрішньої реалізації Hermes. Основний шлях деплою зафіксовано, а специфіка інсталяції агента налаштовується через параметри `HERMES_INSTALL_CMD` та `HERMES_START_CMD`.

Proxmox VE не є DHCP-сервером за замовчуванням. У цьому каркасі використовується статична IP-адресація контейнерів у приватній мережі `vmbr1`.

Схема зовнішнього доступу до веб-частини Hermes:

- public `80/443` на Proxmox;
- DNAT на LXC з `Nginx Proxy Manager`;
- проксі-хости NPM на приватні IP Hermes-контейнерів.
