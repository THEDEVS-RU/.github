id: 2026-10-26-ci-addon-tests-exclude-host-autoconfigurations
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

При выполнении тестов зависимостей аддонов (`testAddon_*`) в Gradle-харнессе TD-2039 (`actions/setup-addon-tests/ci-addon-tests.init.gradle`) выходы стартера хостового проекта (`starterMainOutput`) и основного модуля (`p.sourceSets.main.output`) подключаются к `testAddon.classpath`.

Стартер хоста содержит дескриптор `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` (например, `ITINKAutoConfiguration` в `addon-tinkoff`). При запуске теста зависимого аддона (`BalFragmentsFlowUiSmokeTest` из `ru.thedevs.account:balance-tests`) Spring Boot выполняет автоконфигурацию `@EnableAutoConfiguration` и загружает автоконфигурацию стартера хоста. В результате импортируется конфигурация хоста (`ITINKConfiguration`), запускающая сканирование пакета хоста (`@ComponentScan ru.thedevs.integration.tinkoff`) и создающая бины хоста в контексте (в том числе SPI-провайдеры, такие как `TinkoffDepositUIProvider`).

При этом тестовое приложение зависимого аддона (`BalTestConfiguration`) конфигурирует Jmix метамодель и persistence unit только для своих собственных модулей (`@JmixModule(id = "ru.thedevs.account.balance.test")`) и не знает о модулях хоста. Когда SPI-бин хоста вызывается в ходе теста (например, `BalDepositUIProvider.isAvailable()`) и выполняет JPQL-запрос к своей JPA-сущности (`itink_AcquiringConnection`), происходит падение с ошибкой:
`JPQLException: The abstract schema type 'itink_AcquiringConnection' is unknown`.

В других аддонах (Uniteller, 1C) ошибка пока не проявляется только потому, что их реализации `isAvailable()` не обращаются к БД.

Попытка исключения через системное свойство `-Dspring.autoconfigure.exclude` имеет блокирующий дефект: в Spring Boot системные свойства обладают наивысшим приоритетом и монопольно перекрывают (а не дополняют) значения свойства `spring.autoconfigure.exclude` из тестовых файлов конфигураций зависимости (`application*.properties/yml`, например `addon-repository` объявляет исключение 7 классов).

Системным решением является физическая фильтрация ресурсов хоста на classpath `testAddon_*`: подключение классов хоста через `classesDirs`, а ресурсов хоста — через выделенную `Sync`-задачу `filterHostResources_${baseModule}`, которая копирует ресурсы хоста с исключением дескриптора `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`.

## Компромисс архитектурного решения
После исключения дескриптора автоконфигурации хоста из classpath задачи `testAddon_*` тесты зависимого аддона выполняются в чистом контексте зависимости и не валидируют сценарии переопределения бинов/SPI-провайдеров зависимости компонентами хоста.
Обоснование:
1. Тесты зависимого аддона (`testAddon_*`) запускаются исключительно для проверки совместимости версий транзитивных библиотек, согласованности объединенного classpath и корректности применения схемы БД (`aggregate-changelog.xml`).
2. Совместимость и работоспособность SPI-провайдеров хоста проверяется собственным тестовым набором хостового проекта (`:tinkoff:test`), где разворачивается полный Jmix-контекст с включением метамодели хоста.

# Что сделать

## 1. Фильтрация ресурсов хоста в `ci-addon-tests.init.gradle`

В файле `actions/setup-addon-tests/ci-addon-tests.init.gradle`:
1. Импортировать классы `org.gradle.api.file.DuplicatesStrategy` и `org.gradle.api.tasks.Sync`.
2. В блоке настройки задачи `testAddon` для каждого `baseModule`:
   - Определить выходы классов стартера `starterClassesDirs`:
     ```groovy
     def starterClassesDirs = (starterProject != null && starterProject.pluginManager.hasPlugin('java')) ?
         starterProject.sourceSets.main.output.classesDirs : p.files()
     ```
   - Зарегистрировать задачу синхронизации ресурсов `filterHostResources_${baseModule}` типа `Sync`:
     ```groovy
     def filterHostResourcesTaskName = "filterHostResources_${baseModule}"
     def filteredResourcesDir = p.layout.buildDirectory.dir("addon-tests/${baseModule}/host-resources")

     def filterHostResources = p.tasks.maybeCreate(filterHostResourcesTaskName, Sync)
     filterHostResources.destinationDir = filteredResourcesDir.get().asFile
     filterHostResources.duplicatesStrategy = DuplicatesStrategy.INCLUDE
     filterHostResources.from(p.tasks.named('processResources'))
     if (starterProject != null && starterProject.pluginManager.hasPlugin('java')) {
         filterHostResources.from(starterProject.tasks.named('processResources'))
     }
     filterHostResources.exclude 'META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports'
     ```
   - Добавить явную зависимость задачи тестирования:
     ```groovy
     testAddon.dependsOn(filterHostResources)
     ```
   - Заменить `p.sourceSets.main.output` и `starterMainOutput` в формировании `testAddon.classpath` на `classesDirs` и отфильтрованный каталог ресурсов:
     ```groovy
     testAddon.classpath = p.files({
         if (testState.skippedPreRollout || testState.testsDisabled) {
             return p.files()
         }
         return p.files(classesDir, aggregateFile.parentFile, filteredResourcesDir) +
                addonTestClasspath +
                p.sourceSets.main.output.classesDirs +
                starterClassesDirs +
                runtimeClasspath
     })
     ```
3. Не модифицировать системные свойства `spring.autoconfigure.exclude` в `testAddon.doFirst`, сохраняя исходные настройки и свойства зависимости без изменений.

## 2. Обновление контрактного теста `tests/test-setup-addon-tests.sh`

В файле `tests/test-setup-addon-tests.sh`:
1. В фикстуре `upstream` (`itink-mod`):
   - Добавить дескриптор `src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` со строкой `ru.thedevs.itink.ItinkAutoConfiguration`.
   - Добавить тестовое свойство в `src/test/resources/test-itink.properties`:
     `thedevs.test.systemProperties.spring.autoconfigure.exclude=ru.thedevs.itink.CustomExcludedAutoConfiguration`.
2. В фикстуре `downstream` (`consumer-starter`):
   - Добавить дескриптор `src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` со строкой `ru.thedevs.consumer.starter.ConsumerAutoConfiguration`.
3. В тестовом классе `ItinkTest.java` (запускаемом внутри `testAddon_itink` потребителя) реализовать проверки:
   - Проверка (а): через `ClassLoader.getResources("META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports")` подтвердить, что дескриптор хоста `ru.thedevs.consumer.starter.ConsumerAutoConfiguration` отсутствует на classpath, а дескриптор зависимости `ru.thedevs.itink.ItinkAutoConfiguration` присутствует.
   - Проверка (б): через `Class.forName("ru.thedevs.consumer.starter.ConsumerAutoConfiguration")` подтвердить, что классы хоста сохраняются и успешно загружаются из classpath.
   - Проверка (в): подтвердить сохранение собственных исключений зависимости (`CustomExcludedAutoConfiguration`), переданных через `thedevs-test.properties`, без затирания системным свойством хоста.

## Затрагиваемые файлы

1. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
2. `tests/test-setup-addon-tests.sh`

# Что уже есть

- Архитектура изоляции тестов зависимостей TD-2039: `actions/setup-addon-tests/ci-addon-tests.init.gradle`.
- Задача `processResources` и свойство `sourceSets.main.output.classesDirs` в Gradle Java plugin.
- Сквозной контрактный тест `tests/test-setup-addon-tests.sh`.

## Проверенные API

- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:15`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:599`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:605`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:612`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:628`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:634`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:53`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:373`
- `THEDEVS-RU/.github@dev:.github/workflows/ci.yml:28`

# Критерии готовности

1. В `actions/setup-addon-tests/ci-addon-tests.init.gradle` зарегистрирована `Sync`-задача `filterHostResources_${baseModule}`, исключающая дескриптор `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` из ресурсов хоста (`p` и `starterProject`).
2. В `testAddon.classpath` подключаются `p.sourceSets.main.output.classesDirs`, `starterClassesDirs` и каталог отфильтрованных ресурсов `host-resources/` вместо прямых `p.sourceSets.main.output` и `starterMainOutput`. Системное свойство `spring.autoconfigure.exclude` не выставляется принудительно и не затирает свойства зависимости.
3. В `tests/test-setup-addon-tests.sh` реализована сквозная верификация: (а) отсутствие дескриптора автоконфигурации хоста при сохранении дескриптора зависимости; (б) доступность классов хоста через `Class.forName`; (в) сохранение собственных исключений зависимости.
4. Спецификация валидируется `validate-spec-format.sh` с кодом 0.
5. Верификация после доставки в `dev`: перезапуск CI на PR THEDEVS-RU/addon-tinkoff#11 подтверждает успешный статус задачи `:tinkoff:testAddon_balance` без изменений в продуктовом коде `addon-tinkoff`, а также отсутствие регрессий тестов зависимостей в других аддонах (`addon-1c`, `addon-uniteller`, `addon-balance`).

# Не трогать

- Не исключать скомпилированные классы хоста (`p.sourceSets.main.output.classesDirs`, `starterClassesDirs`) из `testAddon.classpath` во избежание потери проверки совместимости типов и версий транзитивных библиотек.
- Не изменять логику генерации объединенного `aggregate-changelog.xml` и системных свойств Liquibase.
- Не модифицировать тестовые конфигурации и классы внутри продуктовых репозиториев аддонов (`addon-balance`, `addon-tinkoff`, `addon-uniteller`, `addon-1c`).
- Не включать публикацию Gradle Module Metadata (`GenerateModuleMetadata.enabled = false` сохраняется).
