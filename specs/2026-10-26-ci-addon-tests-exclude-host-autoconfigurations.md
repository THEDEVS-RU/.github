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

Системным решением является физическая фильтрация ресурсов хоста на classpath `testAddon_*`: подключение классов хоста через `classesDirs`, а ресурсов хоста — через выделенные `Sync`-задачи фильтрации ресурсов основного модуля и стартера в изолированные каталоги (`host-resources/main` и `host-resources/starter`), которые копируют ресурсы хоста с исключением дескриптора `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`. Разделение каталогов исключает риск взаимной перезаписи одинаковых ресурсов (например, `META-INF/services/*`).

## Компромисс архитектурного решения
После исключения дескриптора автоконфигурации хоста из classpath задачи `testAddon_*` тесты зависимого аддона выполняются в чистом контексте зависимости и не валидируют сценарии переопределения бинов/SPI-провайдеров зависимости компонентами хоста.
Обоснование:
1. Тесты зависимого аддона (`testAddon_*`) запускаются исключительно для проверки совместимости версий транзитивных библиотек, согласованности объединенного classpath и корректности применения схемы БД (`aggregate-changelog.xml`).
2. Совместимость и работоспособность SPI-провайдеров хоста проверяется собственным тестовым набором хостового проекта (`:tinkoff:test`), где разворачивается полный Jmix-контекст с включением метамодели хоста.

# Что сделать

## 1. Фильтрация ресурсов хоста в `ci-addon-tests.init.gradle`

В файле `actions/setup-addon-tests/ci-addon-tests.init.gradle` (в блоке `gradle.projectsEvaluated`):
1. Импортировать класс `org.gradle.api.tasks.Sync`.
2. В блоке настройки задачи `testAddon` для каждого `baseModule`:
   - Определить выходы классов стартера `starterClassesDirs`:
     ```groovy
     def starterClassesDirs = (starterProject != null && starterProject.pluginManager.hasPlugin('java')) ?
         starterProject.sourceSets.main.output.classesDirs : p.files()
     ```
   - Зарегистрировать задачу синхронизации ресурсов основного модуля `filterHostMainResources_${baseModule}` типа `Sync`:
     ```groovy
     def mainResDir = p.layout.buildDirectory.dir("addon-tests/${baseModule}/host-resources/main")
     def filterHostMainResources = p.tasks.maybeCreate("filterHostMainResources_${baseModule}", Sync)
     filterHostMainResources.destinationDir = mainResDir.get().asFile
     filterHostMainResources.from(p.tasks.named('processResources'))
     filterHostMainResources.exclude 'META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports'
     testAddon.dependsOn(filterHostMainResources)
     ```
   - При наличии `starterProject` (с плагином `java`) зарегистрировать отдельную задачу `filterHostStarterResources_${baseModule}` типа `Sync` в изолированный подкаталог `starter`:
     ```groovy
     def starterResDir = (starterProject != null && starterProject.pluginManager.hasPlugin('java')) ?
         p.layout.buildDirectory.dir("addon-tests/${baseModule}/host-resources/starter") : null
     if (starterResDir != null) {
         def filterHostStarterResources = p.tasks.maybeCreate("filterHostStarterResources_${baseModule}", Sync)
         filterHostStarterResources.destinationDir = starterResDir.get().asFile
         filterHostStarterResources.from(starterProject.tasks.named('processResources'))
         filterHostStarterResources.exclude 'META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports'
         testAddon.dependsOn(filterHostStarterResources)
     }
     ```
   - Заменить `p.sourceSets.main.output` и `starterMainOutput` в формировании `testAddon.classpath` на `classesDirs` и отфильтрованные каталоги ресурсов:
     ```groovy
     def hostResourcesDirs = [mainResDir] + (starterResDir != null ? [starterResDir] : [])
     testAddon.classpath = p.files({
         if (testState.skippedPreRollout || testState.testsDisabled) {
             return p.files()
         }
         return p.files(classesDir, aggregateFile.parentFile, hostResourcesDirs) +
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
   - В `itink-mod/build.gradle` сконфигурировать задачу `test`:
     ```groovy
     test {
         systemProperty 'spring.autoconfigure.exclude', 'ru.thedevs.itink.CustomExcludedAutoConfiguration'
     }
     ```
     (что приводит к генерации свойства `thedevs.test.systemProperties.spring.autoconfigure.exclude=ru.thedevs.itink.CustomExcludedAutoConfiguration` в дескрипторе `META-INF/thedevs-test.properties`).
   - Добавить дескриптор `src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` со строкой `ru.thedevs.itink.ItinkAutoConfiguration`.
2. В фикстуре `downstream`:
   - В `consumer-mod/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` добавить `ru.thedevs.consumer.ConsumerMainAutoConfiguration`.
   - В `consumer-starter/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` добавить `ru.thedevs.consumer.starter.ConsumerAutoConfiguration`.
3. В валидации опубликованного артефакта апстрима (в районе строки 278 `test-setup-addon-tests.sh`):
   - Проверить наличие строки `thedevs.test.systemProperties.spring.autoconfigure.exclude=ru.thedevs.itink.CustomExcludedAutoConfiguration` в распакованном `thedevs-test.properties`.
4. В тестовом классе `ItinkTest.java` (запускаемом внутри `testAddon_itink` потребителя) реализовать проверки:
   - Проверка (а): через `ClassLoader.getResources("META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports")` подтвердить, что дескрипторы хоста (`ru.thedevs.consumer.ConsumerMainAutoConfiguration` и `ru.thedevs.consumer.starter.ConsumerAutoConfiguration`) отсутствуют на classpath, а дескриптор зависимости `ru.thedevs.itink.ItinkAutoConfiguration` присутствует.
   - Проверка (б): через `Class.forName("ru.thedevs.consumer.starter.ConsumerAutoConfiguration")` и `Class.forName("ru.thedevs.consumer.ConsumerService")` подтвердить, что скомпилированные классы хоста сохраняются и успешно загружаются из classpath.
   - Проверка (в): через `assertEquals("ru.thedevs.itink.CustomExcludedAutoConfiguration", System.getProperty("spring.autoconfigure.exclude"))` подтвердить, что собственные исключения зависимости из `testTask.systemProperties` приходят в неизменном виде без затирания со стороны харнесса.

## Затрагиваемые файлы

1. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
2. `tests/test-setup-addon-tests.sh`

# Что уже есть

- Архитектура изоляции тестов зависимостей TD-2039: `actions/setup-addon-tests/ci-addon-tests.init.gradle`.
- Механизм передачи системных свойств через `testTask.systemProperties` в `thedevs-test.properties`: `ci-addon-tests.init.gradle:183-189`.
- Задача `processResources` и свойство `sourceSets.main.output.classesDirs` в Gradle Java plugin.
- Сквозной контрактный тест `tests/test-setup-addon-tests.sh`.

## Проверенные API

- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:183`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:315`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:599`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:605`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:612`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:628`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:634`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:53`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:278`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:373`
- `THEDEVS-RU/.github@dev:.github/workflows/ci.yml:28`

# Критерии готовности

1. В `actions/setup-addon-tests/ci-addon-tests.init.gradle` зарегистрированы изолированные `Sync`-задачи `filterHostMainResources_${baseModule}` и `filterHostStarterResources_${baseModule}`, исключающие дескриптор `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` из ресурсов хоста (`p` и `starterProject`) в каталоги `host-resources/main` и `host-resources/starter`.
2. В `testAddon.classpath` подключаются `p.sourceSets.main.output.classesDirs`, `starterClassesDirs` и отфильтрованные каталоги ресурсов вместо прямых `p.sourceSets.main.output` и `starterMainOutput`. Системное свойство `spring.autoconfigure.exclude` не выставляется принудительно и не затирает свойства зависимости.
3. В `tests/test-setup-addon-tests.sh` реализована сквозная верификация: (а) отсутствие дескрипторов автоконфигурации хоста (`main` и `starter`) при сохранении дескриптора зависимости через `ClassLoader.getResources`; (б) доступность классов хоста через `Class.forName`; (в) сохранение собственных исключений зависимости (`CustomExcludedAutoConfiguration`) через `assertEquals`.
4. Спецификация валидируется `validate-spec-format.sh` с кодом 0.
5. Верификация после доставки в `dev`: перезапуск CI на PR THEDEVS-RU/addon-tinkoff#11 подтверждает успешный статус задачи `:tinkoff:testAddon_balance` без изменений в продуктовом коде `addon-tinkoff`, а также отсутствие регрессий тестов зависимостей в других аддонах (`addon-1c`, `addon-uniteller`, `addon-balance`).

# Не трогать

- Не исключать скомпилированные классы хоста (`p.sourceSets.main.output.classesDirs`, `starterClassesDirs`) из `testAddon.classpath` во избежание потери проверки совместимости типов и версий транзитивных библиотек.
- Не объединять ресурсы хостового модуля и стартера в один каталог с `DuplicatesStrategy.INCLUDE`, сохраняя строгую изоляцию `host-resources/main` и `host-resources/starter`.
- Не изменять логику генерации объединенного `aggregate-changelog.xml` и системных свойств Liquibase.
- Не модифицировать тестовые конфигурации и классы внутри продуктовых репозиториев аддонов (`addon-balance`, `addon-tinkoff`, `addon-uniteller`, `addon-1c`).
- Не включать публикацию Gradle Module Metadata (`GenerateModuleMetadata.enabled = false` сохраняется).
