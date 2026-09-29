id: 2026-09-29-ci-cd-kaniko-build-and-deploy-resolve
product: global
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
impl_model: sonnet
impl_effort: high

# Контекст

В рамках проектирования и внедрения единого стандарта CI/CD платформы TheDevs (задача TD-1659) проводится централизация и унификация конвейеров сборки и развертывания проектных приложений экосистемы (`thedevslk`, `mobitrack-2`, `shield-3`, `marta`, `flparser` и др.).

Централизованный репозиторий `THEDEVS-RU/.github` предоставляет переиспользуемые экшены GitHub Actions для всех проектов организации. В текущем состоянии репозитория выявлены следующие критические расхождения и риски:

1. **Дефолты и защитные механизмы в `actions/kaniko-build/action.yml`:**
   - Входной параметр `docker_secret` имеет значение по умолчанию `ghcr-secret`, относящееся к выведенному из эксплуатации реестру GitHub Container Registry (`ghcr.io`). По новому стандарту платформы корпоративным реестром является `registry.thedevs.ru`, а имя секрета авторизации типа `kubernetes.io/dockerconfigjson` стандартизировано как `thedevs-registry-secret`.
   - В описании параметра `image` остался устаревший пример `ghcr.io/thedevs-ru/thedevslk`.
   - При отсутствии сборочного секрета в namespace Kaniko-под монтирует `secretName: $SECRET` и зависает в фазе `ContainerCreating` на 40 минут (2400 с) до исчерпания `build_timeout`. В экшене отсутствует быстрый pre-flight контроль наличия секрета в namespace.
   - Проект `euromobil-2` (`.github/workflows/release.yml:347-356`) вызывает `kaniko-build@dev` без явного указания `docker_secret`, то есть опирается на дефолт. Остальные 10 потребителей передают `docker_secret: ghcr-secret` явно. Смена дефолта на `thedevs-registry-secret` без предварительного заведения секрета в namespace `dev` и `master` сломает рабочий релизный конвейер `euromobil-2`.

2. **Дублирование инфраструктурной логики в проектных репозиториях (ecosystem DRY):**
   - Проектные воркфлоу (`build.yml`, `redeploy.yml`) вынуждены копировать разрозненные shell-скрипты:
     - Вычисление матрицы окружений `resolve`: разбор `inputs.environment`, подстановка дефолтного стенда `dev` или массива `vars.PROD_ENVIRONMENTS`.
     - Защита продакшна `Prod Guard`: предотвращение случайной раскатки продуктовых сред через сборочный конвейер ветки `dev`.
     - Двухзвенное динамическое определение целевого режима раскатки `Determine Deploy Target`: выбор между Kubernetes (Tier 1, наличие `DEPLOY_CONFIG_K8S`) и SSH Compose (Tier 2, наличие `SSH_PRIVATE_KEY`).
   - Ручная реализация этих проверок в bash порождает риски script injection (CWE-78), ошибки регулярных выражений, невалидный JSON в `$GITHUB_OUTPUT` и запуск длительных сборок до срабатывания защиты продакшна.

Для решения этих задач в репозитории `THEDEVS-RU/.github` актуализируется экшен `actions/kaniko-build` (с внедрением безопасной pre-flight проверки секрета) и реализуется новый переиспользуемый композитный экшен `actions/deploy-resolve` с выносом исполняемой логики в отдельный тестируемый скрипт.

# Что сделать

Все изменения выполняются в репозитории `THEDEVS-RU/.github` на ветке `task/TD-1665`, отведённой от ветки доставки `dev`.

---

## 1. Актуализация `actions/kaniko-build/action.yml`

1. **Параметр `image`:**
   Заменить описание в блоке `inputs`:
   ```yaml
   image:
     description: 'Base target image name (e.g. registry.container-registry.svc.cluster.local:5000/thedevslk or registry.thedevs.ru/thedevslk)'
     required: true
   ```

2. **Параметр `docker_secret`:**
   Заменить значение по умолчанию и описание:
   ```yaml
   docker_secret:
     description: 'Secret name with registry auth (type kubernetes.io/dockerconfigjson)'
     required: false
     default: 'thedevs-registry-secret'
   ```

3. **Pre-flight проверка наличия секрета перед запуском сборки:**
   В секцию скрипта `run:` (перед циклом попыток `while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do`) добавить безопасную pre-flight проверку существования секрета в целевом namespace с сохранением `stderr`:
   ```bash
   echo "PREFLIGHT: checking registry secret '$SECRET' in namespace '$NS'..."
   PREFLIGHT_ERR=$(mktemp)
   if kubectl -n "$NS" get secret "$SECRET" --request-timeout=15s >/dev/null 2>"$PREFLIGHT_ERR"; then
     echo "PREFLIGHT: secret '$SECRET' confirmed in namespace '$NS'"
   else
     PREFLIGHT_MSG=$(cat "$PREFLIGHT_ERR" 2>/dev/null)
     if printf '%s' "$PREFLIGHT_MSG" | grep -qEi "\(NotFound\)|not found"; then
       echo "::error::Registry secret '$SECRET' not found in namespace '$NS'. Kaniko build cannot start without registry credentials."
       rm -f "$PREFLIGHT_ERR"
       exit 1
     else
       echo "::warning::PREFLIGHT skipped (cannot verify secret '$SECRET' in '$NS'): $(printf '%s' "$PREFLIGHT_MSG" | tr '\n' ' ' | cut -c1-200)"
     fi
   fi
   rm -f "$PREFLIGHT_ERR"
   ```
   - При статусе `NotFound`: прерывание с понятным `::error::` и `exit 1` (предотвращает 40-минутное зависание пода в `ContainerCreating`).
   - При статусе `Forbidden` или иной сетевой/API ошибке: вывод предупреждения `::warning::PREFLIGHT skipped...` и продолжение выполнения (проверка рекомендательная, pod-цикл работает в штатном режиме, отсутствие прав `get secrets` у сервисного аккаунта не блокирует раннеры).

4. **Предусловие слияния (Merge Precondition) для `THEDEVS-RU/euromobil-2`:**
   Поскольку проект `euromobil-2` вызывает `kaniko-build@dev` без явного `docker_secret`, до слияния PR задачи TD-1665 в ветку `dev` оператор обязан подтвердить наличие секрета `thedevs-registry-secret` (тип `kubernetes.io/dockerconfigjson`) в сборочных namespace `master` и `dev`. Стадия реализации `/impl` запрашивает подтверждение оператора через `update_task(taskCode="TD-1665", awaitingReply=true)`.

---

## 2. Создание композитного экшена `actions/deploy-resolve`

Логика экшена разделяется на два компонента: декларативный манифест `actions/deploy-resolve/action.yml` и исполняемый bash-скрипт `actions/deploy-resolve/resolve.sh`.

### 2.1. Контракт экшена (`actions/deploy-resolve/action.yml`)

#### Входные параметры (`inputs`):
- `action`:
  - Описание: `Action to perform: 'environments' (matrix resolution), 'target' (deploy mode resolution with optional guard), or 'guard' (standalone Prod Guard)`
  - `required: true`
- `input_environment`:
  - Описание: `Target environment passed via workflow inputs (e.g. ${{ inputs.environment }})`
  - `required: false`
  - `default: ''`
- `default_environment`:
  - Описание: `Default environment to fallback when input_environment is empty (default: 'dev')`
  - `required: false`
  - `default: 'dev'`
- `fallback_to_prod`:
  - Описание: `When true and input_environment is empty, use prod_environments array (for redeploy/release workflows)`
  - `required: false`
  - `default: 'false'`
- `prod_environments`:
  - Описание: `JSON array string of production environments (e.g. ${{ vars.PROD_ENVIRONMENTS }})`
  - `required: false`
  - `default: ''`
- `environment`:
  - Описание: `Current target environment being deployed (e.g. ${{ matrix.environment }})`
  - `required: false`
  - `default: ''`
- `prod_guard`:
  - Описание: `Whether to abort if target/resolved environment is a production environment (for build.yml)`
  - `required: false`
  - `default: 'false'`
- `has_k8s_config`:
  - Описание: `Boolean flag indicating whether K8s deploy config is available (e.g. ${{ secrets.DEPLOY_CONFIG_K8S != '' }})`
  - `required: false`
  - `default: 'false'`
- `has_ssh_key`:
  - Описание: `Boolean flag indicating whether SSH private key is available (e.g. ${{ secrets.SSH_PRIVATE_KEY != '' }})`
  - `required: false`
  - `default: 'false'`

#### Выходные параметры (`outputs`):
- `environments`:
  - Описание: `JSON array string of resolved environments for job matrix strategy`
  - Значение: `${{ steps.resolve.outputs.environments }}`
- `mode`:
  - Описание: `Resolved deployment target mode: 'k8s' (Tier 1) or 'ssh' (Tier 2)`
  - Значение: `${{ steps.resolve.outputs.mode }}`
- `is_prod`:
  - Описание: `Whether the target environment is a production environment ('true' or 'false')`
  - Значение: `${{ steps.resolve.outputs.is_prod }}`

#### Структура `actions/deploy-resolve/action.yml`:
```yaml
name: 'Deploy Resolve'
description: 'Composite action to resolve deployment matrix, enforce Prod Guard, and dynamically select deploy target mode (k8s vs ssh)'

inputs:
  action:
    description: "Action to perform: 'environments' (matrix resolution), 'target' (deploy mode resolution with optional guard), or 'guard' (standalone Prod Guard)"
    required: true
  input_environment:
    description: 'Target environment passed via workflow inputs (e.g. ${{ inputs.environment }})'
    required: false
    default: ''
  default_environment:
    description: "Default environment to fallback when input_environment is empty (default: 'dev')"
    required: false
    default: 'dev'
  fallback_to_prod:
    description: 'When true and input_environment is empty, use prod_environments array (for redeploy/release workflows)'
    required: false
    default: 'false'
  prod_environments:
    description: 'JSON array string of production environments (e.g. ${{ vars.PROD_ENVIRONMENTS }})'
    required: false
    default: ''
  environment:
    description: 'Current target environment being deployed (e.g. ${{ matrix.environment }})'
    required: false
    default: ''
  prod_guard:
    description: 'Whether to abort if target/resolved environment is a production environment (for build.yml)'
    required: false
    default: 'false'
  has_k8s_config:
    description: 'Boolean flag indicating whether K8s deploy config is available (e.g. ${{ secrets.DEPLOY_CONFIG_K8S != '' }})'
    required: false
    default: 'false'
  has_ssh_key:
    description: 'Boolean flag indicating whether SSH private key is available (e.g. ${{ secrets.SSH_PRIVATE_KEY != '' }})'
    required: false
    default: 'false'

outputs:
  environments:
    description: 'JSON array string of resolved environments for job matrix strategy'
    value: ${{ steps.resolve.outputs.environments }}
  mode:
    description: "Resolved deployment target mode: 'k8s' or 'ssh'"
    value: ${{ steps.resolve.outputs.mode }}
  is_prod:
    description: "Whether the target environment is a production environment ('true' or 'false')"
    value: ${{ steps.resolve.outputs.is_prod }}

runs:
  using: "composite"
  steps:
    - name: Resolve
      id: resolve
      shell: bash
      env:
        ACTION: ${{ inputs.action }}
        INPUT_ENV: ${{ inputs.input_environment }}
        DEFAULT_ENV: ${{ inputs.default_environment }}
        FALLBACK_PROD: ${{ inputs.fallback_to_prod }}
        PROD_ENVS: ${{ inputs.prod_environments }}
        TARGET_ENV: ${{ inputs.environment }}
        PROD_GUARD: ${{ inputs.prod_guard }}
        HAS_K8S_CONFIG: ${{ inputs.has_k8s_config }}
        HAS_SSH_KEY: ${{ inputs.has_ssh_key }}
      run: bash "$GITHUB_ACTION_PATH/resolve.sh"
```

### 2.2. Исполняемый скрипт `actions/deploy-resolve/resolve.sh`

Создать файл `actions/deploy-resolve/resolve.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required for actions/deploy-resolve but not found in PATH."
  exit 1
fi

validate_env_name() {
  local name="$1"
  local label="$2"
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "::error::Invalid $label '$name'. Environment names must match pattern ^[A-Za-z0-9._-]+$"
    exit 1
  fi
}

validate_prod_environments() {
  local prod_json="$1"
  if [ -n "$prod_json" ]; then
    if ! echo "$prod_json" | jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9._-]+$"))' >/dev/null 2>&1; then
      echo "::error::prod_environments must be a valid non-empty JSON array of strings matching ^[A-Za-z0-9._-]+$ (e.g. [\"prod-1\", \"prod-2\"]). Got: $prod_json"
      exit 1
    fi
  fi
}

check_env_is_prod() {
  local env_name="$1"
  local prod_json="$2"
  if [ -n "$prod_json" ]; then
    if echo "$prod_json" | jq -e --arg env "$env_name" 'index($env) != null' >/dev/null 2>&1; then
      echo "true"
      return
    fi
  fi
  echo "false"
}

ACT="${ACTION:-}"
if [ -z "$ACT" ]; then
  echo "::error::Input 'action' is required and must be one of: environments, target, guard."
  exit 1
fi

validate_prod_environments "${PROD_ENVS:-}"

case "$ACT" in
  environments)
    if [ -n "${INPUT_ENV:-}" ]; then
      validate_env_name "$INPUT_ENV" "input_environment"
      ENV_ARRAY=$(jq -cn --arg env "$INPUT_ENV" '[$env]')
    elif [ "${FALLBACK_PROD:-false}" = "true" ]; then
      if [ -z "${PROD_ENVS:-}" ]; then
        echo "::error::No target environment specified and PROD_ENVIRONMENTS variable is missing or empty."
        exit 1
      fi
      ENV_ARRAY=$(echo "$PROD_ENVS" | jq -c .)
    else
      DEF="${DEFAULT_ENV:-dev}"
      validate_env_name "$DEF" "default_environment"
      ENV_ARRAY=$(jq -cn --arg env "$DEF" '[$env]')
    fi

    # Ранний Prod Guard в джобе resolve
    if [ "${PROD_GUARD:-false}" = "true" ] && [ -n "${PROD_ENVS:-}" ]; then
      while IFS= read -r resolved_env; do
        if [ "$(check_env_is_prod "$resolved_env" "$PROD_ENVS")" = "true" ]; then
          echo "::error::Resolved environment '$resolved_env' is a prod environment — prod deploys go through release.yml or redeploy.yml, not build.yml"
          exit 1
        fi
      done < <(echo "$ENV_ARRAY" | jq -r '.[]')
    fi

    echo "environments=$(echo "$ENV_ARRAY" | jq -c .)" >> "$GITHUB_OUTPUT"
    ;;

  guard)
    if [ -z "${TARGET_ENV:-}" ]; then
      echo "::error::Input 'environment' is required for action 'guard'."
      exit 1
    fi
    validate_env_name "$TARGET_ENV" "environment"

    IS_PROD=$(check_env_is_prod "$TARGET_ENV" "${PROD_ENVS:-}")
    echo "is_prod=$IS_PROD" >> "$GITHUB_OUTPUT"

    if [ "$IS_PROD" = "true" ]; then
      echo "::error::'$TARGET_ENV' is a prod environment — prod deploys go through release.yml or redeploy.yml, not build.yml"
      exit 1
    fi
    ;;

  target)
    if [ -z "${TARGET_ENV:-}" ]; then
      echo "::error::Input 'environment' is required for action 'target'."
      exit 1
    fi
    validate_env_name "$TARGET_ENV" "environment"

    IS_PROD=$(check_env_is_prod "$TARGET_ENV" "${PROD_ENVS:-}")
    echo "is_prod=$IS_PROD" >> "$GITHUB_OUTPUT"

    if [ "${PROD_GUARD:-false}" = "true" ] && [ "$IS_PROD" = "true" ]; then
      echo "::error::'$TARGET_ENV' is a prod environment — prod deploys go through release.yml or redeploy.yml, not build.yml"
      exit 1
    fi

    if [ "${HAS_K8S_CONFIG:-false}" = "true" ]; then
      echo "mode=k8s" >> "$GITHUB_OUTPUT"
    elif [ "${HAS_SSH_KEY:-false}" = "true" ]; then
      echo "mode=ssh" >> "$GITHUB_OUTPUT"
    else
      echo "::error::Neither DEPLOY_CONFIG_K8S nor SSH_PRIVATE_KEY is configured for environment '$TARGET_ENV'. Deployment aborted."
      exit 1
    fi
    ;;

  *)
    echo "::error::Input 'action' must be one of: environments, target, guard. Got: '$ACT'"
    exit 1
    ;;
esac
```

---

## 3. Документация в каталогах экшенов

Корневой `README.md` репозитория `THEDEVS-RU/.github` не модифицируется (он содержит информацию для участников команды). Документация создаётся непосредственно в каталогах экшенов:

1. **`actions/kaniko-build/README.md`:**
   - Описание назначения: сборка Docker-образов через Kaniko в K8s-кластере с многоуровневым кэшированием (PVC).
   - Описание входных параметров со значениями по умолчанию (`docker_secret: 'thedevs-registry-secret'`).
   - Описание встроенной pre-flight проверки секретов реестра: проверка рекомендательная, не прерывает сборку при отсутствии прав `get secrets` (выдаётся `::warning::`), но обеспечивает немедленный `::error::` при статусе `NotFound`. Для корректной работы проверки сервисный аккаунт раннера должен обладать правом `get` на `secrets` в `BUILD_NAMESPACE`.
   - Пример использования в сборочном шаге воркфлоу.

2. **`actions/deploy-resolve/README.md`:**
   - Описание трёх режимов работы (`environments`, `target`, `guard`).
   - Таблица входных параметров и выходных значений.
   - Важное примечание по Prod Guard: параметр `prod_guard: true` выставляется исключительно в конвейере сборки ветки разработки (`build.yml`). В конвейерах повторного или релизного развертывания (`redeploy.yml`, `release.yml`) параметр `prod_guard` должен иметь значение `false` (значение по умолчанию), так как раскатка на продуктовые среды в них является целевым действием.
   - Примеры интеграции:
     - В джобе `resolve` конвейера `build.yml` (с `prod_guard: true`):
       ```yaml
       resolve:
         runs-on: master
         outputs:
           environments: ${{ steps.resolve.outputs.environments }}
         steps:
           - name: Resolve target environments
             id: resolve
             uses: THEDEVS-RU/.github/actions/deploy-resolve@dev
             with:
               action: environments
               input_environment: ${{ inputs.environment }}
               default_environment: 'dev'
               prod_guard: true
               prod_environments: ${{ vars.PROD_ENVIRONMENTS }}
       ```
     - В джобе `resolve` конвейера `redeploy.yml` (с `fallback_to_prod: true` и `prod_guard: false`):
       ```yaml
       resolve:
         runs-on: master
         outputs:
           environments: ${{ steps.resolve.outputs.environments }}
         steps:
           - name: Resolve target environments
             id: resolve
             uses: THEDEVS-RU/.github/actions/deploy-resolve@dev
             with:
               action: environments
               input_environment: ${{ inputs.environment }}
               fallback_to_prod: true
               prod_guard: false
               prod_environments: ${{ vars.PROD_ENVIRONMENTS }}
       ```
     - В джобе `deploy` (динамический выбор K8s/SSH и вторая линия Prod Guard):
       ```yaml
       deploy:
         needs: [resolve, build]
         runs-on: master
         strategy:
           fail-fast: false
           matrix:
             environment: ${{ fromJSON(needs.resolve.outputs.environments) }}
         environment: ${{ matrix.environment }}
         steps:
           - name: Resolve Deploy Target & Prod Guard
             id: target
             uses: THEDEVS-RU/.github/actions/deploy-resolve@dev
             with:
               action: target
               environment: ${{ matrix.environment }}
               has_k8s_config: ${{ secrets.DEPLOY_CONFIG_K8S != '' }}
               has_ssh_key: ${{ secrets.SSH_PRIVATE_KEY != '' }}
               prod_guard: true
               prod_environments: ${{ vars.PROD_ENVIRONMENTS }}

           - name: Deploy to K8s
             if: steps.target.outputs.mode == 'k8s'
             ...

           - name: Deploy via SSH
             if: steps.target.outputs.mode == 'ssh'
             ...
       ```

---

## 4. Верификация реализации и тестовый комплект: `tests/test-deploy-resolve.sh`

Поскольку в репозитории `THEDEVS-RU/.github` отсутствуют воркфлоу GitHub Actions и отсутствует автоматический CI-раннер, проверка корректности реализации выполняется локальным тестовым комплектом `tests/test-deploy-resolve.sh`, вызывающим реальный файл `actions/deploy-resolve/resolve.sh`.

Файл `tests/test-deploy-resolve.sh` запускает `actions/deploy-resolve/resolve.sh` напрямую с передачей переменных окружения и проверяет код возврата и содержимое `$GITHUB_OUTPUT` для 13 сценариев:
1. Запуск без параметра `action` — ошибка (код 1).
2. Запуск с недопустимым `action` (алиас или опечатка) — ошибка (код 1).
3. `action: environments`: дефолтный вызов без `input_environment` — вывод `environments=["dev"]`.
4. `action: environments`: передача `input_environment` — вывод `environments=["<input>"]`.
5. `action: environments`: ранний Prod Guard блокирует prod-стенд в resolve при `prod_guard: true` — ошибка (код 1).
6. `action: environments`: redeploy-режим с `fallback_to_prod: true` и валидным `PROD_ENVIRONMENTS` — вывод массива prod-стендов.
7. `action: environments`: redeploy-режим с `fallback_to_prod: true` и пустым `PROD_ENVIRONMENTS` — ошибка (код 1).
8. `action: environments`: невалидный синтаксис `PROD_ENVIRONMENTS` (не JSON-массив строк) — ошибка (код 1).
9. Валидация недопустимых символов в имени окружения (инъекции `;`, пробелы, кавычки, переводы строк) — ошибка (код 1).
10. `action: target`: `has_k8s_config: 'true'` — вывод `mode=k8s`, `is_prod=false`.
11. `action: target`: `has_k8s_config: 'false'`, `has_ssh_key: 'true'` — вывод `mode=ssh`, `is_prod=false`.
12. `action: target`: оба флага `'false'` — ошибка (код 1).
13. `action: target`: prod-стенд при `prod_guard: 'true'` — ошибка (код 1); при `prod_guard: 'false'` — успех (режим redeploy), `is_prod=true`.

Обязательные статические проверки скрипта:
- `bash -n actions/deploy-resolve/resolve.sh`
- `shellcheck actions/deploy-resolve/resolve.sh` (при наличии утилиты).

---

## 5. Взаимосвязь со стандартом TD-1659 и миграция флота

1. **Текущий статус стандартизации:**
   - Канонический стандарт CI/CD платформы TheDevs формулируется в задаче `TD-1659` (спецификация `thedevs-plugins` в статусе ревью).
   - После слияния настоящей задачи TD-1665 в `dev`, канонические шаблоны конвейеров в `thedevs-plugins` (`shared/builder/references/ci-workflows/build-project.yml` и `redeploy-project.yml`) в рамках стадии `impl` задачи `TD-1659` явно переводятся на использование `uses: THEDEVS-RU/.github/actions/deploy-resolve@dev`.
2. **Перевод флота и эталонного проекта:**
   - Задача `TD-1660` (`template-project`) переводит шаблонный проект организации на `actions/deploy-resolve@dev`.
   - Проектные задачи миграции (`shield-3` TD-1661, `marta` TD-1662, `thedevslk` TD-1663, `mobitrack-2` TD-1666 и MOBI2-288, `flparser` TD-1670, `ai-runner` TD-1671, `addon-crypto-collector` TD-1672) при раскатке стандарта подключают `THEDEVS-RU/.github/actions/deploy-resolve@dev`.
   - В `euromobil-2` (задача `EMB-37`) локальный экшен `.github/actions/deploy-target` после доступности `deploy-resolve@dev` подлежит плановой замене на централизованный экшен платформы.

# Что уже есть

1. `actions/kaniko-build/action.yml`:
   - Рабочий экшен сборки Kaniko в Kubernetes с конечным автоматом опроса статуса, монтированием томов кэша (`kaniko-cache` и `cache_pvc`) и механизмом retry при транзиентных сетевых сбоях.
2. Задача `TD-1659`:
   - Находится в активной проработке на этапе ревью; задает требования к единому стандарту CI/CD (реестр `registry.thedevs.ru`, сборочный секрет `BUILDER_CONFIG_K8S`, двухзвенный деплой Tier 1 K8s / Tier 2 SSH, Prod Guard, матрица environments).
3. Инструменты контроля:
   - Скрипт валидации спецификаций `references/contracts/builder/tools/validate-spec-format.sh`.

# Критерии готовности

1. **В `actions/kaniko-build/action.yml`:**
   - Значение по умолчанию для `inputs.docker_secret` изменено на `'thedevs-registry-secret'`.
   - Описание `inputs.docker_secret` актуализировано: `'Secret name with registry auth (type kubernetes.io/dockerconfigjson)'`.
   - В описании `inputs.image` полностью удалено упоминание `ghcr.io`, указан пример `registry.container-registry.svc.cluster.local:5000/thedevslk or registry.thedevs.ru/thedevslk`.
   - В скрипт `run:` перед циклом попыток добавлена безопасная pre-flight проверка: при `NotFound` — `::error::` и `exit 1`; при `Forbidden` или иной ошибке — `::warning::PREFLIGHT skipped...` и продолжение выполнения.
   - В файле отсутствуют упоминания `ghcr` или `ghcr.io`.
2. **Создан композитный экшен `actions/deploy-resolve`:**
   - Созданы файлы `actions/deploy-resolve/action.yml` и `actions/deploy-resolve/resolve.sh`.
   - В `action.yml` шаг `resolve` вызывает `run: bash "$GITHUB_ACTION_PATH/resolve.sh"`.
   - Параметр `action` является обязательным (`required: true`) и принимает только `environments`, `target`, `guard`.
   - Утилита `jq` обязательна, fallback-ветки без `jq` отсутствуют.
   - Имена окружений валидируются regex-шаблоном `^[A-Za-z0-9._-]+$`.
   - Значение `prod_environments` валидируется внутри `jq` выражением `type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9._-]+$"))`.
   - Определение продуктовой среды выполняется строго по вхождению в `prod_environments` без эвристик по именам.
   - В режиме `environments` реализован ранний Prod Guard (`prod_guard: true`), завершающий конвейер до запуска Kaniko.
   - В режиме `target` реализовано динамическое определение целевого режима (`k8s` при `has_k8s_config: 'true'`, `ssh` при `has_ssh_key: 'true'`) и вторая линия Prod Guard.
   - Все входные значения передаются в shell строго через блок `env:` шага.
   - Запись в `$GITHUB_OUTPUT` производится исключительно через `jq -c`.
3. **Создана документация экшенов:**
   - Создан файл `actions/kaniko-build/README.md` (с описанием прав RBAC на `secrets` в `BUILD_NAMESPACE` для pre-flight).
   - Создан файл `actions/deploy-resolve/README.md` (с пояснением, что `prod_guard: true` задаётся только в `build.yml`).
   - Корневой `README.md` репозитория сохранен без изменений.
4. **Создан тестовый комплект `tests/test-deploy-resolve.sh`:**
   - Скрипт вызывает `actions/deploy-resolve/resolve.sh` напрямую, тестирует все 13 сценариев и успешно завершается с кодом 0.
   - Проверка `bash -n actions/deploy-resolve/resolve.sh` завершается с кодом 0.
5. **Предусловие слияния (Merge Precondition):**
   - Оператор подтвердил наличие секрета `thedevs-registry-secret` в сборочных namespace `master` и `dev`. Стадия `/impl` запрашивает подтверждение через `update_task(taskCode="TD-1665", awaitingReply=true)` до передачи PR на ревью. Без подтверждения слияние PR в `dev` заблокировано.
6. **Валидация спецификации:**
   - Спецификация валидируется утилитой `validate-spec-format.sh` с нулевым кодом возврата.

# Не трогать

1. Не изменять логику сборки Kaniko, init-контейнер `merge-docker-config`, ресурсные лимиты, монтирование томов кэша и конечный автомат опроса пода в `actions/kaniko-build/action.yml` (модифицируются только описание `image`, дефолт/описание `docker_secret` и добавляется pre-flight проверка секрета).
2. Не модифицировать корневой `README.md` репозитория `THEDEVS-RU/.github` (он предназначен для описания команды, условий работы и процесса онбординга).
3. Не изменять служебные файлы репозитория в `.github/ISSUE_TEMPLATE` и каталоге `profile/`.
4. Не выполнять прямой коммит и пуш в ветки `dev`, `main` или `master`. Все изменения коммитятся в ветку задачи `task/TD-1665`.
