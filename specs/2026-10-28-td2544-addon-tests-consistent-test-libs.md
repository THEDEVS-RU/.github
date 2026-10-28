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
4. BOM `ru.thedevs:bom` содержит ограничения на тестовые библиотеки: `lcoretest = ru.thedevs:core-test` (version.ref = `core`), `lcoreuitest = ru.thedevs:coreui-test` (`THEDEVS-RU/bom@dev:gradle/libs.versions.toml:48,50`; список `constraints` в `THEDEVS-RU/bom@dev:build.gradle`). Но в `addonTestClasspath_*` этот BOM не подключён.

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

## 2. BOM хоста в `addonTestClasspath_*`

Для хостов, у которых тестовой библиотеки нет в `testRuntimeClasspath` (`addon-core-gps`), добавить в `addonTestClasspath_${baseModule}` платформы хоста:

1. Один раз на проект (до `candidateAddons.each`, строка 735) собрать список платформ: компоненты `runtimeClasspath.incoming.resolutionResult.allComponents`, у которых `id instanceof ModuleComponentIdentifier`, `group.startsWith('ru.thedevs')` и `variants` содержат Category `REGULAR_PLATFORM` или `ENFORCED_PLATFORM` (та же проверка, что в строках 580-589 и 687-696; вынести в общую функцию верхнего уровня `isPlatformComponent`, чтобы не дублировать третий раз). Координаты берутся из результата разрешения, не из констант.
2. Для каждой найденной платформы добавить в `addonTestClasspath_${baseModule}` зависимость `enforcedPlatform(<group>:<name>:<version>)` через `p.dependencies`. `enforcedPlatform`, а не `platform`: критерий 1 требует, чтобы версия BOM хоста побеждала пин из `-tests.pom` детерминированно (обычная `platform` — это constraint с правилом «побеждает старшая версия»).
3. Платформы групп вне `ru.thedevs` (Jmix BOM, Spring BOM) не добавляются: их версии уже закреплены согласованием из п.1.

## 3. Журналирование

Для каждой конфигурации печатать одну строку `[TD-2544] addonTestClasspath_<mod>: consistent with testRuntimeClasspath, platforms=[<group>:<name>:<version>,...]` (список пуст — `platforms=[]`) — по образцу строк `[TD-2521]`/`[TD-2533]` в скрипте.

## 4. Контрактный тест `tests/test-setup-addon-tests.sh`

Расширить фикстуры (`helper-test` — тестовая библиотека, пиннится в `itink-tests.pom`, `tests/test-setup-addon-tests.sh:325,381-415,670`):

1. Опубликовать вторую версию `ru.thedevs:helper-test` (например `1.1.0`) в тот же `local-repo`; `itink-tests.pom` остаётся с пином `1.0.0` (сценарий «зависимость не перепубликовывалась»).
2. Сценарий A (хост объявляет библиотеку): downstream-хост с `testImplementation 'ru.thedevs:helper-test:1.1.0'`. Проверка: `gradle dependencyInsight --configuration addonTestClasspath_itink --dependency helper-test` содержит `1.1.0` и не выбирает `1.0.0`.
3. Сценарий B (хост не объявляет, но подключает BOM): фикстурный BOM `ru.thedevs:fixture-bom` (java-platform) с constraint `ru.thedevs:helper-test:1.1.0`, подключён хостом в `implementation` как `platform(...)` (не enforced, как в `gpscore.gradle:2`). Проверка тем же `dependencyInsight`: выбрана `1.1.0`.
4. Сценарий C (регресс): существующий `consumer-mod` из TD-2039 — все прежние проверки остаются зелёными; в логе присутствует строка `[TD-2544] addonTestClasspath_itink:`.

Конкретный набор фикстурных модулей и порядок публикации выбирает исполнитель по образцу существующих `nested-lib`/`transit-lib`; новые классы логики в тестовых модулях не нужны (достаточно разных версий артефакта).

## 5. Документация

В `AGENTS.md`: пункт 5 схемы classpath (строка 24) переписать — «разрешаются согласованно с `testRuntimeClasspath` хоста; платформы `ru.thedevs` хоста применяются как `enforcedPlatform`»; добавить подраздел «Версии тестовых библиотек в addonTestClasspath (TD-2544)» с механизмом (п.1-2 «Контекста») и контрактом: версии тестовых библиотек определяет хост, перепубликация зависимостей не требуется. Добавить TD-2544 в заголовок раздела 2.

В `references/ci-standards.md` плагина builder правок не требуется: он не описывает `addonTestClasspath_*` (grep по файлу — только §7 про шаги `Run addon dependency tests`; шаг и команда не меняются).

## Затрагиваемые файлы

- `THEDEVS-RU/.github`: `actions/setup-addon-tests/ci-addon-tests.init.gradle`
- `THEDEVS-RU/.github`: `tests/test-setup-addon-tests.sh`
- `THEDEVS-RU/.github`: `AGENTS.md`

# Потребители

Репозиторий — общий init-скрипт CI, не аддон; потребители — аддоны с шагом `Run addon dependency tests` (`./gradlew testAddonDependencies -I "$THEDEVS_ADDON_TESTS_INIT"`, `ci-standards.md` §7):

- addon-core-ui, addon-core-crypto, addon-cryptoconnector, addon-coinex, addon-crypto-collector: `core-test`/`coreui-test` в `addonTestClasspath_*` теперь версии хоста (из его `testRuntimeClasspath`).
- addon-core-gps: версии тестовых библиотек определяются `enforcedPlatform` BOM хоста.
- Остальные аддоны с зависимостями `ru.thedevs:*` получают то же поведение автоматически; перепубликации зависимостей не требуется.
- Публикация `<dep>-tests.jar`/POM (строки 570-640) не меняется: пины в уже опубликованных POM остаются, но перекрываются хостом при разрешении.

# Что уже есть

- Харнесс TD-2039 и последующие (TD-2499, TD-2521, TD-2526, TD-2533): `actions/setup-addon-tests/ci-addon-tests.init.gradle`, контрактный тест `tests/test-setup-addon-tests.sh`, документ `AGENTS.md`.
- Определение платформ по Category — уже есть в двух местах скрипта (`:580-589`, `:687-696`).
- Параллельные спеки того же init-скрипта (`specs/2026-10-28-td2521-…`, `td2526-…`, `td2533-…`) правят другие регионы (persistence overlay, хранилища, Liquibase); пересечение — только в `AGENTS.md` и контрактном тесте (возможны конфликты слияния без логических).

## Проверенные API

- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:10` (`import org.gradle.api.attributes.Category`), `:580-589`, `:687-696` (проверка Category платформы), `:658`, `:671` (`runtimeClasspath.incoming.resolutionResult`), `:746` (`shouldResolveConsistentlyWith`), `:1335-1349` (classpath).
- `ResolutionResult.getAllComponents()` — `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:576` (`resolutionResult.allComponents.each`).
- `DependencyHandler.enforcedPlatform(Object)` — Gradle API; DSL-форма используется хостами: `THEDEVS-RU/addon-coinex@dev:coinex/coinex.gradle:4`. Для Groovy init-скрипта вызов `p.dependencies.enforcedPlatform(String)` (TODO: specify actual method — подтвердить сигнатуру на `p.dependencies` в Gradle-версии CI по дистрибутиву Gradle и первым запуском контрактного теста; класс `DependencyHandler` верифицирован через DSL-использование).
- `Configuration.shouldResolveConsistentlyWith(Configuration)` — `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:746`.
- `THEDEVS-RU/bom@dev:gradle/libs.versions.toml:48` (`lcoretest`), `:50` (`lcoreuitest`).

## Альтернативы

1. **Только слой 1** (`shouldResolveConsistentlyWith(testRuntimeClasspath)`) — предпочтительное направление постановки, минимум изменений. Закрывает 5 из 6 хостов; `addon-core-gps` остаётся на пине из `-tests.pom`. Отклонено как единственное решение: тот же класс отставания останется у любого хоста без `core-test` в тестовом classpath (подтверждённый потребитель — gps).
2. **Захардкодить `ru.thedevs:core-test` и `coreui-test` в init-скрипте** — запрещено постановкой и не масштабируется на новые тестовые библиотеки.
3. **Не писать пины тестовых библиотек в `-tests.pom` при публикации** (исключить `*-test` из блока `:570-640`) — исправляет причину, но только для будущих публикаций; нужна перепубликация каждой зависимости, чего задача требует избежать.
4. **`platform` вместо `enforcedPlatform`** — отклонено: при пине выше версии BOM побеждал бы пин (недетерминированно относительно критерия 1).

Расхождение с постановкой: добавлен слой 2 (BOM хоста) сверх предложенного «`testRuntimeClasspath` вместо `runtimeClasspath`». Основание — конкретный потребитель `addon-core-gps` (таблица выше); слой 1 заявленные критерии для coinex выполняет сам. Ревью вправе принять только слой 1.

## Компромиссы и риски

- `testRuntimeClasspath` может разрешать общий модуль в более новую версию, чем `runtimeClasspath` (тестовая зависимость хоста тянет его выше). `addonTestClasspath` последует за ним; это то поведение, при котором тесты зависимости видят те же версии, что и тесты хоста. Регресс-индикатор — зелёный `Run addon dependency tests` у хостов из критерия 2.
- Если `testRuntimeClasspath` не разрешается (ошибка репозитория), `addonTestClasspath_*` тоже не разрешится; ранее та же зависимость от `runtimeClasspath` уже была, класс отказа не новый.
- `enforcedPlatform` BOM хоста в `addonTestClasspath_*` может понизить версию `ru.thedevs`-библиотеки ниже требуемой тестами зависимости, если BOM отстаёт от зависимости. Хост в `runtimeClasspath` уже получает те же версии, поэтому тесты зависимости запускаются на классах, которые реально поставляются; при расхождении падение — корректный сигнал о рассинхроне BOM.

# Критерии готовности

1. В `ci-addon-tests.init.gradle` `addonTestClasspath_<mod>` согласуется с `testRuntimeClasspath` (fallback `runtimeClasspath`) и получает `enforcedPlatform` для платформ `ru.thedevs` из `runtimeClasspath` хоста; координаты `core-test`/`coreui-test` в скрипте не встречаются.
2. Контрактный тест `tests/test-setup-addon-tests.sh` содержит сценарии A, B, C п.4 «Что сделать».
3. `AGENTS.md` содержит подраздел TD-2544 и обновлённый пункт 5 схемы classpath.
4. Верификация после доставки в `dev` (на стороне CI хостов, не в рамках arch): `./gradlew dependencyInsight --configuration addonTestClasspath_cryptocollector --dependency core-test` на addon-coinex показывает версию `core-test` из BOM хоста, а не `3.0.0.86` из `cryptocollector-tests-3.0.0.108.pom`.
5. Верификация после доставки: `Run addon dependency tests` зелёный у addon-core-ui, addon-core-crypto, addon-core-gps, addon-cryptoconnector (зелёные по TD-2039) и addon-coinex.
6. Спецификация проходит `validate-spec-format.sh` с кодом 0.

# Не трогать

- Блок публикации `<dep>-tests.jar` и генерацию POM (`ci-addon-tests.init.gradle:~500-645`); `GenerateModuleMetadata.enabled = false` сохраняется.
- Логику TD-2499 (фильтрация `AutoConfiguration.imports`), TD-2521 (persistence overlay), TD-2526 (хранилища), TD-2533 (Liquibase) и порядок элементов classpath `testAddon_*` (`:1335-1349`).
- Продуктовые репозитории хостов и зависимостей, `THEDEVS-RU/bom`, `references/ci-standards.md` и workflow-файлы.
