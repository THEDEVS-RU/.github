# Kaniko Build Action (`actions/kaniko-build`)

Переиспользуемый композитный экшен для сборки Docker-образов через Kaniko внутри Kubernetes-кластера с поддержкой PVC-кэширования Gradle/Node/npm, аутентификации в корпоративном реестре и механизмом автоматических повторов (retry).

## Описание

Экшен разворачивает эфемерный под Kaniko в указанном Kubernetes-пространстве имен (`namespace`), монтирует постоянные тома кэша (`kaniko-cache` и переданный `cache_pvc`), инициирует сборку из контекста Git-репозитория и отслеживает состояние сборки до успешного завершения либо исчерпания таймаута.

По умолчанию экшен ориентирован на корпоративный реестр платформы TheDevs (`registry.thedevs.ru`) с секретом авторизации `thedevs-registry-secret`.

## Входные параметры (`inputs`)

| Параметр | Описание | Обязательный | По умолчанию |
|---|---|:---:|:---:|
| `image` | Базовое имя целевого Docker-образа (например, `registry.container-registry.svc.cluster.local:5000/thedevslk` или `registry.thedevs.ru/thedevslk`) | Да | — |
| `tag` | Тег собираемого Docker-образа | Да | — |
| `namespace` | Целевой Kubernetes namespace для запуска пода Kaniko | Да | — |
| `git_token` | GitHub токен для клонирования контекста репозитория в Kaniko | Да | — |
| `cache_pvc` | Имя PVC-тома для кэша сборки конкретного проекта | Да | — |
| `docker_secret` | Имя K8s-секрета с данными авторизации в реестре (тип `kubernetes.io/dockerconfigjson`) | Нет | `thedevs-registry-secret` |
| `registry_token` | Токен или пароль для аутентификации в корпоративном реестре | Нет | `''` |
| `registry_username` | Имя пользователя для корпоративного реестра | Нет | `'thedevsru'` |
| `registry_server` | Хост корпоративного реестра | Нет | `'registry.thedevs.ru'` |
| `repo` | Путь к репозиторию для контекста Kaniko (если пустой, берётся текущий репозиторий) | Нет | `''` |
| `branch` | Git-ветка контекста сборки | Нет | `''` |
| `cache_repo` | Репозиторий удаленного кэша слоев Kaniko | Нет | `''` |
| `build_timeout` | Таймаут сборки в секундах | Нет | `'7200'` |
| `dockerfile` | Относительный путь к Dockerfile | Нет | `'Dockerfile'` |
| `claude_cli_version` | Версия Claude CLI для передачи в `--build-arg=CLAUDE_CLI_VERSION` | Нет | `''` |
| `dockerhub_username` | Логин Docker Hub для аутентифицированных pull | Нет | `''` |
| `dockerhub_token` | Токен Docker Hub PAT для аутентифицированных pull | Нет | `''` |
| `insecure` | Флаг передачи `--insecure` в Kaniko | Нет | `'true'` |
| `insecure_pull` | Флаг передачи `--insecure-pull` в Kaniko | Нет | `'true'` |
| `image_fs_extract_retry`| Количество повторов распаковки файловой системы в Kaniko | Нет | `'0'` |

## Встроенная Pre-flight проверка секрета реестра

Если входной параметр `docker_secret` не пустой (`if [ -n "$SECRET" ]`), перед созданием пода Kaniko экшен выполняет pre-flight проверку существования секрета в целевом namespace:

```bash
SECRET_CHECK_ERR=$(kubectl -n "$NS" get secret "$SECRET" --request-timeout=15s 2>&1 >/dev/null || true)
```

### Поведение проверки:
1. **Секрет существует:** сборка запускается в штатном режиме, секрет монтируется с `optional: true`.
2. **Секрет не найден (`NotFound`):**
   - Если передан непустой `registry_token`, отсутствие K8s-секрета не блокирует выполнение: экшен выводит предупреждение `::warning::Docker secret '$SECRET' not found in namespace '$NS', but registry_token is provided — proceeding with token auth` и продолжает сборку с аутентификацией по токену через init-контейнер `merge-docker-config`.
   - Если `registry_token` не передан, экшен немедленно завершает работу с `::error::Docker secret '$SECRET' specified but not found in namespace '$NS'` и кодом 1. Это предотвращает создание пода, который завис бы в статусе `ContainerCreating` из-за невозможности смонтировать несуществующий K8s-секрет.
3. **Отказ в доступе (`Forbidden`) или иная ошибка API/сети:** проверка носит рекомендательный характер. Экшен выводит предупреждение `::warning::Could not verify secret '$SECRET' in namespace '$NS' (proceeding with optional volume): $SECRET_CHECK_ERR` и продолжает сборку (секрет монтируется как `optional: true`).
4. **Секрет не передан (`docker_secret: ''`):** проверка пропускается, вместо тома секрета под монтирует пустой каталог `emptyDir: {}`.

### Требования к RBAC:
Для полноценной работы pre-flight проверки сервисный аккаунт runner-а должен обладать правами `get` на ресурс `secrets` в сборочном пространстве имен (`BUILD_NAMESPACE`):

```yaml
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
```

## Примеры использования

### Сборка с аутентификацией через GitHub Secret (рекомендуется)

```yaml
- name: Build Docker Image
  uses: THEDEVS-RU/.github/actions/kaniko-build@dev
  with:
    image: registry.thedevs.ru/thedevslk
    tag: ${{ github.sha }}
    namespace: ${{ vars.BUILD_NAMESPACE }}
    git_token: ${{ secrets.GITHUB_TOKEN }}
    cache_pvc: thedevslk-cache-pvc
    registry_token: ${{ secrets.REGISTRY_TOKEN }}
```

### Сборка с аутентификацией через K8s-секрет

```yaml
- name: Build Docker Image
  uses: THEDEVS-RU/.github/actions/kaniko-build@dev
  with:
    image: registry.thedevs.ru/thedevslk
    tag: ${{ github.sha }}
    namespace: ${{ vars.BUILD_NAMESPACE }}
    git_token: ${{ secrets.GITHUB_TOKEN }}
    cache_pvc: thedevslk-cache-pvc
    docker_secret: thedevs-registry-secret
```
