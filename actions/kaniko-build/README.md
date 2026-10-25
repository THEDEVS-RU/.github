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
| `claude_cli_version` | Версия Claude CLI для передачи в `--build-arg=CLAUDE_CLI_VERSION` (если задана в `build_args`, приоритет у `build_args`) | Нет | `''` |
| `dockerhub_username` | Логин Docker Hub для аутентифицированных pull | Нет | `''` |
| `dockerhub_token` | Токен Docker Hub PAT для аутентифицированных pull | Нет | `''` |
| `insecure` | Флаг передачи `--insecure` в Kaniko | Нет | `'true'` |
| `insecure_pull` | Флаг передачи `--insecure-pull` в Kaniko | Нет | `'true'` |
| `image_fs_extract_retry`| Количество повторов распаковки файловой системы в Kaniko | Нет | `'0'` |
| `cpu_limit` | Лимит CPU для пода Kaniko (например, `16000m`, `8`). `0`, `0m` или `none` снимают лимит. Минимум — `requests.cpu` (`1000m`) | Нет | `'16000m'` |
| `extra_tags` | Дополнительные теги через запятую или пробел/перевод строки | Нет | `''` |
| `build_args` | Построчный список аргументов сборки (`KEY=VALUE`, без секретов). Имеет приоритет над `claude_cli_version` | Нет | `''` |
| `gradle_secret` | Имя существующего K8s-секрета в namespace с ключом `gradle.properties` для аутентификации в Gradle-репозиториях (opt-in) | Нет | `''` |
| `gradle_username` | Имя пользователя для аутентификации в приватном репозитории Gradle (`repo.thedevs.ru`). Передаётся строго вместе с `gradle_password` | Нет | `''` |
| `gradle_password` | Пароль для аутентификации в приватном репозитории Gradle (`repo.thedevs.ru`). Передаётся строго вместе с `gradle_username` | Нет | `''` |

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

## Передача секретов Gradle (`gradle_username` / `gradle_password` / `gradle_secret`)

Для сборки проектов, зависящих от закрытых snapshot-репозиториев артефактов (`repo.thedevs.ru`), экшен поддерживает безопасную передачу учетных данных Gradle в сборочный под Kaniko без сохранения паролей в Dockerfile, `--build-arg`, `env.value` или метаданных пода.

### Схема работы:
1. **Эфемерный секрет из учетных данных (`gradle_username` + `gradle_password`):**
   - На каждую попытку сборки экшен генерирует временный K8s-секрет `${POD}-gradle` (с `umask 077` и экранированием `\` как `\\`), содержащий канонический файл `gradle.properties` со свойствами `thedevsRepoUser`, `thedevsRepoPassword`, `uploadUser`, `uploadPassword`.
   - Создание выполняется через пайп `kubectl create secret generic --dry-run=client -o yaml | kubectl apply -f -` под `set -o pipefail`.
   - На созданный секрет проставляется `ownerReferences` на под Kaniko, что гарантирует автоматическое удаление секрета Kubernetes Garbage Collector-ом при аварийном завершении раннера (`SIGKILL`).
   - Имена созданных секретов аккумулируются в массиве `CREATED_GRADLE_SECRETS` и гарантированно удаляются через `trap` при завершении экшена (успешном или с ошибкой), а также немедленно при сбое попытки `kubectl apply` пода.
2. **Монтирование постоянного секрета (`gradle_secret`):**
   - Если передан существующий секрет `gradle_secret`, выполняется fail-fast pre-flight проверка: при статусе `NotFound` экшен немедленно завершается с кодом 1, исключая зависание пода в `ContainerCreating`.
3. **Прямое монтирование в Kaniko (без init-контейнеров):**
   - Секрет монтируется напрямую в контейнер `kaniko` как том `secret` с правами `defaultMode: 0400` в точку монтирования `/root/.gradle/gradle.properties` (`subPath: gradle.properties`, `readOnly: true`).
   - При отсутствии параметров `gradle_*` монтирование не производится, манифест пода сохраняет стандартный вид.

### Требования к RBAC для работы с секретами:
Сервисный аккаунт сборочного раннера (`BUILDER_CONFIG_K8S`) должен обладать правами `get`, `create`, `delete` и `patch` на ресурс `secrets` в пространстве имен сборщика (`BUILD_NAMESPACE`):

```yaml
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "delete", "patch"]
```

## Примеры использования

### Сборка с учетными данными Gradle из GitHub Secrets (рекомендуется для JVM)

```yaml
- name: Build container image
  uses: THEDEVS-RU/.github/actions/kaniko-build@dev
  with:
    image: ${{ env.IMAGE_NAME }}
    tag: ${{ env.IMAGE_TAG }}
    namespace: ${{ vars.BUILD_NAMESPACE }}
    git_token: ${{ secrets.GITHUB_TOKEN }}
    cache_pvc: ${{ env.CACHE_PVC }}
    gradle_username: ${{ secrets.MAVEN_USERNAME }}
    gradle_password: ${{ secrets.MAVEN_PASSWORD }}
```

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
    registry_username: ${{ secrets.REGISTRY_USERNAME }}
    registry_token: ${{ secrets.REGISTRY_PASSWORD }}
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
