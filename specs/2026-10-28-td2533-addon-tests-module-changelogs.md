---
id: 2026-10-28-td2533-addon-tests-module-changelogs
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: architectural
stage: detailed
external_content: false
impl_model: opus
impl_effort: high
---

# Контекст

TD-2533 блокирует TD-2453 (THEDEVS-RU/addon-coinex PR #3, head 02cb216). После TD-2522 (hsql) и TD-2532 (Kafka SASL) контекст `testAddon_coreui` у coinex поднимается, но 65 из 627 тестов падают (`CoreuiAllViewsRuntimeI18nTest` — 63, `ForgotPasswordChannelDisabledTest` — 2) на `ERROR: column "dtype" does not exist` (`SELECT ID, DTYPE, VERSION, PROVIDER_ID, USER_ID, PASSPHRASE_ID FROM CORE_SECRET`). Воспроизведение и логи CI — из постановки (в arch сборки и тесты не запускаются).

## Подтверждённый механизм

1. Оверлей TD-2521 добавляет в PU зависимости классы из сгенерированных Jmix-дескрипторов хоста (`persistence.xml` на полном графе хоста, включая транзитивные модули — cryptocore, cryptocollector, balance и др.): `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:787-1117`, `AGENTS.md` §2 «Оверлей persistence.xml». Метамодель и PU знают колонки сущностей этих модулей (`CryptoToken extends CoreSecret` → `DTYPE`, `PASSPHRASE_ID`).
2. Схему БД в `testAddon_<dep>` собирает `aggregate-changelog.xml`, который генерируется в `unpackTask.doLast`: он включает ровно два файла — changelog зависимости и changelog самого хоста (`ci-addon-tests.init.gradle:720-756`). Changelog транзитивных модулей хоста в агрегат не попадают, поэтому changeSet'ы cryptocore (`ru/thedevs/crypto/liquibase/changelog/2026/07/1-cryptotoken-discriminator-backfill.xml`, `2026/10/1-td2374-cryptotoken-passphrase.xml`) не накатываются.
3. В собственных тестах хоста схему создаёт тестовый мастер хоста (`THEDEVS-RU/addon-coinex@dev:coinex/src/test/resources/liquibase/test-changelog.xml:11` — Jmix data/securitydata/quartz + changelog coinex); в production — приложение, перечисляющее changelog всех модулей.

## Факты, на которых строится решение (проверены чтением jar и исходников)

- **Соглашение о расположении.** Changelog модуля Jmix лежит по пути `<basePackage>/liquibase/changelog.xml`: `io/jmix/data/liquibase/changelog.xml` (jmix-data-3.0.0), `io/jmix/audit/liquibase/changelog.xml` (jmix-audit-3.0.0), `io/jmix/quartz/liquibase/changelog.xml`, `ru/thedevs/liquibase/changelog.xml` (core-3.0.0.88), `ru/thedevs/crypto/liquibase/changelog.xml` (cryptocore-3.0.0.92), `ru/thedevs/account/balance/liquibase/changelog.xml` (balance-3.0.0.87), `ru/thedevs/integration/uniteller/liquibase/changelog.xml`, `ru/thedevs/core/gps/liquibase/changelog.xml`. Модули без своих миграций (cryptocollector-3.0.0.99, coreui-3.0.0.185, limiter-3.0.0.26) файла не имеют.
- **`module.properties` для обнаружения непригоден:** в jmix-data-3.0.0 и jmix-audit-3.0.0 его нет вовсе; ключ `main.liquibase.change-log` есть лишь у отдельных модулей (`ru/thedevs/browser/module.properties`) и отсутствует у core, cryptocore, balance; ключа `jmix.liquibase.*` нет ни в одном просмотренном `module.properties`. Jmix 3.0.0 не имеет рантайм-обнаружения changelog модулей (в `jmix-data-3.0.0` из liquibase — только XML).
- **Мастера аддонов вкладывают друг друга под требуемым контекстом.** `ru/thedevs/liquibase/changelog.xml` (core) включает шесть changelog Jmix с `contextFilter="@jmix-addon"`; cryptocore включает balance так же. По `liquibase-core-5.0.2` (`liquibase/util/ExpressionMatcher.java:101-113`) выражение `@x` — «обязательный» контекст: при пустых рантайм-контекстах include не выполняется, при активном контексте `jmix-addon` — выполняется. Тесты зависимостей задают `main.liquibase.contexts=jmix-addon` (`coreui-tests-3.0.0.185:ru/thedevs/coreui/test-app.properties` и `application-test.properties`, `balance-tests-3.0.0.74:ru/thedevs/account/balance/test-app.properties`, `cryptocore-tests-3.0.0.79:ru/thedevs/crypto/test-app.properties`).
- **Дубли include фатальны.** Повторный include одного файла даёт одинаковые changeSet'ы; `ValidatingVisitor` (`liquibase-core-5.0.2:liquibase/changelog/visitor/ValidatingVisitor.java:208,226`) считает их `duplicateChangeSets`, и `validationPassed()` возвращает false. Пути сравниваются без ведущего `/` (`DatabaseChangeLog.normalizePath`, `liquibase/changelog/DatabaseChangeLog.java:1303-1334`). `liquibase.duplicateFileMode` относится к дублям ресурсов в classpath, а не к повторным include (`liquibase/GlobalConfiguration.java:236`, `liquibase/resource/ResourceAccessor.java:56`).
- Порядок модулей Jmix зависит от `dependsOn`; в Gradle ему соответствует граф `runtimeClasspath` хоста (то же дерево, из которого скрипт уже выбирает кандидатов: `ci-addon-tests.init.gradle:498`).

# Что сделать

Решение: агрегат собирается из changelog **всех** Jmix-модулей `runtimeClasspath` хоста, найденных по соглашению о пути, в топологическом порядке графа зависимостей; модули, уже вложенные (активным include) в другой включаемый changelog, не дублируются. Правка — только в харнессе `THEDEVS-RU/.github`; coinex, coreui и прочие репозитории не меняются.

## 1. Обнаружение changelog модулей (функции верхнего уровня `ci-addon-tests.init.gradle`)

Разместить рядом с `resolveHostMainLiquibaseChangelog` (строка 158), до блока `gradle.projectsEvaluated`. Использовать существующие `createSafeDocumentBuilder`, `localXmlTag`, `parseStoreNames`-стиль чтения jar (`java.util.zip.ZipFile`) и рекурсивного обхода каталогов (как `collectStoreNamesFromClasspathModuleProperties`, строка 192).

1. **Топологический порядок компонентов.** Обход графа `runtimeClasspath.incoming.resolutionResult.root` в глубину с выдачей в пост-порядке (зависимости раньше зависящих): рёбра — `ResolvedDependencyResult` без `constraint`, потомки отсортированы по `group:name` для детерминизма, множество посещённых защищает от циклов, корень (сам хост) исключается. Ключ компонента — `selected.moduleVersion.group + ':' + name`.
2. **Файлы компонентов.** Из `runtimeClasspath.resolvedConfiguration.resolvedArtifacts` собрать отображение `group:name` → список `File` (jar или каталог) по `art.moduleVersion.id`.
3. **Фильтр компонентов.** Рассматриваются компоненты с группой, начинающейся с `ru.thedevs` или `io.jmix` (тот же приём префикса группы, что в TD-2521, строка 888; это не список модулей), а также проектные зависимости (`ProjectComponentIdentifier`, сиблинг-модули многомодульного хоста).
4. **Поиск changelog.** В каждом файле компонента найти записи/файлы с путём вида `<pkg>/liquibase/changelog.xml` (регулярное выражение `^(?!META-INF/).+/liquibase/changelog\.xml$` от корня jar/каталога; в каталогах — рекурсивно с относительным путём через `toPath().relativize`). Результат — упорядоченный список `[path, component, root]` без дублей по нормализованному пути (в порядке топологического обхода; внутри компонента — лексикографически).
5. **Ошибки.** Нечитаемый артефакт — `GradleException("[TD-2533] ...")` с путём артефакта (молчаливый пропуск воспроизвёл бы исходный дефект). Отсутствие подходящих файлов — не ошибка.

## 2. Вложенные include и активные контексты

1. **Нормализация пути:** убрать префикс `classpath:`, ведущий `/`, заменить `\` на `/` (по `DatabaseChangeLog.normalizePath`). Все сравнения путей — по нормализованному виду.
2. **Активные контексты Liquibase `C`.** Объединение (нижний регистр, разбор по `,` с trim) значений ключа `main.liquibase.contexts` из: `*.properties` распакованного `classesDir` (обобщить `collectStoreNamesFromDependencyProperties`, строка 246, параметром «ключ»), `thedevs.test.systemProperties.main.liquibase.contexts` из `META-INF/thedevs-test.properties` (`depProps`, строка 709), `testAddon.systemProperties['main.liquibase.contexts']` (объявление хоста).
3. **Замыкание вложенных include `closure(X)`** для changelog `X`: прочитать XML `X` (содержимое берётся по пути из корней: исходные каталоги ресурсов хоста `sourceSets.main.resources.srcDirs`, `classesDir`, файлы компонентов шага 1.2), собрать элементы `include` (локальное имя тега `include`; `includeAll` игнорируется — это каталоги changeSet'ов, не мастера). `file` с `relativeToChangelogFile="true"` разрешается относительно каталога `X`. Include следуем, если `contextFilter` отсутствует либо вычисляется активным: выражение — список имён через `,` или `or` с необязательным префиксом `@`; активно, если хотя бы одно имя (без `@`, нижний регистр) ∈ `C`. Выражения с `!`, `and`, `not`, скобками считаются неоцениваемыми и **не** следуются (консервативно: модуль будет включён явно, возможная ошибка проявится громко как дубль, а не тихо как пропуск). Обход рекурсивный с множеством посещённых. Нечитаемый/ненайденный вложенный файл — `::warning::[TD-2533] ...`, ветка не следуется.

## 3. Сборка агрегата (заменяет блок `ci-addon-tests.init.gradle:741-756`)

1. Кандидаты: changelog модулей (шаг 1.4), changelog зависимости (`depChangelog`, строка 720) и changelog хоста (`hostChangelog`, строка 722). Для каждого кандидата `X` вычисляется `closure(X)`.
2. Модуль `M` не включается в агрегат отдельно, если его нормализованный путь входит в `closure(X)` хотя бы одного другого кандидата `X ≠ M` (в том числе хоста и зависимости). Это обобщение существующей проверки `hostAlreadyIncludesDep` (строки 732-739): её текстовая проверка сохраняется, дополняясь проверкой по замыканию. Пример: balance вложен в cryptocore, поэтому `<include>` balance не пишется; Jmix data/securitydata/email/messagetemplates/quartz/audit вложены в мастер core и не пишутся отдельно, а Jmix-модули вне мастера core (если они на classpath хоста) пишутся.
3. Порядок записи: (а) заголовок `databaseChangeLog` как сейчас и два `<property name="uuid.type" .../>` (`dbms="oracle"` → `varchar2(32)`, `dbms="!oracle"` → `uuid`), идентичные мастерам парка (core, cryptocore, balance, gps, uniteller): changelog модуля может использовать `${uuid.type}`, не определяя его; (б) changelog зависимости **первым**, если он не совпадает с changelog какого-либо модуля из шага 1.4; если совпадает (пример: `ru/thedevs/liquibase/changelog.xml` у `coreui` — это changelog core), он пишется в своей топологической позиции среди модулей и повторно не пишется; (в) невложенные changelog модулей в топологическом порядке; (г) changelog хоста последним. Правило пропуска зависимости при `hostAlreadyIncludesDep` сохраняется.
4. Формат строки: `<include file="/<normalizedPath>" relativeToChangelogFile="false"/>` — с ведущим `/` для модулей (как в мастерах парка); строки зависимости и хоста остаются в текущем формате.
5. Лог в Gradle-вывод одной строкой на категорию: `[TD-2533] aggregate-changelog for '<dep>': included=<пути>; nested(skipped)=<пути>; active contexts=<C>`.
6. Входы `unpackTask` (строки 587-602): добавить `unpackTask.inputs.files(runtimeClasspath)` и `unpackTask.inputs.property("liquibaseContexts", { значение C })` — агрегат теперь зависит от состава classpath хоста и контекстов; без этого Gradle признаёт задачу актуальной при смене набора модулей.

## 4. Контрактный тест `tests/test-setup-addon-tests.sh`

Фикстуры вымышленные. Структура секций скрипта: upstream (`settings.gradle`, строка 25), downstream (consumer-mod), проверки (секция 4, строка 717).

1. Upstream: добавить подпроект `transit-lib` (группа `ru.thedevs`, `settings.gradle` upstream — `include 'transit-lib'`, публикация в тот же локальный репозиторий, что `itink-mod`) с ресурсами `ru/thedevs/transit/liquibase/changelog.xml` (содержит `<property name="uuid.type"...>`, один changeSet и include `/ru/thedevs/nested/liquibase/changelog.xml` с `contextFilter="@jmix-addon"`) и вложенный `nested-lib` (`ru/thedevs/nested/liquibase/changelog.xml`, один changeSet). `itink-mod` получает `api project(':transit-lib')`, `transit-lib` — `api project(':nested-lib')`, чтобы downstream получил оба **транзитивно** (через `upstream-starter` → itink, как cryptocore приходит через cryptocollector). Вторая пара — модуль без `module.properties` с changelog (`ru/thedevs/nomodprops/liquibase/changelog.xml`) и библиотека с зависимостью на `transit-lib`, чтобы проверить порядок.
2. В `test-itink.properties` (upstream) добавить `main.liquibase.contexts=jmix-addon`.
3. Проверки в секции 4 по `$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/aggregate-changelog.xml`: (а) содержит include `/ru/thedevs/transit/liquibase/changelog.xml`; (б) **не** содержит include `ru/thedevs/nested/liquibase/changelog.xml` (вложен при активном `jmix-addon`; счётчик вхождений нормализованного пути равен 0); (в) include модуля без `module.properties` присутствует (обнаружение по пути); (г) позиции: changelog зависимости itink раньше `transit`, `transit` раньше changelog хоста (`consumer`), а зависимая библиотека — позже `transit`; (д) ровно одно вхождение каждого включённого пути; (е) строка `[TD-2533] aggregate-changelog for 'itink'` присутствует в сохранённом логе downstream-сборки (лог через `tee`, как сделано для `[TD-2526]`).
4. Негативный сценарий: вариант downstream без `main.liquibase.contexts` в upstream (или скрипт прогоняется повторно с отключённым свойством) — `nested` **присутствует** в агрегате (include под `@jmix-addon` неактивен).
5. Существующие проверки секции 4 (`ru/thedevs/itink/liquibase/changelog.xml`, `ru/thedevs/consumer/liquibase/changelog.xml`) остаются зелёными.

## 5. Документация

В `AGENTS.md` (раздел 2, после подраздела «Оверлей persistence.xml и затенение orm.xml (TD-2521)») добавить подраздел «Схема БД testAddon: changelog транзитивных модулей (TD-2533)»: зачем нужно (схема должна соответствовать PU после оверлея), как обнаруживаются changelog (путь `<pkg>/liquibase/changelog.xml`, группы `ru.thedevs*`/`io.jmix*`, проектные зависимости; `module.properties` не используется и почему), порядок (топологический по графу `runtimeClasspath`; зависимость — в своей позиции или первой; хост — последним), правило вложенных include и роль контекста `jmix-addon`, определение `uuid.type`, строка диагностики, **контракт модуля** («changelog модуля обязан лежать в `<basePackage>/liquibase/changelog.xml`; вложенные мастера других модулей — только под `contextFilter="@jmix-addon"`»), ограничения (раздел «Компромиссы»). В списке контрактных тестов (раздел 3 `AGENTS.md`) добавить пункт про агрегат миграций. В `README.md`, если там описан `setup-addon-tests`, добавить одну ссылку на новый подраздел.

## Затрагиваемые файлы

1. `actions/setup-addon-tests/ci-addon-tests.init.gradle` — новые функции (после строки 179), замена блока генерации агрегата (741-756), входы `unpackTask` (587-602), обобщение `collectStoreNamesFromDependencyProperties` (246)
2. `tests/test-setup-addon-tests.sh`
3. `AGENTS.md`
4. `README.md` — только если в нём есть описание `setup-addon-tests`

# Что уже есть

- Харнесс TD-2039/TD-2499/TD-2521/TD-2526 в `actions/setup-addon-tests/ci-addon-tests.init.gradle`; контрактный тест с фикстурами `itink-mod`/`consumer-mod`; `AGENTS.md` с разделом 2.
- Уже работающее обнаружение зависимостей по графу `runtimeClasspath` (строки 485-560), чтение jar через `ZipFile` (строки 908-925), безопасный разбор XML (строка 31).
- Мастера аддонов уже подготовлены к вложенному подключению под `@jmix-addon` (core, cryptocore) — дублей не будет, пока харнесс уважает это замыкание.

## Проверенные API

- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:498` (`runtimeClasspath.incoming.resolutionResult.root.dependencies`)
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:550` (`ResolvedDependencyResult.selected.moduleVersion`, `group`/`name`/`version`)
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:883-885` (`resolvedConfiguration.resolvedArtifacts`, `art.moduleVersion.id.group`, `art.file`)
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:908-925` (обход записей jar через `ZipFile`)
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:709` (`depProps`), `:720-739` (`depChangelog`, `hostChangelog`, `hostAlreadyIncludesDep`), `:1168` (`testAddon.systemProperties[...]`), `:1198` (`main.liquibase.change-log`)
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:31` (`createSafeDocumentBuilder`), `:54` (`localXmlTag`), `:158` (`resolveHostMainLiquibaseChangelog`), `:246` (`collectStoreNamesFromDependencyProperties`)
- `dep-sources/org.liquibase/liquibase-core-5.0.2@local:liquibase/util/ExpressionMatcher.java:101`, `liquibase/changelog/visitor/ValidatingVisitor.java:208`, `liquibase/changelog/DatabaseChangeLog.java:1303`, `liquibase/GlobalConfiguration.java:236`
- `THEDEVS-RU/addon-core@dev:core/src/main/resources/ru/thedevs/liquibase/changelog.xml:12-18` (вложенные include под `@jmix-addon`), `THEDEVS-RU/addon-core-crypto@dev:cryptocore/src/main/resources/ru/thedevs/crypto/liquibase/changelog.xml:12`
- `THEDEVS-RU/addon-coinex@dev:coinex/src/test/resources/liquibase/test-changelog.xml:11`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:25` (`settings.gradle` upstream), `:35` (`group = 'ru.thedevs'`), `:717` (секция 4)

## Альтернативы (рассмотрены и отклонены)

1. **Только модули, чьи классы реально добавил оверлей** (отображение `<class>` → jar → changelog). Точнее по формулировке постановки, но: требует результата оверлея внутри `unpackTask` (сейчас оверлей — отдельная задача, выполняющаяся позже) либо разбиения генерации агрегата на отдельную задачу; пропускает миграции без собственных сущностей (патчи данных, регистрация Quartz-job, правки таблиц других модулей), которые в production есть. Выбранный вариант даёт надмножество: PU после оверлея выводится из дескрипторов полного графа хоста, поэтому все модули с сущностями входят заведомо; лишние таблицы безвредны. Если выбор окажется спорным на ревью — сужение делается фильтром по результату оверлея без изменения остальной схемы.
2. **Обнаружение по `module.properties` / ключу `main.liquibase.change-log`.** Отклонено: у jmix-data и jmix-audit нет `module.properties`, у core/cryptocore/balance нет ключа, ключ — скаляр уровня приложения.
3. **Включать changelog всех модулей без анализа вложенности.** Отклонено: при активном `jmix-addon` (cryptocore → balance, core → Jmix) получаются дубли changeSet'ов и фатальная валидация Liquibase.
4. **Зафиксировать контекст `jmix-addon` системным свойством харнесса.** Отклонено: меняет набор выполняемых changeSet'ов у зависимостей, не объявивших контекст; активные контексты берутся из объявлений самой зависимости.
5. **Явные списки модулей/changelog в харнессе или правки coinex/coreui.** Запрещено постановкой.

## Компромиссы и риски (не проверены запуском — arch сборки не запускает; подтверждаются impl и CI хостов)

- Порядок вложенного модуля определяется позицией родителя: если иной корневой модуль зависит от вложенного, но стоит в топологическом порядке раньше родителя, его миграции могут пойти до вложенных. Для существующих мастеров парка (core → Jmix, cryptocore → balance) не проявляется; при обнаружении — отдельная доработка порядка.
- Активные контексты берутся из объявлений зависимости; фактические контексты контекста Spring в отдельном тестовом классе могут отличаться через `@TestPropertySource`. При расхождении — дубль (громкая ошибка валидации) или пропуск вложенного; в первом случае — фатально сразу.
- `${offsetDateTime.type}` используется в core (`ru/thedevs/liquibase/changelog/2026/03/008-business-role.xml`), но не определён ни в core, ни в cryptocore, ни в Liquibase/Jmix (поиск по jar); как он разрешается у уже зелёных `testAddon_coreui` — не установлено. impl обязан на первом локальном прогоне (`:coinex:testAddon_coreui`) убедиться, что новые changelog не вводят неразрешённых параметров; при необходимости определить параметр в агрегате по тому же принципу, что `uuid.type`, и описать это в AGENTS.md.
- Добавление changelog модулей, чьи таблицы раньше не создавались, может вскрыть ранее скрытые ошибки миграций на PostgreSQL CI; это ожидаемая цена соответствия production.
- Старые опубликованные `<dep>-tests.jar` обрабатываются без перепубликации: используются только их файлы и `META-INF/thedevs-test.properties`.

# Критерии готовности

1. В `ci-addon-tests.init.gradle` агрегат содержит changelog всех не вложенных Jmix-модулей `runtimeClasspath` хоста (по пути `<pkg>/liquibase/changelog.xml`) в топологическом порядке, без дублей с changelog зависимости и хоста; coinex, coreui и прочие репозитории не изменены.
2. Вложенные под активным `jmix-addon` include не дублируются, под неактивным — включаются явно; строка `[TD-2533] aggregate-changelog for '<dep>': ...` печатается в Gradle-выводе.
3. `tests/test-setup-addon-tests.sh` содержит фикстуры и проверки п.4 «Что сделать»; `AGENTS.md` содержит подраздел «Схема БД testAddon: changelog транзитивных модулей (TD-2533)».
4. Верификация после доставки в `dev` (CI хостов, отдельный перезапуск): `:coinex:testAddon_coreui` в addon-coinex PR #3 (TD-2453) зелёный без правок в coinex и coreui; нет регресса у addon-core-gps PR #44 (`testAddon_coreui`), addon-core-crypto `testAddon_balance`, addon-cryptoconnector, addon-uniteller.
5. Спецификация проходит `validate-spec-format.sh` с кодом 0.

# Не трогать

- Оверлей persistence (`buildHostPersistenceOverlay_*`, TD-2521) и видимость замен в тестах зависимостей (TD-2447); объединение хранилищ (TD-2526); фильтрацию `AutoConfiguration.imports` (TD-2499).
- `thedevs.tests.disabled`, `thedevs.tests.strict`, пропуск тестов.
- Репозитории addon-coinex, addon-core-ui (coreui), addon-core, addon-core-crypto и любые хосты; хардкод списков модулей и changelog.
