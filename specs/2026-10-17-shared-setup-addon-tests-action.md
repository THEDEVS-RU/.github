id: 2026-10-17-shared-setup-addon-tests-action
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: architectural
impl_model: opus
impl_effort: high

# Контекст

В рамках архитектуры сквозного тестирования аддонов TD-2039 требуется единый fleet-wide механизм запуска тестов прямых платформенных зависимостей (`ru.thedevs:*`) при сборке любого аддона экосистемы.

В соответствии с конвенцией организации `THEDEVS-RU/.github`, переиспользуемые CI-действия размещаются в репозитории `THEDEVS-RU/.github` по пути `actions/<name>/action.yml` (аналогично `actions/kaniko-build`, `actions/deploy-resolve`, `actions/ensure-lk-mcp-secret`).
Создание композитного действия `actions/setup-addon-tests` решает ключевые задачи:
1. **Устранение дублирования кода (DRY):** исключает размещение 27 локальных копий Gradle init-скрипта в репозиториях аддонов.
2. **Единая точка истины:** канонический скрипт `ci-addon-tests.init.gradle` хранится строго в каталоге экшена (`actions/setup-addon-tests/ci-addon-tests.init.gradle`) и используется через `${{ github.action_path }}`.
3. **Безопасность публикации и изоляция проектов:** скрипт регистрирует выделенную публикацию `javaMavenTests` (`<artifactId>-tests`) со своим независимым POM, не включая Gradle Module Metadata (GMM остается выключенным во всем флоте). Метаданные основного артефакта аддона не изменяются, исключая утечку `enforcedPlatform(libs.thedevsbom)` в прикладные проекты.
4. **Контрактное тестирование и CI в `.github`:** экшен покрывается сквозным контрактным тестом в `tests/test-setup-addon-tests.sh` и проверяется в workflow `.github/workflows/ci.yml`.

# Что сделать

## 1. Композитное действие `actions/setup-addon-tests/action.yml`

Создать манифест композитного действия `actions/setup-addon-tests/action.yml`:
```yaml
name: 'Setup Addon Tests Environment'
description: 'Provides canonical ci-addon-tests.init.gradle and configures test dependency execution environment'

outputs:
  init_script:
    description: 'Absolute path to canonical ci-addon-tests.init.gradle'
    value: ${{ steps.export.outputs.init_script }}

runs:
  using: 'composite'
  steps:
    - name: Export init script path
      id: export
      shell: bash
      run: |
        SCRIPT_PATH="${{ github.action_path }}/ci-addon-tests.init.gradle"
        if [ ! -f "$SCRIPT_PATH" ]; then
          echo "::error::Init script not found at $SCRIPT_PATH"
          exit 1
        fi
        echo "init_script=$SCRIPT_PATH" >> "$GITHUB_OUTPUT"
        echo "THEDEVS_ADDON_TESTS_INIT=$SCRIPT_PATH" >> "$GITHUB_ENV"
        echo "Canonical addon tests init script located at: $SCRIPT_PATH"
```

## 2. Канонический init-скрипт `actions/setup-addon-tests/ci-addon-tests.init.gradle`

Создать файл `actions/setup-addon-tests/ci-addon-tests.init.gradle`, реализующий:

### 2.1. Изолированная публикация `javaMavenTests` (`<artifactId>-tests`)
1. Регистрация выполняется лениво через `pluginManager.withPlugin('maven-publish')` и `pluginManager.withPlugin('java')`:
   - Для каждого подпроекта, не оканчивающегося на `-starter` и `-test`:
     - Идемпотентно регистрируется задача формирования тестового архива:
       ```groovy
       if (tasks.findByName('testJar') == null) {
           tasks.register('testJar', Jar) {
               archiveClassifier.set('tests')
               from sourceSets.test.output
           }
       }
       ```
     - В задачу `testJar` включается генерация дескриптора `META-INF/thedevs-test.properties`:
       - Если в `src/test` нет скомпилированных классов: пишется маркер `thedevs.tests.disabled=true`.
       - Если тесты присутствуют: записываются системные свойства и теги:
         - `thedevs.test.systemProperties.liquibase.duplicateFileMode=WARN`
         - `thedevs.test.systemProperties.spring.test.context.cache.maxSize=16`
         - `thedevs.test.excludeTags=hsql-pending`
         - Пользовательские свойства из `tasks.named('test', Test).get().systemProperties`.
     - В `publishing.publications` регистрируется отдельная публикация `javaMavenTests(MavenPublication)`:
       - `artifactId = "${archName}-tests"`
       - `artifact(tasks.named('testJar'))`
       - POM генерирует зависимости через `pom.withXml`:
         - Зависимость на основной модуль: `<dependency><groupId>${project.group}</groupId><artifactId>${archName}</artifactId><version>${project.version}</version><scope>compile</scope></dependency>`.
         - Зависимости времени выполнения тестов извлекаются с точными версиями из `configurations.testRuntimeClasspath.incoming.resolutionResult.allComponents`.
         - Исключаются платформенные BOM (`Category.REGULAR_PLATFORM` и `Category.ENFORCED_PLATFORM`, включая `thedevs-bom` и `jmix-bom`).
         - Зависимости на внутренние подпроекты (`ProjectDependency`, например `core-test`) записываются по их публикуемому артефакту (`archName`) с сохранением всех объявленных правил исключений (`exclusions`).
         - Для внешних зависимостей без версий в `build.gradle` (Spring Boot Starter Test, PostgreSQL, FlowUI Test Assist) в POM подставляется фактически разрешенная версия из `resolutionResult`.
2. `tasks.withType(GenerateModuleMetadata).configureEach { enabled = false }` — GMM принудительно отключен.

### 2.2. Разрешение графа зависимостей после завершения оценки проектов (`gradle.projectsEvaluated`)
1. Для исключения конфликта с плагином `io.jmix` (который добавляет `jmix-bom` в хуке `project.afterEvaluate`), разрешение зависимостей и регистрация задач `testAddon_*` откладывается до хука `gradle.projectsEvaluated`:
   ```groovy
   gradle.projectsEvaluated {
       // Выполняется строго после всех project.afterEvaluate, когда Jmix BOM уже добавлен в implementation
   }
   ```
2. Для основного модуля аддона (не являющегося `-starter` и `-test`):
   - Инспектируются прямые зависимости `configurations.runtimeClasspath.incoming.resolutionResult.root.dependencies`.
   - Отбираются `ResolvedDependencyResult`, группа которых начинается с `ru.thedevs`.
   - Исключаются BOM-платформы (проверка атрибута `Category.CATEGORY_ATTRIBUTE in [Category.REGULAR_PLATFORM, Category.ENFORCED_PLATFORM]`).
   - Исключаются подпроекты текущей сборки.
   - Зависимости `testImplementation` игнорируются.

### 2.3. Маппинг стартеров в модули тестов через граф зависимостей
1. Определение целевого модуля тестов выполняется без эвристического отрезания суффикса `-starter`:
   - Если прямая зависимость является стартером, в разрешенном графе инспектируются исходящие зависимости компонента стартера (`selected.dependencies`).
   - Находится дочерний модуль с той же группой и версией (например, для `tinkoff-starter` находится модуль `itink`, для `core-starter` — `core`, для `balance-starter` — `balance`).
   - Имя найденного модуля (`baseModule`) используется как целевое для тестов.
2. Целевые координаты тестового артефакта формируются с точной группой и версией из графа: `"${depGroup}:${baseModule}-tests:${depVersion}"`.

### 2.4. Генерация изолированных задач `testAddon_${baseModule}`
Для каждого найденного целевого модуля:
1. Создается конфигурация `addonTestClasspath_${baseModule}`:
   ```groovy
   def depConf = configurations.maybeCreate("addonTestClasspath_${baseModule}")
   depConf.canBeConsumed = false
   depConf.canBeResolved = true
   depConf.transitive = true
   dependencies.add(depConf.name, "${depGroup}:${baseModule}-tests:${depVersion}")
   depConf.shouldResolveConsistentlyWith(configurations.runtimeClasspath)
   ```
2. Создается задача `testAddon_${baseModule}` (тип `Test`):
   - Распаковка `${baseModule}-tests.jar` в `layout.buildDirectory.dir("addon-tests/${baseModule}/classes")`.
   - Если в `META-INF/thedevs-test.properties` указано `thedevs.tests.disabled=true`, задача регистрирует факт отсутствия тестов по дизайну и пропускает запуск.
   - `classpath`: артефакты `depConf` + `sourceSets.main.output` текущего модуля + `sourceSets.main.output` стартера текущего модуля (для применения автоконфигурации `@EnableAutoConfiguration`) + `configurations.runtimeClasspath`.
   - `sourceSets.test.output` текущего модуля исключен.
   - `testClassesDirs = layout.buildDirectory.dir("addon-tests/${baseModule}/classes")`.
   - Настройки: `useJUnitPlatform()`, `filter.failOnNoMatchingTests = false`.
   - Системные свойства и теги считываются из упакованного дескриптора.
   - Отчеты сохраняются в `test-results/testAddon_${baseModule}` и `reports/tests/testAddon_${baseModule}`.
3. Агрегирующая задача `testAddonDependencies`:
   - Зависит от всех задач `testAddon_*`.
   - Подключается к `check.dependsOn(testAddonDependencies)`.

### 2.5. Дифференцированная классификация ошибок и Strict Mode
1. Сетевые сбои (ConnectException, SocketTimeoutException), HTTP 401/403/500 вызывают `GradleException`.
2. Ошибка разрешения транзитивных зависимостей внутри `<baseModule>-tests`: завершает сборку ошибкой во всех режимах.
3. Отсутствие корневого артефакта `${baseModule}-tests` в репозитории:
   - В переходном режиме (Фазы 1–3): выводится `::warning::[TD-2039] Skipped dependency tests for '${depGroup}:${baseModule}': tests artifact not yet published (pre-rollout).`
   - В строгом режиме (`-Pthedevs.tests.strict=true`): сборка падает с ошибкой, требуя наличия опубликованного tests-артефакта.

## 3. Сквозной контрактный тест `tests/test-setup-addon-tests.sh`

Создать скрипт `tests/test-setup-addon-tests.sh`, выполняющий:
1. Создание локального файлового Maven-репозитория.
2. Сборку и публикацию фикстуры `upstream` с генерацией `upstream-tests.jar` и POM через `ci-addon-tests.init.gradle`.
3. Валидацию содержимого POM (отсутствие GMM, корректные версии, импорт зависимостей).
4. Запуск сборки фикстуры-потребителя `downstream` с резолвом `upstream-tests` и выполнением задачи `testAddonDependencies`.

## 4. Непрерывная интеграция `.github/workflows/ci.yml`

Создать рабочий процесс PR-чека `.github/workflows/ci.yml`:
```yaml
name: CI & Contract Tests

on:
  pull_request:
    branches: [dev, master]
  push:
    branches: [dev]

jobs:
  contract-tests:
    name: Contract Tests
    runs-on: master
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          java-version: '25'
          distribution: 'temurin'
      - name: Run Contract Tests
        run: bash tests/test-setup-addon-tests.sh
```

## Затрагиваемые файлы

1. `actions/setup-addon-tests/action.yml`
2. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
3. `tests/test-setup-addon-tests.sh`
4. `.github/workflows/ci.yml`

# Что уже есть

- Архитектура composite actions в `THEDEVS-RU/.github`: `actions/deploy-resolve`, `actions/kaniko-build`, `actions/ensure-lk-mcp-secret`.
- Настройки публикации в Nexus в шаблонах аддонов.

# Критерии готовности

1. Создано действие `actions/setup-addon-tests/action.yml`.
2. Создан канонический скрипт `actions/setup-addon-tests/ci-addon-tests.init.gradle` с регистрацией публикации `javaMavenTests`, хуком `gradle.projectsEvaluated`, маппингом стартеров по графу и отключенным GMM.
3. Создан end-to-end контрактный тест `tests/test-setup-addon-tests.sh`.
4. Создан рабочий процесс `.github/workflows/ci.yml`.
5. Спецификация валидируется `validate-spec-format.sh` с кодом 0.

# Не трогать

- Не изменять существующие экшены `actions/kaniko-build`, `actions/deploy-resolve`, `actions/ensure-lk-mcp-secret`.
- Не включать публикацию Gradle Module Metadata (`tasks.withType(GenerateModuleMetadata) { enabled = false }` сохраняется).
