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
4. **Контрактное тестирование и безопасность CI в `.github`:** экшен покрывается сквозным контрактным тестом в `tests/test-setup-addon-tests.sh` и проверяется в workflow `.github/workflows/ci.yml` строго на GitHub-hosted раннере `ubuntu-latest` с установкой Gradle 9.5.1 через `gradle/actions/setup-gradle@v4`. Использование self-hosted раннера `master` в публичном репозитории `THEDEVS-RU/.github` категорически запрещено политикой безопасности во избежание исполнения произвольного кода из форков.

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
1. Регистрация подключается лениво через `pluginManager.withPlugin('maven-publish')` и `pluginManager.withPlugin('java')`:
   - Отбор основных библиотечных подпроектов: подпроекты с плагинами `java` или `java-library`, чьи имена не оканчиваются на `-starter`, `-test` и `-app` (исключение `cryptocollector-app`).
   - Идемпотентно регистрируется задача формирования тестового архива `testJar` (тип `Jar`).
   - В `testJar` упаковывается дескриптор `META-INF/thedevs-test.properties`:
     - Если в `src/test` нет скомпилированных классов: пишется маркер `thedevs.tests.disabled=true`.
     - Если тесты присутствуют: записываются системные свойства и фильтры:
       - `thedevs.test.systemProperties.liquibase.duplicateFileMode=WARN`
       - `thedevs.test.systemProperties.spring.test.context.cache.maxSize=16`
       - `thedevs.test.excludeTags=hsql-pending`
       - Пользовательские свойства из `tasks.named('test', Test).get().systemProperties`.
   - В блоке `publishing.publications` регистрируется отдельная публикация `javaMavenTests(MavenPublication)`:
     - Определение `artifactId`: извлекается фактический `artifactId` публикации `javaMaven` (`publishing.publications.findByName('javaMaven')?.artifactId ?: project.name`), после чего формируется `artifactId = "${mainArtifactId}-tests"`. Это исключает расхождения для модулей с переопределенным именем (например, `itink-tests` для `addon-tinkoff`).
     - `artifact(tasks.named('testJar'))`
     - POM генерирует зависимости через `pom.withXml`:
       - Зависимость на основной модуль: `<dependency><groupId>${project.group}</groupId><artifactId>${mainArtifactId}</artifactId><version>${project.version}</version><scope>compile</scope></dependency>`.
       - Зависимости тестового рантайма извлекаются из `configurations.testRuntimeClasspath.incoming.resolutionResult.allComponents`. Для каждой зависимости проставляется реальная версия из `resolutionResult` (без подстановки версии проекта).
       - Исключаются платформы по атрибуту `Category.CATEGORY_ATTRIBUTE in [Category.REGULAR_PLATFORM, Category.ENFORCED_PLATFORM]` (включая `thedevs-bom` и `jmix-bom`).
       - Внутренние подпроекты (`ProjectDependency`, такие как `core-test`) записываются по их `archName` с сохранением объявленных `exclusions`.
2. `tasks.withType(GenerateModuleMetadata).configureEach { enabled = false }` — GMM принудительно отключен.

### 2.2. Разрешение графа зависимостей в `gradle.projectsEvaluated`
1. Инспекция графа и конфигурирование `testAddon_*` откладываются до `gradle.projectsEvaluated` (строго после `jmix.afterEvaluate`, добавляющего Jmix BOM в `implementation`), предотвращая сбои мутации конфигурации после резолва.
2. Для основного модуля аддона (не оканчивающегося на `-starter`, `-test` и `-app`):
   - Инспектируются прямые зависимости `configurations.runtimeClasspath.incoming.resolutionResult.root.dependencies`.
   - Отбираются зависимости (`ResolvedDependencyResult`) с группой `ru.thedevs*`.
   - Исключаются подпроекты текущей сборки и платформы (`Category.REGULAR_PLATFORM`, `Category.ENFORCED_PLATFORM`). Зависимости `testImplementation` игнорируются.

### 2.3. Маппинг стартеров по графу зависимостей
1. Если прямая зависимость является стартером, в разрешенном графе инспектируются ее исходящие зависимости (`selected.dependencies`).
2. Находится дочерний модуль с той же группой и версией (например, `tinkoff-starter -> itink`, `core-starter -> core`, `balance-starter -> balance`).
3. Имя найденного модуля (`baseModule`) используется для формирования координат: `"${depGroup}:${baseModule}-tests:${depVersion}"`.

### 2.4. Генерация изолированных задач `testAddon_${baseModule}` и объединенный Liquibase Changelog
Для каждого найденного целевого модуля:
1. Создается конфигурация `addonTestClasspath_${baseModule}` (`transitive = true`), согласованная через `shouldResolveConsistentlyWith(configurations.runtimeClasspath)`.
2. Создается объединенный master-changelog Liquibase `layout.buildDirectory.file("addon-tests/${baseModule}/aggregate-changelog.xml")`:
   - Включает changelog зависимости и changelog хостового модуля.
   - Путь передается в задачу через системное свойство `-Dmain.liquibase.change-log`, перекрывая одиночные пути тестовых конфигураций и обеспечивая создание таблиц как зависимости, так и хоста. Исключение автоконфигурации хоста категорически запрещено.
3. Создается задача `testAddon_${baseModule}` (тип `Test`):
   - Распаковка `${baseModule}-tests.jar` в `layout.buildDirectory.dir("addon-tests/${baseModule}/classes")`.
   - Проверка: если в `META-INF/thedevs-test.properties` указано `thedevs.tests.disabled=true`, задача регистрирует факт отсутствия тестов и завершается без запуска.
   - `classpath`: артефакты `addonTestClasspath_${baseModule}` + `sourceSets.main.output` текущего модуля + `sourceSets.main.output` стартера текущего модуля + `configurations.runtimeClasspath`.
   - `sourceSets.test.output` текущего модуля исключен.
   - Настройки: `useJUnitPlatform()`, `failOnNoDiscoveredTests = false`, `filter.failOnNoMatchingTests = false`.
   - Системные свойства и теги считываются из дескриптора зависимости, дополняясь `-Dmain.liquibase.change-log`.
   - Изолированные отчеты: `test-results/testAddon_${baseModule}` и `reports/tests/testAddon_${baseModule}`.
4. Агрегирующая задача `testAddonDependencies`:
   - Зависит от всех задач `testAddon_*`.
   - Подключается к `check.dependsOn(testAddonDependencies)`.

### 2.5. Дифференцированная классификация ошибок и Strict Mode
1. Сетевые ошибки (Timeout, Connection refused), HTTP 401/403/500 вызывают `GradleException`.
2. Ошибка разрешения транзитивных зависимостей внутри `<baseModule>-tests`: безусловный сбой сборки во всех режимах.
3. Отсутствие корневого артефакта `${baseModule}-tests`:
   - В Фазах 1–3: выводится `::warning::[TD-2039] Skipped dependency tests for '${depGroup}:${baseModule}': tests artifact not yet published (pre-rollout).`
   - В Фазе 4 (`-Pthedevs.tests.strict=true`): сборка завершается ошибкой, если зависимость не помечена маркером `thedevs.tests.disabled=true`.

## 3. Сквозной контрактный тест `tests/test-setup-addon-tests.sh`

Создать скрипт `tests/test-setup-addon-tests.sh`, выполняющий:
1. Создание локального файлового Maven-репозитория.
2. Сборку и публикацию фикстуры `upstream` с генерацией `upstream-tests.jar` и POM через `ci-addon-tests.init.gradle`.
3. Валидацию содержимого POM (отсутствие GMM, корректные версии, сохранение `exclusions`).
4. Запуск сборки фикстуры-потребителя `downstream` с плагином, мутирующим `implementation` в `project.afterEvaluate` (эмуляция `io.jmix`), проверку резолва `upstream-tests`, генерации объединенного changelog и выполнения `testAddonDependencies`.
5. Скрипт использует команду `gradle` из окружения `PATH`.

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
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          java-version: '25'
          distribution: 'temurin'
      - uses: gradle/actions/setup-gradle@v4
        with:
          gradle-version: '9.5.1'
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
- Конвенция размещения workflows в `THEDEVS-RU/.github`.

# Критерии готовности

1. Создано действие `actions/setup-addon-tests/action.yml`.
2. Создан канонический скрипт `actions/setup-addon-tests/ci-addon-tests.init.gradle` с регистрацией публикации `javaMavenTests`, фактическим `artifactId` из `javaMaven`, хуком `gradle.projectsEvaluated`, маппингом стартеров по графу, объединенным Liquibase changelog, `failOnNoDiscoveredTests = false` и отключенным GMM.
3. Создан end-to-end контрактный тест `tests/test-setup-addon-tests.sh` с проверкой устойчивости к `afterEvaluate`-мутациям конфигураций.
4. Создан рабочий процесс `.github/workflows/ci.yml` на GitHub-hosted раннере `ubuntu-latest` с установкой Gradle 9.5.1.
5. Спецификация валидируется `validate-spec-format.sh` с кодом 0.

# Не трогать

- Не запускать PR-чеки на self-hosted раннерах с меткой `master` в публичном репозитории `THEDEVS-RU/.github`.
- Не включать публикацию Gradle Module Metadata (`tasks.withType(GenerateModuleMetadata) { enabled = false }` сохраняется).
- Не изменять существующие экшены `actions/kaniko-build`, `actions/deploy-resolve`, `actions/ensure-lk-mcp-secret`.
