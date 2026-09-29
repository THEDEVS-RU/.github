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

Перед созданием пода Kaniko экшен выполняет быструю pre-flight проверку существования указанного `docker_secret` в целевом namespace:

```bash
kubectl -n "$NS" get secret "$SECRET" --request-timeout=15s
```

### Поведение проверки:
1. **Секрет существует (`Confirmed`):** сборка запускается в штатном режиме.
2. **Секрет не найден (`NotFound`):** экшен немедленно завершает работу с `::error::` и кодом 1. Это предотвращает создание пода, который завис бы на 40 минут (2400 секунд) в статусе `ContainerCreating` из-за невозможности смонтировать несуществующий K8s-секрет.
3. **Отказ в доступе (`Forbidden`) или ошибка сети/API:** проверка носит рекомендательный характер. Экшен выводит предупреждение `::warning::PREFLIGHT skipped...` и продолжает запуск сборки. Отсутствие у сервисного аккаунта раннера прав на чтение секретов не блокирует конвейер.

### Требования к RBAC:
Для полноценной работы pre-flight проверки сервисный аккаунт runner-а должен обладать правами `get` на ресурс `secrets` в сборочном пространстве имен (`BUILD_NAMESPACE`):

```yaml
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
```

## Пример использования

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
