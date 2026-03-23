# Local Deploy Files

У цій директорії зберігаються локальні робочі файли для деплою.

- `hermes-lxc.env.example` -> копіюється в `hermes-lxc.env`
- `hermes.env.example` -> копіюється в `hermes.env`
- `authorized_keys.example` -> копіюється в `authorized_keys`
- `port-forwards.tsv.example` -> копіюється в `port-forwards.tsv`
- `npm-proxy-hosts.tsv.example` -> копіюється в `npm-proxy-hosts.tsv`
- `container-notes.tsv.example` -> копіюється в `container-notes.tsv`

Файли без суфікса `.example` ігноруються в git, тому сюди можна безпечно підставляти реальні параметри, ключі та службові нотатки.

Для доменної схеми `yourdomain.com` (основний вхід `agent.yourdomain.com`) файл `npm-proxy-hosts.tsv` можна не лише редагувати вручну, а й перевизначати через `bash scripts/generate_default_domains.sh` на основі параметрів із `hermes-lxc.env`.
Для покрокового розширення краще використовувати `bash scripts/generate_default_domains.sh --append <ctid>`, щоб додати `adm-<ctid>.yourdomain.com` без перезапису вже наявних записів.

`authorized_keys` - опційний локальний файл. Якщо він заповнений, `deploy_hermes.sh` передасть його у bootstrap, а той встановить ключі в контейнер. Для реального SSH входу в контейнер при цьому має бути доступний `openssh-server`.
