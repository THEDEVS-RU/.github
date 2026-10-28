# AGENTS.md — .github

Правила, архитектурные инварианты, соглашения и контекст для AI-агентов (Antigravity, Claude Code, Codex и др.), работающих с репозиторием `THEDEVS-RU/.github`.

---

## 1. Назначение репозитория

Репозиторий `THEDEVS-RU/.github` содержит централизованные переиспользуемые workflow GitHub Actions, составные экшены (composite actions), init-скрипты Gradle и скрипты контрактного тестирования инфраструктуры CI/CD организации TheDevs.

---

## 2. setup-addon-tests: изоляция тестов зависимостей (TD-2039, TD-2499, TD-2521)

Составной action `actions/setup-addon-tests` и его канонический init-скрипт `actions/setup-addon-tests/ci-addon-tests.init.gradle` реализуют архитектуру запуска тестов прямых зависимостей (`testAddon_<dep>`) в контексте хост-проекта.

### Схема classpath `testAddon_<dep>`

Для каждого `testAddon_<dep>` формируется изолированный classpath с детерминированным порядком разрешения ресурсов:
1. `build/addon-tests/<dep>/persistence-overlay` — оверлей persistence unit (TD-2521); добавляется первым элементом classpath лениво и только при наличии в нём файлов;
2. `build/addon-tests/<dep>/classes` — каталог распакованного артефакта тестов зависимости (`<dep>-tests.jar`);
3. `build/addon-tests/<dep>/aggregate-changelog.xml` — каталог агрегированного Liquibase-мастера;
4. `build/addon-tests/<dep>/host-resources/main` и `host-resources/starter` — каталоги отфильтрованных ресурсов хоста (TD-2499);
5. `addonTestClasspath_<dep>` — транзитивные зависимости тестов (разрешаются согласованно с `runtimeClasspath`);
6. `sourceSets.main.output.classesDirs` — скомпилированные классы основного модуля хоста;
7. `sourceSets.main.output.dirs` — сгенерированные дескрипторы хоста (`build/generated/jmix-descriptors/main`);
8. `starterClassesDirs` и `starterGeneratedDirs` — классы и сгенерированные дескрипторы сопутствующего `-starter` модуля хоста (при наличии);
9. `runtimeClasspath` — runtime classpath хост-проекта.

### Фильтрация AutoConfiguration.imports хоста (TD-2499)

При запуске тестов зависимости классы хоста обязаны присутствовать на classpath (для проверки бинарной и метамодельной совместимости), однако автоконфигурации хоста не должны загружаться в Spring-контекст зависимости, так как они инициализируют инфраструктурные бины хоста, не относящиеся к тестам зависимости.
Задачи `filterHostMainResources_<dep>` и `filterHostStarterResources_<dep>` копируют ресурсы хоста в каталоги `host-resources/main` и `host-resources/starter`, исключая дескриптор `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`.

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
- Оверлей добавляет в PU все `<class>` из сгенерированных Jmix-дескрипторов хоста (надмножество сущностей хоста).
- `orm.xml` хоста является источником истины для всех описанных в нём сущностей при конфликтах `target-entity`.
- Запуск тестов зависимости происходит в приближённом к боевому окружению PU (включающем сущности хоста), что предотвращает скрытые несовместимости при подмене сущностей.

---

## 3. Контрактное тестирование

Репозиторий валидируется контрактными тестами:
- `tests/test-kaniko-build.sh` — контрактные тесты Kaniko build;
- `tests/test-setup-addon-tests.sh` — контрактные тесты `setup-addon-tests`:
  - Публикация `-tests.jar` и отключение GMM;
  - Изоляция classpath и фильтрация `AutoConfiguration.imports` (TD-2499);
  - Формирование оверлея `persistence.xml` и объединение классов/конвертеров (TD-2521);
  - Затенение `orm.xml` при конфликте `target-entity` (TD-2521);
  - Негативный сценарий для хостов без сущностей (нулевой регресс, TD-2521);
  - Поведение `thedevs.tests.strict` vs pre-rollout.
