id: 2026-10-28-td2526-addon-tests-host-stores
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
awaits_task: TD-2521
complexity: simple
stage: detailed
external_content: false
impl_model: sonnet
impl_effort: high

# Контекст

Задача TD-2526 выявлена в TD-2522 (THEDEVS-RU/addon-core-crypto PR #79). Хост, у которого в `testAddon_*` запускаются тесты зависимости, вынужден сам объявлять свои дополнительные хранилища Jmix системным свойством, иначе контекст зависимости не поднимается.

## Факты (из постановки, подтверждены чтением исходников)

- run 40462922033 (addon-core-crypto@dev, в `tasks.withType(Test)` стоит `systemProperty 'jmix.core.additional-stores', 'cryptodata,hsql'`, `THEDEVS-RU/addon-core-crypto@dev:cryptocore/cryptocore.gradle:52`): `testAddon_balance` зелёный.
- run 40712807755 (head 326b22f PR #79, свойство удалено): `testAddon_balance` падает `IllegalArgumentException: Store cryptodata is not registered` (`Stores.get`, `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/Stores.java:88` ← `MetaModelLoader.assignStore`, `io/jmix/core/impl/MetaModelLoader.java:189-190`); собственные тесты cryptocore зелёные.

## Механизм

1. `ru.thedevs.CoreConfiguration` (`THEDEVS-RU/addon-core@dev:core/src/main/java/ru/thedevs/CoreConfiguration.java:52`) имеет базовый пакет `ru.thedevs`, поэтому метамодель любого контекста сканирует все сущности `ru.thedevs.**` на classpath, включая сущности хоста и его `ru.thedevs`-зависимостей со `@Store(name = "cryptodata")`. `assignStore` вызывает `stores.get(storeAnn.name())` для каждой такой сущности.
2. Имена хранилищ `Stores` берёт из `StoreDescriptorsRegistry#initialize`: `environment.getProperty("jmix.core.additional-stores")`, разбор по запятой с trim и пропуском пустых (`io/jmix/core/impl/StoreDescriptorsRegistry.java:52,59-70`). Для каждого имени без явного `jmix.core.store-descriptor-<имя>` берётся `JpaStoreDescriptor` (`StoreDescriptorsRegistry.java:100-114`); Jmix Data не создаёт `EntityManagerFactory` для имени хранилища сам (в `jmix-data-3.0.0` и `jmix-eclipselink-3.0.0` нет потребителей `getAdditionalDataStoreNames`, кроме `Stores`), поэтому регистрация одного имени безвредна — это подтверждает и зелёный run 40462922033, где `cryptodata` зарегистрировано только именем, без `jmix.data-store.cryptodata.*`.
3. Объявление хоста живёт в `module.properties` его модуля (`THEDEVS-RU/addon-core-crypto@dev:cryptocore/src/main/resources/ru/thedevs/crypto/module.properties:16`, подключается `@PropertySource` на `CryptoCoreConfiguration`). В `testAddon_*` конфигурация хоста не импортируется тестовым контекстом зависимости (`addon-balance@dev:balance/src/test/java/ru/thedevs/account/balance/BalTestConfiguration.java:19-28`) и `AutoConfiguration.imports` хоста исключён (`THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:616,625`, TD-2499), поэтому `@PropertySource` хоста не применяется. Property source Jmix-модуля попадает в `Environment` только если модуль входит в контекст (`io/jmix/core/JmixModulesProcessor.java:131-133,177`).
4. `jmix.core.additional-stores` — скаляр: при нескольких объявлениях побеждает источник с высшим приоритетом, слияния нет. Системное свойство Test-задачи перекрывает все файловые источники. Следовательно, harness может задать это свойство только как **объединение** (хост ∪ зависимость), иначе он затрёт хранилища, которые зависимость объявляет сама (пример: `addon-binance@dev:binance/src/test/resources/application.properties:2` объявляет `cryptodata,hsql` и попадает в `binance-tests.jar`).

## Масштаб (grep по `origin/dev` репозиториев workspace)

- `module.properties` с `jmix.core.additional-stores`: addon-core-crypto (`cryptodata`), addon-binance (`cryptodata,hsql`).
- Объявление в `tasks.withType(Test)` gradle-файла хоста (действует и на `testAddon_*`): addon-core-crypto (`cryptocore.gradle:52`), addon-cryptoconnector (`cryptoconnector.gradle:43`), addon-cryptomath (`cryptomath.gradle:47`).
- Объявление только в тестовых ресурсах собственных тестов (на `testAddon_*` не влияет): coinex, bybit, kraken, kucoin, binance, crypto-collector.

# Что сделать

Решение: в `testAddon_*` init-скрипт сам вычисляет объединение имён хранилищ и выставляет одно системное свойство `jmix.core.additional-stores`. Применяется ТОЛЬКО это свойство, остальное содержимое `module.properties` хоста не применяется (обоснование ниже).

## 1. Вспомогательные функции в `ci-addon-tests.init.gradle`

Добавить на верхнем уровне скрипта (рядом с `resolveHostMainLiquibaseChangelog`, до `gradle.projectsEvaluated`) функции:
1. Разбор значения списка хранилищ: делит строку по `,`, trim, отбрасывает пустые, сохраняет порядок (семантика `StoreDescriptorsRegistry.SPLITTER`). Значение с `${` пропускается с `::warning::[TD-2526]` (плейсхолдеры без `Environment` не разрешимы).
2. Сбор имён из каталогов и jar-ов: для заданного набора `File` из classpath находит файлы `module.properties` (рекурсивно в каталоге; в jar — записи `module.properties` на любой глубине через `java.util.zip.ZipFile`), загружает `java.util.Properties` и читает единственный ключ `jmix.core.additional-stores`.
3. Сбор имён из свойств-файлов зависимости: рекурсивно по распакованному `classesDir` читает ключ `jmix.core.additional-stores` из всех `*.properties` (покрывает `application*.properties`, `test-app.properties` и т.п. из `<dep>-tests.jar`). YAML не разбирается (в парке `origin/dev` workspace объявлений в YAML нет).
Ошибки чтения отдельного файла/jar не валят задачу, но печатают `::warning::[TD-2526] ...` с путём файла.

## 2. Применение в `testAddon.doFirst`

В блоке `testAddon.doFirst` (`ci-addon-tests.init.gradle:652-673`), после ветки `skippedPreRollout || testsDisabled`:
1. До цикла `depProps.each` запомнить текущее значение `testAddon.systemProperties['jmix.core.additional-stores']` — это объявление хоста из `tasks.withType(Test)`, которое цикл `depProps.each` перезаписывает, если дескриптор зависимости несёт то же свойство (`thedevs.test.systemProperties.jmix.core.additional-stores`).
2. После цикла вычислить множество (`LinkedHashSet`, порядок: хост-системное, дескриптор зависимости, файлы зависимости, `module.properties` classpath):
   - значение из п.1;
   - значение `thedevs.test.systemProperties.jmix.core.additional-stores` из дескриптора зависимости (уже применено циклом);
   - имена из `*.properties` в `classesDir` (функция 3);
   - имена из `module.properties` всех элементов `testAddon.classpath.files` (функция 2): отфильтрованные каталоги `host-resources/main` и `host-resources/starter`, jar-ы `runtimeClasspath` (транзитивные `ru.thedevs`-зависимости хоста, например cryptocore для cryptomath) и `addonTestClasspath`.
3. Если множество не пусто — `testAddon.systemProperty('jmix.core.additional-stores', joined)` (через `,`) и одна строка лога `[TD-2526] testAddon_<baseModule>: jmix.core.additional-stores=<joined>`. Если пусто — свойство не трогается.
4. Не применять и не копировать: `jmix.core.store-descriptor-*`/`store-descriptor_*` (значения — имена бинов контекста хоста, например `cryptodata_descriptor` из `module.properties:17`, которых в контексте зависимости нет: `resolveStoreDescriptor` бросит `IllegalStateException("Store descriptor not found")`, `StoreDescriptorsRegistry.java:111-118`), `jmix.data-store.*` (JDBC-адреса, логины и пароли среды хоста), `thedevs.kafka.*`, `jmix.core.fetch-plans-config` и любые другие ключи. Хост, которому в `testAddon_*` нужен нестандартный дескриптор, по-прежнему объявляет его сам.

## 3. Контрактный тест `tests/test-setup-addon-tests.sh`

Расширить фикстуры (имена хранилищ в фикстуре вымышленные, они не обращаются к платформенным API):
1. Upstream `itink-mod`: в `test {}` (`test-setup-addon-tests.sh:158-160`) добавить `systemProperty 'jmix.core.additional-stores', 'itinkprop'`; в `src/test/resources/test-itink.properties` (`:138-140`) добавить `jmix.core.additional-stores=itinkfile`. После публикации проверить в распакованном `thedevs-test.properties` строку `thedevs.test.systemProperties.jmix.core.additional-stores=itinkprop` (рядом с проверкой `spring.autoconfigure.exclude`, секция 2).
2. Downstream `consumer-mod`: добавить `src/main/resources/ru/thedevs/consumer/module.properties` с `jmix.core.additional-stores=consumerdata`, `jmix.core.store-descriptor-consumerdata=consumer_descriptor`, `jmix.data-store.consumerdata.jdbc-url=jdbc:fixture://unreachable`, `thedevs.fixture.leak=must-not-apply`; в `consumer-mod/build.gradle` (`:428-461`) добавить `tasks.withType(Test).configureEach { systemProperty 'jmix.core.additional-stores', 'hostsys' }`.
3. Downstream `consumer-starter`: добавить `src/main/resources/ru/thedevs/consumer/starter/module.properties` с `jmix.core.additional-stores=starterdata`.
4. В `ItinkTest.java` (`:81-133`) добавить проверки: (а) множество, полученное разбором `System.getProperty("jmix.core.additional-stores")`, равно `{hostsys, itinkprop, itinkfile, consumerdata, starterdata}` (ничего не потеряно у зависимости и хоста); (б) `System.getProperty("jmix.core.store-descriptor-consumerdata")`, `System.getProperty("jmix.data-store.consumerdata.jdbc-url")` и `System.getProperty("thedevs.fixture.leak")` равны `null` (прочие ключи `module.properties` не применяются).
5. В секции 4 (проверка результатов downstream, `:496-559`) проверить, что в Gradle-выводе есть строка `[TD-2526] testAddon_itink: jmix.core.additional-stores=`.

## 4. Документация

В `AGENTS.md` (создан в TD-2521, раздел «setup-addon-tests», после подраздела «Фильтрация AutoConfiguration.imports хоста (TD-2499)») добавить подраздел «Хранилища хоста в testAddon (TD-2526)»: что объединяется (4 источника из п.2.2), что не применяется (п.2.4) и почему, правило «хост не объявляет `jmix.core.additional-stores` в `tasks.withType(Test)` ради `testAddon_*`», ограничения (YAML, плейсхолдеры, дескрипторы).

## Затрагиваемые файлы

1. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
2. `tests/test-setup-addon-tests.sh`
3. `AGENTS.md`

## Последующие правки хостов (вне этой спеки, отдельные задачи по репозиториям)

После доставки этой спеки в `dev` (хосты вызывают action по ссылке на `dev`) снять у хостов объявления, нужные только ради `testAddon_*`; каждый шаг подтверждается зелёным CI хоста (`testAddon_*` и собственные тесты):
- addon-core-crypto: `cryptocore/cryptocore.gradle:52` (`cryptodata,hsql`); собственные тесты покрыты `test-app.properties` (`jmix.core.additional-stores=hsql,cryptodata`). В TD-2522 `cryptodata` остаётся объявленным хостом до выкатки этой спеки.
- addon-cryptoconnector: `cryptoconnector.gradle:43`; addon-cryptomath: `cryptomath.gradle:47` (их тесты покрыты `test-app.properties`, а `cryptodata` приходит в `testAddon_*` из `module.properties` cryptocore на `runtimeClasspath`). `hsql` снимать только после проверки, что у хоста нет сущностей `@Store(name = "hsql")`, объявленных лишь в `test-app.properties`: `module.properties` их не покрывает.
- addon-coinex, addon-binance, addon-bybit, addon-kraken, addon-kucoin, addon-crypto-collector: объявления лежат в тестовых ресурсах собственных тестов и нужны им самим; к `testAddon_*` не относятся, снятию не подлежат.

# Что уже есть

- Харнесс TD-2039/TD-2499: `actions/setup-addon-tests/ci-addon-tests.init.gradle` (фильтрация `AutoConfiguration.imports` `:612-627`, classpath `:630-641`, `doFirst` `:652-673`, перенос системных свойств зависимости `:662-668`).
- Контрактный тест с фикстурами `itink-mod` (upstream) и `consumer-mod`/`consumer-starter` (downstream): `tests/test-setup-addon-tests.sh`.
- Параллельная задача TD-2521 (ветка `impl/2026-10-28-td2521-addon-tests-host-entities-in-pu`) правит тот же init-скрипт, тот же контрактный тест и создаёт `AGENTS.md`; поэтому `awaits_task: TD-2521` — чтобы избежать конфликтов слияния. Логических зависимостей между задачами нет.

## Проверенные API

- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/impl/StoreDescriptorsRegistry.java:52` (`SPLITTER`)
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/impl/StoreDescriptorsRegistry.java:59` (`environment.getProperty("jmix.core.additional-stores")`)
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/impl/StoreDescriptorsRegistry.java:100`
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/impl/StoreDescriptorsRegistry.java:111`
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/Stores.java:67`
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/Stores.java:88`
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/impl/MetaModelLoader.java:189`
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/JmixModulesProcessor.java:131`
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/JmixModulesProcessor.java:177`
- `dep-sources/io.jmix.data/jmix-data-3.0.0@local:io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:50`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:24` (`Test.systemProperties`)
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:612`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:630`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:652`
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:665` (`testAddon.systemProperty`)
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:81`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:138`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:158`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:428`
- `THEDEVS-RU/addon-core-crypto@dev:cryptocore/src/main/resources/ru/thedevs/crypto/module.properties:16`
- `THEDEVS-RU/addon-core-crypto@dev:cryptocore/cryptocore.gradle:52`

## Альтернативы (рассмотрены и отклонены)

1. **Применять весь `module.properties` хоста** (как заказано буквально). Отклонено: файл содержит среду-специфичные ключи (`jmix.data-store.cryptodata.jdbc-url=jdbc:clickhouse://192.168.88.215:30108/...`, `thedevs.kafka.*`), имена бинов хоста (`cryptodata_descriptor`) и через системное свойство перекрывал бы объявления зависимости; в CI это сетевые обращения и падение `Store descriptor not found`.
2. **Выводить имена из аннотаций `@Store` в байткоде классов хоста.** Точнее по потребности (не зависит от места объявления), но требует разбора class-файлов в Groovy init-скрипте без стабильного публичного API (ASM Gradle — внутренний) либо загрузки классов в демоне Gradle; хрупко. Не нужно сейчас (YAGNI): декларация в `module.properties` — каноническое место, у всех затронутых хостов она есть.
3. **Спринговый бин `AdditionalStoreDescriptorProvider`** (аддитивный, без перезаписи скаляра) через сгенерированный `AutoConfiguration.imports` — требует компиляции вспомогательного класса в харнессе и новой автоконфигурации в контексте зависимости, т.е. обратного движения относительно TD-2499. Отклонено.
4. **Сгенерированный `application.properties` на classpath.** Классовый путь отдаёт первый `application.properties`, он бы затенял файл зависимости целиком (тот же класс дефекта, что затенение `orm.xml` в TD-2521). Отклонено.

## Компромиссы и риски

- Объединение — надмножество: `*.properties` в `classesDir` включают профильные файлы (`application-test.properties`), которые в конкретном запуске могли быть неактивны. Лишнее зарегистрированное имя без сущностей безвредно (п.2 механизма).
- Старые опубликованные `<dep>-tests.jar` обрабатываются без перепубликации: источники — файлы внутри jar и системные свойства из `thedevs-test.properties`.
- Хост, который сам объявил `jmix.core.additional-stores` (до снятия объявлений), продолжает работать: его значение входит в объединение.
- Наблюдение (не проверялось, не входит в задачу): `jmix.core.store-descriptor_cryptodata` в `module.properties:17` написано через `_`, а Jmix читает `jmix.core.store-descriptor-<имя>` (`StoreDescriptorsRegistry.java:111`); возможно, ключ в хосте не действует.

# Критерии готовности

1. В `ci-addon-tests.init.gradle` добавлены функции сбора имён хранилищ и блок в `testAddon.doFirst`, выставляющий `jmix.core.additional-stores` как объединение четырёх источников (системное свойство хоста, дескриптор зависимости, `*.properties` из `classesDir`, `module.properties` элементов `testAddon.classpath`); при пустом объединении свойство не выставляется.
2. Ключи `jmix.core.store-descriptor-*`, `jmix.data-store.*` и любые другие ключи `module.properties` не применяются; в Gradle-выводе печатается строка `[TD-2526] testAddon_<dep>: jmix.core.additional-stores=...`.
3. `tests/test-setup-addon-tests.sh` содержит расширенные фикстуры и проверки п.3 «Что сделать»; `AGENTS.md` содержит подраздел о хранилищах хоста.
4. Спецификация проходит `validate-spec-format.sh` с кодом 0.
5. Верификация после доставки в `dev` (на стороне хостов, отдельными задачами): PR addon-core-crypto без `systemProperty 'jmix.core.additional-stores'` для `testAddon_*` даёт зелёный `testAddon_balance` (run 40712807755 воспроизводил падение).

# Не трогать

- Не менять логику фильтрации `AutoConfiguration.imports` (TD-2499), оверлей persistence (TD-2521), генерацию `aggregate-changelog.xml` и Liquibase-свойства.
- Не копировать в `testAddon_*` другие ключи `module.properties` хоста и не выставлять `jmix.core.store-descriptor-*`.
- Не править продуктовые репозитории хостов и зависимостей в рамках этой спеки; не включать публикацию Gradle Module Metadata (`GenerateModuleMetadata.enabled = false` сохраняется).
