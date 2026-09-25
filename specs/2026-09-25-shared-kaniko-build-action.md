id: 2026-09-25-shared-kaniko-build-action
product: global
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
impl_model: sonnet
impl_effort: high

# Контекст

Сейчас в организации `THEDEVS-RU` сборка образов через Kaniko в Kubernetes дублируется в 9 репозиториях в виде локального action `.github/actions/kaniko-build/action.yml`. Эти копии разошлись по содержимому (7 различных хешей md5) и содержат критические архитектурные и логические дефекты:
1. Ложное признание живого пода удалённым при разовых сетевых сбоях и задержках kube-apiserver: подавление stderr `2>/dev/null` приводит к пустому выводу, который ошибочно трактуется как `deleted externally`, и скрипт сам принудительно удаляет здоровый работающий под (зафиксировано в run 36106883270).
2. Отсутствие повторных попыток при транзиентных сбоях сети/реестра в 8 из 9 репозиториев (только в `thedevslk` ранее был добавлен цикл `MAX_ATTEMPTS=3`).
3. Порог недоступности API в прежней версии `thedevslk` считался по числу итераций (200), что при таймауте запроса в 30 секунд приводило к ожиданию более 110 минут вместо заявленных 10 минут.
4. При превышении общего таймаута сборки или при длительной недоступности API под оставался брошенным в кластере.

Для устранения дублирования и надежной работы сборки создается единый централизованный action в публичном репозитории `THEDEVS-RU/.github` по пути `actions/kaniko-build/action.yml`. Веткой доставки является `dev` (в соответствии со стандартом конвейера TheDevs Builder: unnamed delivery branch always means `dev`). Поскольку репозиторий `THEDEVS-RU/.github` является публичным (`isPrivate: false`) и манифест не содержит секретов, экшен доступен всем воркфлоу организации сразу после слияния PR в `dev` через `uses: THEDEVS-RU/.github/actions/kaniko-build@dev` без ожидания ручной расстановки тегов.

# Что сделать

- Create: `actions/kaniko-build/action.yml` в репозитории `THEDEVS-RU/.github`.

### Входные параметры (inputs)

Экшен параметризуется всеми атрибутами, необходимыми для 9 проектов организации:
- `image`: обязательный (`required: true`), базовое имя целевого образа (например, `ghcr.io/thedevs-ru/thedevslk`).
- `tag`: обязательный (`required: true`), тег образа (формирует полное имя `${IMAGE}:${TAG}`).
- `namespace`: обязательный (`required: true`), namespace Kubernetes для запуска пода. Значения по умолчанию нет во избежание случайного запуска в namespace `default`.
- `git_token`: обязательный (`required: true`), токен доступа для клонирования контекста репозитория.
- `cache_pvc`: обязательный (`required: true`), имя тома PVC для кэша сборки конкретного проекта (`kaniko-cache-lk`, `kaniko-cache-mobitrack`, `kaniko-cache-shield`, `kaniko-cache-flparser`, `kaniko-cache-airunner`, `kaniko-cache-template-project`).
- `docker_secret`: необязательный, по умолчанию `ghcr-secret`, имя K8s Secret с конфигурацией реестра контейнеров.
- `repo`: необязательный, по умолчанию `${{ github.repository }}`, путь к репозиторию для Kaniko (`--context`).
- `branch`: необязательный, по умолчанию `${{ github.ref_name }}`, ветка репозитория.
- `cache_repo`: необязательный, по умолчанию пустая строка. В скрипте при пустом значении подставляется fallback `${IMAGE}:cache` (или `${IMAGE}/cache`).
- `build_timeout`: необязательный, по умолчанию `7200`, предельное время ожидания сборки в секундах (2400 для mobitrack-2/ai-runner/TemplateProject/euromobil-2, 7000 для flparser, 7200 для thedevslk/shield-3/m2m-ioo/addon-crypto-collector).
- `dockerfile`: необязательный, по умолчанию `Dockerfile`, относительный путь к Dockerfile.
- `claude_cli_version`: необязательный, по умолчанию пустая строка, версия CLI для передачи через `--build-arg=CLAUDE_CLI_VERSION`.
- `dockerhub_username`: необязательный, по умолчанию пустая строка, логин для аутентификации в Docker Hub.
- `dockerhub_token`: необязательный, по умолчанию пустая строка, токен для аутентификации в Docker Hub.
- `insecure`: необязательный, по умолчанию `'true'`, передача флага `--insecure` в Kaniko (во `flparser` передаётся `'false'`).
- `insecure_pull`: необязательный, по умолчанию `'true'`, передача флага `--insecure-pull` в Kaniko (в `shield-3` и `addon-crypto-collector` передаётся `'false'`).
- `image_fs_extract_retry`: необязательный, по умолчанию `'0'`, число попыток извлечения слоев Kaniko (во `flparser` передаётся `'5'`).

### Логика выполнения (runs)

1. **Инициализация и запуск пода сборки:**
   - Поддерживается цикл попыток `ATTEMPT` от 1 до `MAX_ATTEMPTS=3` для автоматического повтора при транзиентных сбоях (ошибки резолва git, обрывы TCP-соединений, таймауты TLS, статус `Evicted`).
   - Имя пода формируется уникальным на каждую попытку: `POD="${POD_NAME}-a${ATTEMPT}"` (где `POD_NAME="kaniko-${RUN_ID}-${RUN_ATTEMPT}"`), перед стартом выполняется предварительная зачистка старого пода с тем же именем: `kubectl -n "$NS" delete pod "$POD" --force --grace-period=0 --ignore-not-found --request-timeout=30s`.
   - Временные файлы для сохранения вывода проверки статуса размещаются в `${RUNNER_TEMP}/kaniko-phase-${ATTEMPT}.out` и `${RUNNER_TEMP}/kaniko-phase-${ATTEMPT}.err`.
   - Неработающая строка `export KUBECTL_REQUEST_TIMEOUT=30s` исключена; на всех вызовах `kubectl` явно задаётся `--request-timeout=30s`.
   - Динамический расчет дедлайна пода: `DEADLINE=$((BUILD_TIMEOUT + 600))`. В манифесте пода проставляется `activeDeadlineSeconds: $DEADLINE`, что гарантирует 10-минутный буфер сверх таймаута шага для сбора логов до вмешательства контроллера k8s.
   - Ожидание готовности пода перед опросом: `timeout 300s sh -c 'until kubectl -n "'"$NS"'" wait --for=condition=Ready "pod/'"$POD"'" --timeout=60s --request-timeout=30s 2>/dev/null; do sleep 5; done' || true` (увеличенный таймаут 300s покрывает медленные ноды flparser и ai-runner).
   - В манифест Kaniko передаются флаги: `--insecure` (если `insecure == 'true'`), `--insecure-pull` (если `insecure_pull == 'true'`), `--image-fs-extract-retry=${IMAGE_FS_EXTRACT_RETRY}` (если значение больше 0).

2. **Конечный автомат опроса статуса пода:**
   - Опрос выполняется с интервалом `sleep 3` в цикле `while [ $SECONDS -lt "$BUILD_TIMEOUT" ] && [ "$PHASE" != "Succeeded" ] && [ "$PHASE" != "Failed" ]`. Общее время job может составлять до `MAX_ATTEMPTS * BUILD_TIMEOUT` плюс бэкофф между попытками.
   - Состояния и переменные:
     - `PHASE="Running"`
     - `API_FAIL_SINCE=0` (временная метка начала серии ошибок связи с API в секундах `$SECONDS`)
     - `API_TIMEOUT=600` (порог длительной недоступности API — 10 минут)
     - `NOT_FOUND_FAILS=0` (счётчик подряд идущих ошибок отсутствия объекта)
     - `NOT_FOUND_LIMIT=5` (порог подтверждения внешнего удаления пода — 5 последовательных проверок)
     - `POD_GONE=0` (флаг подтверждённого внешнего удаления пода)
     - `API_EXHAUSTED=0` (флаг превышения лимита недоступности контрол-плейна)
     - `TIMED_OUT=0` (флаг превышения общего лимита времени сборки `$BUILD_TIMEOUT`)
   - Дифференциация результата `kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' --request-timeout=30s`:
     1. `$RC -eq 0` и вывод `$POLL_OUT` не пуст:
        `PHASE="$POLL_OUT"`, `API_FAIL_SINCE=0`, `NOT_FOUND_FAILS=0`.
     2. `$RC -eq 0` и вывод `$POLL_OUT` пуст:
        Под найден в API, но статус фазы ещё не инициализирован kubelet. Фаза не меняется, `API_FAIL_SINCE=0`, `NOT_FOUND_FAILS=0`.
     3. `$RC -ne 0` и в `$POLL_ERR` обнаружена строгая подстрока `(NotFound)`:
        `API_FAIL_SINCE=0`. Увеличивается счётчик `NOT_FOUND_FAILS=$((NOT_FOUND_FAILS + 1))`. В лог выводится `Pod $POD not found (attempt $NOT_FOUND_FAILS/$NOT_FOUND_LIMIT)...`. При достижении `NOT_FOUND_FAILS >= 5` фиксируется факт внешнего удаления: `POD_GONE=1`, `PHASE="Failed"`.
     4. `$RC -ne 0` без `(NotFound)` (сетевой таймаут, сбой шлюза 502/503, перезапуск apiserver):
        `NOT_FOUND_FAILS=0`. Если `API_FAIL_SINCE == 0`, то `API_FAIL_SINCE=$SECONDS`. Вычисляется `FAIL_ELAPSED=$((SECONDS - API_FAIL_SINCE))`. В лог выводится предупреждение `API unavailable for ${FAIL_ELAPSED}s (limit ${API_TIMEOUT}s): ...`. Фаза пода НЕ меняется (под жив и продолжает сборку). Если `FAIL_ELAPSED >= 600`, выводится сообщение об ошибке, фиксируется `API_EXHAUSTED=1`, `PHASE="Failed"`.

3. **Обработка общего таймаута сборки:**
   - После выхода из цикла `while` проверяется условие: если `[ "$PHASE" != "Succeeded" ] && [ "$PHASE" != "Failed" ]`, это означает, что истёк лимит времени сборки (`$SECONDS -ge $BUILD_TIMEOUT`) при незавершённом поде. Выводится строка `BUILD_FAILED: build timed out after ${SECONDS}s (limit ${BUILD_TIMEOUT}s)`, фиксируется `TIMED_OUT=1`, `PHASE="Failed"`.

4. **Завершение и очистка ресурсов:**
   - При успешном завершении (`PHASE == "Succeeded"`): выполняется удаление пода `kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false --request-timeout=30s`, удаление временных файлов фазы и выход с кодом 0.
   - При неуспешном завершении:
     - Выводится диагностика пода (YAML статуса, события пода, логи контейнеров с `--tail=-1` и фильтрацией шума git clone).
     - Выполняется best-effort удаление пода: `kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false --request-timeout=30s >/dev/null 2>&1 || true` во всех случаях, КРОМЕ `POD_GONE == 1` (если под уже удалён из кластера снаружи, вызов удаления пропускается; при `TIMED_OUT` и `API_EXHAUSTED` под удаляется).
     - Временные файлы фазы удаляются.
     - Если `POD_GONE == 1`, выводится `Build failed: pod was confirmed deleted externally` и происходит выход с кодом 1 без повторных попыток.
     - Если `API_EXHAUSTED == 1`, выводится `Build failed: kubernetes API unavailable for ${FAIL_ELAPSED}s` и происходит выход с кодом 1.
     - Если `TIMED_OUT == 1`, выводится `Build failed: build timed out after ${SECONDS}s` и происходит выход с кодом 1.
     - Если ошибка классифицирована как транзиентная и `ATTEMPT < MAX_ATTEMPTS`, скрипт выполняет паузу (бэкофф 10s / 30s) и переходит к следующей попытке.

# Что уже есть

- Исходный код экшена сборки `THEDEVS-RU/thedevslk@dev:.github/actions/kaniko-build/action.yml`, откуда без изменений переносятся:
  - build-arg `CACHEBUST=${CACHEBUST}`;
  - ресурсные запросы и лимиты (`requests: memory: "2Gi", cpu: "1000m"`, `limits: memory: "8Gi", cpu: "3000m"`);
  - init-контейнер `merge-docker-config` на базе `busybox:1.36` со сборкой `config.json`;
  - монтирование тома `shared-cache` (`kaniko-cache`) с subPath `gradle-wrapper`, `vaadin-root-cache`, `gradle-nodejs`, `npm-cache`;
  - монтирование тома `project-cache` (PVC из `inputs.cache_pvc`) без subPath в `/root/.gradle/caches`.
- Публичный репозиторий `THEDEVS-RU/.github` с рабочей веткой `dev`.

# Критерии готовности

- В репозитории `THEDEVS-RU/.github` на ветке `dev` создан файл `actions/kaniko-build/action.yml`.
- Поддерживаются все требуемые параметры для всех 9 потребителей организации (`cache_pvc`, `build_timeout`, `insecure`, `insecure_pull`, `image_fs_extract_retry`, `dockerfile`, `claude_cli_version`).
- Параметры `image`, `tag`, `namespace`, `git_token`, `cache_pvc` объявлены обязательными (`required: true`).
- Значение `activeDeadlineSeconds` рассчитывается динамически как `build_timeout + 600`.
- Порог недоступности API отсчитывается по фактическому времени (600 секунд), проверка отсутствия пода сужена строго до `(NotFound)`.
- При общем таймауте `$BUILD_TIMEOUT` под переходит в `TIMED_OUT` с последующим удалением.
- При исчерпании доступности API под удаляется best-effort. При `POD_GONE=1` удаление не вызывается.
- Валидатор `validate-spec-format.sh` подтверждает валидность спецификации.

# Не трогать

- Существующие файлы репозитория `THEDEVS-RU/.github`: `README.md`, `profile/`, `.github/ISSUE_TEMPLATE/`.
- Версии образов Kaniko executor (`v1.23.2`) и busybox (`1.36`).
