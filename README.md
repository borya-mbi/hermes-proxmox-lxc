# deploy-hermes v2 (Multi-User)

Каркас для професійного деплою [Hermes Agent](https://hermes-agent.nousresearch.com/) та [Claude Code](https://claude.ai/code) у `Proxmox VE + LXC`. 

Версія v2 переходить від моделі "1 LXC = 1 Hermes" до моделі **"1 LXC = N користувачів"**, що суттєво економить ресурси Proxmox та дозволяє реалізувати повноцінний DTAP (Development, Testing, Acceptance, Production) workflow.

## 📖 Документація та аналіз
Для глибокого розуміння концепції проекту перегляньте інтерактивний аналітичний звіт:
- [📊 **Гермес: Функціональна модель (Аналіз Г.Л. Олді)**](https://htmlpreview.github.io/?https://github.com/borya-mbi/hermes-proxmox-lxc/blob/main/docs/hermes-god-oldi.html) — *інтерактивна сторінка з графіками та детальним розбором ролі "Адміністратора Космосу".*

## Архітектура v2

- **Один контейнер - багато користувачів**: Кожен Linux-користувач має власний інстанс Hermes.
- **Systemd Template Units**: Керування інстансами через `hms@<user>.service`.
- **Fork Workflow**: Підтримка власних форків Hermes Agent з різними гілками для Prod та Dev.
- **Security Hardening**: `chmod 700` on домашні папки, обмеження `sudoers` та `cgroups` ліміти (Memory/CPU) на рівні сервісу.
- **Claude Code**: Автоматичне per-user встановлення через `npm` з локальним префіксом.

## Release Checklist (v2)
1. `bash scripts/init_local_config.sh` - ініціалізація локальних файлів.
2. Заповнити `deploy/hermes-lxc.env` (інвентар та Proxmox).
3. Заповнити `deploy/hermes-user.env` (спільні секрети для bootstrap).
4. Заповнити `deploy/config.yaml` (моделі та провайдери).
5. `bash scripts/create_golden_template.sh` - створення базового образу.
6. `bash scripts/preflight_check.sh` - фінальна перевірка.
7. `DRY_RUN=0 bash scripts/deploy_single_ct.sh <ctid>` - деплой.
8. **Onboarding**: Після bootstrap розвести `TG_CHANNEL_ID` по юзерах у їхніх локальних `.env` (`~/.hermes/.env`) всередині контейнера.
9. На кожного юзера виконати `bash scripts/sync_configs.sh <ctid> <user>` для застосування індивідуальних налаштувань.

## Довідник скриптів v2

| Скрипт | Призначення | Типовий виклик |
| --- | --- | --- |
| `scripts/init_local_config.sh` | Створює локальні конфіги з `.example` шаблонів | `bash scripts/init_local_config.sh` |
| `scripts/preflight_check.sh` | Валідація всіх конфігів перед деплоєм | `bash scripts/preflight_check.sh` |
| `scripts/deploy_single_ct.sh` | Розгортає контейнер з усіма користувачами | `DRY_RUN=0 bash scripts/deploy_single_ct.sh 931` |
| `scripts/upgrade_prod.sh` | Безпечне оновлення Prod-user (бінарник + DB + env + config backup) | `bash scripts/upgrade_prod.sh 931 user1` |
| `scripts/upgrade_dev.sh` | Швидке оновлення Dev-user за вказаною гілкою | `bash scripts/upgrade_dev.sh 931 dev-user` |
| `scripts/rollback_user.sh` | Відкат бінарника, БД та конфігів до вказаного бекапу | `bash scripts/rollback_user.sh 931 user1 <timestamp>` |
| `scripts/add_user.sh` | Динамічне додавання нового користувача (Inventory-First) | `bash scripts/add_user.sh 931 new-user` |
| `scripts/sync_configs.sh` | Синхронізація `config.yaml` через `envsubst` | `bash scripts/sync_configs.sh 931 user1` |
| `scripts/health_check.sh` | Моніторинг статусу, RAM та CPU (systemd cgroup) | `bash scripts/health_check.sh 931 1` |
| `scripts/update_hermes.sh` | Масове оновлення всіх користувачів у всіх CT | `bash scripts/update_hermes.sh 931 1` |
| `scripts/bootstrap_hermes.sh` | Короткий setup середовища (запускається автоматично) | - |

## Локальні файли (deploy/)

- `hermes-lxc.env` - Системні налаштування Proxmox та списки `HERMES_PROD_USERS` / `HERMES_DEV_USERS`.
- `hermes-user.env` - Шаблон секретів для bootstrap (копіюється в `~/.hermes/.env`).
- `config.yaml` - Конфігурація моделей та провайдерів (підставляється через `envsubst`).
- `authorized_keys` - Authoritative джерело публічних SSH-ключів (очищення файлу видаляє ключі в контейнері).
- `container_info.tsv` - Автоматичне зведення по розгорнутих CT.
- `failed_ctids.txt` - Список помилок деплою.
