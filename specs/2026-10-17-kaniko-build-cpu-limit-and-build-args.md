id: 2026-10-17-kaniko-build-cpu-limit-and-build-args
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
stage: detailed
impl_model: sonnet
impl_effort: high

# Контекст

В сборочной инфраструктуре TheDevs сборка Docker-образов микросервисов в Kubernetes выполняется через общий composite action `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml`. В манифесте сборочного пода Kaniko (`actions/kaniko-build/action.yml:284-288`) зафиксированы жесткие ресурсные ограничения:
`requests.memory: "2Gi"`, `requests.cpu: "1000m"`, `limits.memory: "8Gi"`, `limits.cpu: "3000m"`.

Фактическая длительность шага `build` в микросервисах платформы на сборочном узле `.248`:
- `THEDEVS-RU/shield-3`: 4–5 минут;
- `THEDEVS-RU/thedevslk`: 6.5–8 минут;
- `THEDEVS-RU/mobitrack-2`: 2.5–3 минуты.

Анализ узких мест показал:
1. **Жесткий троттлинг CPU в Kaniko:**
   Сборочный узел `.248` оснащён процессором AMD Ryzen 9 7900X (12 физических ядер / 24 потока). Kaniko эффективно кэширует неизменяемые слои (`--cache=true --cache-ttl=168h`), однако наиболее ресурсоемкая фаза сборки — параллельная компиляция Java/Kotlin (`./gradlew bootJar`), сборка фронтенда (TypeScript, Vite, Vaadin) и компрессия слоев образа (pigz) — жестко зажата лимитом CFS-квоты в 3000m (3 ядра). Процессор простаивает, пока сборка длится минуты.
2. **Инвариант защиты ноды по памяти:**
   Лимит памяти `limits.memory: 8Gi` является критическим инвариантом, предотвращающим исчерпание RAM ноды `.248` и аварийное вытеснение (OOMKilled) системных подов и баз данных. Этот лимит должен быть строго сохранен.
3. **Отсутствие гибкой передачи аргументов сборки и тегов:**
   Экшен принимает только одиночный `tag` и частный `claude_cli_version`. Отсутствует возможность передавать множественные теги (`extra_tags`) для одновременной публикации `latest` и иммутабельного версионного тега, а также произвольные сборочные аргументы (`build_args`), необходимые для продвижения базовых образов и параметризации Dockerfile.
4. **Декомпозиция задачи:**
   По решению оператора (раунд 1 ревью TD-2197) исходная задача разделена на две части:
   - **Спека A (данная спецификация TD-2197):** снятие троттлинга CPU в `actions/kaniko-build`, добавление параметров `cpu_limit`, `extra_tags` и `build_args` в `THEDEVS-RU/.github`;
   - **Спека B (дочерняя задача TD-2201):** создание приватного репозитория `THEDEVS-RU/base-images` и сборка 3-слойной Lego-иерархии (`thedevs-core` -> `thedevs-ai` -> `thedevs-browser`) с использованием новых возможностей экшена Kaniko.

# Что сделать

Модифицировать `actions/kaniko-build/action.yml` в репозитории `THEDEVS-RU/.github`:

### 1. Новые входные параметры (inputs)
Добавить в секцию `inputs` файла `actions/kaniko-build/action.yml`:
```yaml
  cpu_limit:
    description: 'CPU limit for Kaniko pod container (e.g. 16000m, 8, 4000m). Set to empty string, 0, or none to remove CPU limit'
    required: false
    default: '16000m'
  extra_tags:
    description: 'Comma or space separated extra tags for target image'
    required: false
    default: ''
  build_args:
    description: 'Multiline or comma-separated list of build arguments to pass as --build-arg=KEY=VALUE to Kaniko'
    required: false
    default: ''
```

### 2. Передача параметров в bash-рантайм (env)
В секцию `runs.steps[0].env` добавить:
```yaml
        INPUT_CPU_LIMIT: ${{ inputs.cpu_limit }}
        INPUT_EXTRA_TAGS: ${{ inputs.extra_tags }}
        INPUT_BUILD_ARGS: ${{ inputs.build_args }}
```

### 3. Валидация формата cpu_limit (Fail-Fast)
В начале bash-скрипта добавить валидацию формата `cpu_limit` (Kubernetes Quantity синтаксис):
```bash
CPU_LIMIT="${INPUT_CPU_LIMIT:-16000m}"
if [ -n "$CPU_LIMIT" ] && [ "$CPU_LIMIT" != "0" ] && [ "$CPU_LIMIT" != "none" ]; then
  if ! printf '%s' "$CPU_LIMIT" | grep -qE '^[0-9]+([.][0-9]+)?m?$'; then
    echo "::error::Invalid cpu_limit format: '$CPU_LIMIT'. Must be Kubernetes CPU quantity (e.g. 16000m, 8, 4000m), 0, or none."
    exit 1
  fi
fi
```

### 4. Динамическая генерация манифеста пода
В блоке формирования манифеста пода (HEREDOC `cat <<EOF`):
1. **Ресурсы контейнера Kaniko:**
   - Запросы `requests.memory: "2Gi"` и `requests.cpu: "1000m"` остаются без изменений.
   - Лимит `limits.memory: "8Gi"` строго сохраняется.
   - Лимит `limits.cpu` формируется условно:
   ```bash
            resources:
              requests:
                memory: "2Gi"
                cpu: "1000m"
              limits:
                memory: "8Gi"
   EOF
   if [ -n "$CPU_LIMIT" ] && [ "$CPU_LIMIT" != "0" ] && [ "$CPU_LIMIT" != "none" ]; then
     cat <<EOF
                cpu: "${CPU_LIMIT}"
   EOF
   fi
   cat <<EOF
   ```
2. **Дополнительные теги назначения (`extra_tags`):**
   После генерации основного аргумента `--destination=${IMAGE_FULL}` добавить обработку `extra_tags`:
   ```bash
   if [ -n "$INPUT_EXTRA_TAGS" ]; then
     for EXTRA_TAG in $(echo "$INPUT_EXTRA_TAGS" | tr ',' ' '); do
       if [ -n "$EXTRA_TAG" ]; then
         cat <<EOF
             - "--destination=${IMAGE}:${EXTRA_TAG}"
   EOF
       fi
     done
   fi
   ```
3. **Произвольные build-args (`build_args`):**
   Добавить итерацию по строкам/запятым входного параметра `build_args` с добавлением аргументов `--build-arg=...`:
   ```bash
   if [ -n "$INPUT_BUILD_ARGS" ]; then
     while IFS= read -r BARG || [ -n "$BARG" ]; do
       BARG_TRIM="$(echo "$BARG" | xargs)"
       if [ -n "$BARG_TRIM" ]; then
         cat <<EOF
             - "--build-arg=${BARG_TRIM}"
   EOF
       fi
     done <<< "$(echo "$INPUT_BUILD_ARGS" | tr ',' '\n')"
   fi
   ```

### 5. Анализ краевых сценариев и рисков снятия CPU-лимита на ноде .248

1. **Dev-нагрузки без явных CPU requests:**
   - **Фактическое состояние:** Микросервисы в namespace `dev` на ноде `.248` (`shield`, `thedevslk`, `mobitrack`, `euromobil-2`) не имеют явно заданных `requests.cpu`, распределяя циклы процессора по CFS shares.
   - **Риск:** Сборочный под Kaniko при многопоточной компиляции может на короткое время утилизировать доступные ядра, вызывая повышение задержек ответа работающих dev-подов и возможные таймауты liveness/readiness проб.
   - **Анализ и минимизация риска:** Процессор Ryzen 9 7900X предоставляет 24 потока. Лимит `16000m` (16 потоков) гарантирует, что 8 потоков процессора (33% суммарной вычислительной мощности узла) физически изолированы от сборочного пода и остаются в монопольном распоряжении системных компонентов хоста (kubelet, containerd, OS kernel) и прикладных dev-подов.
   - **Управляемость:** Если на узле наблюдается повышенная фоновая нагрузка, любой вызывающий воркфлоу может ограничить аппетит сборки (например, `cpu_limit: '8000m'`).
   - **Follow-up:** Запланировать установку базовых `requests.cpu: 100m` в Deployment-манифестах сервисов dev-контура для гарантированного выделения минимальных квантов CFS при пиковой конкуренции.

2. **Рост параллелизма при фиксированном лимите памяти 8Gi:**
   - **Риск:** При 16 доступных ядрах сборочные инструменты (Gradle worker pool `--max-workers`, компилятор Node.js/Vite, потоки сборщика мусора JVM) могут запустить больше параллельных потоков, что увеличивает пиковое потребление памяти внутри пода.
   - **Анализ и минимизация риска:** В `Dockerfile` ключевых проектов уже зафиксированы ограничения: `ENV NODE_OPTIONS="--max-old-space-size=4096"` в `thedevslk` и `mobitrack-2`, а также лимиты памяти в Gradle. Лимит пода `limits.memory: 8Gi` жестко отсекает превышение. В критериях готовности зафиксирована обязательная верификация сборки самого тяжелого проекта (`thedevslk`) на 16 ядрах без падений по OOM.

3. **Влияние ссылки @dev на master-пайплайны и стратегия отката:**
   - **Контекст:** Репозитории экосистемы вызывают экшен через `THEDEVS-RU/.github/actions/kaniko-build@dev`. Изменение в ветке `dev` сразу становится активным как для dev-, так и для master-сборок при их запуске.
   - **План выкатки:**
     1. Слияние PR в `dev` репозитория `THEDEVS-RU/.github`.
     2. Запуск контрольной сборки в `thedevslk` (ветка `dev`) с замером времени и контролем расхода памяти через `kubectl top pod`.
     3. Проверка успешности сборки `shield-3` и `mobitrack-2`.
   - **План отката (Rollback):**
     В случае выявления регрессий или OOM-падений откат выполняется мгновенно одним из двух способов:
     - Экстренный реверт коммита в ветке `dev` репозитория `THEDEVS-RU/.github`;
     - Точечный override в воркфлоу проблемного микросервиса: `with: cpu_limit: '3000m'`.

## Затрагиваемые файлы

1. `actions/kaniko-build/action.yml`

# Что уже есть

1. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:284-288` — работающий экшен запуска Kaniko в Kubernetes с настроенным кэшированием томов (`shared-cache`, `project-cache`), аутентификацией в реестрах и циклом повторных попыток.
2. Процессор AMD Ryzen 9 7900X (12c/24t) на ноде `.248` с достаточным запасом свободных ядер.
3. Дочерняя задача `TD-2201` в статусе `SPEC` для реализации 3-слойной иерархии базовых образов в `THEDEVS-RU/base-images`.

# Критерии готовности

1. В `actions/kaniko-build/action.yml` объявлены входные параметры `cpu_limit` (со значением по умолчанию `'16000m'`), `extra_tags` (по умолчанию `''`) и `build_args` (по умолчанию `''`).
2. При валидации `cpu_limit` проверяется соответствие формату Kubernetes CPU quantity; некорректные значения приводят к Fail-Fast ошибке шага.
3. В генерируемом манифесте пода Kaniko:
   - При `cpu_limit: '16000m'` в `limits` присутствует строка `cpu: "16000m"`;
   - Лимит памяти `limits.memory: "8Gi"` строго сохранен;
   - При `cpu_limit: ''`, `'0'` или `'none'` строка `cpu` в секции `limits` отсутствует;
   - Для каждого переданного значения в `extra_tags` генерируется аргумент `--destination=${IMAGE}:${EXTRA_TAG}`;
   - Для каждого аргумента в `build_args` генерируется аргумент `--build-arg=${KEY}=${VALUE}`.
4. Выполнена верификационная сборка микросервиса `thedevslk` с экшеном `THEDEVS-RU/.github/actions/kaniko-build@dev` при `cpu_limit: 16000m`:
   - Сборка завершается статусом `Succeeded` без `OOMKilled` (Exit code 137);
   - Зафиксирован хронометраж длительности джобы `build` до и после снятия троттлинга.
5. Спецификация проходит валидацию `bash references/contracts/builder/tools/validate-spec-format.sh specs/2026-10-17-kaniko-build-cpu-limit-and-build-args.md` с кодом 0.

# Не трогать

1. Не изменять лимит памяти `limits.memory: "8Gi"` в `actions/kaniko-build/action.yml` (критический инвариант защиты ноды `.248` от OOM).
2. Не коммитить и не пушить изменения напрямую в ветки `dev`, `main`, `master`.
3. Не изменять логику работы с секретами реестров (`thedevs-registry-secret`, `docker_secret`, `registry_token`).
4. Не создавать базовые образы Docker в публичном репозитории `THEDEVS-RU/.github` (базовые образы собираются в приватном репозитории `THEDEVS-RU/base-images` в рамках TD-2201).
