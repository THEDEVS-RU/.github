id: 2026-10-18-thedevs-ai-cli-paths-contract
product: thedevs-base-images
repo: THEDEVS-RU/base-images
branch: dev
depends_on: [2026-10-17-thedevs-base-images-lego-stack]
awaits_task: TD-2201
complexity: simple
stage: detailed
external_content: false
impl_model: sonnet
impl_effort: high

# Контракт

- **Consumes**:
  1. Базовая архитектура Lego-стека образов из `THEDEVS-RU/.github@task/TD-2201:specs/2026-10-17-thedevs-base-images-lego-stack.md` (задача TD-2201), определяющая слой 2 `thedevs-ai` (`docker/thedevs-ai/Dockerfile`) на базе `thedevs-core`.
  2. Контракт путей по умолчанию `addon-core-ai`:
     - `addon-core-ai@dev:coreai-starter/src/main/java/ru/thedevs/autoconfigure/coreai/CAIAutoConfiguration.java:105,122,138,176` (дефолтные пути `@Value("${ai.cli.path:/usr/local/bin/claude}")`, `@Value("${ai.codex.cli.path:/usr/local/bin/codex}")`, `@Value("${ai.antigravity.cli.path:/usr/local/bin/agy}")`);
     - `addon-core-ai@dev:coreai/src/main/java/ru/thedevs/coreai/entity/CoreAiSettings.java:32` (`@AppSettingsDefault("/usr/local/bin/claude")`);
     - `addon-core-ai@dev:coreai/src/main/java/ru/thedevs/coreai/provider/common/CoreAiCliDescriptor.java:18,23,28` (`defaultSystemPath` для `claude`, `codex`, `agy` = `/usr/local/bin/{claude,codex,agy}`);
     - `addon-core-ai@dev:coreai/src/main/java/ru/thedevs/coreai/provider/glm/GlmProcessHandler.java:293-294` и `addon-core-ai@dev:coreai/src/main/java/ru/thedevs/coreai/provider/codex/CodexProcessHandler.java:286`, вызывающие бинарники напрямую через заданный путь `cliPath`.
  3. Контракты потребителей платформы:
     - `shield-3@dev:Dockerfile:33` и `shield-3@dev:scripts/install-agy-cli.sh:6` (задача TD-2204, спецификация `THEDEVS-RU/shield-3@task/TD-2204:specs/2026-10-17-shield3-base-image-thedevs-ai.md`);
     - `thedevslk@dev:Dockerfile:175`, `thedevslk@dev:scripts/install-claude-cli.sh:38-39`, `thedevslk@dev:scripts/install-codex-cli.sh:5` (задача TD-2205).
- **Produces**:
  1. Гарантированное наличие исполняемых файлов или симлинков по путям `/usr/local/bin/claude`, `/usr/local/bin/codex`, `/usr/local/bin/agy` в базовом образе `thedevs-ai` (`docker/thedevs-ai/Dockerfile`).
  2. Двунаправленную доступность CLI-утилит: каждый инструмент доступен как по путям пакетного менеджера (`/usr/bin/{claude,codex,agy}`), так и по платформенным путям контракта TheDevs (`/usr/local/bin/{claude,codex,agy}`).
  3. Обязательную smoke-проверку на этапе сборки `docker/thedevs-ai/Dockerfile`:
     `test -x /usr/local/bin/claude && test -x /usr/local/bin/codex && test -x /usr/local/bin/agy` с контролем версий через вызов по абсолютным путям `/usr/local/bin/{claude,codex,agy} --version`.
  4. Прозрачную совместимость для слоя 3 `thedevs-browser` (`docker/thedevs-browser/Dockerfile`), наследующего слой `thedevs-ai`, а также проектов-потребителей `shield-3` (TD-2204) и `thedevslk` (TD-2205) без необходимости ручного создания симлинков в их собственных Dockerfile.

# Контекст

В базовом образе `thedevs-ai` (слой 2 Lego-стека `THEDEVS-RU/base-images`, задача TD-2201) утилиты AI-CLI устанавливаются через системный NodeSource и архивы:
- NodeSource пакет `nodejs` на Ubuntu 24.04 настраивает глобальный префикс npm в `/usr`, поэтому `npm install -g @anthropic-ai/claude-code` и `npm install -g @openai/codex` создают исполняемые файлы и симлинки в `/usr/bin/claude` и `/usr/bin/codex`.
- Google Antigravity CLI скачивается архивом `cli_linux_x64.tar.gz`, распаковывается и устанавливается как `antigravity` -> `agy`.

В то же время платформа TheDevs (`addon-core-ai` и микросервисы `shield-3`, `thedevslk`) исторически зафиксировала путь `/usr/local/bin/` как стандартный контракт для AI-CLI:
1. **`addon-core-ai`**:
   - `CAIAutoConfiguration.java:105`: `@Value("${ai.cli.path:/usr/local/bin/claude}") String cliPath`
   - `CAIAutoConfiguration.java:122`: `@Value("${ai.codex.cli.path:/usr/local/bin/codex}") String cliPath`
   - `CAIAutoConfiguration.java:138`: `@Value("${ai.cli.path:/usr/local/bin/claude}") String cliPath` (GLM-провайдер)
   - `CAIAutoConfiguration.java:176`: `@Value("${ai.antigravity.cli.path:/usr/local/bin/agy}") String cliPath`
   - `CoreAiSettings.java:32`: `@AppSettingsDefault("/usr/local/bin/claude") private String cliPath;`
   - `CoreAiCliDescriptor.java:18,23,28`: дефолтные пути `forClaude`, `forCodex`, `forAgy` жестко заданы как `/usr/local/bin/{claude,codex,agy}`.
   - `GlmProcessHandler.java:293-294` и `CodexProcessHandler.java:286`: проверяют `Files.isExecutable(Paths.get(cliPath))` и запускают процесс напрямую по переданному `cliPath`. Если `/usr/local/bin/claude` или `/usr/local/bin/codex` физически отсутствует, процесс падает с ошибкой инициализации.
2. **`shield-3`**:
   - `shield-3@dev:Dockerfile:33`: содержал временный костыль `RUN which claude && claude --version && ln -sf $(which claude) /usr/local/bin/claude`.
   - `shield-3@dev:scripts/install-agy-cli.sh:6`: объявлял `AGY_BIN="/usr/local/bin/agy"`.
   - В задаче `TD-2204` при переходе на `thedevs-ai` все локальные шаги установки CLI удаляются.
3. **`thedevslk`**:
   - `thedevslk@dev:Dockerfile:175`: `install -m 0755 "$AGY_TMP/antigravity" /usr/local/bin/agy`.
   - `thedevslk@dev:scripts/install-claude-cli.sh:38-39`: `ln -sf "$CLAUDE_PATH" /usr/local/bin/claude`.
   - `thedevslk@dev:scripts/install-codex-cli.sh:5`: `CODEX_BIN="/usr/local/bin/codex"`.
   - В задаче `TD-2205` образ `thedevslk` переводится на `thedevs-browser` (наследник `thedevs-ai`).

Если базовый образ `thedevs-ai` не гарантирует наличие исполняемых файлов или симлинков по путям `/usr/local/bin/{claude,codex,agy}`, сервисы платформы при вызовах через дефолтные пути получают отказ, либо требуют повторного костыльного создания симлинков в каждом проекте.

# Что сделать

## 1. Слой thedevs-ai (`docker/thedevs-ai/Dockerfile`)

В `docker/thedevs-ai/Dockerfile` обеспечить гарантированное наличие исполняемых файлов и симлинков по путям `/usr/local/bin/{claude,codex,agy}` и `/usr/bin/{claude,codex,agy}`:

1. **Claude Code CLI**:
   После команды установки `npm install -g @anthropic-ai/claude-code@${CLAUDE_CLI_VERSION}`:
   ```dockerfile
   RUN test "$(which claude)" = "/usr/local/bin/claude" || ln -sf "$(which claude)" /usr/local/bin/claude
   ```
2. **Codex CLI**:
   После команды установки `npm install -g @openai/codex@${CODEX_CLI_VERSION}`:
   ```dockerfile
   RUN test "$(which codex)" = "/usr/local/bin/codex" || ln -sf "$(which codex)" /usr/local/bin/codex
   ```
3. **Google Antigravity CLI (`agy`)**:
   При распаковке архива `cli_linux_x64.tar.gz` бинарник `antigravity` устанавливается напрямую в `/usr/local/bin/agy` с правами `0755`, и создается симлинк в `/usr/bin/agy`:
   ```dockerfile
   RUN curl -fsSL -o /tmp/cli_linux_x64.tar.gz "${AGY_CLI_URL}" \
       && echo "${AGY_CLI_SHA512}  /tmp/cli_linux_x64.tar.gz" | sha512sum -c - \
       && tar -xzf /tmp/cli_linux_x64.tar.gz -C /tmp \
       && install -m 0755 /tmp/antigravity /usr/local/bin/agy \
       && ln -sf /usr/local/bin/agy /usr/bin/agy \
       && rm -rf /tmp/cli_linux_x64.tar.gz /tmp/antigravity
   ```
4. **Smoke-проверка на этапе сборки Dockerfile**:
   Заменить базовую проверку из TD-2201 на строгую верификацию путей и исполняемости:
   ```dockerfile
   RUN test -x /usr/local/bin/claude \
       && test -x /usr/local/bin/codex \
       && test -x /usr/local/bin/agy \
       && /usr/local/bin/claude --version \
       && /usr/local/bin/codex --version \
       && /usr/local/bin/agy --version \
       && test -x /usr/bin/claude \
       && test -x /usr/bin/codex \
       && test -x /usr/bin/agy
   ```

## 2. CI-пайплайн сборки (`.github/workflows/build-base-images.yml`)

В шаге smoke-проверки джобы `build-ai` (или в пост-сборочной верификации) подтвердить исполняемость утилит по обоим контрактам путей:
```bash
test -x /usr/local/bin/claude && test -x /usr/local/bin/codex && test -x /usr/local/bin/agy
```

## 3. Документация репозитория (`README.md`)

В разделе описания слоя `thedevs-ai` зафиксировать контракт путей:
- `/usr/local/bin/claude` и `/usr/bin/claude` — Claude Code CLI;
- `/usr/local/bin/codex` и `/usr/bin/codex` — OpenAI Codex CLI;
- `/usr/local/bin/agy` и `/usr/bin/agy` — Google Antigravity CLI.
Все утилиты доступны под непривилегированным пользователем `appuser` (UID 1000).

## Затрагиваемые файлы

1. `docker/thedevs-ai/Dockerfile`
2. `.github/workflows/build-base-images.yml`
3. `README.md`

# Что уже есть

1. Спецификация модульных базовых образов `specs/2026-10-17-thedevs-base-images-lego-stack.md` (TD-2201) в `THEDEVS-RU/.github@task/TD-2201`, согласованная в раунде 4 ревью.
2. Контракт дефолтных путей в `addon-core-ai`:
   - `CAIAutoConfiguration.java:105,122,138,176`;
   - `CoreAiSettings.java:32`;
   - `CoreAiCliDescriptor.java:18,23,28`.
3. Резолвер путей `CoreAiCliPathResolver.java` (`addon-core-ai`, TD-1553), проверяющий `/usr/local/bin` первым среди системных путей.
4. Дочерние спецификации потребителей:
   - `THEDEVS-RU/shield-3@task/TD-2204:specs/2026-10-17-shield3-base-image-thedevs-ai.md` (принята в раунде 2);
   - Задача `TD-2205` в `THEDEVS-RU/thedevslk`.

# Критерии готовности

1. В `docker/thedevs-ai/Dockerfile` обеспечено гарантированное создание симлинков или бинарников по путям `/usr/local/bin/claude`, `/usr/local/bin/codex`, `/usr/local/bin/agy`.
2. Обеспечена двунаправленная доступность утилит по путям `/usr/local/bin/` и `/usr/bin/` для `claude`, `codex`, `agy`.
3. На этапе сборки `docker/thedevs-ai/Dockerfile` выполняется обязательная smoke-проверка:
   `test -x /usr/local/bin/claude && test -x /usr/local/bin/codex && test -x /usr/local/bin/agy && /usr/local/bin/claude --version && /usr/local/bin/codex --version && /usr/local/bin/agy --version`.
4. Слой 3 `thedevs-browser` наследует доступность путей `/usr/local/bin/{claude,codex,agy}` от `thedevs-ai` без дублирования инструкций.
5. В `README.md` зафиксирован контракт путей AI-CLI.
6. Спецификация проходит валидацию `bash references/contracts/builder/tools/validate-spec-format.sh specs/2026-10-18-thedevs-ai-cli-paths-contract.md` с кодом возврата 0.
7. Спецификация закоммичена в ветку `task/TD-2225` в репозитории `THEDEVS-RU/.github`.

# Не трогать

1. Не изменять дефолтные пути в `addon-core-ai` (`CAIAutoConfiguration.java:105,122,138,176`, `CoreAiSettings.java:32`) — контракт `/usr/local/bin/` является неизменным стандартом платформы.
2. Не возвращать Gemini CLI в базовый образ `thedevs-ai` (закрыт Google 18.06.2026, миграция в TD-2212).
3. Не модифицировать слой `thedevs-core` (`docker/thedevs-core/Dockerfile`) — слой ядра платформы остается свободным от AI CLI и Node.js.
4. Не коммитить и не пушить изменения напрямую в ветки `dev`, `main`, `master`.
