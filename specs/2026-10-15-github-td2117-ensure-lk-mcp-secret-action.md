id: 2026-10-15-github-td2117-ensure-lk-mcp-secret-action
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: [2026-10-15-coreai-td2117-lktask-default-mcp-out-of-the-box]
complexity: simple
impl_model: sonnet
impl_effort: high

# Контракт

- **Consumes**: соглашение о переменных окружения и ключах секрета для системного MCP `lkTask` (`THEDEVS_LK_MCP_TOKEN`, `THEDEVS_LK_MCP_URL`), зафиксированное в спецификации `2026-10-15-coreai-td2117-lktask-default-mcp-out-of-the-box`.
- **Produces**: общий composite action `actions/ensure-lk-mcp-secret`, создающий или обновляющий K8s Secret `thedevs-lk-mcp` (ключи `token` и опционально `url`) в целевом namespace на шаге деплоя для всех микросервисов платформы (`marta`, `shield-3`, `TemplateProject`).

# Контекст

В рамках решения TD-2117 токен доступа к системному MCP `lkTask` доставляется в runtime-сессии агентов через секреты Kubernetes.
Для исключения дублирования bash-скриптов создания K8s-секретов в workflow-файлах каждого микросервиса (`build.yml`) требуется создать единый переиспользуемый composite action `actions/ensure-lk-mcp-secret` в репозитории `THEDEVS-RU/.github`.
Action строится по проверенному паттерну `Ensure Registry Secret` из `marta/.github/workflows/build.yml` и использует `kubectl create secret generic ... --dry-run=client -o yaml | kubectl apply -f -`.

# Что сделать

1. **Создать директорию и манифест `actions/ensure-lk-mcp-secret/action.yml`:**
   ```yaml
   name: 'Ensure LK MCP Secret'
   description: 'Idempotently create or update thedevs-lk-mcp Kubernetes secret in target namespace'

   inputs:
     namespace:
       description: 'Target Kubernetes namespace'
       required: true
       default: 'dev'
     token:
       description: 'LK MCP service token (from secrets.THEDEVS_LK_MCP_TOKEN)'
       required: false
       default: ''
     url:
       description: 'Optional LK MCP URL override (from vars.THEDEVS_LK_MCP_URL)'
       required: false
       default: ''
     secret_name:
       description: 'Kubernetes secret name'
       required: false
       default: 'thedevs-lk-mcp'

   runs:
     using: "composite"
     steps:
       - name: Ensure Secret
         shell: bash
         env:
           TARGET_NS: ${{ inputs.namespace }}
           TOKEN: ${{ inputs.token }}
           URL: ${{ inputs.url }}
           SECRET_NAME: ${{ inputs.secret_name }}
         run: bash "$GITHUB_ACTION_PATH/ensure.sh"
   ```

2. **Создать скрипт `actions/ensure-lk-mcp-secret/ensure.sh`:**
   - Если переменная `TOKEN` пуста, выводить предупреждение `::warning::THEDEVS_LK_MCP_TOKEN is empty. Skipping secret creation for $SECRET_NAME in $TARGET_NS.` и завершать шаг без ошибки.
   - Если `TOKEN` не пуст:
     - Формировать аргументы `--from-literal=token="$TOKEN"`.
     - Если `URL` не пуст, добавлять аргумент `--from-literal=url="$URL"`.
     - Применять команду:
       ```bash
       kubectl create secret generic "$SECRET_NAME" "${ARGS[@]}" \
         --dry-run=client -o yaml | kubectl apply -n "$TARGET_NS" -f -
       echo "Kubernetes secret '$SECRET_NAME' successfully ensured in namespace '$TARGET_NS'."
       ```

3. **Сделать скрипт исполняемым (`chmod +x actions/ensure-lk-mcp-secret/ensure.sh`).**

## Затрагиваемые файлы

1. `actions/ensure-lk-mcp-secret/action.yml`
2. `actions/ensure-lk-mcp-secret/ensure.sh`

# Что уже есть

- Архитектура composite actions в `THEDEVS-RU/.github`: `actions/deploy-resolve`, `actions/kaniko-build`, `actions/resolve-deploy-target`.
- Паттерн создания K8s-секретов через `--dry-run=client -o yaml | kubectl apply -f -`.

# Критерии готовности

1. Создан composite action `actions/ensure-lk-mcp-secret/action.yml` с входами `namespace`, `token`, `url`, `secret_name`.
2. Создан скрипт `actions/ensure-lk-mcp-secret/ensure.sh`, корректно обрабатывающий пустой токен (warning без падения) и обновляющий секрет `thedevs-lk-mcp` при наличии токена.
3. Ключ `token` присутствует в секрете всегда при наличии значения `token`; ключ `url` добавляется только при передаче входного параметра `url`.
4. Формат спецификации успешно валидируется `validate-spec-format.sh` с кодом 0.

# Не трогать

- Не изменять существующие экшены `deploy-resolve`, `kaniko-build`, `resolve-deploy-target`.
- Не модифицировать конфигурацию workflows самого репозитория `.github`.
