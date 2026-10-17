id: 2026-10-17-thedevs-base-images-lego-stack
product: thedevs-base-images
repo: THEDEVS-RU/base-images
branch: dev
depends_on: [2026-10-17-kaniko-build-cpu-limit-and-build-args]
awaits_task: TD-2197
complexity: simple
stage: detailed
external_content: true
impl_model: sonnet
impl_effort: high

# Контракт

- **Consumes**:
  1. `actions/kaniko-build` из `THEDEVS-RU/.github@dev` с поддержкой входных параметров `cpu_limit`, `extra_tags` и `build_args` per `2026-10-17-kaniko-build-cpu-limit-and-build-args` (PR THEDEVS-RU/.github#29, задача TD-2197).
  2. K8s Secret `thedevs-registry-secret` (тип `kubernetes.io/dockerconfigjson`) в namespace `dev` для авторизации в реестре `registry.thedevs.ru`.
  3. Прецедент тиражирования и копирования образов через кластерный под `crane` с флагом `--insecure` из `marta/.github/workflows/mirror-images.yml:35-67`.
  4. Предварительные условия bootstrap оператора: созданный приватный репозиторий `THEDEVS-RU/base-images`, дефолтная ветка `dev`, группа self-hosted раннеров `master`, доступ к org-секретам `BUILDER_CONFIG_K8S`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`.
- **Produces**:
  1. Репозиторий `THEDEVS-RU/base-images` со структурой Dockerfile для 3 слоев Lego-стека (`thedevs-core` -> `thedevs-ai` -> `thedevs-browser`) и манифестом K8s PVC кэша `k8s/pvc-cache.yaml` (10Gi).
  2. CI-пайплайн `.github/workflows/build-base-images.yml` на self-hosted раннере `master` с регулярной сборкой (cron по воскресеньям в 03:00 UTC на дефолтной ветке `dev`), ручным запуском (`workflow_dispatch`), расчетом тегов в resolve-джобе, каскадной пересборкой зависимых слоев и сборкой тегов `dev`, `<branch>-YYYYMMDD-<run>`.
  3. Пайплайн продвижения `.github/workflows/promote-base-images.yml` для перетегирования проверенного digest в `master` и `latest` через эфемерный под `gcr.io/go-containerregistry/crane` в кластере без повторной сборки.
  4. Опубликованные базовые Docker-образы в `registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-{core,ai,browser}` (внешний шлюз `registry.thedevs.ru`).
  5. Контракт перевода проектов платформы (`shield-3`, `thedevslk`, `mobitrack-2`, `TemplateProject`, `marta`/`flparser`) на базовые слои через дочерние задачи (`TD-2204`–`TD-2208`).

# Контекст

В микросервисах платформы TheDevs (`thedevslk`, `shield-3`, `mobitrack-2`, `marta`, `flparser`, `TemplateProject`) в каждом `Dockerfile` дублируется ручная установка системных пакетов, JRE, Node.js, утилит командной строки CoreAI и браузеров. Это приводит к разрастанию времени сборки (до 4–8 минут), дублированию уязвимостей, расхождению версий и повторной загрузке сотен мегабайт внешних зависимостей.

Фактическое состояние экосистемы (проверяемые факты):
1. **Версии PostgreSQL серверов и клиента**:
   - `postgres-service.default.svc.cluster.local:5432` отдаёт `PostgreSQL 16.10 (Debian 16.10-1.pgdg13+1)`.
   - `addon-core@dev:core/src/main/java/ru/thedevs/backup/target/PgDumpBackupTarget.java:94-99` требует строго `clientMajorVersion >= serverMajorVersion`. Фиксация `ARG PG_CLIENT_MAJOR=18` в `thedevs-core` (репозиторий `noble-pgdg` предоставляет пакет `postgresql-client-18`) обеспечивает `18 >= 16`, гарантируя совместимость с текущими серверами кластера и будущими релизами PostgreSQL 17 и 18.
2. **Версии Playwright**:
   - `THEDEVS-RU/addon-browser@dev:gradle/libs.versions.toml:4` фиксирует `playwright = "1.58.0"`. Снятие устаревшего принудительного `force = "1.52.0"` вынесено в задачу `TD-2211`.
   - `thedevs-browser` запекает Chromium и Firefox версии `1.58.0` с установкой системных библиотек через Playwright CLI.
3. **Память и лимиты подов**:
   - `kubectl get deployment -n dev`: `flparser` (limits.memory 6Gi), `thedevslk` (limits.memory 10Gi), `shield` (limits.memory 20Gi), `mobitrack` (limits.memory 3Gi).
   - Базовый образ полностью свободен от дефолтных флагов памяти JVM (отсутствует `JAVA_TOOL_OPTIONS`). Настройки памяти передаются строго через переменные окружения деплойментов. В `shield-3` сервисные JVM-флаги (`-XX:MaxRAMPercentage=85` и др.) переносятся из `Dockerfile:57` в `JAVA_TOOL_OPTIONS` манифеста `Deployment/deployment-dev.yaml` в рамках задачи `TD-2204`.
4. **Сетевые политики и безопасность**:
   - `kubectl get networkpolicy -n dev` возвращает `No resources found in dev namespace.` Утверждения о наличии защитных NetworkPolicy в dev являются ложными. Блокировка исходящего UDP и WebRTC утечек оформлена в задачу `TD-2210`.
5. **Инфраструктура Kaniko**:
   - `kubectl get pvc -n dev` подтверждает отсутствие тома `kaniko-cache-thedevs-base`. В манифесте фиксируется объем `10Gi`.
6. **Gemini CLI**:
   - Закрыт Google 18.06.2026. Исключен из `thedevs-ai`. Аудит и миграция раннеров в `thedevslk` и `addon-core-ai` вынесены в задачу `TD-2212`. Задача перевода `thedevslk` (`TD-2205`) ожидает выполнения `TD-2212`.
7. **Структура marta и flparser**:
   - Оба сервиса размещены в едином репозитории `THEDEVS-RU/marta` (деплойменты генерируются из `Deployment/app.yaml.tpl:43,102`). Перевод обоих сервисов с упразднением `marta-base` и снятием переопределения `PLAYWRIGHT_BROWSERS_PATH` оформлен в задачу `TD-2208`.
8. **Каскадное продвижение и cron**:
   - GitHub cron запускается строго на дефолтной ветке `dev`. Ветка `master` не пересобирает образы, а продвигает проверенный digest из `dev` перетегированием через под с `crane copy --insecure`. Потребители на ветке `dev` передают `build_args: BASE_TAG=dev`.

# Что сделать

## 1. Подготовительные действия оператора (Bootstrap)

До первого запуска пайплайна оператор выполняет разовые действия:
1. Создает приватный репозиторий `THEDEVS-RU/base-images`.
2. Устанавливает ветку по умолчанию `dev`.
3. Назначает репозиторию группу self-hosted раннеров `master`.
4. Предоставляет репозиторию доступ к org-секретам `BUILDER_CONFIG_K8S`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`.

## 2. Структура репозитория THEDEVS-RU/base-images

Создать в репозитории `THEDEVS-RU/base-images`:
- `docker/thedevs-core/Dockerfile`
- `docker/thedevs-ai/Dockerfile`
- `docker/thedevs-browser/Dockerfile`
- `k8s/pvc-cache.yaml`
- `.github/workflows/build-base-images.yml`
- `.github/workflows/promote-base-images.yml`
- `README.md`

## 3. Слой thedevs-core (`docker/thedevs-core/Dockerfile`)

Базовый образ платформы для серверных Java-приложений без AI-раннеров (`mobitrack-2`, `TemplateProject`):
- База: `eclipse-temurin:25-jre-noble` (Ubuntu 24.04 LTS).
- Удаление системного пользователя `ubuntu` (UID 1000) и создание непривилегированного пользователя:
  `groupadd -g 1000 appuser && useradd -u 1000 -g appuser -m -s /bin/bash appuser`.
- Переключение зеркал на `ru.archive.ubuntu.com` для deb822 (`/etc/apt/sources.list.d/ubuntu.sources`) и классического формата.
- Системный стек: `ca-certificates`, `curl`, `git`, `jq`, `tini`, `locales` (`ENV LANG=C.UTF-8`, `ENV LC_ALL=C.UTF-8`), `fontconfig`, `fonts-dejavu-core`, `fonts-liberation`.
- PostgreSQL клиент: официальный репозиторий PGDG `noble-pgdg` с установкой ключа в `/etc/apt/keyrings/postgresql.gpg` (без устаревшего apt-key) и фиксированным аргументом `ARG PG_CLIENT_MAJOR=18`.
- Проверка версий на этапе сборки:
  `git --version && jq --version && curl --version && /usr/bin/tini --version && pg_dump --version | grep -E " (18\.|18 )"`
- `WORKDIR /app`, `chown -R 1000:1000 /app`.
- Отсутствие дефолтных флагов кучи JVM в `JAVA_TOOL_OPTIONS`.
- `ENTRYPOINT ["/usr/bin/tini", "--"]`.
- `ARG CACHEBUST=0` для управляемой инвалидации кэша слоев при обновлениях безопасности.

## 4. Слой thedevs-ai (`docker/thedevs-ai/Dockerfile`)

Слой на базе `thedevs-core` для сервисов с агентами CoreAI (`shield-3`):
- `ARG BASE_IMAGE=registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-core:latest`
- `FROM ${BASE_IMAGE}`
- `ARG CACHEBUST=0`
- Node.js 22 LTS: установка официального репозитория NodeSource через signed-by связку ключей `/etc/apt/keyrings/nodesource.gpg` (без использования небезопасного `curl | bash`).
- GitHub CLI: установка `gh` через официальный репозиторий с `/etc/apt/keyrings/githubcli-archive-keyring.gpg`.
- Claude Code CLI: `npm install -g @anthropic-ai/claude-code@${CLAUDE_CLI_VERSION}` с аргументом `ARG CLAUDE_CLI_VERSION=latest`, передаваемым из CI.
- Codex CLI: установка `ARG CODEX_CLI_VERSION=0.144.6` (`npm install -g @openai/codex@${CODEX_CLI_VERSION}`).
- Google Antigravity CLI (`agy`): скачивание бинарного релиза с контролем целостности через `sha512sum`:
  `ARG AGY_CLI_URL=https://storage.googleapis.com/antigravity-public/antigravity-cli/1.2.3-5101874907578368/linux-x64/cli_linux_x64.tar.gz`
  `ARG AGY_CLI_SHA512=ec74dc5ce20e64623a4d68e73a8957e468c026bdb3d07b15c5291490323133970c735d985af839eab057b52b1bfd1b2e91ff49abeebef032ffae6dded8e2a763`
  `ENV AGY_CLI_DISABLE_AUTO_UPDATE=true`
- Gemini CLI: явно исключен (закрыт Google 18.06.2026, миграция в `TD-2212`).
- Каталоги сессий CoreAI с правами `1000:1000`:
  `/app/.jmix/claude-home`, `/tmp/coreai-sessions`, `/tmp/coreai-tool-markers`.
- Smoke-проверка на этапе сборки:
  `node --version && npm --version && gh --version && claude --version && codex --version && agy --version`
- ENTRYPOINT сохраняет `/usr/bin/tini --` для корректного сбора зомби-процессов Claude CLI.

## 5. Слой thedevs-browser (`docker/thedevs-browser/Dockerfile`)

Слой на базе `thedevs-ai` для UI-рендеринга и скрапинга (`thedevslk`, `marta`, `flparser`):
- `ARG BASE_IMAGE=registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-ai:latest`
- `FROM ${BASE_IMAGE}`
- `ARG CACHEBUST=0`
- `ARG PLAYWRIGHT_VERSION=1.58.0`
- `LABEL ru.thedevs.playwright.version="${PLAYWRIGHT_VERSION}"`
- Установка браузеров Chromium и Firefox с системными библиотеками:
  `ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright`
  `ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`
  `RUN npx --yes playwright@${PLAYWRIGHT_VERSION} install --with-deps chromium firefox`
  `RUN npm install -g playwright@${PLAYWRIGHT_VERSION}`
  `ENV NODE_PATH="/usr/lib/node_modules"`
- Права доступа: каталог `/opt/ms-playwright` сохраняет владение `root:root` и права `755` (`find /opt/ms-playwright -type d -exec chmod 755 {} + && find /opt/ms-playwright -type f -exec chmod a+rx {} +`). Блокировочный файл `__dirlock` используется только при установке; пользовательские данные браузеров изолируются в эфемерных каталогах `/tmp`.
- Smoke-проверка на этапе сборки образа с проверкой пути глобального модуля:
  `RUN test -d "$(npm root -g)/playwright" && NODE_PATH="$(npm root -g)" node -e "const { chromium, firefox } = require('playwright'); (async () => { const b1 = await chromium.launch({ headless: true }); await b1.close(); const b2 = await firefox.launch({ headless: true }); await b2.close(); console.log('Chromium & Firefox launch OK'); })()"`

## 6. Инфраструктурный манифест PVC (`k8s/pvc-cache.yaml`)

Манифест создания тома кэша Kaniko для базовых образов:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: kaniko-cache-thedevs-base
  namespace: dev
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: standard
  resources:
    requests:
      storage: 10Gi
```

## 7. CI-пайплайн сборки (`.github/workflows/build-base-images.yml`)

1. **Триггеры и concurrency**:
   - `workflow_dispatch` с выбором слоя: `layer: ['all', 'core', 'ai', 'browser']`.
   - `schedule`: cron `0 3 * * 0` (еженедельно в воскресенье в 03:00 UTC на дефолтной ветке `dev`).
   - `push`: ветка `dev` (пути `docker/**`, `k8s/**`, `.github/workflows/**`).
   - `concurrency: { group: base-images-${{ github.ref }}, cancel-in-progress: false }`.
2. **Права и раннер**:
   - `permissions: { contents: read }`.
   - `runs-on: master` (self-hosted раннер с доступом к K8s кластеру).
3. **Настройка K8s**:
   - Шаг `azure/setup-kubectl@v4`.
   - Шаг создания `~/.kube/config` из `secrets.BUILDER_CONFIG_K8S`.
4. **Resolve job (`resolve`)**:
   - Вычисляет теги один раз в UTC:
     `DATE_TAG=$(date -u +'%Y%m%d')`
     `RUN_TAG="${{ github.ref_name }}-${DATE_TAG}-${{ github.run_number }}"`
   - Разрешает актуальную версию `@anthropic-ai/claude-code` через `npm view @anthropic-ai/claude-code version`.
   - Формирует список `extra_tags`: для ветки `dev` передает `dev`.
   - Определяет флаги сборки слоев (`build_core`, `build_ai`, `build_browser`):
     - При cron, push или `layer=all`: все слои (`build_core`, `build_ai`, `build_browser`) выставляются в `true`.
     - При dispatch: каскад (`core` -> все `true`; `ai` -> `ai` и `browser` `true`; `browser` -> только `browser` `true`).
   - Вычисляет `BASE_IMAGE_AI` и `BASE_IMAGE_BROWSER`:
     - Если нижний слой собирается в текущем прогоне: `registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-<layer>:${RUN_TAG}`.
     - Если нижний слой пропущен: фиксирует актуальный digest тега `:dev` через под crane и передает его для воспроизводимости.
5. **Шаг инициализации инфраструктуры (`init-infra`)**:
   - Джоба `init-infra` применяет `kubectl apply -f k8s/pvc-cache.yaml --request-timeout=30s` для гарантии наличия тома `kaniko-cache-thedevs-base`.
6. **Сборочные джобы (`build-core`, `build-ai`, `build-browser`)**:
   - `build-core`: `needs: [resolve, init-infra]`, `if: ${{ !failure() && !cancelled() && needs.resolve.outputs.build_core == 'true' }}`.
     Входные параметры `actions/kaniko-build`:
     `image: registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-core`
     `tag: ${{ needs.resolve.outputs.run_tag }}`
     `dockerfile: docker/thedevs-core/Dockerfile`
     `namespace: dev`
     `git_token: ${{ secrets.GITHUB_TOKEN }}`
     `dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}`
     `dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}`
     `cache_pvc: kaniko-cache-thedevs-base`
     `cpu_limit: 16000m`
     `build_timeout: 7200`
     `extra_tags: ${{ needs.resolve.outputs.extra_tags }}`
     `build_args: CACHEBUST=${{ needs.resolve.outputs.date_tag }}`
   - `build-ai`: `needs: [resolve, init-infra, build-core]`, `if: ${{ !failure() && !cancelled() && needs.resolve.outputs.build_ai == 'true' }}`.
     Входные параметры `actions/kaniko-build`:
     `image: registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-ai`
     `tag: ${{ needs.resolve.outputs.run_tag }}`
     `dockerfile: docker/thedevs-ai/Dockerfile`
     `namespace: dev`
     `git_token: ${{ secrets.GITHUB_TOKEN }}`
     `dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}`
     `dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}`
     `cache_pvc: kaniko-cache-thedevs-base`
     `cpu_limit: 16000m`
     `build_timeout: 7200`
     `extra_tags: ${{ needs.resolve.outputs.extra_tags }}`
     `build_args: BASE_IMAGE=${{ needs.resolve.outputs.base_image_ai }},CLAUDE_CLI_VERSION=${{ needs.resolve.outputs.claude_version }},CACHEBUST=${{ needs.resolve.outputs.date_tag }}`
   - `build-browser`: `needs: [resolve, init-infra, build-ai]`, `if: ${{ !failure() && !cancelled() && needs.resolve.outputs.build_browser == 'true' }}`.
     Входные параметры `actions/kaniko-build`:
     `image: registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-browser`
     `tag: ${{ needs.resolve.outputs.run_tag }}`
     `dockerfile: docker/thedevs-browser/Dockerfile`
     `namespace: dev`
     `git_token: ${{ secrets.GITHUB_TOKEN }}`
     `dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}`
     `dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}`
     `cache_pvc: kaniko-cache-thedevs-base`
     `cpu_limit: 16000m`
     `build_timeout: 7200`
     `extra_tags: ${{ needs.resolve.outputs.extra_tags }}`
     `build_args: BASE_IMAGE=${{ needs.resolve.outputs.base_image_browser }},PLAYWRIGHT_VERSION=1.58.0,CACHEBUST=${{ needs.resolve.outputs.date_tag }}`

## 8. Пайплайн продвижения и отката (`.github/workflows/promote-base-images.yml`)

1. Ручной запуск `workflow_dispatch` с входными параметрами:
   - `source_tag`: неизменяемый проверенный тег (например `dev-20261018-12`).
   - `promote_target`: выбор целевых тегов (`latest-and-master` или `rollback`).
2. Продвижение выполняется без повторной сборки через запуск эфемерного пода с утилитой `crane` внутри K8s кластера per `marta/.github/workflows/mirror-images.yml:35-67`:
   - Настройка `KUBECONFIG` из `secrets.BUILDER_CONFIG_K8S`.
   - Запуск пода `crane-promote` в namespace `dev` с образом `gcr.io/go-containerregistry/crane:latest` и флагом `--insecure`.
   - Проверка наличия `SOURCE_TAG` для каждого слоя (`crane digest ... --insecure`).
   - Копирование проверенного digest в `latest` и `master`:
     ```bash
     REGISTRY="registry.container-registry.svc.cluster.local:5000/thedevs-ru"
     for img in thedevs-core thedevs-ai thedevs-browser; do
       crane copy "${REGISTRY}/${img}:${SOURCE_TAG}" "${REGISTRY}/${img}:latest" --insecure
       crane copy "${REGISTRY}/${img}:${SOURCE_TAG}" "${REGISTRY}/${img}:master" --insecure
     done
     ```
   - Ожидание завершения пода (`Phase == Succeeded`).
3. Откат (Rollback): выполняется аналогичным запуском с указанием предыдущего проверенного тега `<branch>-YYYYMMDD-<run>`, восстанавливая `latest` и `master` за секунды без пересборки.

## 9. Контракты перевода проектов (дочерние задачи)

Общий инвариант: в CI-пайплайнах всех потребителей (`.github/workflows/*.yml`) при сборках на ветке `dev` передается `build_args: BASE_TAG=dev`, гарантируя автоматическое тестирование свежих образов до их продвижения. На ветке `master` используется дефолт `BASE_TAG=latest`.

1. **`THEDEVS-RU/shield-3` -> `thedevs-ai`** (Задача `TD-2204`, depends_on `TD-2201`):
   - Замена `FROM eclipse-temurin:25-jre-noble` на `ARG BASE_TAG=latest` и `FROM registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-ai:${BASE_TAG}`.
   - Удаление дублирующихся установок Node.js, `gh`, `claude-code`, `agy`, `postgresql-client`.
   - Сохранение контрактов: `find . -name "*-plain.jar" -delete && mv *.jar app.jar && chown 1000:1000 app.jar`.
   - Перенос сервисных флагов JVM (`-XX:MaxRAMPercentage=85`, `-XX:+ExplicitGCInvokesConcurrent`, `-Xlog:gc*...`) из `Dockerfile:57` в переменную `JAVA_TOOL_OPTIONS` манифеста `Deployment/deployment-dev.yaml`.
   - `ENTRYPOINT ["/usr/bin/tini", "--", "java", "-jar", "app.jar"]`.
2. **`THEDEVS-RU/thedevslk` -> `thedevs-browser`** (Задача `TD-2205`, depends_on `TD-2201` и `TD-2212`):
   - Замена ручной сборки рантайма на `ARG BASE_TAG=latest` и `FROM registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-browser:${BASE_TAG}`.
   - Проверка совпадения зарезолвленной зависимости `com.microsoft.playwright:playwright` с `LABEL ru.thedevs.playwright.version` базового образа.
   - Сохранение `scripts/generate-kubeconfig.sh`, `scripts/entrypoint.sh` и `kubectl`.
   - Сохранение `ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]`.
   - Использование запеченных шрифтов `fonts-liberation` и `fonts-dejavu-core` для отчетов `BAL_INVOICE`.
   - Передача параметров безопасности при запуске браузеров: `--force-webrtc-ip-handling-policy=disable_non_proxied_udp` для Chromium, `media.peerconnection.enabled=false` для Firefox.
3. **`THEDEVS-RU/mobitrack-2` -> `thedevs-core`** (Задача `TD-2206`, depends_on `TD-2201`):
   - Замена на `ARG BASE_TAG=latest` и `FROM registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-core:${BASE_TAG}`.
   - Сохранение импорта банковских сертификатов Минцифры в cacerts (`COPY docker/certs/*.pem /tmp/certs/` и `keytool -importcert`).
   - Сохранение `find . -name "*-plain.jar" -delete && mv *.jar app.jar`.
4. **`THEDEVS-RU/TemplateProject` -> `thedevs-core`** (Задача `TD-2207`, depends_on `TD-2201`):
   - Замена на `ARG BASE_TAG=latest` и `FROM registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-core:${BASE_TAG}`.
   - Чистый эталон для микросервисов платформы без CoreAI.
5. **`THEDEVS-RU/marta` (деплойменты `marta` и `flparser`) -> `thedevs-browser`** (Задача `TD-2208`, depends_on `TD-2201`):
   - Замена `marta-base` на `ARG BASE_TAG=latest` и `FROM registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-browser:${BASE_TAG}`.
   - Удаление устаревших артефактов в `marta`: `Dockerfile.base`, `.github/workflows/build-base.yml`, образ `marta-base`.
   - Удаление переопределения `PLAYWRIGHT_BROWSERS_PATH` в манифесте шаблона `Deployment/app.yaml.tpl:43,102`.
   - Проверка совпадения зарезолвленной зависимости `com.microsoft.playwright:playwright` с `LABEL ru.thedevs.playwright.version` базового образа.
   - Сохранение каталогов `/app/.jmix/heapdumps` и `/app/.jmix/gc-logs`, `USER 1000`.

## Затрагиваемые файлы

1. `docker/thedevs-core/Dockerfile`
2. `docker/thedevs-ai/Dockerfile`
3. `docker/thedevs-browser/Dockerfile`
4. `k8s/pvc-cache.yaml`
5. `.github/workflows/build-base-images.yml`
6. `.github/workflows/promote-base-images.yml`
7. `README.md`

# Что уже есть

1. `THEDEVS-RU/.github:actions/kaniko-build/action.yml` — PR #29 с поддержкой `cpu_limit`, `extra_tags`, `build_args` ожидает мерджа в `dev` по задаче TD-2197 (зафиксировано в `awaits_task: TD-2197`).
2. K8s Secret `thedevs-registry-secret` в namespace `dev` (тип `kubernetes.io/dockerconfigjson`, возраст 18d).
3. Прецедент тиражирования и копирования образов через кластерный под `crane` в `marta/.github/workflows/mirror-images.yml:35-67`.
4. Сборочный узел `.248` с 24 потоками AMD Ryzen 9 7900X под управлением Kubernetes.
5. Внутренний реестр кластера `registry.container-registry.svc.cluster.local:5000/thedevs-ru/` и внешний шлюз `registry.thedevs.ru`.
6. Кластерная база данных `PostgreSQL 16.10` на `postgres-service.default.svc.cluster.local:5432`.
7. Зависимость `com.microsoft.playwright:playwright:1.58.0` в `addon-browser@dev:gradle/libs.versions.toml:4`.
8. Заведенные задачи на доске: `TD-2204` (shield-3), `TD-2205` (thedevslk), `TD-2206` (mobitrack-2), `TD-2207` (TemplateProject), `TD-2208` (marta/flparser), `TD-2209` (SSRF-фильтр), `TD-2210` (Egress NetworkPolicy UDP), `TD-2211` (Playwright unforce), `TD-2212` (Gemini CLI аудит/миграция).

# Модель угроз

Включение инструментов выполнения кода, CLI-утилит и headless-браузеров (Chromium, Firefox) в слои `thedevs-ai` и `thedevs-browser` требует строгого анализа рисков работы с внешним контентом per `security-external-content.md`:

### 1. SSRF (Server-Side Request Forgery)
- **Реализовано в базе**: В базовые образы не запекаются пароли, статические API-ключи, служебные токены кластера или kubeconfig.
- **Требования к сервисам-потребителям**: Потребители (`flparser`, `marta`, `thedevslk`) обязаны валидировать IP-адрес назначения строго в момент установки TCP Connect (кастомный `DnsResolver` / socket connect hook) с блокировкой приватных сетей RFC 1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), Loopback (`127.0.0.0/8`), Link-Local (`169.254.0.0/16`), Cloud Metadata (`169.254.169.254`, `metadata.google.internal`) и имен K8s (`*.svc.cluster.local`, `kubernetes.default`). Разрешены строго схемы `http://` и `https://`; схемы `file://`, `chrome://`, `data:` запрещены.
- **Пробел / Follow-up**: Централизованный SSRF-фильтр в `addon-browser` оформлен задачей `TD-2209`.

### 2. Обход loopback в Chromium (`<-loopback>`)
- **Реализовано в базе**: Базовый образ не навязывает небезопасных дефолтных флагов Chromium.
- **Требования к сервисам-потребителям**: Сервисы автоматизации браузера обязаны передавать флаг `--proxy-bypass-list=<-loopback>` при старте Chromium для предотвращения скрытого обхода прокси-фильтра при обращении к `localhost`. Внутренние эндпоинты (`/mcp`, Spring Actuator) защищаются обязательной Bearer-аутентификацией.
- **Пробел / Follow-up**: Контролируется тестами в задаче перевода `TD-2205`.

### 3. Утечки через WebRTC и UDP
- **Реализовано в базе**: Ничего (базовый образ содержит бинарные пакеты браузеров).
- **Требования к сервисам-потребителям**: Запуск Chromium с аргументом `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`, настройка Firefox через `media.peerconnection.enabled=false` в параметрах контекста. Задачи `TD-2205` и `TD-2208`.
- **Пробел / Follow-up**: В namespace `dev` политики `NetworkPolicy` отсутствуют (`kubectl get networkpolicy -n dev` -> `No resources found`). Блокировка исходящего UDP на уровне кластера выделена в отдельную инфраструктурную задачу `TD-2210`.

### 4. Попапы, загрузки файлов и сервис-воркеры
- **Реализовано в базе**: Переменная `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` запрещает скачивание сторонних версий браузеров в рантайме.
- **Требования к сервисам-потребителям**: Потребители настраивают контексты Playwright с параметрами `serviceWorkers: 'block'`, `--disable-features=ServiceWorker`, `acceptDownloads: false` и обработчиком `page.on('popup', p => p.close())`.
- **Пробел / Follow-up**: Полноценный `readOnlyRootFilesystem: true` не может быть включен в контейнере без монтирования `emptyDir` томов, так как сессионные каталоги `/tmp/coreai-sessions`, `/tmp/coreai-tool-markers` и `/app/.jmix/` требуют записи.

### 5. Keep-Alive и переиспользование сетевых соединений
- **Реализовано в базе**: Отсутствуют разделяемые пулы соединений на уровне ОС.
- **Требования к сервисам-потребителям**: HTTP-клиенты потребителей (`addon-limiter`, `addon-browser`) изолируют TCP-пулы per-host без передачи сессионных заголовков при cross-origin редиректах.
- **Пробел / Follow-up**: Реализовано в `addon-limiter`.

### 6. Изоляция Origin
- **Реализовано в базе**: Ничего (базовый образ не навязывает веб-сервер и домен).
- **Требования к сервисам-потребителям**: Запрещен рендеринг внешнего HTML через `<iframe>` с `SAMEORIGIN`. Отображение внешних веб-страниц в UI Личного Кабинета выполняется исключительно через графические снимки (PNG/WebP canvas stream) либо на изолированном домене `*.thedevs-preview.ru` с атрибутом `sandbox="allow-scripts"` (без `allow-same-origin`). Задача `TD-2205`.
- **Пробел / Follow-up**: Соответствует стандарту `thedevslk:LkUiPreviewRenderService`.

### 7. Разграничение сервисных ролей и сессий пользователей
- **Реализовано в базе**: Все процессы выполняются под пользователем `appuser (1000:1000)`. Каталоги сессий изолированы по путям `/tmp/coreai-sessions`.
- **Требования к сервисам-потребителям**: Каждая браузерная задача исполняется в эфемерном контексте `browser.newContext()` с гарантированным вызовом `context.close()`. Хранилища cookie и LocalStorage сбрасываются после каждой операции.
- **Пробел / Follow-up**: Контролируется кодовой базой `addon-browser`.

### 8. Бюджет памяти пода
- **Реализовано в базе**: Базовые образы не содержат прибитых флагов памяти JVM (отсутствует `JAVA_TOOL_OPTIONS`), предотвращая конфликт кучи JVM с процессами браузера.
- **Фактические лимиты подов (проверено в кластере)**:
  - `flparser`: `limits.memory: 6Gi` (куча JVM `-XX:MaxRAMPercentage=50` = 3.0 GiB, 3.0 GiB для ОС, Node.js и Firefox на 1–2 сессии).
  - `thedevslk`: `limits.memory: 10Gi` (куча JVM ~4–6 GiB, остаток для Playwright Chromium и сессий Claude CLI).
  - `shield`: `limits.memory: 20Gi` (куча JVM `-XX:MaxRAMPercentage=85` = 17.0 GiB, 3.0 GiB для CoreAI CLI).
- **Пробел / Follow-up**: Потребители браузера обязаны лимитировать одновременные браузерные вкладки (не более 1–2 на под). Задачи `TD-2205`, `TD-2208`.

# Критерии готовности

1. Оператором выполнены предварительные условия bootstrap: репозиторий `THEDEVS-RU/base-images` создан, дефолтная ветка `dev`, назначен раннер `master`, выданы секреты `BUILDER_CONFIG_K8S`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`.
2. В репозитории `THEDEVS-RU/base-images` созданы 3 Dockerfile: `docker/thedevs-core/Dockerfile`, `docker/thedevs-ai/Dockerfile`, `docker/thedevs-browser/Dockerfile`.
3. Создан и применен манифест `k8s/pvc-cache.yaml`, в результате чего в namespace `dev` успешно создан PVC `kaniko-cache-thedevs-base` объемом 10Gi.
4. Создан CI-пайплайн `.github/workflows/build-base-images.yml` с правами `contents: read`, настройкой K8s из `secrets.BUILDER_CONFIG_K8S`, расчетом `DATE_TAG` в UTC, поддержкой cron на ветке `dev`, ручным запуском с каскадной пересборкой зависимых слоев и сборкой на self-hosted раннере `master`.
5. Пайплайн успешно собирает и публикует 3 слоя в `registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-{core,ai,browser}` с тегами `dev` и `dev-YYYYMMDD-<run>`.
6. Выполнены автоматизированные smoke-проверки в сборочном пайплайне:
   - `thedevs-core`: `java -version`, `pg_dump --version` (клиент v18, совместим с сервером 16.10), `git --version`, `jq --version`, `curl --version`, `/usr/bin/tini --version`.
   - `thedevs-ai`: `node --version` (v22), `npm --version`, `claude --version`, `gh --version`, `agy --version`, `codex --version`. Gemini CLI отсутствует.
   - `thedevs-browser`: успешная проверка `test -d "$(npm root -g)/playwright"`, запуск и закрытие headless Chromium и Firefox через `node -e "const { chromium, firefox } = require('playwright'); ..."` с Playwright 1.58.0.
7. Создан пайплайн продвижения `.github/workflows/promote-base-images.yml`, перетегирующий проверенный digest в `master` и `latest` через под `crane copy --insecure`, а также поддерживающий откат к предыдущему тегу.
8. Выполнен первичный запуск воркфлоу продвижения `promote-base-images.yml` для формирования базовых тегов `latest` и `master` в реестре до запуска задач перевода проектов.
9. Созданы и привязаны к `TD-2201` все дочерние задачи перевода проектов (`TD-2204`–`TD-2208`) и сопутствующие задачи безопасности/зависимостей (`TD-2209`–`TD-2212`).
10. Спецификация проходит валидатор формата `validate-spec-format.sh specs/2026-10-17-thedevs-base-images-lego-stack.md` с кодом 0 и закоммичена в ветку `task/TD-2201` в репозитории `THEDEVS-RU/.github`.

# Не трогать

1. Не пересобирать образы в ветке `master` с нуля — продвижение в `master` и `latest` выполняется строго перетегированием проверенного digest ветки `dev` через `crane copy --insecure`.
2. Не публиковать тег `latest` из сборок ветки `dev` (тег `latest` выставляется исключительно через пайплайн продвижения).
3. Не включать дефолтные флаги памяти JVM в `JAVA_TOOL_OPTIONS` базовых образов (настройки памяти остаются исключительной зоной ответственности env-переменных деплойментов).
4. Не коммитить и не пушить изменения напрямую в ветки `dev`, `main`, `master`.
5. Не изменять лимит памяти Kaniko `limits.memory: 8Gi` в сборочных подах (инвариант защиты ноды `.248`).
6. Не производить непосредственную модификацию исходного кода микросервисов (`shield-3`, `thedevslk`, `mobitrack-2`, `TemplateProject`, `marta`, `flparser`) в рамках задачи `TD-2201` — перевод выполняется строго отдельными дочерними задачами реализации `TD-2204`–`TD-2208`.
