id: 2026-10-17-shared-setup-addon-tests-action
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
impl_model: sonnet
impl_effort: high

# Контекст

В рамках архитектуры сквозного тестирования аддонов TD-2039 требуется единый fleet-wide механизм запуска тестов прямых платформенных зависимостей (`ru.thedevs:*`) при сборке любого аддона экосистемы.

В соответствии с конвенцией организации `THEDEVS-RU/.github`, переиспользуемые CI-действия размещаются в репозитории `THEDEVS-RU/.github` по пути `actions/<name>/action.yml` (аналогично `actions/kaniko-build`, `actions/deploy-resolve`, `actions/ensure-lk-mcp-secret`).
Создание композитного действия `actions/setup-addon-tests` решает ключевые задачи:
1. **Устранение дублирования кода (DRY):** исключает размещение 27 локальных копий Gradle init-скрипта в репозиториях аддонов.
2. **Единая точка истины:** канонический скрипт `ci-addon-tests.init.gradle` хранится строго в каталоге экшена (`actions/setup-addon-tests/ci-addon-tests.init.gradle`) и используется через `${{ github.action_path }}`.
3. **Безопасность публикации и изоляция проектов:** скрипт регистрирует выделенную публикацию `javaMavenTests` (`<artifactId>-tests`) со своим независимым POM, не включая Gradle Module Metadata (GMM остается выключенным во всем флоте). Метаданные основного артефакта аддона не изменяются, исключая утечку `enforcedPlatform(libs.thedevsbom)` в прикладные проекты.

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
1. Для каждого подпроекта с плагином `java` или `java-library`:
   - Если в `src/test/java` (или `groovy`, `kotlin`) присутствуют скомпилированные исходные файлы тестов:
     - Идемпотентно регистрируется задача формирования тестового архива:
       ```groovy
       if (tasks.findByName('testJar') == null) {
           tasks.register('testJar', Jar) {
               archiveClassifier.set('tests')
               from sourceSets.test.output
           }
       }
       ```
     - В задачу `testJar` включается генерация дескриптора `META-INF/thedevs-test.properties` со свойствами из текущей задачи `test`:
       - `thedevs.test.systemProperties.liquibase.duplicateFileMode=WARN`
       - `thedevs.test.systemProperties.spring.test.context.cache.maxSize=16`
       - `thedevs.test.excludeTags=hsql-pending`
       - А также пользовательские системные свойства из `tasks.named('test', Test).get().systemProperties`.
     - В блоке `publishing.publications` регистрируется отдельная публикация `javaMavenTests(MavenPublication)`:
       - `artifactId = "${archName}-tests"`
       - `artifact(tasks.named('testJar'))`
       - POM генерирует зависимости на основной артефакт `${project.group}:${archName}:${project.version}` и зависимости из `configurations.testRuntimeClasspath` (исключая внутренние проектные классы и платформенные BOM).
2. `tasks.withType(GenerateModuleMetadata).configureEach { enabled = false }` — GMM принудительно остается выключенным во избежание конфликтов с `enforcedPlatform`.

### 2.2. Извлечение прямых зависимостей и маппинг стартеров
1. В хуке после оценки проекта (`afterEvaluate`) анализируются зависимости конфигурации времени выполнения `configurations.runtimeClasspath.incoming.resolutionResult.root.dependencies`.
2. Фильтруются только прямые производственные зависимости с группой `group.startsWith('ru.thedevs')`:
   - Исключаются подпроекты текущей мультимодульной сборки.
   - Исключаются платформенные BOM (`Category.CATEGORY_ATTRIBUTE == Category.REGULAR_PLATFORM` или артефакты без jar).
   - Зависимости из `testImplementation` игнорируются (исключение тестовых библиотек-утилит из тестирования контрактов).
3. Маппинг стартеров в модули тестов:
   - Если имя зависимости оканчивается на `-starter` (`${module}-starter`), целевым именем базового модуля тестов является `${module}` (например, `core-starter` -> `core`, `balance-starter` -> `balance`, `limiter-starter` -> `limiter`).
   - Имя тестового артефакта формируется по правилу: `"${depGroup}:${baseModule}-tests:${depVersion}"` с точными группой и версией из графа зависимостей.

### 2.3. Генерация изолированных задач `testAddon_${baseName}`
Для каждого найденного базового модуля зависимости:
1. Создается конфигурация `addonTestClasspath_${baseName}`:
   ```groovy
   def depConf = configurations.maybeCreate("addonTestClasspath_${baseName}")
   depConf.canBeConsumed = false
   depConf.canBeResolved = true
   depConf.transitive = true
   dependencies.add(depConf.name, "${depGroup}:${baseName}-tests:${depVersion}")
   depConf.shouldResolveConsistentlyWith(configurations.runtimeClasspath)
   ```
2. Создается задача типа `Test` с именем `testAddon_${baseName}`:
   - `testClassesDirs`: распакованные классы тестов из `${baseName}-tests.jar` в `layout.buildDirectory.dir("addon-tests/${baseName}/classes")`.
   - `classpath`: артефакты `depConf` + `sourceSets.main.output` текущего модуля + `sourceSets.main.output` стартер-модуля хоста (для применения автоконфигурации `@EnableAutoConfiguration`) + `configurations.runtimeClasspath`.
   - `sourceSets.test.output` текущего модуля в classpath **НЕ добавляется** (полная изоляция ресурсов и контекста).
   - Настройка тестового раннера: `useJUnitPlatform()`, `filter.failOnNoMatchingTests = false`.
   - Системные свойства и теги считываются из упакованного `META-INF/thedevs-test.properties` с платформенными значениями (`duplicateFileMode=WARN`, `spring.test.context.cache.maxSize=16`, `excludeTags 'hsql-pending'`).
   - Изолированные отчеты:
     - XML: `layout.buildDirectory.dir("test-results/testAddon_${baseName}")`
     - HTML: `layout.buildDirectory.dir("reports/tests/testAddon_${baseName}")`
3. Создается агрегирующая задача `testAddonDependencies`:
   - Зависит от всех зарегистрированных задач `testAddon_*`.
   - Включается в жизненный цикл: `check.dependsOn(testAddonDependencies)`.
   - Задача `test` остается независимой и быстрой для локального цикла разработки.

### 2.4. Дифференцированная обработка ошибок и Strict Mode
1. Сетевые ошибки (Timeout, Connection refused), HTTP 401/403/500 приводят к немедленному падению сборки с ошибкой `GradleException`.
2. Отсутствие тестового артефакта:
   - В обычном режиме (Фазы 1–3 раскатки): задача `testAddon_${baseName}` пропускается с выводом в лог и генерацией предупреждения `::warning::[TD-2039] Skipped dependency tests for '${depGroup}:${baseModule}': tests artifact not yet published (pre-rollout).`
   - В строгом режиме (`-Pthedevs.tests.strict=true`): сборка завершается с ошибкой, если зависимость не имеет явного маркера отсутствия тестов по дизайну (`thedevs.tests.disabled=true`).

## 3. Контрактный тест действия `tests/test-setup-addon-tests.sh`

Создать проверочный скрипт `tests/test-setup-addon-tests.sh`:
- Проверяет валидность синтаксиса `action.yml` и `ci-addon-tests.init.gradle`.
- Проверяет применение init-скрипта к тестовому мультимодульному проекту Gradle, создание задачи `testJar`, корректность регистрации публикации `javaMavenTests` и отключение GMM.

## Затрагиваемые файлы

1. `actions/setup-addon-tests/action.yml`
2. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
3. `tests/test-setup-addon-tests.sh`

# Что уже есть

- Архитектура composite actions в `THEDEVS-RU/.github`: `actions/deploy-resolve`, `actions/kaniko-build`, `actions/ensure-lk-mcp-secret`.
- Контрактные тесты шелл-скриптов и экшенов в `tests/`.

# Критерии готовности

1. Создано композитное действие `actions/setup-addon-tests/action.yml`.
2. Создан канонический инициализационный скрипт `actions/setup-addon-tests/ci-addon-tests.init.gradle`.
3. Создан контрактный тест `tests/test-setup-addon-tests.sh`.
4. Спецификация проходит валидацию `validate-spec-format.sh` с кодом 0.

# Не трогать

- Не изменять существующие экшены `actions/kaniko-build`, `actions/deploy-resolve`, `actions/ensure-lk-mcp-secret`.
- Не включать публикацию Gradle Module Metadata (`tasks.withType(GenerateModuleMetadata) { enabled = false }` должно строго соблюдаться).
