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
    description: 'CPU limit for Kaniko pod container (e.g. 16000m, 8). Set to 0 or none to remove CPU limit. Empty/omitted defaults to 16000m.'
    required: false
    default: '16000m'
  extra_tags:
    description: 'Comma- or whitespace-separated extra tags for target image'
    required: false
    default: ''
  build_args:
    description: 'Multiline list of build arguments (one KEY=VALUE per line) to pass to Kaniko. Not for secrets (visible in pod YAML).'
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

### 3. Валидация входных параметров (Fail-Fast)
В начале bash-скрипта до обращения к Kubernetes API выполнять проверку и нормализацию параметров:

1. **Валидация и нормализация `cpu_limit`:**
   ```bash
   CPU_LIMIT="${INPUT_CPU_LIMIT:-16000m}"
   REMOVE_CPU_LIMIT=0
   if [ "$CPU_LIMIT" = "0" ] || [ "$CPU_LIMIT" = "none" ]; then
     REMOVE_CPU_LIMIT=1
   else
     if ! printf '%s' "$CPU_LIMIT" | grep -qE '^([0-9]+m|[0-9]+([.][0-9]+)?)$'; then
       echo "::error::Invalid cpu_limit format: '$CPU_LIMIT'. Must be Kubernetes CPU quantity (e.g. 16000m, 8), 0, or none."
       exit 1
     fi
     case "$CPU_LIMIT" in
       *m)
         CPU_MILLIS="${CPU_LIMIT%m}"
         ;;
       *.*)
         CPU_MILLIS=$(awk -v val="$CPU_LIMIT" 'BEGIN { printf "%.0f", val * 1000 }')
         ;;
       *)
         CPU_MILLIS=$((CPU_LIMIT * 1000))
         ;;
     esac
     if [ "$CPU_MILLIS" -lt 1000 ]; then
       echo "::error::cpu_limit '$CPU_LIMIT' (${CPU_MILLIS}m) cannot be less than requests.cpu (1000m). Set to 0 or none to remove limit."
       exit 1
     fi
   fi
   ```

2. **Валидация и парсинг `extra_tags`:**
   ```bash
   VALIDATED_EXTRA_TAGS=()
   if [ -n "$INPUT_EXTRA_TAGS" ]; then
     while IFS= read -r tag_line || [ -n "$tag_line" ]; do
       tag_line="${tag_line#"${tag_line%%[![:space:]]*}"}"
       tag_line="${tag_line%"${tag_line##*[![:space:]]}"}"
       [ -z "$tag_line" ] && continue
       for single_tag in $(echo "$tag_line" | tr ',' ' '); do
         [ -z "$single_tag" ] && continue
         if ! printf '%s' "$single_tag" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'; then
           echo "::error::Invalid docker tag format in extra_tags: '$single_tag'."
           exit 1
         fi
         VALIDATED_EXTRA_TAGS+=("$single_tag")
       done
     done <<< "$INPUT_EXTRA_TAGS"
   fi
   ```

3. **Построчный парсинг и валидация `build_args`:**
   Разбор выполняется строго построчно без `xargs` и без разделения по запятым, сохраняя пробелы, двоеточия, дефисы и спецсимволы в значениях. Кавычки (`"`) и обратные слэши (`\`) запрещены во избежание повреждения YAML-манифеста пода.
   ```bash
   VALIDATED_BUILD_ARGS=()
   if [ -n "$INPUT_BUILD_ARGS" ]; then
     while IFS= read -r line || [ -n "$line" ]; do
       line="${line#"${line%%[![:space:]]*}"}"
       line="${line%"${line##*[![:space:]]}"}"
       [ -z "$line" ] && continue
       case "$line" in
         '#'*) continue ;;
       esac
       if ! printf '%s' "$line" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
         echo "::error::Invalid build_args line: '$line'. Must match KEY=VALUE syntax."
         exit 1
       fi
       if printf '%s' "$line" | grep -qE '["\\]'; then
         echo "::error::Invalid build_args line: '$line'. Quotes (\") and backslashes (\\) are forbidden."
         exit 1
       fi
       VALIDATED_BUILD_ARGS+=("$line")
     done <<< "$INPUT_BUILD_ARGS"
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
   if [ "$REMOVE_CPU_LIMIT" -eq 0 ]; then
     cat <<EOF
                cpu: "${CPU_LIMIT}"
   EOF
   fi
   cat <<EOF
   ```
2. **Дополнительные теги назначения (`extra_tags`):**
   После генерации основного аргумента `--destination=${IMAGE_FULL}` добавить обработку проверенных тегов:
   ```bash
   for EXTRA_TAG in "${VALIDATED_EXTRA_TAGS[@]}"; do
     cat <<EOF
             - "--destination=${IMAGE}:${EXTRA_TAG}"
   EOF
   done
   ```
3. **Произвольные build-args (`build_args`):**
   Добавить проверенные строки `build_args`:
   ```bash
   for BARG in "${VALIDATED_BUILD_ARGS[@]}"; do
     cat <<EOF
             - "--build-arg=${BARG}"
   EOF
   done
   ```

### 5. Анализ краевых сценариев и рисков снятия CPU-лимита на ноде .248

1. **CFS-квоты и конкуренция раннеров за CPU на узле .248:**
   - **Механика Linux CFS:** Лимит `limits.cpu: 16000m` задает квоту процессорного времени одного пода (`cfs_quota_us / cfs_period_us = 16`), но не изолирует физические ядра процессора (не является `cpuset`).
   - **Конкуренция раннеров:** На узле `.248` развернуты 3 self-hosted раннера GitHub Actions (`github-runner-1`, `github-runner-2`, `github-runner-3`). При одновременном запуске 3 сборок суммарный пиковый спрос может достигать 3 × 16 = 48 ядер на 24 аппаратных потоках AMD Ryzen 9 7900X.
   - **Сосуществование с dev и master (продакшн):** На ноде `.248` запущены сервисы контуров `dev` и `master`. Многие из них исторически не имеют заданных `requests.cpu`, распределяя кванты времени по умолчанию. При пиковой конкуренции сборки могут увеличивать время отклика сервисов и вызывать таймауты сетевых проб.
   - **Меры управления:**
     1. В вызывающих воркфлоу лимит может быть явно ограничен параметром `with: cpu_limit: '8000m'`.
     2. Для системного решения проблемы создана задача `TD-2202` («Настройка CPU requests и лимитов для dev и master на сборочном узле .248») по выставлению минимальных гарантированных `requests.cpu` (100–500m) на постоянные сервисы, что защитит их вес в CFS-планировщике независимо от сборочных пиков.

2. **Память и рост параллелизма воркеров при фиксированном лимите 8Gi:**
   - **Анализ:** Лимит памяти JVM в Gradle (`org.gradle.jvmargs=-Xmx2g`) зафиксирован только в `shield-3`, но отсутствует в `thedevslk` и `mobitrack-2`. При 16 доступных ядрах сборочные инструменты (Gradle воркеры, компилятор Node.js, потоки GC) запускают больше параллельных задач, увеличивая пиковое потребление RAM.
   - **Защита:** Лимит пода `limits.memory: 8Gi` жестко отсекает превышение. Для валидации безопасности сборочного процесса проверка стабильности вынесена в критерии готовности на самом тяжелом сервисе платформы (`thedevslk`).

3. **Влияние ссылки @dev на master-пайплайны и стратегия отката:**
   - Репозитории экосистемы вызывают экшен через `THEDEVS-RU/.github/actions/kaniko-build@dev`. Изменение в ветке `dev` сразу становится активным как для dev-, так и для master-сборок.
   - **План выкатки и отката:**
     1. Слияние PR в `dev` репозитория `THEDEVS-RU/.github`.
     2. Запуск контрольной сборки в `thedevslk` (ветка `dev`) с контролем расхода памяти и времени.
     3. При выявлении деградаций или OOM-падений откат выполняется либо экстренным revert коммита в `dev` репозитория `THEDEVS-RU/.github`, либо точечным override `with: cpu_limit: '3000m'` в воркфлоу микросервиса.

## Затрагиваемые файлы

1. `actions/kaniko-build/action.yml`

# Что уже есть

1. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:284-288` — работающий экшен запуска Kaniko в Kubernetes с настроенным кэшированием томов (`shared-cache`, `project-cache`), аутентификацией в реестрах и циклом повторных попыток.
2. Процессор AMD Ryzen 9 7900X (12c/24t) на ноде `.248` с достаточным запасом свободных ядер.
3. Дочерняя задача `TD-2201` в статусе `SPEC` для реализации 3-слойной иерархии базовых образов в `THEDEVS-RU/base-images`.
4. Системная задача `TD-2202` в статусе `SPEC` для настройки CPU requests/limits сервисов `dev` и `master` на узле `.248`.

# Критерии готовности

1. В `actions/kaniko-build/action.yml` объявлены входные параметры `cpu_limit` (дефолт `'16000m'`), `extra_tags` (дефолт `''`) и `build_args` (дефолт `''`).
2. При валидации `cpu_limit` проверяется соответствие формату Kubernetes CPU quantity и требование `cpu_limit >= 1000m` (requests.cpu); некорректные значения приводят к Fail-Fast ошибке шага.
3. Входной параметр `build_args` разбирается построчно без применения `xargs`, отклоняет символы `"` и `\` с выводом понятной ошибки; для каждой пары `KEY=VALUE` генерируется аргумент `--build-arg=KEY=VALUE`.
4. Входной параметр `extra_tags` безопасно разбирается без глоббинга и валидирует синтаксис Docker-тегов; для каждого тега генерируется `--destination=${IMAGE}:${EXTRA_TAG}`.
5. В генерируемом манифесте пода Kaniko:
   - При `cpu_limit: '16000m'` (или по умолчанию) в `limits` присутствует строка `cpu: "16000m"`;
   - Лимит памяти `limits.memory: "8Gi"` строго сохранен;
   - При `cpu_limit: '0'` или `'none'` строка `cpu` в секции `limits` отсутствует.
6. Спецификация проходит валидацию `bash references/contracts/builder/tools/validate-spec-format.sh specs/2026-10-17-kaniko-build-cpu-limit-and-build-args.md` с кодом 0.
7. На этапе доставки (TESTING) после слияния PR в `dev` перезапущена джоба `build` микросервиса `thedevslk`: сборка завершается со статусом `Succeeded` без `OOMKilled` и зафиксировано сокращение времени компиляции.

# Не трогать

1. Не изменять лимит памяти `limits.memory: "8Gi"` в `actions/kaniko-build/action.yml` (критический инвариант защиты ноды `.248` от OOM).
2. Не коммитить и не пушить изменения напрямую в ветки `dev`, `main`, `master`.
3. Не изменять логику работы с секретами реестров (`thedevs-registry-secret`, `docker_secret`, `registry_token`).
4. Не создавать базовые образы Docker в публичном репозитории `THEDEVS-RU/.github` (базовые образы собираются в приватном репозитории `THEDEVS-RU/base-images` в рамках TD-2201).
