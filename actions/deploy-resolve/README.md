# Deploy Resolve Action (`actions/deploy-resolve`)

Переиспользуемый композитный экшен платформы TheDevs для вычисления матрицы окружений развертывания, защиты продуктовых сред (Prod Guard) и динамического выбора целевого механизма деплоя (Tier 1 Kubernetes vs Tier 2 SSH Docker Compose).

## Назначение

Экшен устраняет дублирование низкоуровневой bash-логики в конвейерах проектов (`build.yml`, `redeploy.yml`, `release.yml`), предотвращает риски инъекций (CWE-78), гарантирует валидный формат матрицы окружений для `$GITHUB_OUTPUT` и обеспечивает раннюю защиту продуктовых стендов до запуска длительных сборщиков.

## Режимы работы (`action`)

Экшен поддерживает три режима работы:
1. `environments`: Вычисляет JSON-массив сред развертывания для стратегии матрицы (`job.strategy.matrix.environment`). Разбирает `input_environment`, применяет `default_environment` или разворачивает массив `prod_environments` при включенном `fallback_to_prod`. Поддерживает ранний Prod Guard.
2. `target`: Определяет механизм развертывания для конкретного окружения: `k8s` при наличии `has_k8s_config: 'true'`, либо `ssh` при наличии `has_ssh_key: 'true'`. Проверяет принадлежность окружения к продакшну (`is_prod`) и обеспечивает вторую линию Prod Guard.
3. `guard`: Автономная проверка окружения на принадлежность к продакшну. Выставляет `is_prod` и прерывает выполнение с ошибкой, если стенд входит в `prod_environments`.

## Входные параметры (`inputs`)

| Параметр | Описание | Обязательный | По умолчанию |
|---|---|:---:|:---:|
| `action` | Режим работы: `environments`, `target` или `guard` | Да | — |
| `input_environment` | Окружение, переданное через входные параметры воркфлоу (например, `${{ inputs.environment }}`) | Нет | `''` |
| `default_environment` | Окружение по умолчанию при пустом `input_environment` (для `environments`) | Нет | `'dev'` |
| `fallback_to_prod` | Использовать массив `prod_environments` при пустом `input_environment` (для `redeploy.yml`) | Нет | `'false'` |
| `prod_environments` | Строка JSON-массива продуктовых окружений (например, `${{ vars.PROD_ENVIRONMENTS }}`) | Нет | `''` |
| `environment` | Текущее целевое окружение (для режимов `target` и `guard`, например `${{ matrix.environment }}`) | Нет | `''` |
| `prod_guard` | Прерывать конвейер при попытке развертывания на prod-окружение (для `build.yml`) | Нет | `'false'` |
| `has_k8s_config` | Флаг наличия конфигурации K8s (например, `${{ secrets.DEPLOY_CONFIG_K8S != '' }}`) | Нет | `'false'` |
| `has_ssh_key` | Флаг наличия приватного ключа SSH (например, `${{ secrets.SSH_PRIVATE_KEY != '' }}`) | Нет | `'false'` |

## Выходные параметры (`outputs`)

| Параметр | Описание | Формат/Значения |
|---|---|---|
| `environments` | JSON-массив разрешенных окружений для матрицы задач | Строка JSON-массива, например `["dev"]` или `["prod-1","prod-2"]` |
| `mode` | Разрешенный режим развертывания | `'k8s'` (Tier 1) или `'ssh'` (Tier 2) |
| `is_prod` | Флаг принадлежности окружения к списку продуктовых | `'true'` или `'false'` |

## Важное примечание по Prod Guard

Параметр `prod_guard: true` выставляется **исключительно** в конвейере сборки ветки разработки (`build.yml`), чтобы защитить продуктовые среды от непреднамеренной раскатки dev-сборки.

В конвейерах повторного развертывания и релизов (`redeploy.yml`, `release.yml`) параметр `prod_guard` должен иметь значение `false` (значение по умолчанию), так как раскатка на продуктовые среды в них является целевым штатным действием.

## Примеры использования

### 1. В джобе `resolve` конвейера `build.yml` (с `prod_guard: true`)

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

### 2. В джобе `resolve` конвейера `redeploy.yml` (с `fallback_to_prod: true`)

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

### 3. В джобе `deploy` (динамический выбор K8s/SSH и вторая линия Prod Guard)

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
      run: |
        echo "Deploying to K8s environment: ${{ matrix.environment }}"

    - name: Deploy via SSH
      if: steps.target.outputs.mode == 'ssh'
      run: |
        echo "Deploying via SSH to environment: ${{ matrix.environment }}"
```
