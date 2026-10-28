# AGENTS.md — .github

Правила, архитектурные инварианты, соглашения и контекст для AI-агентов (Antigravity, Claude Code, Codex и др.), работающих с репозиторием `THEDEVS-RU/.github`.

---

## 1. Назначение репозитория

Репозиторий `THEDEVS-RU/.github` содержит централизованные переиспользуемые workflow GitHub Actions, составные экшены (composite actions), init-скрипты Gradle и скрипты контрактного тестирования инфраструктуры CI/CD организации TheDevs.

---

## 2. setup-addon-tests: изоляция тестов зависимостей (TD-2039, TD-2499, TD-2521, TD-2526, TD-2533, TD-2544)

Составной action `actions/setup-addon-tests` и его канонический init-скрипт `actions/setup-addon-tests/ci-addon-tests.init.gradle` реализуют архитектуру запуска тестов прямых зависимостей (`testAddon_<dep>`) в контексте хост-проекта.

### Схема classpath `testAddon_<dep>`

Для каждого `testAddon_<dep>` формируется изолированный classpath с детерминированным порядком разрешения ресурсов:
1. `build/addon-tests/<dep>/persistence-overlay` — оверлей persistence unit (TD-2521); добавляется первым элементом classpath лениво и только при наличии в нём файлов;
2. `build/addon-tests/<dep>/classes` — каталог распакованного артефакта тестов зависимости (`<dep>-tests.jar`);
3. `build/addon-tests/<dep>/aggregate-changelog.xml` — каталог агрегированного Liquibase-мастера;
4. `build/addon-tests/<dep>/host-resources/main` и `host-resources/starter` — каталоги отфильтрованных ресурсов хоста (TD-2499);
5. `addonTestClasspath_<dep>` — транзитивные зависимости тестов (разрешаются согласованно с `testRuntimeClasspath` хоста; платформы `ru.thedevs` хоста применяются в той же категории, что и в графе хоста (`platform` или `enforcedPlatform`));
6. `sourceSets.main.output.classesDirs` — скомпилированные классы основного модуля хоста;
7. `sourceSets.main.output.dirs` — сгенерированные дескрипторы хоста (`build/generated/jmix-descriptors/main`);
8. `starterClassesDirs` и `starterGeneratedDirs` — классы и сгенерированные дескрипторы сопутствующего `-starter` модуля хоста (при наличии);
9. `runtimeClasspath` — runtime classpath хост-проекта.

### Фильтрация AutoConfiguration.imports хоста (TD-2499)

При запуске тестов зависимости классы хоста обязаны присутствовать на classpath (для проверки бинарной и метамодельной совместимости), однако автоконфигурации хоста не должны загружаться в Spring-контекст зависимости, так как они инициализируют инфраструктурные бины хоста, не относящиеся к тестам зависимости.
Задачи `filterHostMainResources_<dep>` и `filterHostStarterResources_<dep>` копируют ресурсы хоста в каталоги `host-resources/main` и `host-resources/starter`, исключая дескриптор `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`.

### Хранилища хоста в testAddon (TD-2526)

#### Зачем нужно объединение хранилищ
При запуске `testAddon_<dep>` Spring-контекст зависимости не импортирует конфигурацию хоста, а автоконфигурации хоста исключены (TD-2499). Поэтому `@PropertySource` хоста (в частности, `module.properties`) в контексте `testAddon_*` не применяется.
В то же время метамодель Jmix сканирует все сущности `ru.thedevs.**` на classpath (включая сущности хоста и его зависимостей с аннотациями `@Store(name = "...")`). При назначении хранилища (`MetaModelLoader.assignStore`) Jmix проверяет наличие хранилища через `Stores.get(storeName)`. Если имя хранилища не зарегистрировано в `jmix.core.additional-stores`, контекст падает с `IllegalArgumentException: Store <name> is not registered`.

#### Механизм решения (testAddon.doFirst)
В блоке `testAddon.doFirst` вычисляется объединение имён дополнительных хранилищ (`LinkedHashSet`) из 4 источников:
1. **Системные свойства хоста:** значение `testAddon.systemProperties['jmix.core.additional-stores']` (объявленное хостом в `tasks.withType(Test)`);
2. **Дескриптор зависимости:** значение `thedevs.test.systemProperties.jmix.core.additional-stores` из `META-INF/thedevs-test.properties`;
3. **Свойства-файлы зависимости:** значение `jmix.core.additional-stores` из всех `*.properties` распакованного `classesDir` (`<dep>-tests.jar`);
4. **module.properties элементов classpath:** ключ `jmix.core.additional-stores` из файлов `module.properties` всех каталогов и jar-артефактов `testAddon.classpath` (включая `host-resources/main`, `host-resources/starter` и транзитивные библиотеки).

Если объединение не пусто, выставляется одно системное свойство `jmix.core.additional-stores` (через `,`) и в лог выводится строка:
`[TD-2526] testAddon_<dep>: jmix.core.additional-stores=<joined>`.
Если объединение пусто, свойство не трогается.

#### Контракт модуля
Харнесс собирает имена хранилищ исключительно из `module.properties`. Каждый модуль обязан перечислять в своём `module.properties` в ключе `jmix.core.additional-stores` **все** имена дополнительных хранилищ, на которые ссылаются аннотации `@Store(name = "...")` сущностей его `src/main`.

#### Что НЕ применяется и почему
Из `module.properties` хоста извлекается **только** ключ `jmix.core.additional-stores`.
Категорически не применяются и не копируются:
- `jmix.core.store-descriptor-*` / `store-descriptor_*` — ссылаются на бины дескрипторов контекста хоста (например, `cryptodata_descriptor`), отсутствующие в тестовом контексте зависимости (вызывают `IllegalStateException: Store descriptor not found`);
- `jmix.data-store.*` — специфичные для среды хоста JDBC-URL, логины и пароли;
- Любые другие ключи (`thedevs.kafka.*`, `jmix.core.fetch-plans-config` и др.).

Хост не должен объявлять `jmix.core.additional-stores` в `tasks.withType(Test)` исключительно ради `testAddon_*` — харнесс извлекает необходимые хранилища автономно по контракту модулей.

### Оверлей persistence.xml и затенение orm.xml (TD-2521)

#### Зачем нужен оверлей
1. **Сканирование метамодели:** Метамодель Jmix строится сканированием classpath по базовым пакетам всех зарегистрированных Jmix-модулей (`JmixModulesClasspathScanner#setJmixComponents`, `JmixModuleDescriptor::getBasePackage`). Поскольку корневая конфигурация `ru.thedevs.CoreConfiguration` находится в пакете `ru.thedevs`, сканируется всё пространство `ru.thedevs.**`. Все сущности хоста (включая замещающие сущности `@ReplaceEntity`) попадают в метамодель и подменяют базовые сущности зависимости (`MetadataLoader`).
2. **Построение Persistence Unit (PU):** Persistence Unit строится из **одного** файла дескриптора `persistence.xml` (`JmixBaseEntityManagerFactoryBean#setupPersistenceUnit`). Метод обходит модули от листового к базовым и выбирает первый существующий `classpath:<basePackage>/persistence.xml`. В задаче `testAddon_<dep>` листовой модуль — конфигурация зависимости (например, `ru.thedevs.coreui`), поэтому выбирается дескриптор зависимости, в котором перечислены только сущности зависимости и стоит `<exclude-unlisted-classes/>`. Сущности хоста в этом дескрипторе отсутствуют.
3. **Рассогласование:** Метамодель переписывает JPQL-запросы на замещающую сущность хоста (например, `GpsPhone` вместо `CorePhone`), но EclipseLink не знает этот класс, что приводит к фатальной ошибке `The abstract schema type '...' is unknown` (`HermesParser.java:200` / `EntityManagerImpl.java:1877`).

#### Механизм решения (buildHostPersistenceOverlay_<dep>)
Для каждой задачи `testAddon_<dep>` регистрируется задача `buildHostPersistenceOverlay_<dep>`, которая формирует в каталоге `build/addon-tests/<dep>/persistence-overlay`:
1. **Объединённые persistence.xml / <store>-persistence.xml:**
   - Находятся все дескрипторы хоста в `sourceSets.main.output.dirs` и `starterGeneratedDirs`. Если ни в одном дескрипторе хоста нет классов (хост без сущностей), оверлей не создаётся (нулевой регресс).
   - В корнях зависимости (`classesDir` и jar-артефакты `addonTestClasspath` из группы `ru.thedevs`) находятся все ресурсы `persistence.xml` / `*-persistence.xml` вне `META-INF/`.
   - Для каждого дескриптора зависимости создаётся объединённая копия: сохраняется исходный `<persistence-unit>`, добавляются недостающие `<class>` и `<mapping-file>` хоста, свойства хоста добавляются при отсутствии имени, а свойство `io.jmix.enhancing.converters-list` объединяется через разделитель `;`.
2. **Затеняющие копии mapping-файлов (<mapping-file>):**
   - Правило авторитетности хоста: `orm.xml` хоста сгенерирован Jmix-плагином на полном графе хоста с финально разрешёнными цепочками замен `target-entity`.
   - Во избежание исключения EclipseLink `conflictingXMLElements` (`ORMetadata#shouldOverride`) для каждого `<mapping-file>` зависимости в оверлей записывается затеняющая копия, из которой удалены элементы `<entity>`, `<mapped-superclass>`, `<embeddable>`, уже описанные в `orm.xml` хоста того же хранилища.
   - Поскольку `MetadataProcessor#loadSpecifiedMappingFiles` берёт первый URL из `ClassLoader.getResources()`, копия из `persistence-overlay` затеняет исходный файл зависимости.

#### Затрагиваемые проекты
Затронут любой хост с JPA-сущностями (особенно с `@ReplaceEntity`), запускающий тесты зависимостей:
- `addon-core-gps` (`GpsPhone` замещает `CorePhone` в `coreui`);
- Цепочки замен: `mobitrack-2` (`MobiPhone` -> `GpsPhone` -> `CorePhone`);
- `addon-core-crypto` (`CryptoUser` над `CoreUserEntity`);
- Любые хосты с собственными сущностями в `ru.thedevs.**`.

#### Диагностика
В логе Gradle задачи `buildHostPersistenceOverlay_<dep>` выводят диагностику:
- `[TD-2521] Persistence overlay for '<dep>': <relPath> (+<N> host classes)` — сформирован объединённый дескриптор PU;
- `[TD-2521] Persistence overlay for '<dep>': <mappingFile> (-<N> entity entries superseded by host)` — создана затеняющая копия mapping-файла;
- Каталог на диске: `build/addon-tests/<dep>/persistence-overlay`.

#### Компромиссы и риски
- Оверлей добавляет в PU все `<class>` из сгенерированных Jmix-дескрипторов хоста (надмножество сущностей хоста). Если Jmix-модуль хоста содержит сущности, не зарегистрированные через Jmix-конфигурацию, в PU окажется класс, которого нет в метамодели (граничный случай, отражается в диагностике).
- `orm.xml` хоста является источником истины для всех описанных в нём сущностей при конфликтах `target-entity`. Пересекающиеся записи в копии `orm.xml` зависимости удаляются. Остаточный риск — редкие нестандартные расхождения вне `<entity>`, `<mapped-superclass>` и `<embeddable>`.
- Если конфигурация хоста сама является листовым модулем Jmix-приложения (например, в боевом приложении без запуска тестов зависимостей), дескриптор хоста выбирается нативным механизмом Jmix без сущностей зависимостей.
- Запуск тестов зависимости происходит в приближённом к боевому окружению PU (включающем сущности хоста), что предотвращает скрытые несовместимости при подмене сущностей.

### Схема БД testAddon: changelog транзитивных модулей (TD-2533)

#### Зачем нужно
Оверлей persistence unit (TD-2521) добавляет в PU зависимости сущности всех транзитивных модулей хоста (`ru.thedevs.**`), включая модули метамодели (cryptocore, balance и др.), что расширяет схему JPA-сущностей (`CryptoToken extends CoreSecret` добавляет колонки `DTYPE`, `PASSPHRASE_ID`).
Для корректной работы тестов зависимости схема БД, формируемая Liquibase через `aggregate-changelog.xml`, обязана содержать миграции всех этих транзитивных модулей, иначе тесты падают с ошибками отсутствующих колонок и таблиц (например, `column "dtype" does not exist`).

#### Обнаружение changelog модулей
Changelog модулей Jmix обнаруживаются по пути `<basePackage>/liquibase/changelog.xml` (регулярное выражение `^(?!META-INF/).+/liquibase/changelog\.xml$`) в файлах (каталогах и jar-артефактах) модулей из `runtimeClasspath` хоста.
Рассматриваются компоненты с группами, начинающимися с `ru.thedevs` или `io.jmix`, а также проектные зависимости (`ProjectComponentIdentifier`, сиблинг-модули многомодульного хоста).
`module.properties` для обнаружения changelog **не используется**, поскольку:
- у базовых модулей `jmix-data` и `jmix-audit` он отсутствует вовсе;
- ключ `main.liquibase.change-log` объявляется лишь отдельными модулями и отсутствует у большинства платформенных библиотек (core, cryptocore, balance);
- ключа `jmix.liquibase.*` в `module.properties` нет в экосистеме Jmix 3.

#### Порядок включения в aggregate-changelog.xml
1. **Свойства `uuid.type`:** заголовок дескриптора и свойства `<property name="uuid.type" dbms="oracle" value="varchar2(32)"/>` и `<property name="uuid.type" dbms="!oracle" value="uuid"/>` (идентично мастерам core, cryptocore, balance, gps, uniteller);
2. **Топологический порядок модулей:** обход графа `runtimeClasspath` в глубину в пост-порядке (зависимости раньше зависящих; внутри компонента пути сортируются лексикографически);
3. **Changelog зависимости:** пишется первым, если он не совпадает с changelog какого-либо модуля classpath; если совпадает (например, `ru/thedevs/liquibase/changelog.xml` у `coreui` является changelog `core`), он включается ровно один раз в своей естественной топологической позиции среди модулей;
4. **Changelog хоста:** пишется последним (дедуплицируется с модулями).

Формат включения модулей: `<include file="/<normalizedPath>" relativeToChangelogFile="false"/>` (с ведущим `/`).

#### Допуск повторных changeSet'ов (флаг Liquibase)
В блоке `testAddon.doFirst` выставляется системное свойство:
`liquibase.allowDuplicatedChangesetIdentifiers=true`.
- **Что делает:** активирует штатный механизм Liquibase `ChangeLogIterator.alreadySaw`, который пропускает повторно встреченные changeSet'ы (с тем же id, автором, нормализованным путём, контекстами и метками) для всех визиторов, включая валидирующий.
- **Область действия:** строго тестовая JVM задачи `testAddon_<dep>`; production-среда, собственные тесты хоста и дескриптор `thedevs-test.properties` не затрагиваются.
- **Почему не используется анализ контекстов и замыкания include в харнессе:** мастера модулей вкладывают друг друга под контекстом `@jmix-addon` (core вкладывает Jmix, cryptocore вкладывает balance). Анализ и разбор выражений `contextFilter` на этапе генерации скрипта Gradle сложен, хрупок и зависит от рантайм-контекстов конкретного теста. Штатный флаг Liquibase гарантирует корректный пропуск вложенных дублей при любом наборе активных контекстов без разбора содержимого файлов.

#### Контракт модуля
Changelog миграций модуля Jmix обязан располагаться по стандартному пути `<basePackage>/liquibase/changelog.xml` (например, `ru/thedevs/crypto/liquibase/changelog.xml`).

#### Диагностика
- `[TD-2533] aggregate-changelog for '<dep>': dep changelog position=<first|topological>, module changelogs=<paths>` — лог генерации агрегата;
- `[TD-2533] testAddon_<dep>: liquibase.allowDuplicatedChangesetIdentifiers=true` — подтверждение выставления флага в JVM.

#### Компромиссы и риски
- Флаг `liquibase.allowDuplicatedChangesetIdentifiers=true` пропускает случайные дубли changeSet с одинаковым id/автором внутри одного файла/пути в контексте `testAddon_*`. Такие дубли по-прежнему ловятся собственными тестами модулей и production-запуском хоста.
- Добавление changelog транзитивных модулей в схему `testAddon` может выявить ранее скрытые ошибки миграций на реальной СУБД (PostgreSQL), что является ожидаемой платой за соответствие боевой схеме.

### Версии тестовых библиотек в addonTestClasspath (TD-2544)

#### Зачем нужно
При публикации `<dep>-tests.jar` init-скрипт фиксирует в POM runtime-зависимости с версиями, разрешёнными на момент публикации зависимости (например, `core-test:3.0.0.86`).
Тестовые библиотеки платформы (`ru.thedevs:core-test`, `ru.thedevs:coreui-test`) объявляются хостом в `testImplementation` и отсутствуют в `runtimeClasspath` хоста. Ранее `addonTestClasspath_<dep>` согласовывался только с `runtimeClasspath`, из-за чего устаревший пин тестовой библиотеки из POM зависимости не перекрывался хостом, а правки базовых тестовых классов (например, `AbstractPostgresIntegrationTest`) не доходили до `testAddon_*` без перепубликации каждой зависимости.

#### Механизм решения (два слоя)
Версии тестовых библиотек определяются хостом через два взаимодополняющих слоя:
1. **Слой 1 — Согласование с `testRuntimeClasspath`:**
   Конфигурация `addonTestClasspath_<dep>` вызывает `shouldResolveConsistentlyWith(testRuntimeClasspath)` (при отсутствии `testRuntimeClasspath` — fallback на `runtimeClasspath`). Поскольку `testRuntimeClasspath` включает тестовые зависимости хоста, все тестовые библиотеки, объявленные хостом (`core-test`, `coreui-test`, `jmix-flowui-test-assist` и др.), согласуются с версиями хоста.
2. **Слой 2 — Платформы BOM хоста с сохранением категории:**
   Для хостов, у которых конкретная тестовая библиотека не объявлена напрямую в `testImplementation` (например, `addon-core-gps`), в `addonTestClasspath_<dep>` транслируются платформы `ru.thedevs` из `runtimeClasspath` хоста. Платформы добавляются в той же категории, в какой их разрешил хост:
   - если вариант разрешён с Category `ENFORCED_PLATFORM`, добавляется `p.dependencies.enforcedPlatform(...)`;
   - если вариант разрешён с Category `REGULAR_PLATFORM`, добавляется `p.dependencies.platform(...)`.
   Сохранение категории гарантирует, что у хостов с обычной `platform` версии выше BOM (из других зависимостей) не конфликтуют с согласованным разрешением, а устаревший пин из POM зависимости поднимается до версии BOM.

#### Контракт хоста и зависимостей
Версии тестовых библиотек в `testAddon_*` определяет хост (через свой `testRuntimeClasspath` или подключённый BOM). Перепубликация промежуточных зависимостей при обновлении тестовых библиотек платформы не требуется.

#### Диагностика
При конфигурации `addonTestClasspath_<dep>` выводится лог:
`[TD-2544] addonTestClasspath_<dep>: consistent with testRuntimeClasspath, platforms=[<group>:<name>:<version>(enforced|regular),...]`
(при отсутствии платформ `platforms=[]`).

---

## 3. Контрактное тестирование

Репозиторий валидируется контрактными тестами:
- `tests/test-deploy-resolve.sh` — контрактные тесты резолва деплоя;
- `tests/test-kaniko-build.sh` — контрактные тесты Kaniko build;
- `tests/test-setup-addon-tests.sh` — контрактные тесты `setup-addon-tests`:
  - Публикация `-tests.jar` и отключение GMM;
  - Изоляция classpath и фильтрация `AutoConfiguration.imports` (TD-2499);
  - Формирование оверлея `persistence.xml` и объединение классов/конвертеров (TD-2521);
  - Затенение `orm.xml` при конфликте `target-entity` (TD-2521);
  - Объединение хранилищ хоста и зависимости в `jmix.core.additional-stores` (TD-2526);
  - Агрегат миграций Liquibase и порядок транзитивных модулей (TD-2533);
  - Согласование версий тестовых библиотек с `testRuntimeClasspath` и сохранение категории платформ BOM (TD-2544, сценарии A, B, C, D, E);
  - Негативный сценарий для хостов без сущностей (нулевой регресс, TD-2521);
  - Поведение `thedevs.tests.strict` vs pre-rollout.
