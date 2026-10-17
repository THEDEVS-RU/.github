id: 2026-10-17-modular-lego-base-images-and-kaniko-cpu-unthrottle
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: architectural
stage: detailed
external_content: true
impl_model: opus
impl_effort: high

# Контекст

Текущий CI-пайплайн сборки проектов экосистемы TheDevs страдает от двух взаимосвязанных узких мест, увеличивающих время сборки до 7–15 минут:
1. **Жесткий троттлинг CPU в Kaniko:**
   В сборочном экшене `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:284-288` зафиксированы ресурсы:
   `requests.cpu: "1000m"`, `limits.cpu: "3000m"`, `limits.memory: "8Gi"`.
   Сборочный узел `.248` оснащён процессором AMD Ryzen 9 7900X (12 ядер / 24 потока). Ограничение в 3000m (3 ядра) искусственно сдерживает многопоточную компиляцию Gradle, обработку TypeScript/Vite в Vaadin, работу Node.js и сжатие слоев pigz в Kaniko. При этом лимит памяти `limits.memory: 8Gi` является критическим инвариантом защиты ноды `.248` от OOM.
2. **Дублирование установки системных пакетов и рантаймов (отсутствие Lego-базы):**
   Каждый микросервис (`shield-3`, `thedevslk`, `mobitrack-2`, `marta`, `flparser`, `TemplateProject`) в своем `Dockerfile` «с нуля» поверх базового OS-образа выполняет длительные шаги `apt-get update`, установку Node.js 22 LTS, `ca-certificates`, `curl`, `git`, `jq`, утилит PostgreSQL, шрифтов Jmix/Vaadin, Claude Code CLI, Google Antigravity CLI (`agy`) и браузера Chromium:
   - `THEDEVS-RU/shield-3@dev:Dockerfile:19-45`: ставит поверх `eclipse-temurin:25-jre-noble` Node.js 22, git, jq, `postgresql-client-16`, Claude CLI, `agy`;
   - `THEDEVS-RU/mobitrack-2@dev:Dockerfile:40-62`: ставит поверх `eclipse-temurin:25-jre-noble` fontconfig, fonts-dejavu-core, git, jq, `postgresql-client-16`;
   - `THEDEVS-RU/thedevslk@dev:Dockerfile:49-165`: поверх `debian:bookworm-slim` ставит `postgresql-client-16`, gh, kubectl, Claude, Codex, Gemini, agy, Playwright Chromium;
   - `THEDEVS-RU/marta@dev:Dockerfile:18` и `THEDEVS-RU/flparser@dev:Dockerfile:18`: зависят от самописного `marta-base:latest`, собираемого в локальном реестре `registry.container-registry.svc.cluster.local:5000/thedevs-ru/marta-base:latest` отдельным воркфлоу `marta/.github/workflows/build-base.yml`.
   Кроме того, во всех проектах утилиты PostgreSQL жестко привязаны к устаревшей версии `postgresql-client-16`, в то время как СУБД обновляются до PostgreSQL 17/18.

Цель задачи — снять CPU-троттлинг Kaniko и создать модульную иерархию базовых образов (Lego-стек) в `registry.thedevs.ru`, сократив сборку микросервисов до < 1 минуты.

# Что сделать

## 1. Параметризация CPU в actions/kaniko-build/action.yml

В файле `actions/kaniko-build/action.yml` репозитория `THEDEVS-RU/.github`:
1. Добавить входной параметр `cpu_limit` со значением по умолчанию `'16000m'`:
   ```yaml
     cpu_limit:
       description: 'CPU limit for Kaniko pod container (e.g. 16000m). Set to empty string, 0, or none to remove CPU limit'
       required: false
       default: '16000m'
     extra_tags:
       description: 'Comma or space separated extra tags for target image'
       required: false
       default: ''
   ```
2. Передать `INPUT_CPU_LIMIT: ${{ inputs.cpu_limit }}` и `INPUT_EXTRA_TAGS: ${{ inputs.extra_tags }}` в секцию `env` шага `Run Kaniko Build`.
3. В bash-скрипте формировать секцию ресурсов пода динамически:
   - Лимит памяти `limits.memory: "8Gi"` и запросы `requests.memory: "2Gi"`, `requests.cpu: "1000m"` сохраняются неизменными.
   - Если переменная `CPU_LIMIT` задана и не равна `'0'`, `''`, `'none'`, в манифест контейнера Kaniko выводится строка `cpu: "${CPU_LIMIT}"`.
   - Если указаны `extra_tags`, для каждого тега добавляется аргумент `--destination=${IMAGE}:${EXTRA_TAG}`.

## 2. Модульная иерархия Lego-образов (директория docker/)

Создать в `THEDEVS-RU/.github` директорию `docker/` с 4 уровнями базовых образов:

### Уровень 1: docker/thedevs-core/Dockerfile (`registry.thedevs.ru/thedevs-core:latest`)
- **Базовый образ:** `eclipse-temurin:25-jre-noble` (Ubuntu 24.04 LTS Noble Numbat).
- **Зеркала APT:** Переключение на `ru.archive.ubuntu.com` для исключения сетевых таймаутов:
  `RUN find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i 's|archive\.ubuntu\.com|ru.archive.ubuntu.com|g; s|security\.ubuntu\.com|ru.archive.ubuntu.com|g' {} +`
- **Системные утилиты:** `ca-certificates`, `curl`, `jq`, `locales`, `gnupg`.
- **Локализация:** Генерация `en_US.UTF-8` и `ru_RU.UTF-8`, установка `LANG=C.UTF-8`, `LC_ALL=C.UTF-8`.
- **PostgreSQL Client:** Подключение официального репозитория PGDG (`noble-pgdg` с ключом `https://www.postgresql.org/media/keys/ACCC4CF8.asc`) и установка метапакета `postgresql-client` (актуальная версия 17/18, поддержка `pg_dump`/`pg_restore` без привязки к v16).
- **Пользователь и рабочая среда:** Удаление дефолтного пользователя `ubuntu` (UID 1000), создание группы и пользователя `appuser` (1000:1000) с домашней директорией `/home/appuser`, создание рабочей директории `/app` с владельцем `1000:1000`.
- **JVM контейнерные флаги:**
  `ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=80 -XX:+ExplicitGCInvokesConcurrent -XX:+UseG1GC -Xlog:gc+init=info,gc=info:stdout:time,level,tags"`

### Уровень 2: docker/thedevs-coreui/Dockerfile (`registry.thedevs.ru/thedevs-coreui:latest`)
- **Базовый образ:** `FROM registry.thedevs.ru/thedevs-core:latest`.
- **Node.js runtime:** Установка Node.js 22 LTS через официальный репозиторий NodeSource (`https://deb.nodesource.com/setup_22.x`).
- **Пакетные менеджеры:** Глобальная установка `pnpm` и `yarn` (`npm install -g pnpm yarn`).
- **UI & Reporting Fonts:** Установка `fontconfig` и `fonts-dejavu-core` с обновлением кэша шрифтов `fc-cache -f -v` (поддержка кириллицы в Jmix Reports, генерации PDF и фронтенд-сборки Vaadin/Vite).

### Уровень 3: docker/thedevs-ai/Dockerfile (`registry.thedevs.ru/thedevs-ai:latest`)
- **Базовый образ:** `FROM registry.thedevs.ru/thedevs-coreui:latest`.
- **Инструменты контроля версий:** Установка `git` и GitHub CLI (`gh`) через официальный репозиторий `cli.github.com/packages`.
- **Claude Code CLI:** Установка `@anthropic-ai/claude-code` глобально через npm с поддержкой сборки через `ARG CLAUDE_CLI_VERSION=latest` и созданием симлинка в `/usr/local/bin/claude`.
- **Google Antigravity CLI (agy):**
  Установка бинарного дистрибутива `agy` с обязательной верификацией по SHA512:
  `ARG AGY_CLI_URL=https://storage.googleapis.com/antigravity-public/antigravity-cli/1.2.3-5101874907578368/linux-x64/cli_linux_x64.tar.gz`
  `ARG AGY_CLI_SHA512=ec74dc5ce20e64623a4d68e73a8957e468c026bdb3d07b15c5291490323133970c735d985af839eab057b52b1bfd1b2e91ff49abeebef032ffae6dded8e2a763`
  `ENV AGY_CLI_DISABLE_AUTO_UPDATE=true`
  Установка бинарника в `/usr/local/bin/agy` с правами 0755 и валидацией `agy --version`.
- **Каталоги сессий CoreAI:**
  Создание каталогов `/app/.jmix/claude-home`, `/tmp/coreai-sessions`, `/tmp/coreai-tool-markers` с владельцем `1000:1000` и правами на запись.

### Уровень 4: docker/thedevs-browser/Dockerfile (`registry.thedevs.ru/thedevs-browser:latest`)
- **Базовый образ:** `FROM registry.thedevs.ru/thedevs-ai:latest`.
- **Зависимости Headless Chromium:**
  Установка системных библиотек Ubuntu Noble:
  `libnss3`, `libatk1.0-0`, `libatk-bridge2.0-0`, `libgbm1`, `libasound2t64`, `xvfb`, `libdrm2`, `libxcomposite1`, `libxdamage1`, `libxfixes3`, `libxrandr2`, `libpango-1.0-0`, `libcairo2`, `libcups2`.
- **Предварительно установленный Chromium:**
  `ARG PLAYWRIGHT_VERSION=1.52.0`
  `ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright`
  Выполнение `npx --yes playwright@${PLAYWRIGHT_VERSION} install --with-deps chromium` и установка владельца `chown -R 1000:1000 /opt/ms-playwright`. Браузер запекается в слой образа, исключая скачивание в рантайме.

## 3. CI-пайплайн сборки и обновления базовых образов

Создать воркфлоу `.github/workflows/build-base-images.yml` в `THEDEVS-RU/.github`:
- **Триггеры:**
  - `workflow_dispatch` (ручной запуск с выбором сборки всех или конкретного слоя);
  - `push: branches: [dev]` при изменениях в `docker/**` или `.github/workflows/build-base-images.yml`;
  - `schedule: cron: '0 3 * * 1'` (еженедельно по понедельникам в 03:00 UTC / 06:00 МСК для автоматического обновления upstream-патчей безопасности).
- **Исполнитель:** `runs-on: master`.
- **Схема сборки:** Четыре последовательные джобы:
  `build-core` -> `build-coreui` -> `build-ai` -> `build-browser`.
  Каждая джоба использует централизованный action `THEDEVS-RU/.github/actions/kaniko-build@dev` с:
  - `image: registry.thedevs.ru/thedevs-<core|coreui|ai|browser>`
  - `tag: latest`
  - `extra_tags: ${{ env.DATE_TAG }}` (где `DATE_TAG=$(date +%Y%m%d)-${{ github.run_number }}`)
  - `cpu_limit: '16000m'`
  - `cache_pvc: kaniko-cache-thedevs-base`
  - `dockerfile: docker/thedevs-<layer>/Dockerfile`

## 4. Контракт перевода проектов на Lego-базу

В микросервисах финальный этап Dockerfile заменяется на соответствующий базовый образ:
1. **shield-3:** `FROM registry.thedevs.ru/thedevs-ai:latest`.
   Удаляются: `RUN apt-get update && apt-get install ... nodejs`, `install-claude-cli.sh`, `install-agy-cli.sh`, `useradd appuser`.
   Остаётся только: `WORKDIR /app`, `COPY --from=builder /app/build/libs/*.jar ./`, `USER 1000`, `ENTRYPOINT ["java", "-jar", "app.jar"]`.
2. **thedevslk:** `FROM registry.thedevs.ru/thedevs-browser:latest`.
   Удаляются: установка bookworm пакетов, PGDG, Node.js, Claude CLI, agy, Playwright Chromium, копирование OpenJDK.
   Остаются: только kubectl, специфичные entrypoint скрипты и `app.jar`.
3. **mobitrack-2:** `FROM registry.thedevs.ru/thedevs-coreui:latest`.
   Удаляются: `apt-get` установка fontconfig, fonts-dejavu-core, git, jq, postgresql-client-16.
   Остаются: импорт банковских сертификатов Минцифры (`COPY docker/certs/*.pem`) и `app.jar`.
4. **marta & flparser:** `FROM registry.thedevs.ru/thedevs-browser:latest`.
   Удаляются: локальный `Dockerfile.base`, воркфлоу `build-base.yml` и зависимость от нестабильного `marta-base:latest`.
5. **TemplateProject:** `FROM registry.thedevs.ru/thedevs-coreui:latest`.
   Служит образцом для всех новых микросервисов платформы.

## Затрагиваемые файлы

1. `actions/kaniko-build/action.yml`
2. `docker/thedevs-core/Dockerfile`
3. `docker/thedevs-coreui/Dockerfile`
4. `docker/thedevs-ai/Dockerfile`
5. `docker/thedevs-browser/Dockerfile`
6. `.github/workflows/build-base-images.yml`

# Что уже есть

1. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml` — централизованный экшен сборки через Kaniko в K8s, содержащий механизм монтирования docker config, обработку ретраев и PVC-кэширование.
2. `THEDEVS-RU/shield-3@dev:scripts/install-agy-cli.sh` — проверенный алгоритм загрузки и валидации Google Antigravity CLI с контролем SHA512.
3. Корпоративный Docker Registry `registry.thedevs.ru` и внутренний сервис кластера `registry.container-registry.svc.cluster.local:5000`.
4. Сборочный узел `.248` с 24-поточным процессором AMD Ryzen 9 7900X под управлением Kubernetes.

# Модель угроз

Включение headless-браузера Chromium в состав базового образа `thedevs-browser` для скрапинга и UI-рендеринга (`marta`, `flparser`, `thedevslk`) требует соблюдения всех 8 категорий стандарта `security-external-content.md`:

1. **SSRF (Server-Side Request Forgery):**
   - Проверка целевых IP-адресов выполняется на этапе TCP Connect (через egress DNS resolver и NetworkPolicy).
   - Запрещены обращения к приватным сетям RFC 1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), Loopback (`127.0.0.0/8`), Link-Local (`169.254.0.0/16`), Cloud Metadata (`169.254.169.254`, `metadata.google.internal`), и внутренним K8s доменам (`*.svc.cluster.local`, `kubernetes.default`).
   - Разрешены строго схемы `http://` и `https://`; схемы `file://`, `chrome://`, `data:` запрещены.
2. **Обход loopback в Chromium (`<-loopback>`):**
   - Все запуски Chromium в сервисах-потребителях обязаны передавать флаг `--proxy-bypass-list=<-loopback>` для предотвращения неявного обхода прокси-фильтра при обращениях к `localhost` и `127.0.0.1`.
   - Внутренние служебные порты подов (`/mcp`, Spring Actuator) защищены обязательной Bearer-аутентификацией.
3. **Утечки через WebRTC и UDP:**
   - Исходящий UDP-трафик блокируется политикой Kubernetes `NetworkPolicy` на уровне namespace пода (разрешён только порт 53 UDP/TCP к CoreDNS).
   - Chromium запускается с параметром `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`.
4. **Попапы, загрузки файлов и сервис-воркеры:**
   - В контексте Playwright регистрируется автоматическое закрытие попапов: `page.on('popup', p => p.close())`.
   - Сервис-воркеры блокируются опцией `browser.newContext({ serviceWorkers: 'block' })` и флагом `--disable-features=ServiceWorker`.
   - Файловая система пода монтируется в режиме `readOnlyRootFilesystem: true`, скачивание файлов отключается опцией `acceptDownloads: false`.
5. **Keep-Alive и переиспользование сетевых соединений:**
   - TCP-пулы HTTP-клиентов изолируются per-host. Запрещено переиспользование соединений между разными внешними хостами и при cross-origin редиректах.
6. **Изоляция Origin:**
   - Запрещено отображение внешнего контента через `<iframe>` с заголовком `X-Frame-Options: SAMEORIGIN` на домене продукта.
   - UI-превью отображается исключительно через графические снимки (PNG/WebP canvas стрим) либо на выделенном cookieless домене `*.thedevs-preview.ru` с атрибутом `sandbox="allow-scripts"` (без `allow-same-origin`).
7. **Разграничение сервисных ролей и сессий пользователей:**
   - Все браузерные задачи парсинга и рендеринга выполняются в эфемерных контекстах (`browser.newContext()`) с обязательным `context.close()`. Кэш, cookies и хранилище не сохраняются между вызовами.
8. **Бюджет памяти пода:**
   - Потребление памяти Chromium ограничивается лимитом concurrent сессий (не более 1–2 сессий на под).
   - Бюджет памяти пода рассчитывается от лимита `limits.memory: 8Gi` с запасом не менее 40% (3.2 GiB) для JVM и Node.js процессов.

# Критерии готовности

1. В `actions/kaniko-build/action.yml` добавлен входной параметр `cpu_limit` (дефолт `16000m`) и `extra_tags`. Лимит `limits.memory: 8Gi` сохранён. При сборке под Kaniko создается с лимитом `cpu: 16000m`.
2. Созданы и синтаксически валидны 4 Dockerfile в `docker/thedevs-{core,coreui,ai,browser}/Dockerfile`.
3. Создан воркфлоу `.github/workflows/build-base-images.yml`, успешно валидируемый синтаксическим линтером GitHub Actions.
4. Воркфлоу настроен на публикацию образов в `registry.thedevs.ru/thedevs-<layer>` с двумя тегами: `latest` и `$(date +%Y%m%d)-${{ github.run_number }}`.
5. Спецификация проходит валидатор формата:
   `bash references/contracts/builder/tools/validate-spec-format.sh specs/2026-10-17-modular-lego-base-images-and-kaniko-cpu-unthrottle.md` с кодом возврата 0.
6. Спецификация закоммичена в ветку `task/TD-2197` репозитория `THEDEVS-RU/.github`.

# Не трогать

1. Не изменять лимит памяти `limits.memory: 8Gi` в `actions/kaniko-build/action.yml` (критический инвариант защиты ноды `.248`).
2. Не коммитить и не пушить изменения напрямую в ветки `dev`, `main`, `master`.
3. Не модифицировать исходные коды приложений (`shield-3`, `thedevslk`, `mobitrack-2`, `marta`, `flparser`) в рамках данного PR репозитория `THEDEVS-RU/.github` (их Dockerfile обновляются отдельными дочерними задачами реализации после публикации базовых образов в реестре).
4. Не удалять поддержку секретов `thedevs-registry-secret`, `docker_secret` и `registry_token` в `actions/kaniko-build/action.yml`.
