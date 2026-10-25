id: 2026-10-25-kaniko-build-gradle-secrets-mount
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
stage: detailed
external_content: false
impl_model: sonnet
impl_effort: high

# Контекст

Сборка Docker-образов микросервисов платформы TheDevs выполняется в изолированных подах Kaniko в Kubernetes-кластере с помощью composite action `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:1`. В сборочных Dockerfile (`thedevslk`, `marta`, `shield-3`) ключевым этапом является компиляция приложения командой `RUN ./gradlew bootJar --no-daemon`.

При сборке микросервисы зависят от платформенных аддонов (`ru.thedevs.*`), публикуемых в закрытый репозиторий snapshot-артефактов платформы `https://repo.thedevs.ru/repository/thedevs-snapshot/`. Доступ к данному репозиторию требует обязательной аутентификации.

В текущей инфраструктуре экшен `kaniko-build` монтирует постоянные тома кэша (`shared-cache` и `project-cache` в `/root/.gradle/caches`, `/root/.gradle/wrapper`, `/root/.gradle/nodejs`), но не поддерживает монтирование секретов с учетными данными для Gradle.

Из-за отсутствия механизма безопасного проброса секретов разработчики были вынуждены:
1. Зашивать открытые литералы учетных данных (`username = 'thedevs'`, `password = 'zxcvzxcv'`) непосредственно в сборочные скрипты `build.gradle` (`THEDEVS-RU/shield-3@dev:build.gradle:25-29`, `THEDEVS-RU/marta@dev:build.gradle:25-29`);
2. Использовать комментарии и литеральные фоллбэки в `build.gradle` (`THEDEVS-RU/thedevslk@dev:build.gradle:25-31`: `// Read-only Nexus account; literal fallback required — kaniko Docker build has no CI env/props`).

Это противоречит стандартам безопасности платформы и создает критические риски компрометации репозиториев. Передача секретов через аргументы сборки Dockerfile (`--build-arg`) неприемлема, поскольку значения сохраняются в истории слоев Docker-образа и отображаются в аргументах контейнера в открытом виде. Передача пароля через `env.value` в манифесте сборочного пода также недопустима, поскольку пароль становится виден любому пользователю кластера через `kubectl get pod -o yaml`.

Задача TD-2442 предписывает реализовать в composite action `actions/kaniko-build` поддержку монтирования Kubernetes Secret с учетными данными Gradle в сборочный под Kaniko в виде канонического файла `/root/.gradle/gradle.properties` (без использования init-контейнеров, без сохранения паролей в git, Dockerfile, метаданных пода и слоях образа).

# Что сделать

## Затрагиваемые файлы

- `actions/kaniko-build/action.yml`
- `actions/kaniko-build/README.md`
- `tests/test-kaniko-build.sh`

## 1. Входные параметры (inputs) в `actions/kaniko-build/action.yml`

Добавить в секцию `inputs` файла `actions/kaniko-build/action.yml`:

```yaml
  gradle_secret:
    description: 'Pre-existing Kubernetes Secret name in namespace with gradle.properties key. Default: empty (opt-in).'
    required: false
    default: ''
  gradle_username:
    description: 'Username for Gradle private repository auth (repo.thedevs.ru). Must be provided together with gradle_password.'
    required: false
    default: ''
  gradle_password:
    description: 'Password for Gradle private repository auth (repo.thedevs.ru). Must be provided together with gradle_username.'
    required: false
    default: ''
```

В секцию `runs.steps[0].env` добавить:

```yaml
        INPUT_GRADLE_SECRET: ${{ inputs.gradle_secret }}
        INPUT_GRADLE_USERNAME: ${{ inputs.gradle_username }}
        INPUT_GRADLE_PASSWORD: ${{ inputs.gradle_password }}
```

## 2. Валидация входных данных и семантика Fail-Fast

В shell-скрипте экшена перед сборочным циклом реализовать строго детерминированный выбор источника учетных данных и проверку недопустимых символов:

```bash
        GRADLE_SECRET="${INPUT_GRADLE_SECRET:-}"
        GRADLE_USERNAME="${INPUT_GRADLE_USERNAME:-}"
        GRADLE_PASSWORD="${INPUT_GRADLE_PASSWORD:-}"

        # 1. Валидация недопустимых символов (защита от разрыва строк в .properties)
        if [[ "$GRADLE_USERNAME" == *[$'\r\n']* ]] || [[ "$GRADLE_PASSWORD" == *[$'\r\n']* ]]; then
          echo "::error::Invalid characters in gradle_username or gradle_password: newlines are forbidden."
          exit 1
        fi

        # 2. Валидация парности учетных данных
        if [ -n "$GRADLE_USERNAME" ] && [ -z "$GRADLE_PASSWORD" ]; then
          echo "::error::Both gradle_username and gradle_password must be specified together."
          exit 1
        fi
        if [ -z "$GRADLE_USERNAME" ] && [ -n "$GRADLE_PASSWORD" ]; then
          echo "::error::Both gradle_username and gradle_password must be specified together."
          exit 1
        fi

        # 3. Выбор режима и pre-flight проверка
        GRADLE_SECRET_NAME=""
        USE_TEMP_GRADLE_SECRET=0

        if [ -n "$GRADLE_USERNAME" ] && [ -n "$GRADLE_PASSWORD" ]; then
          USE_TEMP_GRADLE_SECRET=1
        elif [ -n "$GRADLE_SECRET" ]; then
          echo "Verifying gradle secret '$GRADLE_SECRET' in namespace '$NS'..."
          SECRET_CHECK_ERR=$(kubectl -n "$NS" get secret "$GRADLE_SECRET" --request-timeout=15s 2>&1 >/dev/null || true)
          if [ -n "$SECRET_CHECK_ERR" ]; then
            if printf '%s' "$SECRET_CHECK_ERR" | grep -F -q 'NotFound'; then
              echo "::error::Gradle secret '$GRADLE_SECRET' specified but not found in namespace '$NS'"
              exit 1
            else
              echo "::warning::Could not verify secret '$GRADLE_SECRET' in namespace '$NS' (proceeding with volume mount): $SECRET_CHECK_ERR"
            fi
          fi
          GRADLE_SECRET_NAME="$GRADLE_SECRET"
        fi
```

### Поведение валидации:
1. Запрет переносов строк: при наличии символов `\r` или `\n` шаг немедленно падает с ошибкой `::error::` (по аналогии с `claude_cli_version` в `action.yml:179`).
2. Запрет неполных учетных данных: если передан только один из параметров `gradle_username` или `gradle_password`, шаг немедленно завершается с ошибкой `::error::Both gradle_username and gradle_password must be specified together.` и кодом 1 (дефолтных литералов вроде `thedevs` нет).
3. При передаче обоих параметров активируется режим эфемерного секрета (`USE_TEMP_GRADLE_SECRET=1`).
4. Если задан `gradle_secret`: выполняется pre-flight проверка через `kubectl -n "$NS" get secret "$GRADLE_SECRET"`. Если ответ содержит `NotFound`, шаг завершается с `::error::` и кодом 1 (Fail-Fast). При ошибке сети/RBAC выводится `::warning::`, и секрет используется для монтирования.
5. Если параметры `gradle_*` не переданы: `GRADLE_SECRET_NAME=""`, монтирование тома не производится, манифест пода побайтно идентичен текущему.

## 3. Создание, обработка ошибок, RBAC и жизненный цикл временного секрета `${POD}-gradle`

Создание временного секрета выполняется строго через временный файл на раннере и пайп в `kubectl apply`, исключая попадание пароля в `argv` (`ps aux`) и метаданные пода:

1. **Создание секрета и экранирование спецсимволов Java Properties:**
   В цикле попыток сборки перед запуском пода при `USE_TEMP_GRADLE_SECRET=1`:
   ```bash
   GRADLE_SECRET_NAME="${POD}-gradle"
   GRADLE_PROP_FILE="${RUNNER_TEMP:-/tmp}/${POD}-gradle.properties"

   # Экранирование обратного слэша для формата java.util.Properties
   GRADLE_USER_ESCAPED="${GRADLE_USERNAME//\\/\\\\}"
   GRADLE_PASS_ESCAPED="${GRADLE_PASSWORD//\\/\\\\}"

   (
     umask 077
     cat > "$GRADLE_PROP_FILE" <<EOF
thedevsRepoUser=$GRADLE_USER_ESCAPED
thedevsRepoPassword=$GRADLE_PASS_ESCAPED
uploadUser=$GRADLE_USER_ESCAPED
uploadPassword=$GRADLE_PASS_ESCAPED
EOF
   )
   chmod 600 "$GRADLE_PROP_FILE"

   APPLY_SECRET_OUT=$(kubectl -n "$NS" create secret generic "$GRADLE_SECRET_NAME" \
     --from-file="gradle.properties=$GRADLE_PROP_FILE" \
     --dry-run=client -o yaml | kubectl apply --request-timeout=30s -f - 2>&1)
   APPLY_SECRET_RC=${PIPESTATUS[1]}
   rm -f "$GRADLE_PROP_FILE"

   if [ "$APPLY_SECRET_RC" -ne 0 ]; then
     if printf '%s' "$APPLY_SECRET_OUT" | grep -F -q 'Forbidden'; then
       echo "::error::RBAC permission denied to create temporary gradle secret '$GRADLE_SECRET_NAME' in namespace '$NS'. Ensure the service account from BUILDER_CONFIG_K8S has 'create' and 'delete' verbs on 'secrets'. Details: $(printf '%s' "$APPLY_SECRET_OUT" | tr '\n' ' ' | cut -c1-200)"
       exit 1
     fi
     if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
       BACKOFF=10
       [ "$ATTEMPT" -eq 2 ] && BACKOFF=30
       echo "Transient failure creating gradle secret — retrying in ${BACKOFF}s"
       sleep "$BACKOFF"
       ATTEMPT=$((ATTEMPT + 1))
       continue
     fi
     echo "::error::Failed to create temporary gradle secret '$GRADLE_SECRET_NAME' in namespace '$NS': $(printf '%s' "$APPLY_SECRET_OUT" | tr '\n' ' ' | cut -c1-200)"
     exit 1
   fi
   ```

2. **Защита от осиротевших секретов при аварийном завершении раннера (ownerReferences):**
   После создания пода Kaniko (`kubectl apply -f -`) из метаданных пода извлекается его UID, и на временный секрет проставляется ссылка владельца (`ownerReferences`):
   ```bash
   POD_UID=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' --request-timeout=15s 2>/dev/null || true)
   if [ -n "$POD_UID" ]; then
     kubectl -n "$NS" patch secret "$GRADLE_SECRET_NAME" --type=merge --request-timeout=15s \
       -p "{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"name\":\"$POD\",\"uid\":\"$POD_UID\",\"blockOwnerDeletion\":false}]}}" >/dev/null 2>&1 || true
   fi
   ```
   Благодаря этому, если процесс раннера будет аварийно убит по `SIGKILL` (runner lost), Kubernetes Garbage Collector автоматически удалит Secret вместе с завершенным/удаленным подом.

3. **Гарантированная очистка (Cleanup via trap EXIT):**
   В начале скрипта регистрируется обработчик `trap cleanup_gradle_secrets EXIT INT TERM`:
   ```bash
   cleanup_gradle_secrets() {
     [ -n "${GRADLE_PROP_FILE:-}" ] && rm -f "$GRADLE_PROP_FILE" 2>/dev/null || true
     if [ "$USE_TEMP_GRADLE_SECRET" -eq 1 ] && [ -n "${GRADLE_SECRET_NAME:-}" ]; then
       kubectl -n "$NS" delete secret "$GRADLE_SECRET_NAME" --ignore-not-found --wait=false --request-timeout=30s >/dev/null 2>&1 || true
     fi
   }
   trap cleanup_gradle_secrets EXIT INT TERM
   ```
   Удаление локального файла производится строго по точной переменной пути `GRADLE_PROP_FILE`, без использования опасных масок по каталогу `/tmp`.

4. **Требования к RBAC сборочного кластера:**
   Сервисный аккаунт, переданный в `BUILDER_CONFIG_K8S`, обязан обладать правами `create`, `delete` и `patch` на ресурс `secrets` в пространстве имен сборщика (`vars.BUILD_NAMESPACE` / `master` / `dev`):
   ```yaml
   rules:
     - apiGroups: [""]
       resources: ["secrets"]
       verbs: ["get", "create", "delete", "patch"]
   ```

## 4. Прямое монтирование секрета в контейнер Kaniko (без init-контейнеров)

Секрет монтируется напрямую из памяти кластера (tmpfs тома `secret`) в контейнер `kaniko`. Никаких init-контейнеров на базе `busybox` и томов `emptyDir` на диске узла не создается.

В манифесте пода при `[ -n "$GRADLE_SECRET_NAME" ]`:
1. В секцию `spec.containers[0].volumeMounts` (контейнер `kaniko`) добавляется:
   ```yaml
   - name: gradle-secret
     mountPath: /root/.gradle/gradle.properties
     subPath: gradle.properties
     readOnly: true
   ```
2. В секцию `spec.volumes` добавляется:
   ```yaml
   - name: gradle-secret
     secret:
       secretName: $GRADLE_SECRET_NAME
       items:
       - key: gradle.properties
         path: gradle.properties
       defaultMode: 0400
   ```

### Анализ пограничных случаев монтирования subPath:
В Kubernetes монтирование `subPath` файла из секрета с явным списком `items` имеет особенность: если секрет или указанный ключ `gradle.properties` физически отсутствует в namespace, Kubelet не может создать проекцию и под зависает в статусе `ContainerCreating` с событием `FailedMount`.
Данный риск полностью предотвращен предложенной архитектурой:
- Для временного секрета `${POD}-gradle` создание проверяется через `PIPESTATUS` до создания пода, а сам ключ `gradle.properties` формируется экшеном гарантированно;
- Для постоянного секрета `gradle_secret` pre-flight проверка Fail-Fast завершает шаг ошибкой еще до создания пода, исключая зависание;
- При `GRADLE_SECRET_NAME=""` секции `volumeMounts` и `volumes` для `gradle-secret` не генерируются вовсе.

## 5. Документация в `actions/kaniko-build/README.md`

Обновить `actions/kaniko-build/README.md`:
- Добавить параметры `gradle_secret`, `gradle_username`, `gradle_password` в таблицу `inputs`;
- Задокументировать требования к RBAC сервис-аккаунта (`get`, `create`, `delete`, `patch` на `secrets`);
- Описать схему работы: создание временного K8s-секрета из `gradle_username` и `gradle_password`, привязка `ownerReferences` к поду, прямое монтирование в `/root/.gradle/gradle.properties` с `readOnly: true`, гарантированное удаление по `trap EXIT`;
- Привести пример использования с GitHub Secrets:
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

## 6. Контрактные тесты в `tests/test-kaniko-build.sh`

Расширить набор тестов в `tests/test-kaniko-build.sh`:
1. **Mock kubectl:** дополнить заглушку `kubectl` поддержкой команд `create secret generic`, `delete secret`, `patch secret`, проверкой флага `--from-file` и эмуляцией ошибки `Forbidden`.
2. **Негативный тест безопасности:** проверить, что тестовые значения `INPUT_GRADLE_USERNAME="testuser"` и `INPUT_GRADLE_PASSWORD="testpassword123"` не встречаются ни в захваченном манифесте pod YAML (`CAPTURED_YAML`), ни в логах stdout/stderr экшена.
3. **Тест создания и монтирования временного секрета:** при передаче `gradle_username` и `gradle_password` проверить, что генерируется манифест пода с томом `kaniko-test-1-1-a1-gradle`, `defaultMode: 0400`, `items: [{key: gradle.properties, path: gradle.properties}]` и `volumeMount` в `/root/.gradle/gradle.properties`.
4. **Тест обработки ошибки RBAC:** смоделировать ответ `Forbidden` от `kubectl apply` при создании секрета, проверить, что шаг падает с понятной ошибкой RBAC, и создание пода не инициируется.
5. **Тест удаления временного секрета:** проверить, что при нормальном завершении и при ошибке сборщика mock kubectl регистрирует вызов удаления `delete secret kaniko-test-1-1-a1-gradle`.
6. **Тест изоляции (побайтное совпадение по умолчанию):** без параметров `gradle_*` сгенерированный pod YAML побайтно совпадает с эталонным манифестом (без лишних томов).
7. **Тест валидации парности и переносов строк:** проверить, что указание только `gradle_username` без `gradle_password`, либо передача значения с переводом строки немедленно возвращает код 1 с ошибкой `::error::`.
8. **Тест Fail-Fast для `gradle_secret`:** при передаче несуществующего секрета шаг завершается с ошибкой `::error::Gradle secret '...' specified but not found`.

# Что уже есть

1. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:20` — рабочий composite action запуска Kaniko в Kubernetes с кэшированием томов (`shared-cache`, `project-cache`), поддержкой `docker_secret`, pre-flight проверкой и циклом повторных попыток.
2. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:438-452` — схема монтирования подкаталогов кэша в `/root/.gradle/wrapper`, `/root/.gradle/nodejs` и `/root/.gradle/caches`.
3. `THEDEVS-RU/.github@dev:tests/test-kaniko-build.sh:1` — модульный тестовый раннер на Bash для проверки генерации манифестов пода Kaniko без обращения к реальному кластеру.
4. `THEDEVS-RU/addon-browser@dev:.github/workflows/publish-dev.yml:43-44` — заведенные на уровне организации GitHub org-секреты `secrets.MAVEN_USERNAME` и `secrets.MAVEN_PASSWORD`.
5. `THEDEVS-RU/addon-browser@dev:build.gradle:18-30` — платформенный стандарт каскадного разрешения учетных данных Gradle (TD-2218).

## Проверенные API

1. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:20` — объявление параметров реестра и секретов.
2. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:276` — pre-flight проверка секретов через `kubectl -n "$NS" get secret "$SECRET" --request-timeout=15s`.
3. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:377` — контейнер Kaniko `image: gcr.io/kaniko-project/executor:v1.23.2`.
4. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:438` — объявление volumeMounts кэша `/root/.gradle/wrapper`, `/root/.gradle/nodejs`, `/root/.gradle/caches`.
5. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:457` — определение томов пода.
6. `THEDEVS-RU/thedevslk@dev:build.gradle:25-31` — репозиторий `repo.thedevs.ru/repository/thedevs-snapshot/` с каскадом `thedevsRepoUser`/`THEDEVS_REPO_USER` и литеральным фоллбэком `'thedevs'`/`'zxcvzxcv'`.
7. `THEDEVS-RU/shield-3@dev:build.gradle:25-29` — блок credentials с литералами `'thedevs'`/`'zxcvzxcv'`.
8. `THEDEVS-RU/marta@dev:build.gradle:25-29` — блок credentials с литералами `'thedevs'`/`'zxcvzxcv'`.
9. `THEDEVS-RU/addon-browser@dev:build.gradle:18-30` — каскад чтения `uploadUser`, `thedevsRepoUser`, `MAVEN_USERNAME` из свойств проекта и окружения (TD-2218).
10. `THEDEVS-RU/addon-browser@dev:.github/workflows/publish-dev.yml:43-44` — использование org-секретов `secrets.MAVEN_USERNAME` и `secrets.MAVEN_PASSWORD`.
11. `THEDEVS-RU/thedevs-plugins@dev:shared/builder/references/ci-standards.md:15` — стандарт запуска Kaniko через `THEDEVS-RU/.github/actions/kaniko-build@dev`.

# Потребители

Изменение является обратно совместимым для всех существующих потребителей экшена (при незаданных параметрах `gradle_*` поведение и генерируемый манифест не меняются). Основные вызывающие воркфлоу платформы, выполняющие сборку через Kaniko:
- **thedevslk** (`THEDEVS-RU/thedevslk@dev:.github/workflows/build.yml:171`);
- **shield-3** (`THEDEVS-RU/shield-3@dev:.github/workflows/build.yml:159`);
- **marta** (`THEDEVS-RU/marta@dev:.github/workflows/build.yml:190`).

### Обязательные Follow-up задачи для заведения на доске:
1. `rbac(builder): верификация и выдача RBAC create/delete/patch secrets для BUILDER_CONFIG_K8S` — проверить права через `kubectl auth can-i create secrets -n <ns>` под сборочным kubeconfig в пространствах имен `master` и `dev`. При необходимости дополнить Role/ClusterRole правилами на `verbs: ["get", "create", "delete", "patch"]` для ресурса `secrets` до включения параметров в проектных воркфлоу.
2. `ci(workflows): передать gradle_username и gradle_password в kaniko-build в thedevslk, shield-3, marta` — обновить шаги сборки `build.yml` микросервисов платформы, передав:
   ```yaml
   gradle_username: ${{ secrets.MAVEN_USERNAME }}
   gradle_password: ${{ secrets.MAVEN_PASSWORD }}
   ```
3. `security(build): удалить литералы 'zxcvzxcv' из build.gradle в thedevslk, shield-3, marta` — перевести все прикладные сервисы на каскадный стандарт TD-2218 без зашитых паролей в git:
   - В `thedevslk` (`build.gradle:25-31`): удалить литеральные фоллбэки `'thedevs'` и `'zxcvzxcv'`.
   - В `shield-3` (`build.gradle:25-29`) и `marta` (`build.gradle:25-29`): заменить голые литералы на каскад `project.findProperty('thedevsRepoUser') ?: project.findProperty('uploadUser') ?: ...`.
4. `security(nexus): ротация пароля учетной записи Nexus repo.thedevs.ru` — сменить скомпрометированный пароль `zxcvzxcv` учетной записи в Nexus и обновить секрет `MAVEN_PASSWORD` в организации `THEDEVS-RU`.
5. `docs(ci-standards): актуализация стандарта CI/CD в thedevs-plugins` — внести описание параметров `gradle_username` и `gradle_password` в `references/ci-standards.md` §1 и таблицу §4.

# Критерии готовности

1. В `actions/kaniko-build/action.yml` добавлены параметры `gradle_secret` (дефолт `''`), `gradle_username` (дефолт `''`), `gradle_password` (дефолт `''`).
2. В скрипте экшена реализована проверка входных данных:
   - При наличии символов перевода строки `\r` или `\n` в учетных данных шаг завершается с ошибкой `::error::` и кодом 1.
   - При неполной передаче пары (только `gradle_username` или только `gradle_password`) шаг падает с ошибкой `::error::Both gradle_username and gradle_password must be specified together.` и кодом 1.
   - При передаче обоих параметров активируется генерация временного секрета `${POD}-gradle`.
   - При передаче `gradle_secret` выполняется pre-flight проверка: `NotFound` вызывает ошибку `::error::` и код 1.
   - При отсутствии параметров `gradle_*` манифест пода сохраняет текущую структуру без изменений.
3. Временный секрет `${POD}-gradle` создается без передачи секретов в `argv` через `--from-file` из временного файла с `chmod 600` и экранированием `\` как `\\`, а временный файл немедленно удаляется.
4. Ошибка создания секрета проверяется по `PIPESTATUS[1]`: при ответе `Forbidden` шаг немедленно падает с диагностикой нехватки прав RBAC, при транзиентных ошибках выполняется повтор с backoff, при исчерпании попыток шаг завершается с `::error::`, а под Kaniko не создается.
5. На созданный временный секрет проставляется `ownerReferences` на созданный под Kaniko, что гарантирует удаление секрета Garbage Collector-ом Kubernetes даже при аварийном завершении раннера (`SIGKILL`).
6. Временный секрет `${POD}-gradle` удаляется через обработчик `trap cleanup_gradle_secrets EXIT INT TERM` по точному пути файла и имени секрета.
7. Значения `gradle_username` и `gradle_password` не отображаются в логах экшена и отсутствуют в манифесте pod YAML.
8. В манифесте пода секрет монтируется напрямую в контейнер `kaniko` как том `secret` с `defaultMode: 0400` и `volumeMount` в `/root/.gradle/gradle.properties` (`subPath: gradle.properties`, `readOnly: true`). Никаких init-контейнеров и томов `emptyDir` не создается.
9. Документация в `actions/kaniko-build/README.md` актуализирована с описанием новых параметров и требований к RBAC.
10. Тесты в `tests/test-kaniko-build.sh` дополнены проверками всех сценариев (парность, переносы строк, ошибка RBAC при создании секрета, fail-fast, создание и удаление секрета, отсутствие паролей в YAML и stdout/stderr).
11. Спецификация проходит валидацию `bash references/contracts/builder/tools/validate-spec-format.sh specs/2026-10-25-kaniko-build-gradle-secrets-mount.md` с кодом 0.

# Не трогать

1. Не изменять структуру существующих томов кэша (`shared-cache`, `project-cache`) и их точки монтирования `/root/.gradle/wrapper`, `/root/.gradle/caches`, `/root/.gradle/nodejs`, `/root/.npm`, `/root/.vaadin`.
2. Не изменять логику работы секрета реестра (`docker_secret`, `registry_token`, `thedevs-registry-secret`).
3. Не передавать пароли и секреты через сборочные аргументы `--build-arg` и через `env.value` контейнеров пода.
4. Не использовать сторонние init-контейнеры для генерации `gradle.properties` (монтирование выполняется напрямую через K8s Secret volume).
5. Не коммитить и не пушить изменения напрямую в ветки `dev`, `main`, `master`.
6. Не запускать сборку контейнеров или тестирование локально на раннере во время стадии arch.
