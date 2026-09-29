id: 2026-09-29-ci-cd-kaniko-build-and-deploy-resolve
product: global
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
impl_model: sonnet
impl_effort: high

# Контекст

В рамках внедрения единого стандарта CI/CD платформы TheDevs (TD-1659, канонический референс `references/ci-standards.md`) проводится централизация и унификация конвейеров сборки и развертывания проектных приложений (`thedevslk`, `mobitrack-2`, `shield-3`, `marta`, `flparser` и др.).

Централизованный репозиторий `THEDEVS-RU/.github` предоставляет переиспользуемые экшены GitHub Actions для всех проектов организации. В текущем состоянии репозитория выявлены следующие расхождения со стандартом:

1. **Устаревшие значения и описания в `actions/kaniko-build/action.yml`:**
   - Входной параметр `docker_secret` имеет значение по умолчанию `ghcr-secret`, ссылающееся на выведенный из эксплуатации GitHub Container Registry (`ghcr.io`). По новому стандарту платформы единственным корпоративным реестром является `registry.thedevs.ru`, а соответствующий секрет авторизации в кластере Kubernetes стандартизирован под именем `thedevs-registry-secret`.
   - В описании параметра `image` остался пример `ghcr.io/thedevs-ru/thedevslk`, вводящий разработчиков и AI-агентов в заблуждение относительно целевого реестра.
2. **Дублирование инфраструктурной логики в проектных репозиториях (ecosystem DRY):**
   - Каждый проектный репозиторий вынужден дублировать в своих воркфлоу (`build.yml`, `redeploy.yml`) однотипные shell-скрипты:
     - Вычисление матрицы окружений `resolve`: обработка `inputs.environment`, подстановка дефолтного стенда `dev` или массива `vars.PROD_ENVIRONMENTS`.
     - Защита продакшна `Prod Guard`: блокировка непреднамеренной раскатки продуктовых сред через сборочный воркфлоу ветки `dev`.
     - Двухзвенное динамическое определение целевого режима раскатки `Determine Deploy Target`: безопасная проверка наличия секрета `DEPLOY_CONFIG_K8S` (Tier 1: Kubernetes) с фолбэком на `SSH_PRIVATE_KEY` (Tier 2: SSH Compose) через `env:`, так как контекст `secrets.*` недоступен в выражениях `if:`.
   - Такое дублирование усложняет сопровождение стандартов, повышает риск ошибок script injection (CWE-78 при интерполяции `${{ ... }}` в `run:`) и требует правок десятков строк в каждом проекте.

Для устранения этих проблем в репозитории `THEDEVS-RU/.github` выполняется актуализация экшена `actions/kaniko-build` и создается новый переиспользуемый композитный экшен `actions/deploy-resolve`.

# Что сделать

Все изменения выполняются в репозитории `THEDEVS-RU/.github` на ветке `task/TD-1665`, отведённой от ветки доставки `dev`.

## 1. Актуализация `actions/kaniko-build/action.yml`

Внести следующие точечные изменения в блок `inputs` файла `actions/kaniko-build/action.yml`:

1. **Параметр `image`:**
   Заменить устаревшее описание:
   ```yaml
   image:
     description: 'Base target image name (e.g. ghcr.io/thedevs-ru/thedevslk)'
     required: true
   ```
   на описание, отражающее канонический внутрикластерный и публичный адреса реестра `registry.thedevs.ru`:
   ```yaml
   image:
     description: 'Base target image name (e.g. registry.container-registry.svc.cluster.local:5000/thedevslk or registry.thedevs.ru/thedevslk)'
     required: true
   ```

2. **Параметр `docker_secret`:**
   Заменить устаревший дефолт `ghcr-secret` на `thedevs-registry-secret` и актуализировать описание:
   ```yaml
   docker_secret:
     description: 'Secret name with registry auth (type kubernetes.io/dockerconfigjson)'
     required: false
     default: 'thedevs-registry-secret'
   ```

3. Остальные параметры, алгоритм конечного автомата опроса пода, монтирование томов кэша, зачистка ресурсов и таймауты остаются без изменений.

---

## 2. Создание композитного экшена `actions/deploy-resolve/action.yml`

Создать файл `actions/deploy-resolve/action.yml`, реализующий композитный экшен (Composite Action) для унификации трёх ключевых операций развертывания:

### 2.1. Контракт экшена (Inputs & Outputs)

#### Входные параметры (`inputs`):
- `action`:
  - Описание: `Action to perform: "environments" (matrix resolution), "target" (deploy mode resolution with optional guard), or "guard" (Prod Guard only). Auto-detected if omitted.`
  - `required: false`
  - `default: ''`
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
  - Описание: `Whether to abort if current environment is a production environment (for build.yml)`
  - `required: false`
  - `default: 'false'`
- `k8s_config`:
  - Описание: `Kubernetes kubeconfig secret content (e.g. ${{ secrets.DEPLOY_CONFIG_K8S }})`
  - `required: false`
  - `default: ''`
- `ssh_key`:
  - Описание: `SSH private key secret content (e.g. ${{ secrets.SSH_PRIVATE_KEY }})`
  - `required: false`
  - `default: ''`

#### Выходные параметры (`outputs`):
- `environments`:
  - Описание: `JSON array string of resolved environments for job matrix strategy (e.g. ["dev"] or ["prod-1","prod-2"])`
  - Значение: `${{ steps.resolve.outputs.environments }}`
- `mode`:
  - Описание: `Resolved deployment target mode: "k8s" (Tier 1) or "ssh" (Tier 2)`
  - Значение: `${{ steps.resolve.outputs.mode }}`
- `is_prod`:
  - Описание: `Whether the target environment is classified as a production environment ("true" or "false")`
  - Значение: `${{ steps.resolve.outputs.is_prod }}`

### 2.2. Требования безопасности (CWE-78 Prevention)
Все входные параметры передаются в shell строго через блок `env:` шага. Никаких прямых подстановок `${{ inputs.* }}` в тело скрипта `run:` быть не должно.

### 2.3. Алгоритм выполнения (`runs.using: "composite"`)

Файл `actions/deploy-resolve/action.yml` должен иметь следующую точную структуру:

```yaml
name: 'Deploy Resolve'
description: 'Composite action to resolve deployment matrix, enforce Prod Guard, and dynamically select deploy target mode (k8s vs ssh)'

inputs:
  action:
    description: 'Action to perform: "environments" (matrix resolution), "target" (deploy mode resolution with optional guard), or "guard" (Prod Guard only). Auto-detected if omitted.'
    required: false
    default: ''
  input_environment:
    description: 'Target environment passed via workflow inputs (e.g. ${{ inputs.environment }})'
    required: false
    default: ''
  default_environment:
    description: 'Default environment to fallback when input_environment is empty (default: dev)'
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
    description: 'Whether to abort if current environment is a production environment (for build.yml)'
    required: false
    default: 'false'
  k8s_config:
    description: 'Kubernetes kubeconfig secret content (e.g. ${{ secrets.DEPLOY_CONFIG_K8S }})'
    required: false
    default: ''
  ssh_key:
    description: 'SSH private key secret content (e.g. ${{ secrets.SSH_PRIVATE_KEY }})'
    required: false
    default: ''

outputs:
  environments:
    description: 'JSON array string of resolved environments for job matrix strategy'
    value: ${{ steps.resolve.outputs.environments }}
  mode:
    description: 'Resolved deployment target mode: "k8s" or "ssh"'
    value: ${{ steps.resolve.outputs.mode }}
  is_prod:
    description: 'Whether the target environment is classified as a production environment ("true" or "false")'
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
        K8S_CONFIG: ${{ inputs.k8s_config }}
        SSH_KEY: ${{ inputs.ssh_key }}
      run: |
        set -euo pipefail

        ACT="$ACTION"
        if [ -z "$ACT" ]; then
          if [ -n "$K8S_CONFIG" ] || [ -n "$SSH_KEY" ] || [ -n "$TARGET_ENV" ]; then
            ACT="target"
          else
            ACT="environments"
          fi
        fi

        check_is_prod() {
          local target="$1"
          local prod_json="$2"
          local is_p="false"

          if [ -n "$prod_json" ]; then
            if command -v jq >/dev/null 2>&1 && echo "$prod_json" | jq -e . >/dev/null 2>&1; then
              if echo "$prod_json" | jq -e --arg env "$target" 'if type == "array" then index($env) != null else false end' >/dev/null 2>&1; then
                is_p="true"
              fi
            else
              if echo "$prod_json" | grep -q "\"$target\""; then
                is_p="true"
              fi
            fi
          elif [ "$target" = "prod" ] || [[ "$target" == prod-* ]]; then
            is_p="true"
          fi

          echo "$is_p"
        }

        case "$ACT" in
          environments|matrix|resolve-env)
            if [ -n "$INPUT_ENV" ]; then
              if command -v jq >/dev/null 2>&1; then
                ENV_ARRAY=$(jq -cn --arg env "$INPUT_ENV" '[$env]')
              else
                ENV_ARRAY=$(printf '["%s"]' "$INPUT_ENV")
              fi
            elif [ "$FALLBACK_PROD" = "true" ]; then
              if [ -z "$PROD_ENVS" ] || [ "$PROD_ENVS" = "[]" ] || [ "$PROD_ENVS" = "null" ]; then
                echo "::error::No target environment specified and PROD_ENVIRONMENTS variable is missing or empty."
                exit 1
              fi
              if command -v jq >/dev/null 2>&1 && echo "$PROD_ENVS" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
                ENV_ARRAY=$(echo "$PROD_ENVS" | jq -c .)
              else
                ENV_ARRAY="$PROD_ENVS"
              fi
            else
              DEF="${DEFAULT_ENV:-dev}"
              if command -v jq >/dev/null 2>&1; then
                ENV_ARRAY=$(jq -cn --arg env "$DEF" '[$env]')
              else
                ENV_ARRAY=$(printf '["%s"]' "$DEF")
              fi
            fi
            echo "environments=$ENV_ARRAY" >> "$GITHUB_OUTPUT"
            ;;

          guard|prod-guard)
            if [ -z "$TARGET_ENV" ]; then
              echo "::error::environment input is required for Prod Guard."
              exit 1
            fi
            IS_PROD=$(check_is_prod "$TARGET_ENV" "$PROD_ENVS")
            echo "is_prod=$IS_PROD" >> "$GITHUB_OUTPUT"
            if [ "$IS_PROD" = "true" ]; then
              echo "::error::'$TARGET_ENV' is a prod environment — prod deploys go through release.yml or redeploy.yml, not build.yml"
              exit 1
            fi
            ;;

          target|resolve-target|deploy)
            if [ -z "$TARGET_ENV" ]; then
              echo "::error::environment input is required for deploy target resolution."
              exit 1
            fi

            IS_PROD=$(check_is_prod "$TARGET_ENV" "$PROD_ENVS")
            echo "is_prod=$IS_PROD" >> "$GITHUB_OUTPUT"

            if [ "$PROD_GUARD" = "true" ] && [ "$IS_PROD" = "true" ]; then
              echo "::error::'$TARGET_ENV' is a prod environment — prod deploys go through release.yml or redeploy.yml, not build.yml"
              exit 1
            fi

            if [ -n "$K8S_CONFIG" ]; then
              echo "mode=k8s" >> "$GITHUB_OUTPUT"
            elif [ -n "$SSH_KEY" ]; then
              echo "mode=ssh" >> "$GITHUB_OUTPUT"
            else
              echo "::error::Neither DEPLOY_CONFIG_K8S nor SSH_PRIVATE_KEY is configured for environment '$TARGET_ENV'. Deployment aborted."
              exit 1
            fi
            ;;

          *)
            echo "::error::Unknown action '$ACT'. Valid actions: environments, target, guard."
            exit 1
            ;;
        esac
```

---

## 3. Документирование экшенов в `README.md`

В файле `README.md` репозитория `THEDEVS-RU/.github` добавить раздел с описанием и примерами использования переиспользуемых экшенов:
1. `actions/kaniko-build`:
   - Назначение: сборка образов с кэшированием в K8s-кластере сборщика через `BUILDER_CONFIG_K8S`.
   - Дефолтный секрет авторизации в `registry.thedevs.ru`: `thedevs-registry-secret`.
2. `actions/deploy-resolve`:
   - Назначение: вычисление матрицы окружений, Prod Guard и выбор целевого режима развертывания (K8s vs SSH).
   - Пример использования в джобе `resolve`:
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
             prod_environments: ${{ vars.PROD_ENVIRONMENTS }}
     ```
   - Пример использования в джобе `deploy` (матрица + Prod Guard + выбор K8s/SSH):
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
             k8s_config: ${{ secrets.DEPLOY_CONFIG_K8S }}
             ssh_key: ${{ secrets.SSH_PRIVATE_KEY }}
             prod_guard: true
             prod_environments: ${{ vars.PROD_ENVIRONMENTS }}

         - name: Deploy to K8s
           if: steps.target.outputs.mode == 'k8s'
           ...

         - name: Deploy via SSH
           if: steps.target.outputs.mode == 'ssh'
           ...
     ```

# Что уже есть

1. `actions/kaniko-build/action.yml`:
   - Готовый стабильный экшен сборки Kaniko в K8s, протестированный на реальных пайплайнах (конечный автомат опроса, кэш PVC, retry-логика).
2. Шаблоны и стандарт CI/CD платформы (TD-1659):
   - Документ `references/ci-standards.md` и эталонные воркфлоу `build-project.yml`, `redeploy-project.yml` в плагине `builder`.
   - Вся спецификация `deploy-resolve` выстроена в точном соответствии с регламентом двухзвенного деплоя (Tier 1 K8s / Tier 2 SSH) и защиты продакшна.
3. Валидатор спецификаций:
   - `references/contracts/builder/tools/validate-spec-format.sh`.

# Критерии готовности

1. В `actions/kaniko-build/action.yml`:
   - Значение по умолчанию для `inputs.docker_secret` изменено на `'thedevs-registry-secret'`.
   - Описание `inputs.docker_secret` актуализировано: `'Secret name with registry auth (type kubernetes.io/dockerconfigjson)'`.
   - Из описания `inputs.image` полностью удалено упоминание `ghcr.io`, указан пример с `registry.container-registry.svc.cluster.local:5000/thedevslk or registry.thedevs.ru/thedevslk`.
   - В файле отсутствуют любые другие упоминания `ghcr` или `ghcr.io`.
2. В репозитории создан файл `actions/deploy-resolve/action.yml`:
   - Формат — синтаксически корректный GitHub Actions Composite Action (`runs.using: "composite"`).
   - Все входные контекстные значения передаются в shell строго через блок `env:` шага (отсутствует прямая интерполяция `${{ ... }}` в теле скрипта `run:`).
   - Поддерживаются три режима работы (`action: environments`, `target`, `guard`) с автоматическим определением при пустом `action`.
   - В режиме `environments`:
     - При наличии `input_environment` возвращает JSON-массив `["<input_environment>"]`.
     - При пустом `input_environment` и `fallback_to_prod == 'true'` возвращает `prod_environments`; при пустом `prod_environments` немедленно падает с ошибкой `::error::No target environment specified and PROD_ENVIRONMENTS variable is missing or empty.`.
     - При пустом `input_environment` и `fallback_to_prod == 'false'` возвращает массив с `default_environment` (по умолчанию `["dev"]`).
   - В режиме `target`:
     - Вычисляет `is_prod` (проверка по массиву `prod_environments` через `jq`/`grep`, либо по префиксу `prod*`).
     - При `prod_guard == 'true'` и `is_prod == 'true'` падает с ошибкой `::error::'<env>' is a prod environment — prod deploys go through release.yml or redeploy.yml, not build.yml`.
     - При непустом `k8s_config` возвращает `mode=k8s`.
     - При пустом `k8s_config` и непустом `ssh_key` возвращает `mode=ssh`.
     - Если оба секрета пусты — падает с ошибкой `::error::Neither DEPLOY_CONFIG_K8S nor SSH_PRIVATE_KEY is configured for environment '<env>'. Deployment aborted.`.
   - В режиме `guard`: выполняет изолированную проверку Prod Guard.
3. В `README.md` добавлен раздел с документацией по переиспользуемым экшенам `actions/kaniko-build` и `actions/deploy-resolve` с примерами вызова.
4. Спецификация валидируется утилитой `validate-spec-format.sh` с нулевым кодом возврата.

# Не трогать

1. Не изменять логику сборки, ресурсы, init-контейнер и конечный автомат опроса пода в `actions/kaniko-build/action.yml` (правятся только `docker_secret` и описание `image`).
2. Не изменять другие файлы репозитория `THEDEVS-RU/.github` вне `actions/kaniko-build/action.yml`, `actions/deploy-resolve/action.yml` и `README.md` (в частности, каталоги `.github/ISSUE_TEMPLATE` и `profile/`).
3. Не выполнять прямой коммит и пуш в ветки `dev`, `main` или `master`. Все изменения коммитятся исключительно в ветку задачи `task/TD-1665`.
