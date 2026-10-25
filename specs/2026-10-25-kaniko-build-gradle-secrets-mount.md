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

Сборка Docker-образов микросервисов платформы TheDevs выполняется в изолированных подах Kaniko в Kubernetes-кластере с помощью composite action `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:1`. В сборочных Dockerfile (`thedevslk`, `marta`, `shield-3`) ключевым этапом является сборка JAR-артефакта командой `RUN ./gradlew bootJar --no-daemon`.

При сборке микросервисы зависят от платформенных аддонов (`ru.thedevs.*`), публикуемых в закрытый репозиторий snapshot-артефактов платформы `https://repo.thedevs.ru/repository/thedevs-snapshot/`. Доступ к данному репозиторию требует обязательной аутентификации.

В текущей инфраструктуре экшен `kaniko-build` монтирует постоянные тома кэша (`shared-cache` и `project-cache` в `/root/.gradle/caches`, `/root/.gradle/wrapper`, `/root/.gradle/nodejs`), но не поддерживает монтирование секретов с учетными данными для Gradle.

Из-за отсутствия механизма безопасного проброса секретов разработчики были вынуждены:
1. Зашивать учетные данные (`username = 'thedevs'`, `password = 'zxcvzxcv'`) непосредственно в сборочные скрипты `build.gradle` (`THEDEVS-RU/thedevslk@dev:build.gradle:22`, `THEDEVS-RU/shield-3@dev:build.gradle:22`);
2. Использовать комментарии вида `// Read-only Nexus account; literal fallback required — kaniko Docker build has no CI env/props`.

Это создает серьезные риски утечки учетных данных и нарушает стандарты безопасности платформы. Передача секретов через аргументы сборки Dockerfile (`--build-arg`) также неприемлема, поскольку аргументы сохраняются в истории слоев Docker-образа и открыто отображаются в метаданных сборочного пода.

Задача TD-2442 предписывает реализовать в composite action `actions/kaniko-build` поддержку безопасного монтирования Kubernetes Secret с учетными данными Gradle (`MAVEN_USERNAME`, `MAVEN_PASSWORD` / `uploadUser`, `uploadPassword`) в сборочный под Kaniko для скачивания snapshot-зависимостей из закрытого репозитория `repo.thedevs.ru/repository/thedevs-snapshot` без сохранения паролей в git и Dockerfile.

# Что сделать

## Затрагиваемые файлы

- `actions/kaniko-build/action.yml`
- `actions/kaniko-build/README.md`
- `tests/test-kaniko-build.sh`

## 1. Новые входные параметры (inputs) в `actions/kaniko-build/action.yml`

Добавить в секцию `inputs` файла `actions/kaniko-build/action.yml`:

```yaml
  gradle_secret:
    description: 'Secret name with Gradle credentials for private repositories (repo.thedevs.ru). Default: thedevs-gradle-secret.'
    required: false
    default: 'thedevs-gradle-secret'
  gradle_username:
    description: 'Optional username for Gradle private repository auth (overrides/supplements gradle_secret)'
    required: false
    default: ''
  gradle_password:
    description: 'Optional password/token for Gradle private repository auth (overrides/supplements gradle_secret)'
    required: false
    default: ''
```

В секцию `runs.steps[0].env` добавить проброс переменных:

```yaml
        INPUT_GRADLE_SECRET: ${{ inputs.gradle_secret }}
        INPUT_GRADLE_USERNAME: ${{ inputs.gradle_username }}
        INPUT_GRADLE_PASSWORD: ${{ inputs.gradle_password }}
```

## 2. Pre-flight верификация и Fail-Fast логика для секрета Gradle

В начале bash-скрипта экшена (`run:`), по аналогии с проверкой секрета реестра `docker_secret`, добавить проверку существования секрета Gradle в целевом namespace:

```bash
        GRADLE_SECRET="${INPUT_GRADLE_SECRET:-thedevs-gradle-secret}"
        GRADLE_USERNAME="${INPUT_GRADLE_USERNAME:-}"
        GRADLE_PASSWORD="${INPUT_GRADLE_PASSWORD:-}"

        GRADLE_SECRET_ENABLED=0
        GRADLE_SECRET_FOUND=0

        if [ -n "$GRADLE_SECRET" ]; then
          echo "Verifying gradle secret '$GRADLE_SECRET' in namespace '$NS'..."
          GRADLE_SECRET_ERR=$(kubectl -n "$NS" get secret "$GRADLE_SECRET" --request-timeout=15s 2>&1 >/dev/null || true)
          if [ -n "$GRADLE_SECRET_ERR" ]; then
            if printf '%s' "$GRADLE_SECRET_ERR" | grep -F -q 'NotFound'; then
              if [ -n "$GRADLE_PASSWORD" ]; then
                echo "::warning::Gradle secret '$GRADLE_SECRET' not found in namespace '$NS', but gradle_password is provided — proceeding with token auth"
                GRADLE_SECRET_ENABLED=1
                GRADLE_SECRET_FOUND=0
              elif [ "$GRADLE_SECRET" != "thedevs-gradle-secret" ]; then
                echo "::error::Gradle secret '$GRADLE_SECRET' specified but not found in namespace '$NS'"
                exit 1
              else
                echo "::warning::Default Gradle secret '$GRADLE_SECRET' not found in namespace '$NS' (proceeding without Gradle secret mount)"
                GRADLE_SECRET_ENABLED=0
                GRADLE_SECRET_FOUND=0
              fi
            else
              echo "::warning::Could not verify secret '$GRADLE_SECRET' in namespace '$NS' (proceeding with optional volume): $GRADLE_SECRET_ERR"
              GRADLE_SECRET_ENABLED=1
              GRADLE_SECRET_FOUND=1
            fi
          else
            GRADLE_SECRET_ENABLED=1
            GRADLE_SECRET_FOUND=1
          fi
        elif [ -n "$GRADLE_PASSWORD" ]; then
          GRADLE_SECRET_ENABLED=1
          GRADLE_SECRET_FOUND=0
        fi
```

### Поведение верификации:
1. **Секрет найден в namespace:** `GRADLE_SECRET_ENABLED=1`, `GRADLE_SECRET_FOUND=1` — секрет монтируется в под.
2. **Секрет не найден (`NotFound`):**
   - Если передан `gradle_password`: выводится предупреждение, `GRADLE_SECRET_ENABLED=1`, аутентификация осуществляется по переданному паролю/токену.
   - Если задан нестандартный `gradle_secret` (пользователь явно указал имя секрета): немедленный отказ с `::error::` и кодом 1 (Fail-Fast).
   - Если использован секрет по умолчанию (`thedevs-gradle-secret`) и пароль не передан: выводится предупреждение `::warning::`, сборка продолжается без монтирования секрета Gradle (`GRADLE_SECRET_ENABLED=0`). Это гарантирует 100% обратную совместимость для сборок, не использующих Gradle или приватный snapshot-репозиторий.
3. **Отказ доступа RBAC или сетевой сбой:** носит рекомендательный характер, под пытается смонтировать том с `optional: true`.

## 3. Синтез конфигурации Gradle через initContainer `prepare-gradle-config`

При `GRADLE_SECRET_ENABLED=1` в спецификацию пода добавляется легковесный init-контейнер `prepare-gradle-config` (образ `busybox:1.36`, лимиты 64Mi RAM / 100m CPU):
- Монтирует исходный K8s-секрет в `/gradle-secret-orig` (readOnly, `optional: true`);
- Монтирует пустой том `emptyDir` `gradle-config` в `/gradle-config`;
- Разрешает учетные данные из всех стандартных ключей секрета:
  - Имя пользователя: `INPUT_GRADLE_USERNAME` -> `/gradle-secret-orig/MAVEN_USERNAME` -> `/gradle-secret-orig/uploadUser` -> `/gradle-secret-orig/thedevsRepoUser` -> дефолт `thedevs`.
  - Пароль: `INPUT_GRADLE_PASSWORD` -> `/gradle-secret-orig/MAVEN_PASSWORD` -> `/gradle-secret-orig/uploadPassword` -> `/gradle-secret-orig/thedevsRepoPassword`.
- Если в секрете передан готовый файл `gradle.properties`, он копируется в `/gradle-config/gradle.properties`.
- При наличии учетных данных дополняет `/gradle-config/gradle.properties` платформенными свойствами:
  ```properties
  uploadUser=<user>
  uploadPassword=<pass>
  thedevsRepoUser=<user>
  thedevsRepoPassword=<pass>
  systemProp.MAVEN_USERNAME=<user>
  systemProp.MAVEN_PASSWORD=<pass>
  systemProp.uploadUser=<user>
  systemProp.uploadPassword=<pass>
  ```
- Генерирует универсальный скрипт инициализации `/gradle-config/init.d/thedevs-repository.init.gradle`, который через хук `afterEvaluate` динамически внедряет учетные данные во все Maven-репозитории с URL, содержащим `repo.thedevs.ru`:
  ```groovy
  gradle.allprojects { project ->
      project.afterEvaluate { p ->
          p.repositories.all { repo ->
              if (repo instanceof org.gradle.api.artifacts.repositories.MavenArtifactRepository) {
                  def u = repo.url ? repo.url.toString() : ''
                  if (u.contains('repo.thedevs.ru')) {
                      def user = p.findProperty('uploadUser') ?: p.findProperty('thedevsRepoUser') ?: 'thedevs'
                      def pass = p.findProperty('uploadPassword') ?: p.findProperty('thedevsRepoPassword')
                      if (user && pass) {
                          repo.credentials {
                              username = user.toString()
                              password = pass.toString()
                          }
                      }
                  }
              }
          }
      }
  }
  gradle.settingsEvaluated { settings ->
      try {
          settings.dependencyResolutionManagement?.repositories?.all { repo ->
              if (repo instanceof org.gradle.api.artifacts.repositories.MavenArtifactRepository) {
                  def u = repo.url ? repo.url.toString() : ''
                  if (u.contains('repo.thedevs.ru')) {
                      def user = settings.findProperty('uploadUser') ?: settings.findProperty('thedevsRepoUser') ?: 'thedevs'
                      def pass = settings.findProperty('uploadPassword') ?: settings.findProperty('thedevsRepoPassword')
                      if (user && pass) {
                          repo.credentials {
                              username = user.toString()
                              password = pass.toString()
                          }
                      }
                  }
              }
          }
      } catch (Throwable ignored) {}
  }
  ```
  Скрипт не содержит захардкоженных секретов и читает значения из свойств проекта, загруженных из `gradle.properties`.
- Выставляет права `chmod 644` на сгенерированные файлы конфигурации.

## 4. Монтирование конфигурации в контейнер Kaniko

В контейнере `kaniko` манифеста пода при `GRADLE_SECRET_ENABLED=1`:
1. В `volumeMounts` добавляются точечные монтирования из тома `gradle-config`:
   ```yaml
   - name: gradle-config
     mountPath: /root/.gradle/gradle.properties
     subPath: gradle.properties
   - name: gradle-config
     mountPath: /root/.gradle/init.d/thedevs-repository.init.gradle
     subPath: init.d/thedevs-repository.init.gradle
   ```
2. В `volumes` пода добавляются:
   ```yaml
   - name: gradle-secret-orig
     secret:
       secretName: $GRADLE_SECRET
       optional: true
   - name: gradle-config
     emptyDir: {}
   ```
   Если K8s-секрет не найден, но задан `gradle_password`, том `gradle-secret-orig` создается как `emptyDir: {}`.

При сборке в Kaniko:
- Файлы монтируются в домашний каталог пользователя root (`/root/.gradle/`), используемый сборщиком Java/Gradle во всех Dockerfile платформы;
- Тома монтируются изолированно от существующих кэшей (`/root/.gradle/wrapper`, `/root/.gradle/nodejs`, `/root/.gradle/caches`), не конфликтуя с ними;
- Тома Kaniko исключаются из снимков файловой системы при формировании слоев Docker-образа — учетные данные никогда не попадают в результирующий образ.

## 5. Документация в `actions/kaniko-build/README.md`

Обновить `actions/kaniko-build/README.md`:
- Добавить параметры `gradle_secret`, `gradle_username`, `gradle_password` в таблицу входных параметров;
- Описать работу pre-flight проверки для секрета Gradle и поддерживаемые форматы ключей K8s-секрета (`MAVEN_USERNAME`/`MAVEN_PASSWORD`, `uploadUser`/`uploadPassword`, `thedevsRepoUser`/`thedevsRepoPassword`, `gradle.properties`);
- Привести примеры вызова экшена с K8s-секретом и с передачей секретов из GitHub Secrets.

## 6. Контрактные тесты в `tests/test-kaniko-build.sh`

Добавить в тестовый набор `tests/test-kaniko-build.sh` сценарии валидации:
1. Генерация манифеста пода при существующем `thedevs-gradle-secret` (наличие `initContainers` `prepare-gradle-config`, volumeMounts в `/root/.gradle/gradle.properties` и `/root/.gradle/init.d/...`);
2. Обработка отсутствующего дефолтного секрета `thedevs-gradle-secret` (предупреждение, сборка продолжается без монтирования);
3. Fail-Fast при явном указании несуществующего секрета `gradle_secret` (ошибка и ненулевой код возврата);
4. Аутентификация по переданному токену `gradle_password` при отсутствии K8s-секрета;
5. Отключение монтирования при явном `gradle_secret: ''`.

# Что уже есть

1. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:23` — рабочий composite action запуска Kaniko в Kubernetes с кэшированием томов (`shared-cache`, `project-cache`), поддержкой `docker_secret`, pre-flight проверкой и init-контейнером `merge-docker-config`.
2. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:438-452` — отработанная схема монтирования подкаталогов кэша в `/root/.gradle/wrapper`, `/root/.gradle/nodejs` и `/root/.gradle/caches`.
3. `THEDEVS-RU/.github@dev:tests/test-kaniko-build.sh:1` — модульный тестовый раннер на Bash для проверки генерации манифестов пода Kaniko без обращения к реальному кластеру.
4. `THEDEVS-RU/addon-browser@dev:build.gradle:27` — платформенный стандарт каскадного разрешения учетных данных Gradle (TD-2218).

## Проверенные API

1. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:20` — объявление параметра `docker_secret` с `default: 'thedevs-registry-secret'`.
2. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:276` — вызов pre-flight проверки секретов через `kubectl -n "$NS" get secret "$SECRET" --request-timeout=15s`.
3. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:317` — конфигурация initContainer `merge-docker-config` с образом `busybox:1.36` и лимитами ресурсов 64Mi / 100m.
4. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:438` — объявление volumeMounts кэша `/root/.gradle/wrapper`, `/root/.gradle/nodejs`, `/root/.gradle/caches`.
5. `THEDEVS-RU/.github@dev:actions/kaniko-build/action.yml:457` — монтирование опционального тома секрета `secretName: $SECRET`, `optional: true`.
6. `THEDEVS-RU/thedevslk@dev:build.gradle:22` — конфигурация репозитория `https://repo.thedevs.ru/repository/thedevs-snapshot/` с аутентификацией `uploadUser`/`uploadPassword`/`thedevsRepoUser`/`thedevsRepoPassword`.
7. `THEDEVS-RU/addon-browser@dev:build.gradle:27` — стандарт каскадного разрешения учетных данных приватных репозиториев (TD-2218).
8. `THEDEVS-RU/thedevs-plugins@dev:shared/builder/references/ci-standards.md:15` — платформенный регламент сборки образов через Kaniko в Kubernetes.

# Критерии готовности

1. В `actions/kaniko-build/action.yml` добавлены входные параметры `gradle_secret` (со значением по умолчанию `'thedevs-gradle-secret'`), `gradle_username` (по умолчанию `''`) и `gradle_password` (по умолчанию `''`).
2. В скрипте экшена реализована pre-flight проверка секрета Gradle в целевом namespace через `kubectl get secret`:
   - При наличии секрета или передаче `gradle_password` активируется флаг `GRADLE_SECRET_ENABLED=1`;
   - При отсутствии дефолтного секрета `thedevs-gradle-secret` (и отсутствии пароля) выводится предупреждение, сборка не блокируется (`GRADLE_SECRET_ENABLED=0`);
   - При явном указании несуществующего секрета шаг завершается с ошибкой `::error::` и кодом 1.
3. В манифесте пода при `GRADLE_SECRET_ENABLED=1`:
   - Присутствует init-контейнер `prepare-gradle-config` на базе `busybox:1.36`, корректно извлекающий учетные данные из ключей `MAVEN_USERNAME`/`MAVEN_PASSWORD`, `uploadUser`/`uploadPassword`, `thedevsRepoUser`/`thedevsRepoPassword` или исходного `gradle.properties`;
   - Сгенерированный файл `/root/.gradle/gradle.properties` содержит свойства `uploadUser`, `uploadPassword`, `thedevsRepoUser`, `thedevsRepoPassword`, `systemProp.MAVEN_USERNAME`, `systemProp.MAVEN_PASSWORD`;
   - Сгенерированный скрипт `/root/.gradle/init.d/thedevs-repository.init.gradle` внедряет аутентификацию в репозитории `repo.thedevs.ru` через `afterEvaluate`;
   - Файлы монтируются в контейнер `kaniko` по путям `/root/.gradle/gradle.properties` и `/root/.gradle/init.d/thedevs-repository.init.gradle` через том `emptyDir`.
4. При `GRADLE_SECRET_ENABLED=0` манифест пода сохраняет текущую структуру без лишних init-контейнеров и томов.
5. Файл `actions/kaniko-build/README.md` дополнен описанием новых параметров, pre-flight проверки и примерами использования.
6. В `tests/test-kaniko-build.sh` добавлены тесты для всех сценариев работы с секретом Gradle.
7. Спецификация успешно проходит валидацию `bash references/contracts/builder/tools/validate-spec-format.sh specs/2026-10-25-kaniko-build-gradle-secrets-mount.md` с кодом 0.

# Не трогать

1. Не изменять структуру существующих томов кэша (`shared-cache`, `project-cache`) и их точки монтирования `/root/.gradle/wrapper`, `/root/.gradle/caches`, `/root/.gradle/nodejs`, `/root/.npm`, `/root/.vaadin`.
2. Не изменять логику работы секрета реестра (`docker_secret`, `registry_token`, `thedevs-registry-secret`).
3. Не передавать пароли и секреты через сборочные аргументы `--build-arg` (защита от сохранения в истории слоев образа).
4. Не коммитить и не пушить изменения напрямую в ветки `dev`, `main`, `master`.
5. Не запускать сборку контейнеров или тестирование локально на раннере во время стадии arch.
