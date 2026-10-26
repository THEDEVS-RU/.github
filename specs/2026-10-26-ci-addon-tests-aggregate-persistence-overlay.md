---
id: 2026-10-26-ci-addon-tests-aggregate-persistence-overlay
product: github-actions
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
stage: detailed
external_content: false
impl_model: sonnet
impl_effort: high
---

# Контекст
В рамках архитектуры TD-2039 тесты аддонов платформы TheDevs запускаются в окружении downstream-потребителей через команду `./gradlew testAddonDependencies` (задачи `testAddon_${baseModule}`, например `:uniteller:testAddon_balance`).
При выполнении таких тестов в classpath присутствуют как классы и ресурсы тестируемой зависимости (`balance-tests.jar`), так и компоненты хост-аддона (`addon-uniteller`), включая реализации Spring SPI (`UnitellerAssetSettingsContributor` для `BalAssetSettingsContributor`).

### Проблема изоляции JPA-сущностей хоста
При запуске `:uniteller:testAddon_balance` в `addon-uniteller` тесты UI (`BalFragmentsFlowUiSmokeTest`) завершались с ошибкой:
`Exception [EclipseLink-0] ... The abstract schema type 'UnitellerAllowedCurrency' is unknown`
при попытке выполнить JPQL-запрос к сущности хоста в `UnitellerCurrencyServiceImpl.isCurrencySupported`:
`select count(e) from UnitellerAllowedCurrency e where (e.currency.id = :originalCode or e.currency.id = :upperCode) and e.currency.active = true`

Механизм возникновения дефекта:
1. `JmixModulesProcessor` (`io/jmix/core/JmixModulesProcessor.java:110-123`) определяет тестовую конфигурацию зависимости (`BalTestConfiguration`) как листовой модуль (`leafModules`), так как ее `dependsOn()` по умолчанию равен `AllModules.class`.
2. Алгоритм топологической сортировки `JmixModulesSorter.sort` (`io/jmix/core/impl/JmixModulesSorter.java:34-55`) помещает листовой модуль в самый конец списка `jmixModules.getAll()`.
3. Фабрика `JmixBaseEntityManagerFactoryBean.setupPersistenceUnit()` (`io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:38-47`):
   ```java
   List<JmixModuleDescriptor> modules = jmixModules.getAll();
   for (int i = modules.size() - 1; i >= 0; i--) {
       String path = getPersistenceXmlPath(modules.get(i), storeName);
       if (resources.getResource("classpath:" + path).exists()) {
           log.info("Using persistence.xml at {} for '{}' store", path, storeName);
           setPersistenceXmlLocation("classpath:" + path);
           return;
       }
   }
   ```
   выполняет поиск файла дескриптора `persistence.xml` с конца списка модулей и немедленно останавливается на первом найденном файле.
4. Базовый пакет модуля `BalTestConfiguration` — `ru.thedevs.account.balance` (`beanClass.getPackage()`), соответственно путь поиска — `ru/thedevs/account/balance/persistence.xml`.
5. Файл `ru/thedevs/account/balance/persistence.xml` гарантированно присутствует на classpath: он входит в `balance-tests.jar` (распакованный в `classesDir`) и в производственный артефакт `balance-*.jar` на `runtimeClasspath`.
6. По этой причине `setupPersistenceUnit()` всегда выбирает `ru/thedevs/account/balance/persistence.xml`, содержащий директиву `<exclude-unlisted-classes/>` и перечисляющий исключительно сущности `addon-balance` и `addon-core`. Поиск никогда не доходит до хост-модуля `ru.thedevs.integration.uniteller`, и сущности хоста не регистрируются в EclipseLink.

### Решение
По аналогии с объединением миграций Liquibase (`aggregate-changelog.xml` в TD-2039) вводится механизм агрегации JPA-дескрипторов:
Формирование overlay-каталога `addon-tests/${baseModule}/overlay`, размещаемого **первым** в `testAddon.classpath`. В этот каталог по путям дескрипторов листового модуля тестов зависимости (определяемым по `**/persistence.xml` и `<store>-persistence.xml` из распакованного `tests.jar`) генерируется объединенный дескриптор, содержащий объединение `<class>` из дескриптора хоста (`build/generated/jmix-descriptors/main`) и дескриптора `tests.jar`.

# Потребители
- `THEDEVS-RU/addon-uniteller`: устраняет блокировку `:uniteller:testAddon_balance` при вызове `UnitellerAssetSettingsContributor` без необходимости применения временных guard/catch-all в `UnitellerCurrencyServiceImpl`.
- `THEDEVS-RU/addon-tinkoff`: устраняет аналогичную проблему `:tinkoff:testAddon_balance` (где `TinkoffDepositUIProvider` обращается к `itink_AcquiringConnection`).
- `THEDEVS-RU/addon-cryptoconnector`: гарантирует доступность криптовалютных сущностей коннектора при прогоне тестов зависимостей.
- `THEDEVS-RU/addon-balance`, `THEDEVS-RU/addon-core` и все модули платформы: тесты зависимостей выполняются в консистентном JPA-окружении, где сосуществуют сущности хоста и зависимостей.
- Blast radius: изменения изолированы внутри таски `testAddon_${baseModule}` в `ci-addon-tests.init.gradle`. Обычные задачи `test` и боевая сборка артефактов хост-проектов не затрагиваются.

# Что сделать

## 1. Генерация overlay-дескрипторов в `ci-addon-tests.init.gradle`
В файле `actions/setup-addon-tests/ci-addon-tests.init.gradle` в блоке `candidateAddons.each`:
1. Определить каталог оверлея:
   ```groovy
   def overlayDir = p.layout.buildDirectory.dir("addon-tests/${baseModule}/overlay").get().asFile
   ```
2. Создать задачу агрегации JPA-дескрипторов `generateAddonPersistenceOverlay_${baseModule}`:
   - Задача выполняется после распаковки `unpackTask` и после генерации дескрипторов хоста `enhanceJmixMain` (если задача присутствует в проекте `p`).
   - Находит все файлы `*persistence.xml` в `classesDir` (распакованный `tests.jar`).
   - Для каждого найденного дескриптора определяет относительный путь (например, `ru/thedevs/account/balance/persistence.xml` или `ru/thedevs/account/balance/foo-persistence.xml`).
   - Извлекает имена сущностей `<class>` из дескриптора `tests.jar`.
   - Находит соответствующий дескриптор того же хранилища в каталоге сгенерированных дескрипторов хоста `build/generated/jmix-descriptors/main/**/<store>-persistence.xml` (для `main` хранилища — `persistence.xml`).
   - Извлекает имена сущностей `<class>` из дескриптора хоста. Поскольку `jmix-gradle-plugin` (`EnhancingAction.collectEntitiesFromClasspath`) включает в дескриптор хоста все сущности хоста и сущности из его classpath компиляции, дескриптор хоста уже содержит все продуктовые сущности.
   - Формирует объединенное множество классов (`LinkedHashSet<String>`) с сохранением тестовых сущностей из `tests.jar`.
   - Если хост не имеет сущностей или его дескриптор пуст, берутся только сущности из `tests.jar`.
   - Записывает объединенный XML в `overlayDir` по тому же относительному пути, сохраняя `<provider>io.jmix.data.impl.JmixPersistenceProvider</provider>`, `<mapping-file>`, объединенные `<class>`, `<exclude-unlisted-classes/>` и секцию `<properties>`.
   - Копирует сопутствующие файлы `orm.xml` (и `<store>-orm.xml`) из `classesDir` и/или дескрипторов хоста в соответствующий подкаталог `overlayDir`.
3. Подключить `overlayDir` первым элементом в `testAddon.classpath`:
   ```groovy
   testAddon.classpath = p.files({
       if (testState.skippedPreRollout || testState.testsDisabled) {
           return p.files()
       }
       return p.files(overlayDir, classesDir, aggregateFile.parentFile) +
              addonTestClasspath +
              p.sourceSets.main.output +
              starterMainOutput +
              runtimeClasspath
   })
   ```
4. Добавить зависимость: `testAddon.dependsOn(generateAddonPersistenceOverlay_${baseModule})`.

## 2. Контрактные тесты в `tests/test-setup-addon-tests.sh`
В файле `tests/test-setup-addon-tests.sh`:
Добавить тестовый сценарий, проверяющий:
- создание каталога `addon-tests/<module>/overlay`;
- генерацию `persistence.xml` по относительному пути leaf-модуля;
- присутствие в объединенном `persistence.xml` как сущностей хоста, так и сущностей зависимости и тестовых сущностей;
- корректное копирование `orm.xml`.

## Затрагиваемые файлы
- `actions/setup-addon-tests/ci-addon-tests.init.gradle`
- `tests/test-setup-addon-tests.sh`

# Что уже есть
- В `ci-addon-tests.init.gradle` реализован и валидирован шаблон объединения артефактов на уровне файловой системы (`aggregate-changelog.xml` для Liquibase).
- Плагин `jmix-gradle-plugin` генерирует дескрипторы хоста в `build/generated/jmix-descriptors/main` на этапе `enhanceJmixMain`, включая все сущности с compile classpath хоста (`EnhancingAction.collectEntitiesFromClasspath`).
- Контрактный тестовый harness в `tests/test-setup-addon-tests.sh` разворачивает Gradle-фикстуры upstream и downstream аддонов для проверки логики init-скрипта.

## Проверенные API
- `io.jmix.data.impl.JmixBaseEntityManagerFactoryBean#setupPersistenceUnit`: `dep-sources/io.jmix.data/jmix-data-3.0.0@local:io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:38`
- `io.jmix.data.impl.JmixBaseEntityManagerFactoryBean#getPersistenceXmlPath`: `dep-sources/io.jmix.data/jmix-data-3.0.0@local:io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:57`
- `io.jmix.core.JmixModulesProcessor#postProcessBeanDefinitionRegistry`: `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/JmixModulesProcessor.java:57`
- `io.jmix.core.JmixModulesProcessor#isDependingOnAll`: `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/JmixModulesProcessor.java:138`
- `io.jmix.core.impl.JmixModulesSorter#sort`: `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/impl/JmixModulesSorter.java:34`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:419`: `dot-github/actions/setup-addon-tests/ci-addon-tests.init.gradle:419`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:608`: `dot-github/actions/setup-addon-tests/ci-addon-tests.init.gradle:608`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:1`: `dot-github/tests/test-setup-addon-tests.sh:1`

# Критерии готовности
1. В `actions/setup-addon-tests/ci-addon-tests.init.gradle` реализована задача `generateAddonPersistenceOverlay_${baseModule}`, которая формирует объединенные дескрипторы персистентности в каталоге `addon-tests/${baseModule}/overlay` и размещает его первым в `testAddon.classpath`.
2. При объединении дескрипторов персистентности сохраняются все сущности хост-модуля, сущности upstream-зависимости и тестовые сущности из `tests.jar`, сопутствующие файлы `orm.xml`, а также конфигурации дополнительных хранилищ данных (`<store>-persistence.xml`).
3. При отсутствии сущностей у хоста (или отсутствии каталога сгенерированных дескрипторов хоста) overlay формируется на основе дескриптора `tests.jar` без ошибок выполнения сборки.
4. Контрактные тесты в `tests/test-setup-addon-tests.sh` завершаются успешно (код 0) и подтверждают наличие объединенных дескрипторов в overlay-каталоге.
5. Прогон задачи `:uniteller:testAddon_balance` в CI репозитория `THEDEVS-RU/addon-uniteller` (ветка TD-2083) завершается со статусом PASSED без guard-проверок `metadata.findClass == null` и `catch-all` блоков в `UnitellerCurrencyServiceImpl`, а в логе выполнения фиксируется строка `Using persistence.xml at ru/thedevs/account/balance/persistence.xml for 'main' store`.
6. Спецификация валидируется скриптом `validate-spec-format.sh` с нулевым кодом возврата.

# Не трогать
- Файл `BalTestConfiguration.java` в `addon-balance` (запрет на добавление no-op аннотаций).
- Временные guard-проверки и catch-all блоки в `UnitellerCurrencyServiceImpl.java` (возврат временных костылей запрещён).
- Логику генерации `aggregate-changelog.xml` для миграций Liquibase.
- Формирование `starterClassesDirs` и классов хоста на `testAddon.classpath`.
