id: 2026-10-24-github-td2424-ensure-lk-mcp-secret-no-fallback
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
stage: detailed
external_content: false
impl_model: sonnet
impl_effort: high

# Контекст

Платформенный composite action `actions/ensure-lk-mcp-secret` (`THEDEVS-RU/.github@dev:actions/ensure-lk-mcp-secret/action.yml:1`) отвечает за идемпотентное создание и обновление Kubernetes Secret `thedevs-lk-mcp` в целевом namespace на этапе деплоя микросервисов (`build.yml`, `release.yml`, `redeploy.yml`).

В текущей реализации экшена присутствует опасный фоллбэк на namespace `'dev'`:
1. В `actions/ensure-lk-mcp-secret/action.yml:8` объявлен `default: 'dev'`.
2. В `actions/ensure-lk-mcp-secret/ensure.sh:4` выполняется подстановка `TARGET_NS="${TARGET_NS:-dev}"`.

Если потребитель экшена (например, дочерний сервис из шаблона `TemplateProject`) запускает деплой с не настроенным GitHub Environment (где переменная `vars.K8S_NAMESPACE` не задана), экшен молча обращается к живому неймспейсу `dev` кластера Kubernetes и перезаписывает секрет `thedevs-lk-mcp`.

Кроме того, в описаниях входов `actions/resolve-deploy-target/action.yml:6`, `:18`, `:22` сохраняются ссылки на устаревшие секреты `KUBE_CONFIG`, `SSH_KEY` и устаревший секретный контекст `secrets.SSH_KNOWN_HOSTS`, что противоречит стандарту `references/ci-standards.md` §1.1, §2.4, §4 (где `SSH_KNOWN_HOSTS` переведён в `vars`, а устаревшие секреты запрещены).

# Что сделать

## 1. Устранение фоллбэка `dev` в `actions/ensure-lk-mcp-secret`

1. **В `actions/ensure-lk-mcp-secret/action.yml`:**
   Удалить `default: 'dev'` у входного параметра `namespace`:
   ```yaml
   inputs:
     namespace:
       description: 'Target Kubernetes namespace'
       required: true
   ```
2. **В `actions/ensure-lk-mcp-secret/ensure.sh`:**
   Удалить фоллбэк `TARGET_NS="${TARGET_NS:-dev}"` и внедрить Fail-Fast проверку непустого значения:
   ```bash
   TARGET_NS="${TARGET_NS:-}"
   if [ -z "$TARGET_NS" ]; then
     echo "::error::Input 'namespace' is required and cannot be empty." >&2
     exit 1
   fi
   ```

## 2. Актуализация описаний входов в `actions/resolve-deploy-target`

В `actions/resolve-deploy-target/action.yml`:
1. В описании входа `deploy_config_k8s` (`:6`–`8`) удалить упоминание `KUBE_CONFIG`:
   ```yaml
     deploy_config_k8s:
       description: 'Kubernetes kubeconfig string (secrets.DEPLOY_CONFIG_K8S)'
       required: false
       default: ''
   ```
2. В описании входа `ssh_key` (`:17`–`20`) удалить упоминание `secrets.SSH_KEY`:
   ```yaml
     ssh_key:
       description: 'SSH private key (secrets.SSH_PRIVATE_KEY)'
       required: false
       default: ''
   ```
3. В описании входа `ssh_known_hosts` (`:21`–`24`) заменить `secrets.SSH_KNOWN_HOSTS` на `vars.SSH_KNOWN_HOSTS` (`references/ci-standards.md` §4):
   ```yaml
     ssh_known_hosts:
       description: 'SSH known_hosts string (vars.SSH_KNOWN_HOSTS)'
       required: false
       default: ''
   ```

## Затрагиваемые файлы

- `actions/ensure-lk-mcp-secret/action.yml`
- `actions/ensure-lk-mcp-secret/ensure.sh`
- `actions/resolve-deploy-target/action.yml`

# Что уже есть

- Манифест `actions/ensure-lk-mcp-secret/action.yml` и bash-скрипт `actions/ensure-lk-mcp-secret/ensure.sh`.
- Манифест `actions/resolve-deploy-target/action.yml`.
- Спецификация создания экшена `specs/2026-10-15-github-td2117-ensure-lk-mcp-secret-action.md`.

## Проверенные API

- `THEDEVS-RU/.github@dev:actions/ensure-lk-mcp-secret/action.yml:5` — объявление входа `namespace` с `default: 'dev'`.
- `THEDEVS-RU/.github@dev:actions/ensure-lk-mcp-secret/ensure.sh:4` — подстановка по умолчанию `TARGET_NS="${TARGET_NS:-dev}"`.
- `THEDEVS-RU/.github@dev:actions/resolve-deploy-target/action.yml:6` — устаревшие упоминания `KUBE_CONFIG`, `SSH_KEY`, `secrets.SSH_KNOWN_HOSTS` в описаниях inputs.
- `THEDEVS-RU/thedevs-plugins@dev:shared/builder/references/ci-standards.md:293` — таблица §4 стандарта (`DEPLOY_CONFIG_K8S` — Secret на уровне Environment, `SSH_KNOWN_HOSTS` — Variable на уровне Environment, запрет устаревших секретов).

# Критерии готовности

- В `actions/ensure-lk-mcp-secret/action.yml` у параметра `namespace` отсутствует атрибут `default` (`required: true`).
- В `actions/ensure-lk-mcp-secret/ensure.sh` отсутствует фоллбэк на `dev`, при пустом или отсутствующем `TARGET_NS` шаг немедленно падает с ошибкой `::error::Input 'namespace' is required and cannot be empty.` и кодом 1.
- В `actions/resolve-deploy-target/action.yml` описания входов приведены к стандарту (`secrets.DEPLOY_CONFIG_K8S`, `secrets.SSH_PRIVATE_KEY`, `vars.SSH_KNOWN_HOSTS`).
- Спецификация успешно проходит валидацию `validate-spec-format.sh` с кодом 0.

# Не трогать

- Логику генерации аргументов и создания секрета через `kubectl create secret generic` в `ensure.sh`.
- Логику определения `target=k8s` и `target=ssh` в `actions/resolve-deploy-target/action.yml`.
- Остальные экшены в репозитории `.github` (`actions/kaniko-build`, `actions/deploy-resolve`, `actions/ssh-compose-deploy`, `actions/setup-addon-tests`).
