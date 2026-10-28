id: 2026-10-28-td2521-addon-tests-host-entities-in-pu
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: architectural
stage: detailed
external_content: false
impl_model: opus
impl_effort: high

# Контекст

Задача TD-2521 блокирует TD-2455 (THEDEVS-RU/addon-core-gps PR #44). В CI этого PR (run 40701518504, job 122862309424, шаг «Run addon dependency tests») задача `:gpscore:testAddon_coreui` (распакованный `ru.thedevs:core-ui-tests:3.0.0.181`) падает: 41 тест `CoreuiAllViewsRuntimeI18nTest.testAllModuleViewsLocalization`, первый — `[ru] Phone.list`, `IllegalArgumentException at EntityManagerImpl.java:1877` ← `JPQLException at HermesParser.java:200`. По данным impl-стадии текст ошибки: `The abstract schema type 'GpsPhone' is unknown`. В логе CI текст исключения не печатается (только класс), сборка хоста и собственные тесты gpscore (шаг own) проходят. Факт, подтверждённый логом job 122862309424: `:gpscore:testAddon_core` пропущен (`tests artifact not yet published`), `:gpscore:testAddon_coreui` выполнен и упал.

## Механизм (прочитано в исходниках, не гипотеза)

1. Хост `gpscore` содержит `ru.thedevs.core.gps.entity.GpsPhone extends CorePhone` с `@ReplaceEntity(CorePhone.class)` (`THEDEVS-RU/addon-core-gps@dev:gpscore/src/main/java/ru/thedevs/core/gps/entity/GpsPhone.java:20`).
2. Метамодель Jmix строится сканированием classpath по базовым пакетам **всех** зарегистрированных Jmix-модулей: `JmixModulesClasspathScanner#setJmixComponents` берёт `JmixModuleDescriptor::getBasePackage` (`dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/impl/scanning/JmixModulesClasspathScanner.java:67-68`), а базовый пакет модуля — пакет его конфигурационного класса (`io/jmix/core/JmixModulesProcessor.java:103`). `ru.thedevs.CoreConfiguration` лежит в корневом пакете `ru.thedevs`, поэтому сканируется всё `ru.thedevs.**`, включая классы хоста, которые init-скрипт кладёт на classpath (`p.sourceSets.main.output.classesDirs`, `starterClassesDirs`; `ci-addon-tests.init.gradle:630-640`). `GpsPhone` попадает в метамодель и через `@ReplaceEntity` подменяет `CorePhone` (`io/jmix/core/impl/MetadataLoader.java:176-196`).
3. Persistence unit `main` строится из **одного** `persistence.xml`: `JmixBaseEntityManagerFactoryBean#setupPersistenceUnit` обходит модули от последнего (листового) к первому и берёт первый существующий `classpath:<basePackage>/persistence.xml` (`dep-sources/io.jmix.data/jmix-data-3.0.0@local:io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:38-47,57-60`). Для `testAddon_coreui` листовой модуль — тестовая конфигурация зависимости (`THEDEVS-RU/addon-core-ui@dev:coreui/src/test/java/ru/thedevs/coreui/CoreuiTestConfiguration.java`, пакет `ru.thedevs.coreui`), поэтому выбирается `ru/thedevs/coreui/persistence.xml` из артефактов coreui, где перечислены только сущности coreui и его зависимостей, и стоит `exclude-unlisted-classes`. `GpsPhone` в этом PU нет.
4. Итог: метамодель знает `GpsPhone` (JPQL-запросы к `CorePhone` переписываются на замещающую сущность), а EclipseLink — нет. Это рассогласование метамодели и PU.
5. TD-2499 исключил из classpath только `AutoConfiguration.imports` хоста (бины хоста в контекст зависимости не попадают), но не затрагивает сканирование метамодели и выбор `persistence.xml`; TD-2498 (`THEDEVS-RU/addon-balance@task/TD-2498:specs/2026-10-26-td2498-bal-test-config-all-modules.md`) подтвердил тот же механизм выбора `persistence.xml` и зафиксировал, что оверлей тогда не требовался, потому что рассогласования не было.

Jmix Gradle plugin 3.0.0 генерирует дескрипторы хоста на этапе `enhanceJmix<SourceSet>` в каталог `build/generated/jmix-descriptors/<sourceSet>` и регистрирует его как `sourceSets.main.output.dir(..., builtBy: ...)` (байткод `io.jmix.gradle.JmixPlugin#registerGeneratedDescriptors`, `io.jmix.gradle.EnhancingAction#generatedDescriptorsDir`, `#constructDescriptors`; артефакт `io.jmix.gradle:jmix-gradle-plugin:3.0.0`). Содержимое `persistence.xml`: `<persistence-unit>` с `<provider>io.jmix.data.impl.JmixPersistenceProvider</provider>`, `<mapping-file>`, `<class>`, `<exclude-unlisted-classes/>` и `<properties>/<property name="io.jmix.enhancing.converters-list">` (`io.jmix.gradle.DescriptorGenerationUtils#constructPersistenceXml`). Для имени файла используется схема `persistence.xml` (хранилище `main`) и `<store>-persistence.xml` (дополнительные хранилища), как в `getPersistenceXmlPath`. Эти дескрипторы уже находятся на classpath `testAddon_*` через `p.sourceSets.main.output.dirs` (`ci-addon-tests.init.gradle:637`, `609-610`), и существующий тест-фикстура эмулирует именно такой `output.dir` (`tests/test-setup-addon-tests.sh:442-455`).

## Масштаб

Затронут любой хост с `@ReplaceEntity` (или просто с собственной JPA-сущностью в `ru.thedevs.**`, которую зависимость случайно вызывает) над сущностью зависимости, для которой опубликован `*-tests.jar`. Сейчас — `addon-core-gps` → coreui. Далее — `addon-core-crypto` (`CryptoUser` над `CoreUserEntity`) после публикации core-tests и все аналоги. TD-2447 показывает, что видимость замены в тестах зависимости ожидаема и полезна (ловит реальные несовместимости), поэтому сущности хоста нельзя прятать из метамодели — PU нужно согласовать с ней.

# Что сделать

Решение — платформенное, в одном месте: init-скрипт `actions/setup-addon-tests/ci-addon-tests.init.gradle`. Для каждой `testAddon_<dep>` формируется **оверлей дескрипторов persistence unit**: те `persistence.xml` зависимости, которые Jmix может выбрать как PU, подменяются на classpath объединёнными копиями «дескриптор зависимости ∪ сущности хоста». Поскольку `ClassLoader.getResource` возвращает первое вхождение, а `setupPersistenceUnit` ищет через `classpath:` (`JmixBaseEntityManagerFactoryBean.java:42`), оверлей, поставленный на classpath первым, гарантированно выигрывает независимо от того, какой именно модуль окажется листовым.

## 1. Задача формирования оверлея `buildHostPersistenceOverlay_${baseModule}`

В блоке `candidateAddons.each` (после регистрации `unpackTask`, `ci-addon-tests.init.gradle:423-594`) зарегистрировать задачу (по образцу `unpackTask`: `p.tasks.maybeCreate`, plain task с `doLast`):

- Входы (`inputs`): файлы `p.sourceSets.main.output.dirs` и `starterGeneratedDirs` (несут `builtBy` задачи Jmix-плагина, поэтому порядок относительно `enhanceJmixMain` обеспечивается автоматически), `classesDir` распакованных тестов, артефакты `addonTestClasspath` (по образцу `unpackTask.inputs.files(addonTestClasspath.incoming.artifactView { lenient(true) }.files)`).
- Выход (`outputs.dir`): `build/addon-tests/${baseModule}/persistence-overlay`. Каталог пересоздаётся при каждом выполнении (без устаревших файлов).
- `dependsOn(unpackTask)`; `testAddon.dependsOn(<эта задача>)`.
- Если `testState.skippedPreRollout || testState.testsDisabled` — выйти без записи (как остальной код `testAddon`).

Алгоритм `doLast` (контракт поведения, не построчная реализация):

1. **Дескрипторы хоста.** Рекурсивно найти в каталогах `p.sourceSets.main.output.dirs` + `starterGeneratedDirs` файлы `persistence.xml` и `*-persistence.xml` (относительные пути и каталоги не хардкодятся — берётся то, что сгенерировал Jmix-плагин). Сгруппировать по имени файла (имя определяет хранилище). Из каждого извлечь: список `<class>`, список `<mapping-file>`, пары `<property name,value>`. Если ни в одном дескрипторе хоста нет ни одного `<class>` (хост без сущностей, пустые дескрипторы, которые Jmix-плагин создаёт по сообщению «has no entities. Empty 'persistence.xml' and 'orm.xml' will be generated»), — оверлей не создаётся, поведение `testAddon_<dep>` остаётся прежним (нулевой регресс для хостов без сущностей).
2. **Кандидаты зависимости.** Корни поиска, в порядке их следования на classpath `testAddon_*`: `classesDir`, затем артефакты `addonTestClasspath` с группой, начинающейся с `ru.thedevs` (разрешённые через `addonTestClasspath.resolvedConfiguration.resolvedArtifacts`, `moduleVersion.id.group`; тот же критерий `ru.thedevs` используется в `ci-addon-tests.init.gradle:346`). В корнях найти ресурсы с именем `persistence.xml` / `*-persistence.xml`, лежащие **вне** `META-INF/`. Для одинакового относительного пути использовать первое вхождение в порядке classpath (то же, что вернёт `ClassLoader`). Для каждого пути, имя файла которого есть среди дескрипторов хоста (п.1), сформировать объединённый дескриптор.
3. **Слияние (объединение множеств, дескриптор зависимости — основа):** сохранить `<persistence-unit>` зависимости как есть (имя, `<provider>`, `<exclude-unlisted-classes/>`, остальные элементы); добавить из хоста недостающие `<class>` и `<mapping-file>` (дедупликация по значению, порядок: сначала элементы зависимости, затем хоста); `<property>` хоста добавить, если имени ещё нет; для списочного свойства `io.jmix.enhancing.converters-list` выполнить объединение элементов списка с тем разделителем, который использует плагин (формат определить по реальному сгенерированному файлу при реализации, не вводить свой). Замещаемая сущность (`CorePhone`) остаётся в PU рядом с замещающей (`GpsPhone`): так это устроено в обычном Jmix-приложении, где в `persistence.xml` перечислены и базовые, и расширяющие сущности (наследование JPA); исключение базовых классов запрещено.
4. **Запись.** Записать результат в `persistence-overlay/<тот же относительный путь>`; при чтении/записи сохранять кодировку UTF-8 и корневой элемент с пространствами имён исходного файла. Разбор XML — стандартными средствами Groovy/JDK, доступными в init-скрипте (без новых зависимостей).
5. **Диагностика.** Для каждого созданного файла печатать одну строку `[TD-2521] Persistence overlay for '<baseModule>': <relPath> (+<N> host classes)`. Если дескрипторы хоста с классами есть, а кандидатов в зависимости не найдено — `::warning::[TD-2521] ...` (PU зависимости не содержит ни одного выбираемого дескриптора, оверлей не создан), задача не падает.

## 2. Classpath `testAddon_*`

В `testAddon.classpath` (`ci-addon-tests.init.gradle:630-641`) поставить каталог `persistence-overlay` **первым** элементом списка (перед `classesDir`), чтобы он перекрывал оригинальные дескрипторы как в `classesDir` (тестовый jar), так и в jar-ах `addonTestClasspath`. Остальной состав и порядок classpath не менять. Если оверлей не создан, каталог пуст и ни на что не влияет.

## 3. Контрактный тест `tests/test-setup-addon-tests.sh`

Расширить существующие фикстуры (структура и стиль проверок — как у TD-2499):

1. Upstream `itink-mod`: добавить сущностный класс-заглушку `ru.thedevs.itink.ItinkEntity`, дескриптор `src/main/resources/ru/thedevs/itink/persistence.xml` (`<class>ru.thedevs.itink.ItinkEntity</class>`, `<mapping-file>ru/thedevs/itink/orm.xml</mapping-file>`, `<exclude-unlisted-classes/>`, свойство `io.jmix.enhancing.converters-list` с одним элементом) и соответствующий `orm.xml`.
2. Downstream `consumer-mod`: в уже существующей задаче `generateDescriptors` (`tests/test-setup-addon-tests.sh:442-455`, эмуляция `registerGeneratedDescriptors`) помимо `orm.xml` создавать `ru/thedevs/consumer/persistence.xml` с `<class>ru.thedevs.consumer.ConsumerEntity</class>`, `<mapping-file>ru/thedevs/consumer/orm.xml</mapping-file>`, собственным элементом в `converters-list`; добавить класс `ru.thedevs.consumer.ConsumerEntity`.
3. В `ItinkTest` добавить проверки через `ClassLoader`: (а) первый ресурс `ru/thedevs/itink/persistence.xml` содержит и `ru.thedevs.itink.ItinkEntity`, и `ru.thedevs.consumer.ConsumerEntity`, и `ru/thedevs/itink/orm.xml`, и `ru/thedevs/consumer/orm.xml`, содержит ровно одно вхождение каждого `<class>` и `<exclude-unlisted-classes`; (б) списочное свойство содержит элементы зависимости и хоста; (в) ресурс `ru/thedevs/consumer/persistence.xml` (дескриптор хоста) остаётся доступным и не изменён.
4. В разделе валидации результатов: файл `build/addon-tests/itink/persistence-overlay/ru/thedevs/itink/persistence.xml` существует; оригинальный дескриптор в опубликованном `itink.jar` не изменён (оверлей не пишет в артефакты).
5. Негативный сценарий: второй downstream-хост (или переключатель в том же) без `<class>` в сгенерированных дескрипторах — каталог `persistence-overlay` пуст/отсутствует содержимое, `ClassLoader` отдаёт оригинальный дескриптор зависимости (тест подтверждает «нулевой регресс» для хостов без сущностей).

## 4. Документация

Создать `AGENTS.md` в корне `THEDEVS-RU/.github` (в репозитории его нет; `README.md` — приветственная страница организации и для технического описания не подходит) с разделом «setup-addon-tests: изоляция тестов зависимостей (TD-2039, TD-2499, TD-2521)»: схема classpath `testAddon_<dep>`; фильтрация `AutoConfiguration.imports` хоста (TD-2499); оверлей `persistence.xml` (TD-2521) — зачем нужен (метамодель сканирует `ru.thedevs.**`, PU берётся из одного дескриптора листового модуля, ссылки на `JmixBaseEntityManagerFactoryBean#setupPersistenceUnit` и `JmixModulesClasspathScanner`), что именно сливается, какие хосты затрагиваются, как диагностировать (строки `[TD-2521]` в логе, каталог `build/addon-tests/<dep>/persistence-overlay`), известный компромисс и ограничения (раздел «Компромиссы и риски» ниже). Строка-указатель на `AGENTS.md` в `README.md` не добавляется.

## Затрагиваемые файлы

1. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
2. `tests/test-setup-addon-tests.sh`
3. `AGENTS.md` (новый)

# Что уже есть

- Изоляция тестов зависимостей TD-2039 и фильтрация автоконфигураций TD-2499: `ci-addon-tests.init.gradle:315-678`; на classpath уже лежат `p.sourceSets.main.output.dirs` и `starterGeneratedDirs` (там сгенерированные Jmix-дескрипторы хоста).
- Эмуляция `registerGeneratedDescriptors` в тест-фикстуре: `tests/test-setup-addon-tests.sh:442-455`; проверка того, что `output.dir`-ресурс хоста виден: `tests/test-setup-addon-tests.sh:97-98`.
- Рабочие примеры, на которых нельзя получить регресс (критерий 2): `addon-core-crypto` (`testAddon_balance`), `addon-cryptoconnector`, `addon-uniteller`. Хосты с собственными сущностями в `ru.thedevs.**` (например uniteller, `ru.thedevs.integration.uniteller`) после изменения получат их же в PU, что согласуется с их присутствием в метамодели уже сейчас.

## Проверенные API

- `dep-sources/io.jmix.data/jmix-data-3.0.0@local:io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:38` (`setupPersistenceUnit`, обход модулей от листового, `classpath:` + путь)
- `dep-sources/io.jmix.data/jmix-data-3.0.0@local:io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:57` (`getPersistenceXmlPath`: `<basePackage>/[<store>-]persistence.xml`)
- `dep-sources/io.jmix.data/jmix-data-3.0.0@local:io/jmix/data/impl/JmixEntityManagerFactoryBean.java:39` (вызов `setupPersistenceUnit()` в конструкторе; переопределить через свойство нельзя)
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/JmixModulesProcessor.java:103` (базовый пакет = пакет конфигурационного класса)
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/impl/scanning/JmixModulesClasspathScanner.java:67` (сканирование базовых пакетов всех модулей)
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/impl/MetadataLoader.java:176` (`@ReplaceEntity` в метамодели)
- `dep-sources/io.jmix.core/jmix-core-3.0.0@local:io/jmix/core/entity/annotation/ReplaceEntity.java:27`
- `dep-sources/io.jmix.gradle/jmix-gradle-plugin-3.0.0@local:io/jmix/gradle/EnhancingAction.class:1297` (`constructDescriptors`; артефакт `io.jmix.gradle:jmix-gradle-plugin:3.0.0`, исходников нет — проверено дизассемблированием `javap -c -p`, номер строки — строка вывода `javap`; тот же артефакт: `JmixPlugin.class#registerGeneratedDescriptors`, `EnhancingAction.class#generatedDescriptorsDir`, `DescriptorGenerationUtils.class#constructPersistenceXml`). Точный формат разделителя `io.jmix.enhancing.converters-list` определяется по реальному файлу при реализации (`:gpscore:enhanceJmixMain` в клоне `addon-core-gps`), а не по предположению.
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:346` (критерий `ru.thedevs`), `:423` (`unpackTask`), `:597` (`testAddon.dependsOn(unpackTask)`), `:609` (`starterGeneratedDirs`), `:630` (`testAddon.classpath`)
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:97`, `:442`
- `THEDEVS-RU/addon-core-gps@dev:gpscore/src/main/java/ru/thedevs/core/gps/entity/GpsPhone.java:20`
- `THEDEVS-RU/addon-core@dev:core/src/main/java/ru/thedevs/CoreConfiguration.java:1`

Лог симптома: `THEDEVS-RU/addon-core-gps` run 40701518504, job 122862309424 (`:gpscore:testAddon_core SKIPPED`, `:gpscore:testAddon_coreui` FAILED).

## Альтернативы (рассмотрены и отклонены)

1. **Убрать классы хоста из метамодели/classpath `testAddon_*`** (или `thedevs.tests.disabled`, exclude). Прямо запрещено задачей и ослабляет TD-2447: тесты зависимости перестали бы проверять совместимость с заменой сущности.
2. **Подменить дескриптор целиком дескриптором хоста.** Потеряются тестовые сущности/mapping-файлы самой зависимости; слияние безопаснее.
3. **Вычислить победивший `persistence.xml`, воспроизведя сортировку Jmix-модулей в init-скрипте** (разбор `@JmixModule` в байткоде). Хрупко и дублирует Jmix; оверлей «для всех кандидатов зависимости» не требует знания порядка.
4. **Рантайм-хук в Spring-контексте теста** (BeanPostProcessor / подмена `LocalContainerEntityManagerFactoryBean` через `spring.factories` в харнессе). Требует компилировать Java внутри init-скрипта и ломает принцип «харнесс меняет только classpath»; отклонено.
5. **Правка `gpscore`/`coreui`** — запрещена постановкой.

## Компромиссы и риски

- Скрипт не воспроизводит сканирование метамодели (оно в рантайме Spring); он добавляет в PU все `<class>` из сгенерированных Jmix-дескрипторов хоста — надмножество сущностей хоста в метамодели. Во флоте сущности лежат в `ru.thedevs.**`, т.е. совпадают с областью сканирования `CoreConfiguration`; для хоста с сущностью вне сканируемых пакетов в PU окажется класс, которого нет в метамодели — это граничный случай, он отражён в диагностике и не проверяется отдельно (YAGNI).
- Дубли описаний одной сущности в `orm.xml` хоста и зависимости (хостовый дескриптор Jmix может включать и сущности зависимостей) — возможное место расхождения с поведением EclipseLink; `<class>` и `<mapping-file>` дедуплицируются по значению. Подтверждается только запуском на реальном `addon-core-gps` (критерий 1).
- `testAddon_<dep>` перестаёт быть «чистым» относительно PU хоста; это сознательное решение (см. «Контекст»), симметричное тому, что метамодель хоста там уже присутствует.

# Критерии готовности

1. В `actions/setup-addon-tests/ci-addon-tests.init.gradle` для каждого `testAddon_<dep>` зарегистрирована задача `buildHostPersistenceOverlay_<dep>`, формирующая в `build/addon-tests/<dep>/persistence-overlay` объединённые дескрипторы (дескриптор зависимости ∪ `<class>`/`<mapping-file>`/свойства сгенерированных Jmix-дескрипторов хоста, без хардкода списков сущностей и путей); каталог — первый элемент `testAddon.classpath`; хосты без `<class>` в дескрипторах хоста не получают изменений classpath.
2. Замещаемые сущности не исключаются, исходные артефакты не модифицируются, автоконфигурации хоста по-прежнему отфильтрованы (TD-2499), `thedevs.tests.disabled`/exclude не используются.
3. `tests/test-setup-addon-tests.sh` содержит проверки п.3 раздела «Что сделать» (объединённый дескриптор виден через `ClassLoader` первым, дедупликация, негативный сценарий без сущностей) и существующие проверки TD-2039/TD-2499 остаются в силе.
4. `AGENTS.md` в корне `THEDEVS-RU/.github` описывает решение и диагностику.
5. Спецификация валидируется `validate-spec-format.sh` с кодом 0.
6. Верификация после доставки в `dev` (ветка, на которую ссылаются workflow хостов через `THEDEVS-RU/.github@dev`): перезапуск CI на PR THEDEVS-RU/addon-core-gps#44 даёт зелёный `:gpscore:testAddon_coreui` без правок тестов gpscore и coreui; перезапуск CI на `addon-core-crypto` (`testAddon_balance`), `addon-cryptoconnector`, `addon-uniteller` подтверждает отсутствие регресса.

# Не трогать

- Любой код и тесты продуктовых репозиториев (`addon-core-gps`, `addon-core-ui`, `addon-core`, `addon-balance`, `addon-uniteller`, `addon-core-crypto`, `addon-cryptoconnector`).
- Фильтрацию `AutoConfiguration.imports` (`filterHostMainResources_*`, `filterHostStarterResources_*`), агрегированный Liquibase-changelog, системные свойства Liquibase и публикацию `*-tests` (GMM остаётся отключённым).
- `p.sourceSets.main.output.classesDirs`, `starterClassesDirs` в составе `testAddon.classpath` — классы хоста с classpath не убираются.
- `README.md` организации (приветственная страница).
