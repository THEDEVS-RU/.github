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

В других аддонах (Uniteller, 1C) ошибка пока не проявляется только потому, что их реализации `isAvailable()` не обращаются к БД. Для обеспечения изоляции и согласованности контекста тестов зависимостей требуется исключать автоконфигурации стартера хоста из контекста выполнения `testAddon_*` через системное свойство `spring.autoconfigure.exclude`.

# Что сделать

## 1. Сбор и исключение автоконфигураций хоста в `ci-addon-tests.init.gradle`

В файле `actions/setup-addon-tests/ci-addon-tests.init.gradle`:
1. Добавить вспомогательную функцию `resolveHostAutoConfigurations(Project p, Project starterProject)`, сканирующую проект `p`, `starterProject` и любые `-starter` подпроекты `p.rootProject`, относящиеся к хосту.
2. Функция проверяет каталоги ресурсов (`sourceSets.main.resources.srcDirs`, а также `sourceSets.main.output.resourcesDir` и `sourceSets.main.output.classesDirs` при их наличии) на наличие файлов:
   - `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`: построчное чтение в кодировке UTF-8 с отсечением комментариев `#` и пропуском пустых строк;
   - `META-INF/spring.factories`: чтение свойства `org.springframework.boot.autoconfigure.EnableAutoConfiguration` с разделением по запятой и триммингом.
3. Собранные классы автоконфигураций собираются в `LinkedHashSet<String> hostAutoConfigs`.
4. В конфигурации задачи `testAddon`:
   - Зарегистрировать входное свойство задачи:
     ```groovy
     testAddon.inputs.property("hostAutoConfigurations", hostAutoConfigs.join(','))
     ```
   - В блоке `testAddon.doFirst`:
     - Собрать итоговый набор исключений `excludes = new LinkedHashSet<String>()`.
     - Добавить в `excludes` классы из `hostAutoConfigs`.
     - Проверить наличие системного свойства `spring.autoconfigure.exclude` в `thedevs-test.properties` зависимости: при наличии разбить по запятой и добавить в `excludes`.
     - Проверить существующее значение `testAddon.systemProperties['spring.autoconfigure.exclude']`: при наличии разбить по запятой и добавить в `excludes`.
     - Если `!excludes.isEmpty()`, выставить системное свойство:
       ```groovy
       testAddon.systemProperty('spring.autoconfigure.exclude', excludes.join(','))
       println "[TD-2499] Excluded host autoconfigurations for '${testTaskName}': ${excludes.join(', ')}"
       ```

## 2. Обновление контрактного теста `tests/test-setup-addon-tests.sh`

В файле `tests/test-setup-addon-tests.sh`:
1. В фикстуре `downstream` (`consumer-starter`) добавить генерацию файла ресурсов:
   `src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
   со строкой `ru.thedevs.consumer.starter.ConsumerAutoConfiguration`.
2. В тестовом классе `ItinkTest.java` (запускаемом внутри `testAddon_itink` потребителя) добавить проверку:
   ```java
   String exclude = System.getProperty("spring.autoconfigure.exclude");
   assertNotNull(exclude, "spring.autoconfigure.exclude must be set");
   assertTrue(exclude.contains("ru.thedevs.consumer.starter.ConsumerAutoConfiguration"),
       "Host autoconfiguration must be excluded: " + exclude);
   ```
3. Убедиться, что при выполнении `testAddonDependencies` в `consumer-mod` тестовая задача успешно запускается и подтверждает передачу системного свойства `spring.autoconfigure.exclude` с исключением `ConsumerAutoConfiguration`.

## Затрагиваемые файлы

1. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
2. `tests/test-setup-addon-tests.sh`

# Что уже есть

- Архитектура изоляции тестов зависимостей TD-2039: `actions/setup-addon-tests/ci-addon-tests.init.gradle`.
- Механизм передачи системных свойств через `thedevs-test.properties` и `testAddon.systemProperty`.
- Сквозной контрактный тест `tests/test-setup-addon-tests.sh`.

## Проверенные API

- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:599`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:605`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:612`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:628`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:634`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:53`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:373`
- `THEDEVS-RU/.github@dev:.github/workflows/ci.yml:28`

# Критерии готовности

1. В `actions/setup-addon-tests/ci-addon-tests.init.gradle` реализован сбор автоконфигураций хоста из `AutoConfiguration.imports` и `spring.factories` проектов `p` и `starterProject`.
2. Задача `testAddon_*` передает системное свойство `spring.autoconfigure.exclude` со списком автоконфигураций хоста, объединенным с исключениями из `thedevs-test.properties` зависимости.
3. В `tests/test-setup-addon-tests.sh` фикстура `consumer-starter` содержит `AutoConfiguration.imports`, а тест `ItinkTest` верифицирует наличие `ConsumerAutoConfiguration` в системном свойстве `spring.autoconfigure.exclude`.
4. Спецификация валидируется `validate-spec-format.sh` с кодом 0.

# Не трогать

- Не исключать `starterMainOutput` и `p.sourceSets.main.output` из `testAddon.classpath` во избежание потери проверки совместимости классов хоста и версий транзитивных библиотек.
- Не изменять логику генерации объединенного `aggregate-changelog.xml` и системных свойств Liquibase.
- Не модифицировать тестовые конфигурации и классы внутри продуктовых репозиториев аддонов (`addon-balance`, `addon-tinkoff`, `addon-uniteller`, `addon-1c`).
- Не включать публикацию Gradle Module Metadata (`GenerateModuleMetadata.enabled = false` сохраняется).
