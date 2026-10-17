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
  1. `actions/kaniko-build` из `THEDEVS-RU/.github@dev` с поддержкой входных параметров `cpu_limit`, `extra_tags` и `build_args`, реализованных в спецификации `2026-10-17-kaniko-build-cpu-limit-and-build-args` (TD-2197).
  2. K8s Secret `thedevs-registry-secret` (тип `kubernetes.io/dockerconfigjson`) в namespace `dev` для авторизации в корпоративном реестре `registry.thedevs.ru`.
  3. Согласованное решение оператора (раунд 1 ревью TD-2197 от 2026-10-17 22:59) о разделении базового стека на 3 слоя (`thedevs-core` -> `thedevs-ai` -> `thedevs-browser`) и выносе сборочного пайплайна в выделенный приватный репозиторий `THEDEVS-RU/base-images`.
- **Produces**:
  1. Приватный репозиторий `THEDEVS-RU/base-images` со структурой Dockerfile для 3 слоев Lego-стека и манифестом K8s PVC кэша `k8s/pvc-cache.yaml`.
  2. CI-пайплайн `.github/workflows/build-base-images.yml` на self-hosted раннере `master` с регулярной сборкой (cron по воскресеньям в 03:00 UTC), ручным запуском (`workflow_dispatch`), вычислением тегов в resolve-джобе, каскадной пересборкой зависимых слоев и тегированием (`latest`, `<branch>`, `<branch>-YYYYMMDD-<run>`).
  3. Опубликованные базовые Docker-образы в `registry.thedevs.ru/thedevs-ru/thedevs-{core,ai,browser}` (внутреннее имя `registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-{core,ai,browser}`).
  4. Контракт перевода проектов платформы (`shield-3`, `thedevslk`, `mobitrack-2`, `TemplateProject`, `marta`, `flparser`) на базовые слои через дочерние задачи.

# Контекст

В микросервисах платформы TheDevs (`thedevslk`, `shield-3`, `mobitrack-2`, `marta`, `flparser`, `TemplateProject`) в каждом `Dockerfile` дублируется ручная установка системных пакетов, JRE, Node.js, утилит командной строки CoreAI и браузеров. Это приводит к разрастанию времени сборки (до 4–8 минут), дублированию уязвимостей, расхождению версий и повторной загрузке сотен мегабайт внешних зависимостей.

Фактическое состояние экосистемы (проверяемые факты):
1. **Версии PostgreSQL серверов**:
   - `postgres-service.default.svc.cluster.local:5432` отдаёт `PostgreSQL 16.10 (Debian 16.10-1.pgdg13+1)`.
   - `addon-core@dev:core/src/main/java/ru/thedevs/backup/target/PgDumpBackupTarget.java:94-99` требует строго `clientMajorVersion >= serverMajorVersion`. Фиксация `ARG PG_CLIENT_MAJOR=17` в `thedevs-core` обеспечивает `17 >= 16`, гарантируя совместимость с текущими серверами кластера и будущими обновлениями до PostgreSQL 17.
2. **Версии Playwright**:
   - `THEDEVS-RU/addon-browser@dev:gradle/libs.versions.toml:4` фиксирует `playwright = "1.58.0"`.
   - `THEDEVS-RU/marta@dev:Dockerfile.base:48` устанавливает `playwright@1.58.0`.
   - `THEDEVS-RU/thedevslk@dev:Dockerfile:185` содержал устаревший комментарий про 1.52.0. Требуется единый стандарт `1.58.0` с установкой как Chromium, так и Firefox (`--with-deps`), так как парсеры `flparser` активно используют Firefox (`FlRuParserActionHandler`, `FreelanceRuParserActionHandler`, `KworkParserActionHandler`).
3. **Память и лимиты подов**:
   - `kubectl get deployment -n dev`: `flparser` (limits.memory 6Gi), `thedevslk` (limits.memory 10Gi), `shield` (limits.memory 20Gi), `mobitrack` (limits.memory 3Gi).
   - Включение дефолтных флагов `JAVA_TOOL_OPTIONS` (например `-XX:MaxRAMPercentage=80`) в базовом образе опасно: рядом с Chromium/Firefox и Node.js процессами 80% памяти под кучу JVM приводит к OOMKilled (у `flparser` лимит 6Gi). Базовый образ обязан быть свободным от флагов памяти JVM; настройки памяти передаются исключительно через переменные окружения деплойментов.
4. **Сетевые политики и безопасность**:
   - `kubectl get networkpolicy -n dev` возвращает `No resources found in dev namespace.` Утверждения о наличии защитных NetworkPolicy в dev являются ложными. Требуется честная модель угроз.
5. **Инфраструктура Kaniko**:
   - `kubectl get pvc -n dev` подтверждает отсутствие тома `kaniko-cache-thedevs-base`. Сборка зависает в `Pending` до таймаута без явного создания PVC.

# Что сделать

## 1. Структура репозитория THEDEVS-RU/base-images

Создать в репозитории `THEDEVS-RU/base-images`:
- `docker/thedevs-core/Dockerfile`
- `docker/thedevs-ai/Dockerfile`
- `docker/thedevs-browser/Dockerfile`
- `k8s/pvc-cache.yaml`
- `.github/workflows/build-base-images.yml`
- `README.md`

## 2. Слой thedevs-core (`docker/thedevs-core/Dockerfile`)

Базовый образ платформы для серверных Java-приложений без AI-раннеров (`mobitrack-2`, `TemplateProject`):
- База: `eclipse-temurin:25-jre-noble` (Ubuntu 24.04 LTS).
- Удаление системного пользователя `ubuntu` (UID 1000) и создание непривилегированного пользователя:
  `groupadd -g 1000 appuser && useradd -u 1000 -g appuser -m -s /bin/bash appuser`.
- Переключение зеркал на `ru.archive.ubuntu.com` для deb822 (`/etc/apt/sources.list.d/ubuntu.sources`) и классического формата.
- Системный стек: `ca-certificates`, `curl`, `git`, `jq`, `tini`, `locales` (`ENV LANG=C.UTF-8`, `ENV LC_ALL=C.UTF-8`), `fontconfig`, `fonts-dejavu-core`, `fonts-liberation`.
- PostgreSQL клиент: официальный репозиторий PGDG `noble-pgdg` с установкой ключа в `/etc/apt/keyrings/postgresql.gpg` (без устаревшего apt-key) и фиксированным аргументом `ARG PG_CLIENT_MAJOR=17`.
- Проверка версий на этапе сборки:
  `git --version && jq --version && curl --version && /usr/bin/tini --version && pg_dump --version | grep -E " ${PG_CLIENT_MAJOR}\."`
- `WORKDIR /app`, `chown -R 1000:1000 /app`.
- Отсутствие дефолтных флагов кучи JVM в `JAVA_TOOL_OPTIONS`.
- `ENTRYPOINT ["/usr/bin/tini", "--"]`.
- `ARG CACHEBUST=0` для управляемой инвалидации кэша слоев при обновлениях безопасности.

## 3. Слой thedevs-ai (`docker/thedevs-ai/Dockerfile`)

Слой на базе `thedevs-core` для сервисов с агентами CoreAI (`shield-3`):
- `ARG BASE_IMAGE=registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-core:latest`
- `FROM ${BASE_IMAGE}`
- Node.js 22 LTS: установка официального репозитория NodeSource через signed-by связку ключей `/etc/apt/keyrings/nodesource.gpg` (без использования небезопасного `curl | bash`).
- GitHub CLI: установка `gh` через официальный репозиторий с `/etc/apt/keyrings/githubcli-archive-keyring.gpg`.
- Claude Code CLI: `npm install -g @anthropic-ai/claude-code@${CLAUDE_CLI_VERSION}` с аргументом `ARG CLAUDE_CLI_VERSION=latest`, передаваемым из CI.
- Codex CLI: установка `ARG CODEX_CLI_VERSION=0.144.6` (`npm install -g @openai/codex@${CODEX_CLI_VERSION}`).
- Google Antigravity CLI (`agy`): скачивание бинарного релиза с контролем целостности через `sha512sum`:
  `ARG AGY_CLI_URL=https://storage.googleapis.com/antigravity-public/antigravity-cli/1.2.3-5101874907578368/linux-x64/cli_linux_x64.tar.gz`
  `ARG AGY_CLI_SHA512=ec74dc5ce20e64623a4d68e73a8957e468c026bdb3d07b15c5291490323133970c735d985af839eab057b52b1bfd1b2e91ff49abeebef032ffae6dded8e2a763`
  `ENV AGY_CLI_DISABLE_AUTO_UPDATE=true`
- Gemini CLI: исключен (закрыт Google 18.06.2026).
- Каталоги сессий CoreAI с правами `1000:1000`:
  `/app/.jmix/claude-home`, `/tmp/coreai-sessions`, `/tmp/coreai-tool-markers`.
- ENTRYPOINT сохраняет `/usr/bin/tini --` для корректного сбора зомби-процессов Claude CLI.

## 4. Слой thedevs-browser (`docker/thedevs-browser/Dockerfile`)

Слой на базе `thedevs-ai` для UI-рендеринга и скрапинга (`thedevslk`, `marta`, `flparser`):
- `ARG BASE_IMAGE=registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-ai:latest`
- `FROM ${BASE_IMAGE}`
- Playwright: версия выровнена по `com.microsoft.playwright:playwright:1.58.0` (`ARG PLAYWRIGHT_VERSION=1.58.0`).
- Установка браузеров Chromium и Firefox с системными библиотеками:
  `ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright`
  `ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`
  `RUN npx --yes playwright@${PLAYWRIGHT_VERSION} install --with-deps chromium firefox`
- Права доступа: Firefox в процессе работы создает lock-файл в каталоге установки. Выполняется обязательная настройка прав:
  `RUN chown -R 1000:1000 ${PLAYWRIGHT_BROWSERS_PATH} && chmod -R 775 ${PLAYWRIGHT_BROWSERS_PATH}`.
- Smoke-проверка на этапе сборки образа:
  `node -e "const { chromium, firefox } = require('playwright'); (async () => { const b1 = await chromium.launch(); await b1.close(); const b2 = await firefox.launch(); await b2.close(); console.log('Chromium & Firefox launch OK'); })()"`

## 5. Инфраструктурный манифест PVC (`k8s/pvc-cache.yaml`)

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
      storage: 20Gi
```

## 6. Пайплайн сборки (`.github/workflows/build-base-images.yml`)

1. **Триггеры и concurrency**:
   - `workflow_dispatch` с выбором слоя: `layer` (`all`, `core`, `ai`, `browser`).
   - `schedule`: cron `0 3 * * 0` (еженедельно в воскресенье в 03:00 UTC).
   - `push`: ветки `dev` и `master` (пути `docker/**`, `k8s/**`, `.github/workflows/build-base-images.yml`).
   - `concurrency: { group: base-images-${{ github.ref }}, cancel-in-progress: false }`.
2. **Секреты и раннер**:
   - `runs-on: master` (self-hosted раннер с доступом к K8s кластеру).
   - Необходимые org-секреты: `BUILDER_CONFIG_K8S`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `GH_PAT_SHIELD`.
   - В K8s используется существующий секрет реестра `thedevs-registry-secret` (namespace `dev`).
3. **Resolve job (`resolve`)**:
   - Выполняется на `runs-on: master`.
   - Вычисляет теги один раз в UTC:
     `DATE_TAG=$(date -u +'%Y%m%d')`
     `RUN_TAG="${{ github.ref_name }}-${DATE_TAG}-${{ github.run_number }}"`
   - Разрешает актуальную версию `@anthropic-ai/claude-code` через `npm view @anthropic-ai/claude-code version`.
   - Формирует список `extra_tags`:
     - На ветке `dev`: `dev`, `<branch>-YYYYMMDD-<run>`.
     - На ветке `master`: `latest`, `master`, `master-YYYYMMDD-<run>`.
   - Определяет флаги запуска слоев при `workflow_dispatch` с каскадным включением:
     - `core`: запускает `core` -> `ai` -> `browser`.
     - `ai`: запускает `ai` -> `browser`.
     - `browser`: запускает `browser`.
4. **Шаг инициализации инфраструктуры**:
   - Джоба `init-infra` применяет `kubectl apply -f k8s/pvc-cache.yaml --request-timeout=30s` для гарантии наличия тома `kaniko-cache-thedevs-base`.
5. **Сборочные джобы (`build-core`, `build-ai`, `build-browser`)**:
   - Последовательное выполнение: `build-core` -> `build-ai` -> `build-browser`.
   - `build-ai` строится строго `FROM .../thedevs-core:<RUN_TAG>` текущего прогона через `build_args: BASE_IMAGE=.../thedevs-core:<RUN_TAG>`.
   - `build-browser` строится строго `FROM .../thedevs-ai:<RUN_TAG>` текущего прогона через `build_args: BASE_IMAGE=.../thedevs-ai:<RUN_TAG>`.
   - Использование `actions/kaniko-build` со всеми обязательными входами:
     `namespace: dev`, `git_token: ${{ secrets.GH_PAT_SHIELD }}`, `dockerhub_username`, `dockerhub_token`, `cache_pvc: kaniko-cache-thedevs-base`, `cpu_limit: 16000m`, `build_timeout: 7200`.
6. **Откат и продвижение**:
   - Тег `latest` публикуется исключительно при сборках ветки `master`. Сборки `dev` не перезаписывают `latest`.
   - Откат выполняется либо перетегированием проверенного тега `<branch>-YYYYMMDD-<run>` в `latest`, либо явной передачей `BASE_TAG` в деплойментах микросервисов.

## 7. Контракты перевода проектов (дочерние задачи)

1. **`THEDEVS-RU/shield-3` -> `thedevs-ai`** (Задача `TD-2203`):
   - Замена `FROM eclipse-temurin:25-jre-noble` на `FROM registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-ai:${BASE_TAG:-latest}`.
   - Удаление дублирующихся установок Node.js, `gh`, `claude-code`, `agy`, `postgresql-client`.
   - Сохранение контрактов: `find . -name "*-plain.jar" -delete && mv *.jar app.jar && chown 1000:1000 app.jar`.
   - Флаг `-XX:MaxRAMPercentage=85` переносится в `JAVA_TOOL_OPTIONS` манифеста деплоймента.
   - `ENTRYPOINT ["/usr/bin/tini", "--", "java", "-jar", "app.jar"]`.
2. **`THEDEVS-RU/thedevslk` -> `thedevs-browser`** (Задача `TD-2204`):
   - Замена ручной сборки рантайма на `FROM registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-browser:${BASE_TAG:-latest}`.
   - Сохранение `scripts/generate-kubeconfig.sh`, `scripts/entrypoint.sh` и `kubectl`.
   - Сохранение `ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]`.
   - Использование запеченных шрифтов `fonts-liberation` и `fonts-dejavu-core` для отчетов `BAL_INVOICE`.
3. **`THEDEVS-RU/mobitrack-2` -> `thedevs-core`** (Задача `TD-2205`):
   - Замена на `FROM registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-core:${BASE_TAG:-latest}`.
   - Сохранение импорта банковских сертификатов Минцифры в cacerts (`COPY docker/certs/*.pem /tmp/certs/` и `keytool -importcert`).
   - Сохранение `find . -name "*-plain.jar" -delete && mv *.jar app.jar`.
4. **`THEDEVS-RU/TemplateProject` -> `thedevs-core`** (Задача `TD-2206`):
   - Замена на `FROM registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-core:${BASE_TAG:-latest}`.
   - Чистый эталон для микросервисов платформы без CoreAI.
5. **`THEDEVS-RU/marta` & `THEDEVS-RU/flparser` -> `thedevs-browser`** (Задача `TD-2207`):
   - Замена `marta-base` на `FROM registry.container-registry.svc.cluster.local:5000/thedevs-ru/thedevs-browser:${BASE_TAG:-latest}`.
   - Удаление устаревших артефактов в `marta`: `Dockerfile.base`, `.github/workflows/build-base.yml`, образ `marta-base`.
   - Сохранение каталогов `/app/.jmix/heapdumps` и `/app/.jmix/gc-logs`, `USER 1000`.

## Затрагиваемые файлы

1. `docker/thedevs-core/Dockerfile`
2. `docker/thedevs-ai/Dockerfile`
3. `docker/thedevs-browser/Dockerfile`
4. `k8s/pvc-cache.yaml`
5. `.github/workflows/build-base-images.yml`
6. `README.md`

# Что уже есть

1. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml` с поддержкой `cpu_limit`, `extra_tags`, `build_args` (TD-2197).
2. K8s Secret `thedevs-registry-secret` в namespace `dev` (тип `kubernetes.io/dockerconfigjson`, возраст 18d).
3. Сборочный узел `.248` с 24 потоками AMD Ryzen 9 7900X под управлением Kubernetes.
4. Внутренний реестр кластера `registry.container-registry.svc.cluster.local:5000/thedevs-ru/` и внешний шлюз `registry.thedevs.ru`.
5. Кластерная база данных `PostgreSQL 16.10` на `postgres-service.default.svc.cluster.local:5432`.
6. Библиотека `ru.thedevs:browser-starter` в `addon-browser@dev:gradle/libs.versions.toml:4` на базе `com.microsoft.playwright:playwright:1.58.0`.

# Модель угроз

Включение инструментов выполнения кода, CLI-утилит и headless-браузеров (Chromium, Firefox) в слои `thedevs-ai` и `thedevs-browser` требует строгого анализа рисков работы с внешним контентом per `security-external-content.md`:

### 1. SSRF (Server-Side Request Forgery)
- **Реализовано в базе**: В базовые образы не запекаются пароли, статические API-ключи или токены доступа к сервисам кластера.
- **Требования к сервисам-потребителям**: Потребители (`flparser`, `marta`, `thedevslk`) обязаны валидировать IP-адрес назначения строго в момент установки TCP Connect (кастомный `DnsResolver` / socket connect hook) с блокировкой приватных сетей RFC 1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), Loopback (`127.0.0.0/8`), Link-Local (`169.254.0.0/16`), Cloud Metadata (`169.254.169.254`, `metadata.google.internal`) и имен K8s (`*.svc.cluster.local`, `kubernetes.default`). Разрешены строго схемы `http://` и `https://`; схемы `file://`, `chrome://`, `data:` запрещены.
- **Пробел / Follow-up**: Централизованный SSRF-фильтр в `addon-browser` оформляется задачей `TD-2208`.

### 2. Обход loopback в Chromium (`<-loopback>`)
- **Реализовано в базе**: Базовый образ не навязывает небезопасных дефолтных флагов Chromium.
- **Требования к сервисам-потребителям**: Сервисы автоматизации браузера обязаны передавать флаг `--proxy-bypass-list=<-loopback>` при старте Chromium для предотвращения скрытого обхода прокси-фильтра при обращении к `localhost`. Внутренние эндпоинты (`/mcp`, Spring Actuator) защищаются обязательной Bearer-аутентификацией.
- **Пробел / Follow-up**: Контролируется тестами в задаче перевода `TD-2204`.

### 3. Утечки через WebRTC и UDP
- **Реализовано в базе**: В базовый образ запекается скрипт-обертка запуска браузера с параметром `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`.
- **Требования к сервисам-потребителям**: Запуск Chromium с подавлением непроксированного UDP-трафика.
- **Пробел / Follow-up**: В namespace `dev` политики `NetworkPolicy` в настоящий момент отсутствуют (`kubectl get networkpolicy -n dev` -> `No resources found`). Блокировка исходящего UDP на уровне кластера выделена в отдельную инфраструктурную задачу `TD-2202`.

### 4. Попапы, загрузки файлов и сервис-воркеры
- **Реализовано в базе**: Переменная `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` запрещает скачивание сторонних версий браузеров в рантайме.
- **Требования к сервисам-потребителям**: Потребители настраивают контексты Playwright с параметрами `serviceWorkers: 'block'`, `--disable-features=ServiceWorker`, `acceptDownloads: false` и обработчиком `page.on('popup', p => p.close())`.
- **Пробел / Follow-up**: Полноценный `readOnlyRootFilesystem: true` не может быть включен в контейнере без монтирования `emptyDir` томов, так как сессионные каталоги `/tmp/coreai-sessions`, `/tmp/coreai-tool-markers`, `/app/.jmix/` и lock-файлы Firefox в `/opt/ms-playwright` требуют записи.

### 5. Keep-Alive и переиспользование сетевых соединений
- **Реализовано в базе**: Отсутствуют разделяемые пулы соединений на уровне ОС.
- **Требования к сервисам-потребителям**: HTTP-клиенты потребителей (`addon-limiter`, `addon-browser`) изолируют TCP-пулы per-host без передачи сессионных заголовков при cross-origin редиректах.
- **Пробел / Follow-up**: Реализовано в `addon-limiter`.

### 6. Изоляция Origin
- **Реализовано в базе**: Исключено выполнение пользовательского JavaScript на домене приложения.
- **Требования к сервисам-потребителям**: Запрещен рендеринг внешнего HTML через `<iframe>` с `SAMEORIGIN`. Отображение внешних веб-страниц в UI Личного Кабинета выполняется исключительно через графические снимки (PNG/WebP canvas stream) либо на изолированном домене `*.thedevs-preview.ru` с атрибутом `sandbox="allow-scripts"` (без `allow-same-origin`).
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
- **Пробел / Follow-up**: Потребители браузера обязаны лимитировать одновременные браузерные вкладки (не более 1–2 на под).

# Критерии готовности

1. Создан приватный репозиторий `THEDEVS-RU/base-images` с ветками `dev` и `master`, подключенный к self-hosted раннеру `master` и настроенными секретами (`BUILDER_CONFIG_K8S`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `GH_PAT_SHIELD`).
2. В репозитории `THEDEVS-RU/base-images` созданы и синтаксически валидны 3 Dockerfile: `docker/thedevs-core/Dockerfile`, `docker/thedevs-ai/Dockerfile`, `docker/thedevs-browser/Dockerfile`.
3. Создан и применен манифест `k8s/pvc-cache.yaml`, в результате чего в namespace `dev` успешно создан и примонтирован PVC `kaniko-cache-thedevs-base`.
4. Создан CI-пайплайн `.github/workflows/build-base-images.yml` с поддержкой `concurrency`, расчетом `DATE_TAG` в resolve-джобе, поддержкой ручного запуска с каскадной пересборкой зависимых слоев и сборкой на self-hosted раннере `master`.
5. Пайплайн успешно собирает и публикует 3 слоя в `registry.thedevs.ru/thedevs-ru/thedevs-{core,ai,browser}` с тегами:
   - Ветка `dev`: `dev`, `dev-YYYYMMDD-<run>`.
   - Ветка `master`: `latest`, `master`, `master-YYYYMMDD-<run>`.
6. Выполнены автоматизированные smoke-проверки в сборочном пайплайне:
   - `thedevs-core`: `java -version`, `pg_dump --version` (клиент 17.x, сервер >= 16.10), `git --version`, `jq --version`, `curl --version`, `/usr/bin/tini --version`.
   - `thedevs-ai`: `node --version`, `npm --version`, `claude --version`, `gh --version`, `agy --version`, `codex --version`.
   - `thedevs-browser`: успешный запуск и завершение headless Chromium и Firefox через Playwright 1.58.0.
7. Проведен сравнительный замер длительности сборки микросервисов (`thedevslk`, `shield-3`, `mobitrack-2`) до и после перевода на базовые образы с фиксацией результатов в карточке задачи.
8. Спецификация проходит валидатор формата `validate-spec-format.sh specs/2026-10-17-thedevs-base-images-lego-stack.md` с кодом 0 и закоммичена в ветку `task/TD-2201` в репозитории `THEDEVS-RU/.github`.

# Не трогать

1. Не публиковать тег `latest` из сборок ветки `dev` (тег `latest` формируется строго из ветки `master`).
2. Не включать дефолтные флаги памяти JVM в `JAVA_TOOL_OPTIONS` базовых образов (настройки памяти остаются исключительной зоной ответственности env-переменных деплойментов).
3. Не коммитить и не пушить изменения напрямую в ветки `dev`, `main`, `master`.
4. Не изменять лимит памяти Kaniko `limits.memory: 8Gi` в сборочных подах (инвариант защиты ноды `.248`).
5. Не производить непосредственную модификацию исходного кода микросервисов (`shield-3`, `thedevslk`, `mobitrack-2`, `TemplateProject`, `marta`, `flparser`) в рамках спецификации `TD-2201` — перевод сервисов выполняется строго отдельными дочерними задачами реализации `TD-2203`–`TD-2207`.
