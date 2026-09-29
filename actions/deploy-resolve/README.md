# Deploy Resolve Action (`actions/deploy-resolve`)

Переиспользуемый композитный экшен платформы TheDevs для вычисления матрицы окружений развертывания и защиты продуктовых сред (Prod Guard).

## Назначение

Экшен устраняет дублирование низкоуровневой bash-логики в конвейерах проектов (`build.yml`, `redeploy.yml`, `release.yml`), предотвращает риски инъекций (CWE-78), гарантирует валидный формат матрицы окружений для `$GITHUB_OUTPUT` и обеспечивает раннюю защиту продуктовых стендов до запуска длительных сборщиков.

Для динамического выбора между развертыванием в Kubernetes (Tier 1) и через SSH Compose (Tier 2) используется отдельный стандартизированный экшен платформы `actions/resolve-deploy-target`.

## Режимы работы (`action`)

Экшен поддерживает два режима:
1. `environments`: Вычисляет JSON-массив сред развертывания для стратегии матрицы (`job.strategy.matrix.environment`). Разбирает `input_environment`, применяет `default_environment` или разворачивает массив `prod_environments` при включенном `fallback_to_prod`. Поддерживает ранний Prod Guard (`prod_guard: true`), блокирующий выполнение на этапе планирования матрицы.
2. `guard`: Автономная вторая линия защиты продуктовых сред (Prod Guard) перед шагами развертывания. Проверяет принадлежность стенда к списку `prod_environments`, выставляет `is_prod` в `$GITHUB_OUTPUT` и немедленно прерывает выполнение с ошибкой при попытке раскатки на продакшн.

## Входные параметры (`inputs`)

| Параметр | Описание | Обязательный | По умолчанию |
|---|---|:---:|:---:|
| `action` | Режим работы: `environments` или `guard` | Да | — |
| `input_environment` | Окружение, переданное через входные параметры воркфлоу (например, `${{ inputs.environment }}`) | Нет | `''` |
| `default_environment` | Окружение по умолчанию при пустом `input_environment` (для `environments`) | Нет | `'dev'` |
| `fallback_to_prod` | Использовать массив `prod_environments` при пустом `input_environment` (для `redeploy.yml`) | Нет | `'false'` |
| `prod_environments` | Строка JSON-массива продуктовых окружений (например, `${{ vars.PROD_ENVIRONMENTS }}`) | Нет | `''` |
| `environment` | Текущее целевое окружение для проверки (для режима `guard`, например `${{ matrix.environment }}`) | Нет | `''` |
| `prod_guard` | Прерывать конвейер при разрешении prod-окружения в режиме `environments` (для `build.yml`) | Нет | `'false'` |

## Выходные параметры (`outputs`)

| Параметр | Описание | Формат/Значения |
|---|---|---|
| `environments` | JSON-массив разрешенных окружений для матрицы задач | Строка JSON-массива, например `["dev"]` или `["prod-1","prod-2"]` |
| `is_prod` | Флаг принадлежности окружения к списку продуктовых (в режиме `guard`) | `'true'` или `'false'` |

## Важное примечание по Prod Guard

Защита продуктовых сред (`prod_guard: true` в режиме `environments` и вызов `action: guard` в задаче `deploy`) используется **исключительно** в конвейере сборки ветки разработки (`build.yml`), чтобы исключить непреднамеренное развертывание dev-сборки на продакшн.

В конвейерах повторного развертывания и релизов (`redeploy.yml`, `release.yml`) параметр `prod_guard` не включается и `action: guard` не вызывается, так как раскатка на продуктовые среды в них является целевым штатным действием.

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

### 3. В джобе `deploy` (вторая линия Prod Guard и определение цели через `resolve-deploy-target`)

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
    - name: Prod Guard
      uses: THEDEVS-RU/.github/actions/deploy-resolve@dev
      with:
        action: guard
        environment: ${{ matrix.environment }}
        prod_environments: ${{ vars.PROD_ENVIRONMENTS }}

    - name: Resolve Deploy Target
      id: target
      uses: THEDEVS-RU/.github/actions/resolve-deploy-target@dev
      with:
        deploy_config_k8s: ${{ secrets.DEPLOY_CONFIG_K8S }}
        ssh_host: ${{ vars.SSH_HOST }}
        ssh_user: ${{ vars.SSH_USER }}
        ssh_key: ${{ secrets.SSH_PRIVATE_KEY }}
        ssh_known_hosts: ${{ secrets.SSH_KNOWN_HOSTS }}

    - name: Deploy to K8s
      if: steps.target.outputs.is_k8s == 'true'
      run: |
        echo "Deploying to Kubernetes on environment ${{ matrix.environment }}"

    - name: Deploy via SSH Compose
      if: steps.target.outputs.is_ssh == 'true'
      run: |
        echo "Deploying via SSH Compose on environment ${{ matrix.environment }}"
```
