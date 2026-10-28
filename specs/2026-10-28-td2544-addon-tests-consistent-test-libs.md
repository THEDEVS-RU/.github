id: 2026-10-28-td2544-addon-tests-consistent-test-libs
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

Задача TD-2544 выявлена на ревью спеки TD-2543 (`addon-core@task/TD-2543`). Правки тестовых библиотек платформы (`ru.thedevs:core-test`, `ru.thedevs:coreui-test`) не доходят до `testAddon_<dep>` хоста без перепубликации каждой зависимости. Тот же класс отставаний: TD-2522, TD-2532, TD-2543.

## Факты (подтверждены чтением `THEDEVS-RU/.github@dev` 5783459)

1. При публикации `<dep>-tests.jar` init-скрипт пишет в POM пины всех компонентов `testRuntimeClasspath` зависимости со scope `runtime`; платформы (Category `REGULAR_PLATFORM`/`ENFORCED_PLATFORM`) исключаются (`actions/setup-addon-tests/ci-addon-tests.init.gradle:570-589`). Пример из постановки: `cryptocollector-tests-3.0.0.108.pom` пинит `ru.thedevs:core-test:3.0.0.86`.
2. `addonTestClasspath_<mod>` = `<dep>-tests:<ver>` + `shouldResolveConsistentlyWith(runtimeClasspath)` (`ci-addon-tests.init.gradle:742-747`). Согласование Gradle действует только на модули, присутствующие в `runtimeClasspath` хоста. `core-test` у хоста объявлен как `testImplementation`, в `runtimeClasspath` его нет, поэтому пин из `-tests.pom` остаётся.
3. Classpath `testAddon_<mod>` ставит `addonTestClasspath` раньше `runtimeClasspath` хоста (`ci-addon-tests.init.gradle:1335-1349`), поэтому `AbstractPostgresIntegrationTest` берётся из старого пина.
4. BOM `ru.thedevs:thedevs-bom` (`artifactId = 'thedevs-bom'`, `THEDEVS-RU/bom@dev:build.gradle:102`) содержит ограничения на тестовые библиотеки: `lcoretest = ru.thedevs:core-test` (version.ref = `core`), `lcoreuitest = ru.thedevs:coreui-test` (`THEDEVS-RU/bom@dev:gradle/libs.versions.toml:48,50`; список `constraints` в `THEDEVS-RU/bom@dev:build.gradle`). Но в `addonTestClasspath_*` этот BOM не подключён.

## Раскладка хостов (чтение `@dev`)

| Хост | BOM в `api` | `core-test` в `testImplementation` | Источник |
|---|---|---|---|
| addon-coinex | `enforcedPlatform` | да (`libs.coreTest`) | `THEDEVS-RU/addon-coinex@dev:coinex/coinex.gradle:4,13` |
| addon-crypto-collector | `enforcedPlatform` | да | `THEDEVS-RU/addon-crypto-collector@dev:cryptocollector/cryptocollector.gradle:6,18` |
| addon-core-crypto | `enforcedPlatform` | да | `THEDEVS-RU/addon-core-crypto@dev:cryptocore/cryptocore.gradle:11,21` |
| addon-cryptoconnector | `enforcedPlatform` | да | `THEDEVS-RU/addon-cryptoconnector@dev:cryptoconnector/cryptoconnector.gradle:12,18` |
| addon-core-ui | `enforcedPlatform` | через `project(':coreui-test')`, который сам `api libs.core.test` | `THEDEVS-RU/addon-core-ui@dev:coreui/coreui.gradle:11,16`, `coreui-test/coreui-test.gradle:9` |
| addon-core-gps | `platform` (не enforced) | **нет** (только `spring-boot-starter-test`, `junit-platform-launcher`) | `THEDEVS-RU/addon-core-gps@dev:gpscore/gpscore.gradle:2,12,15` |

Вывод: согласование с `testRuntimeClasspath` закрывает 5 хостов из 6. `addon-core-gps` зависит от `core` и `coreui` (`gpscore.gradle:5-6`), чьи `-tests.pom` пинят тестовые библиотеки, но `core-test` в его `testRuntimeClasspath` нет — для него версии тестовых библиотек может задать только BOM.

# Что сделать

Решение: в `addonTestClasspath_<mod>` версии тестовых библиотек задаются хостом, без захардкоженных координат, в два слоя.

## 1. Согласование с `testRuntimeClasspath`

В `ci-addon-tests.init.gradle` в блоке создания `addonTestClasspath_${baseModule}` (строка 746) заменить `shouldResolveConsistentlyWith(runtimeClasspath)` на `shouldResolveConsistentlyWith(testRuntimeClasspath)`, где `testRuntimeClasspath = p.configurations.findByName('testRuntimeClasspath')`, определяется один раз рядом с `runtimeClasspath` (строка 658). Если `testRuntimeClasspath` отсутствует — использовать `runtimeClasspath` (поведение до задачи).

`testRuntimeClasspath` расширяет `runtimeClasspath` (Gradle Java plugin: `testRuntimeOnly extendsFrom runtimeOnly`, `testImplementation extendsFrom implementation`), поэтому всё, что было согласовано до задачи, остаётся согласованным; добавляются тестовые зависимости хоста (`core-test`, `coreui-test`, `jmix-flowui-test-assist` и др.).

## 2. BOM хоста в `addonTestClasspath_*` с сохранением категории платформы

Для хостов, у которых тестовой библиотеки нет в `testRuntimeClasspath` (`addon-core-gps`), добавить в `addonTestClasspath_${baseModule}` платформы хоста в той же категории, в какой их разрешил хост:

1. Функция верхнего уровня `platformCategoryOf(ResolvedComponentResult)` (рядом с `resolveHostMainLiquibaseChangelog`): возвращает `'enforced'`, если среди `variants` компонента есть вариант с Category `ENFORCED_PLATFORM`; иначе `'regular'`, если есть `REGULAR_PLATFORM`; иначе `null` (не платформа). Обёртка `try/catch` вокруг чтения атрибута — как в существующей проверке.
2. Один раз на проект (до `candidateAddons.each`, строка 735) собрать список платформ: компоненты `runtimeClasspath.incoming.resolutionResult.allComponents`, у которых `id instanceof ModuleComponentIdentifier`, `id.group.startsWith('ru.thedevs')` и `platformCategoryOf(comp) != null`. Координаты и версия берутся из результата разрешения, не из констант.
3. Для каждой найденной платформы добавить в `addonTestClasspath_${baseModule}`: `p.dependencies.enforcedPlatform("<group>:<name>:<version>")`, если категория `'enforced'`; `p.dependencies.platform("<group>:<name>:<version>")`, если `'regular'`. Категория сохраняется, потому что согласованное разрешение (п.1) — жёсткое ограничение (Gradle: «If a version conflict arises that cannot be reconciled, Gradle will fail the build», dependency_resolution_consistency). Хост с обычной `platform` (gps) допускает транзитивное требование выше версии BOM; безусловный `enforcedPlatform` принудил бы версию BOM и конфликтовал с п.1. Обычная `platform` поднимает устаревший пин из `-tests.pom` до версии BOM (случай задачи) и не конфликтует с версиями хоста.
4. Платформы групп вне `ru.thedevs` (Jmix BOM, Spring BOM) не добавляются: их версии уже закреплены согласованием из п.1.
5. Существующую проверку Category на `:687-696` (отбор прямых зависимостей `candidateAddons`) заменить вызовом `platformCategoryOf(selected) != null` без изменения поведения; проверку в блоке публикации `:580-589` не трогать (см. «Не трогать»).

## 3. Журналирование

Для каждой конфигурации печатать одну строку `[TD-2544] addonTestClasspath_<mod>: consistent with testRuntimeClasspath, platforms=[<group>:<name>:<version>(enforced|regular),...]` (список пуст — `platforms=[]`; категория в логе обязательна) — по образцу строк `[TD-2521]`/`[TD-2533]` в скрипте.

## 4. Контрактный тест `tests/test-setup-addon-tests.sh`

Расширить фикстуры (новые фикстурные модули `managed-lib` (версии 1.0.0 и 1.2.0), `needs-managed`, `fixture-bom`; `helper-test` — тестовая библиотека, пиннится в `itink-tests.pom`, `tests/test-setup-addon-tests.sh:325,381-415,670`):

1. Опубликовать вторую версию `ru.thedevs:helper-test` (например `1.1.0`) в тот же `local-repo`; `itink-tests.pom` остаётся с пином `1.0.0` (сценарий «зависимость не перепубликовывалась»).
2. Сценарий A (хост объявляет библиотеку): downstream-хост с `testImplementation 'ru.thedevs:helper-test:1.1.0'`. Проверка: `gradle dependencyInsight --configuration addonTestClasspath_itink --dependency helper-test` содержит `1.1.0` и не выбирает `1.0.0`.
3. Сценарий B (хост не объявляет, но подключает BOM): фикстурный BOM `ru.thedevs:fixture-bom` (java-platform) с constraint `ru.thedevs:helper-test:1.1.0`, подключён хостом в `implementation` как `platform(...)` (не enforced, как в `gpscore.gradle:2`). Проверка тем же `dependencyInsight`: выбрана `1.1.0`.
4. Сценарий C (регресс): существующий `consumer-mod` из TD-2039 — все прежние проверки остаются зелёными; в логе присутствует строка `[TD-2544] addonTestClasspath_itink:`.
5. Сценарий D (конфликт слоёв, обычная `platform`): фикстурный BOM `ru.thedevs:fixture-bom` с constraint `ru.thedevs:managed-lib:1.0.0`, подключён хостом как `platform(...)`; `itink-mod` имеет `managed-lib:1.0.0` в `testRuntimeClasspath` (пин `1.0.0` попадает в `itink-tests.pom`); другая зависимость хоста (`ru.thedevs:needs-managed`) в POM требует `managed-lib:1.2.0`, поэтому `testRuntimeClasspath` хоста разрешает `managed-lib` в `1.2.0` (обычная `platform` — constraint, побеждает старшая). Ожидание: `gradle dependencyInsight --configuration addonTestClasspath_itink --dependency managed-lib` выполняется без ошибки согласованного разрешения, выбрана `1.2.0`, версия совпадает с `dependencyInsight --configuration testRuntimeClasspath --dependency managed-lib` хоста; в логе `[TD-2544]` указана категория `regular`.
6. Сценарий E (категория сохраняется, `enforcedPlatform`): как сценарий B, но хост подключает `fixture-bom` как `enforcedPlatform(...)`; ожидание — выбрана `helper-test:1.1.0`, в логе категория `enforced`.

Конкретный набор фикстурных модулей и порядок публикации выбирает исполнитель по образцу существующих `nested-lib`/`transit-lib`; новые классы логики в тестовых модулях не нужны (достаточно разных версий артефакта).

## 5. Документация

В `AGENTS.md`: пункт 5 схемы classpath (строка 24) переписать — «разрешаются согласованно с `testRuntimeClasspath` хоста; платформы `ru.thedevs` хоста применяются в той же категории, что и в графе хоста (`platform` или `enforcedPlatform`)»; добавить подраздел «Версии тестовых библиотек в addonTestClasspath (TD-2544)» с механизмом (п.1-2 «Контекста») и контрактом: версии тестовых библиотек определяет хост, перепубликация зависимостей не требуется. Дописать TD-2544 в заголовок раздела 2 (`AGENTS.md:13`); на `dev` в нём перечислены TD-2039, TD-2499, TD-2521, TD-2526, TD-2533 добавляется параллельной правкой — исполнитель дописывает TD-2544 к фактическому содержимому заголовка на момент реализации.

В `references/ci-standards.md` плагина builder правок не требуется: он не описывает `addonTestClasspath_*` (grep по файлу — только §7 про шаги `Run addon dependency tests`; шаг и команда не меняются).

## Затрагиваемые файлы

- `THEDEVS-RU/.github`: `actions/setup-addon-tests/ci-addon-tests.init.gradle`
- `THEDEVS-RU/.github`: `tests/test-setup-addon-tests.sh`
- `THEDEVS-RU/.github`: `AGENTS.md`

# Потребители

Репозиторий — общий init-скрипт CI, не аддон; потребители — аддоны с шагом `Run addon dependency tests` (`./gradlew testAddonDependencies -I "$THEDEVS_ADDON_TESTS_INIT"`, `ci-standards.md` §7):

- addon-core-ui, addon-core-crypto, addon-cryptoconnector, addon-coinex, addon-crypto-collector: `core-test`/`coreui-test` в `addonTestClasspath_*` теперь версии хоста (из его `testRuntimeClasspath`).
- addon-core-gps (BOM подключён обычной `platform`, `gpscore.gradle:2-4`): в `addonTestClasspath_*` добавляется `platform(ru.thedevs:thedevs-bom:<версия хоста>)`; устаревший пин тестовой библиотеки из `-tests.pom` поднимается до версии BOM, версии хоста не затрагиваются и конфликта согласованного разрешения нет.
- Хосты с `enforcedPlatform` (coinex, cryptocollector, cryptocore, cryptoconnector, coreui): BOM добавляется как `enforcedPlatform` — конфигурация зеркалит `runtimeClasspath` хоста.
- Остальные аддоны с зависимостями `ru.thedevs:*` получают то же поведение автоматически; перепубликации зависимостей не требуется.
- Публикация `<dep>-tests.jar`/POM (строки 570-640) не меняется: пины в уже опубликованных POM остаются, но перекрываются хостом при разрешении.

# Что уже есть

- Харнесс TD-2039 и последующие (TD-2499, TD-2521, TD-2526, TD-2533): `actions/setup-addon-tests/ci-addon-tests.init.gradle`, контрактный тест `tests/test-setup-addon-tests.sh`, документ `AGENTS.md`.
- Определение платформ по Category — уже есть в двух местах скрипта (`:580-589` в блоке публикации, `:687-696` при отборе зависимостей).
- Параллельные спеки того же init-скрипта (`specs/2026-10-28-td2521-…`, `td2526-…`, `td2533-…`) правят другие регионы (persistence overlay, хранилища, Liquibase); пересечение — только в `AGENTS.md` и контрактном тесте (возможны конфликты слияния без логических).

## Проверенные API

- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:10` (`import org.gradle.api.attributes.Category`), `:580-589`, `:687-696` (проверка Category платформы), `:658`, `:671` (`runtimeClasspath.incoming.resolutionResult`), `:746` (`shouldResolveConsistentlyWith`), `:1335-1349` (classpath).
- `ResolutionResult.getAllComponents()` — `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:576` (`resolutionResult.allComponents.each`).
- `DependencyHandler.platform(Object)` и `DependencyHandler.enforcedPlatform(Object)` — публичный API Gradle, не deprecated в 9.5.1: https://docs.gradle.org/9.5.1/javadoc/org/gradle/api/artifacts/dsl/DependencyHandler.html. Версия Gradle хостов — 9.5.1: `THEDEVS-RU/addon-core-gps@dev:gradle/wrapper/gradle-wrapper.properties` (`distributionUrl=…gradle-9.5.1-bin.zip`), то же в `addon-coinex@dev` и `addon-core-ui@dev`. DSL-использование хостами: `THEDEVS-RU/addon-core-gps@dev:gpscore/gpscore.gradle:2` (`platform`), `THEDEVS-RU/addon-coinex@dev:coinex/coinex.gradle:4` (`enforcedPlatform`).
- `ResolvedComponentResult.getVariants()` / `ResolvedVariantResult.getAttributes()` — `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:580-582` (`comp.variants.any { v -> v.attributes.getAttribute(Category.CATEGORY_ATTRIBUTE) }`).
- `Configuration.shouldResolveConsistentlyWith(Configuration)` — `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:746`.
- `THEDEVS-RU/bom@dev:gradle/libs.versions.toml:48` (`lcoretest`), `:50` (`lcoreuitest`); `THEDEVS-RU/bom@dev:build.gradle:102` (`artifactId = 'thedevs-bom'`).

## Альтернативы

1. **Только слой 1** (`shouldResolveConsistentlyWith(testRuntimeClasspath)`) — предпочтительное направление постановки, минимум изменений. Закрывает 5 из 6 хостов; `addon-core-gps` остаётся на пине из `-tests.pom`. Отклонено как единственное решение: тот же класс отставания останется у любого хоста без `core-test` в тестовом classpath (подтверждённый потребитель — gps).
2. **Захардкодить `ru.thedevs:core-test` и `coreui-test` в init-скрипте** — запрещено постановкой и не масштабируется на новые тестовые библиотеки.
3. **Не писать пины тестовых библиотек в `-tests.pom` при публикации** (исключить `*-test` из блока `:570-640`) — исправляет причину, но только для будущих публикаций; нужна перепубликация каждой зависимости, чего задача требует избежать.
4. **Безусловный `enforcedPlatform`** (первая редакция) — отклонён: у хоста с обычной `platform` (gps) транзитивное требование может поднять модуль выше версии BOM; `testRuntimeClasspath` хоста получает версию X > BOM, слой 1 требует X, `enforcedPlatform` принуждает версию BOM, согласованное разрешение — жёсткое ограничение, и `addonTestClasspath_*` не разрешается либо расходится с classpath хоста.
5. **Безусловная обычная `platform`** — не конфликтует с хостом, но у хоста с `enforcedPlatform` при пине тестовой библиотеки выше версии BOM (BOM отстаёт) побеждал бы пин, а не BOM хоста. Категория по хосту зеркалит `runtimeClasspath` в обоих случаях; выбрано сохранение категории.

Расхождение с постановкой: добавлен слой 2 (BOM хоста) сверх предложенного «`testRuntimeClasspath` вместо `runtimeClasspath`». Основание — конкретный потребитель `addon-core-gps` (таблица выше); слой 1 заявленные критерии для coinex выполняет сам. Ревью вправе принять только слой 1.

## Компромиссы и риски

- `testRuntimeClasspath` может разрешать общий модуль в более новую версию, чем `runtimeClasspath` (тестовая зависимость хоста тянет его выше). `addonTestClasspath` последует за ним; это то поведение, при котором тесты зависимости видят те же версии, что и тесты хоста. Регресс-индикатор — зелёный `Run addon dependency tests` у хостов из критерия 2.
- Если `testRuntimeClasspath` не разрешается (ошибка репозитория), `addonTestClasspath_*` тоже не разрешится; ранее та же зависимость от `runtimeClasspath` уже была, класс отказа не новый.
- Категория платформы сохраняется по хосту: у хоста с `enforcedPlatform` версии BOM принудительны и в `runtimeClasspath`, и в `addonTestClasspath_*`, поэтому конфигурации не расходятся; у хоста с обычной `platform` BOM — только constraint (побеждает старшая версия), версии выше BOM остаются как у хоста, а конфликт со слоем 1 исключён. Остаточный риск: платформа подключена хостом в обеих категориях сразу — тогда применяется `enforced` (приоритет в `platformCategoryOf`), что совпадает с поведением Gradle в графе хоста.
- Хост подключает платформу через `testImplementation`, а не `api`/`implementation`: такая платформа есть только в `testRuntimeClasspath`, слой 2 её не видит (читается `runtimeClasspath`); версии модулей из неё всё равно закрепляет слой 1. Подтверждённых хостов с таким подключением нет (`grep` по шести хостам таблицы).

# Критерии готовности

1. В `ci-addon-tests.init.gradle` `addonTestClasspath_<mod>` согласуется с `testRuntimeClasspath` (fallback `runtimeClasspath`) и получает платформы `ru.thedevs` из `runtimeClasspath` хоста в той же категории (`platform` / `enforcedPlatform`); координаты `core-test`/`coreui-test` в скрипте не встречаются.
2. Контрактный тест `tests/test-setup-addon-tests.sh` содержит сценарии A, B, C, D, E п.4 «Что сделать».
3. `AGENTS.md` содержит подраздел TD-2544 и обновлённый пункт 5 схемы classpath.
4. Верификация после доставки в `dev` (на стороне CI хостов, не в рамках arch): `./gradlew dependencyInsight --configuration addonTestClasspath_cryptocollector --dependency core-test` на addon-coinex показывает версию `core-test` из BOM хоста, а не `3.0.0.86` из `cryptocollector-tests-3.0.0.108.pom`.
5. Верификация после доставки: `Run addon dependency tests` зелёный у addon-core-ui, addon-core-crypto, addon-core-gps, addon-cryptoconnector (зелёные по TD-2039) и addon-coinex.
6. Спецификация проходит `validate-spec-format.sh` с кодом 0.

# Не трогать

- Блок публикации `<dep>-tests.jar` и генерацию POM (`ci-addon-tests.init.gradle:~500-645`), включая проверку Category на `:580-589` (не заменять функцией `platformCategoryOf`); заменяется только проверка на `:687-696`; `GenerateModuleMetadata.enabled = false` сохраняется.
- Логику TD-2499 (фильтрация `AutoConfiguration.imports`), TD-2521 (persistence overlay), TD-2526 (хранилища), TD-2533 (Liquibase) и порядок элементов classpath `testAddon_*` (`:1335-1349`).
- Продуктовые репозитории хостов и зависимостей, `THEDEVS-RU/bom`, `references/ci-standards.md` и workflow-файлы.
