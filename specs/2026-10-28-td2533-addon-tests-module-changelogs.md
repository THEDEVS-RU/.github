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
- **Повторный include по умолчанию фатален, но штатно отключается.** Повторный include одного файла даёт одинаковые changeSet'ы; `ValidatingVisitor` (`liquibase-core-5.0.2:liquibase/changelog/visitor/ValidatingVisitor.java:208,226`) считает их `duplicateChangeSets`, и `DatabaseChangeLog.validate` бросает `ValidationFailedException` (`liquibase/changelog/DatabaseChangeLog.java:364-392`). Однако флаг `liquibase.allowDuplicatedChangesetIdentifiers` (`liquibase/GlobalConfiguration.java:250`, по умолчанию false; читается из системных свойств через `liquibase/configuration/core/SystemPropertyValueProvider.java`) включает `ChangeLogIterator.alreadySaw` (`liquibase/changelog/ChangeLogIterator.java:47,123,215-222`): повторно встреченный changeSet пропускается для всех визиторов, включая валидирующий. Ключ — `changeSet.toString(false)` (id, author, нормализованный путь) + метки + контексты + dbms (`createKey`, `ChangeLogIterator.java:228-235`); в `seenChangeSets` changeSet попадает только после посещения (`markSeen`, `ChangeLogIterator.java:126-143,199-205`), поэтому экземпляр, отфильтрованный контекстом (`@jmix-addon` неактивен), «виденным» не становится и корневой экземпляр того же файла выполнится. Пути сравниваются без ведущего `/` (`DatabaseChangeLog.normalizePath`, `DatabaseChangeLog.java:1303-1334`). `liquibase.duplicateFileMode` относится к дублям ресурсов в classpath, а не к повторным include (`GlobalConfiguration.java:236`, `ResourceAccessor.java:56`).
- Порядок модулей Jmix зависит от `dependsOn`; в Gradle ему соответствует граф `runtimeClasspath` хоста (то же дерево, из которого скрипт уже выбирает кандидатов: `ci-addon-tests.init.gradle:498`).

# Что сделать

Решение: агрегат собирается из changelog **всех** Jmix-модулей `runtimeClasspath` хоста, найденных по соглашению о пути, в топологическом порядке графа зависимостей (зависимость раньше зависящего). Повторно встреченные changeSet'ы (мастер модуля вкладывает changelog другого модуля под `@jmix-addon`) безвредно пропускаются штатным флагом Liquibase `liquibase.allowDuplicatedChangesetIdentifiers=true`, который выставляется только в JVM `testAddon_<dep>`. Анализ вложенности и контекстов в харнессе не нужен. Правка — только в харнессе `THEDEVS-RU/.github`; coinex, coreui и прочие репозитории не меняются.

## 1. Обнаружение changelog модулей (функции верхнего уровня `ci-addon-tests.init.gradle`)

Разместить рядом с `resolveHostMainLiquibaseChangelog` (строка 158), до блока `gradle.projectsEvaluated`. Использовать существующие `createSafeDocumentBuilder`, `localXmlTag`, `parseStoreNames`-стиль чтения jar (`java.util.zip.ZipFile`) и рекурсивного обхода каталогов (как `collectStoreNamesFromClasspathModuleProperties`, строка 192).

1. **Топологический порядок компонентов.** Обход графа `runtimeClasspath.incoming.resolutionResult.root` в глубину с выдачей в пост-порядке (зависимости раньше зависящих): рёбра — `ResolvedDependencyResult` без `constraint`, потомки отсортированы по `group:name` для детерминизма, множество посещённых защищает от циклов, корень (сам хост) исключается. Ключ компонента — `selected.moduleVersion.group + ':' + name`.
2. **Файлы компонентов.** Из `runtimeClasspath.resolvedConfiguration.resolvedArtifacts` собрать отображение `group:name` → список `File` (jar или каталог) по `art.moduleVersion.id`.
3. **Фильтр компонентов.** Рассматриваются компоненты с группой, начинающейся с `ru.thedevs` или `io.jmix` (тот же приём префикса группы, что в TD-2521, строка 888; это не список модулей), а также проектные зависимости (`ProjectComponentIdentifier`, сиблинг-модули многомодульного хоста).
4. **Поиск changelog.** В каждом файле компонента найти записи/файлы с путём вида `<pkg>/liquibase/changelog.xml` (регулярное выражение `^(?!META-INF/).+/liquibase/changelog\.xml$` от корня jar/каталога; в каталогах — рекурсивно с относительным путём через `toPath().relativize`). Результат — упорядоченный список `[path, component, root]` без дублей по нормализованному пути (в порядке топологического обхода; внутри компонента — лексикографически).
5. **Ошибки.** Нечитаемый артефакт — `GradleException("[TD-2533] ...")` с путём артефакта (молчаливый пропуск воспроизвёл бы исходный дефект). Отсутствие подходящих файлов — не ошибка.

## 2. Допуск повторных changeSet'ов в `testAddon` (штатный флаг Liquibase)

1. В `testAddon.doFirst` (якорь — строка `testAddon.systemProperty('liquibase.duplicateFileMode', 'WARN')`, `ci-addon-tests.init.gradle:1200`) добавить `testAddon.systemProperty('liquibase.allowDuplicatedChangesetIdentifiers', 'true')`. Свойство действует только в тестовой JVM `testAddon_<dep>`; production, собственные тесты хоста и дескриптор `META-INF/thedevs-test.properties` не затрагиваются.
2. Семантика (см. «Факты»): первое вхождение changeSet'а выполняется, повторное — пропускается; пропуск касается только того же файла/id/author/контекстов/меток/dbms. Благодаря топологическому порядку зависимость (balance, Jmix-модули) стоит в агрегате раньше зависящего (cryptocore, core), поэтому выигрывает корневое вхождение, а вложенный include родителя под активным `jmix-addon` пропускается. Если `jmix-addon` неактивен, вложенный экземпляр отфильтрован контекстом и не помечается «виденным» — корневое вхождение выполняется. Результат не зависит от того, какие контексты фактически активны в тесте.
3. Сгенерированный агрегат и логика выбора модулей **не** разбирают `contextFilter`, не читают содержимое changelog и не вычисляют замыкание include (обоснование — «Альтернативы», п.3).

## 3. Сборка агрегата (заменяет блок `ci-addon-tests.init.gradle:741-756`)

1. Кандидаты: changelog модулей (шаг 1.4), changelog зависимости (`depChangelog`, строка 720) и changelog хоста (`hostChangelog`, строка 722). Дедупликация — только по равенству нормализованных путей (`DatabaseChangeLog.normalizePath`, см. «Факты»): модуль, чей путь совпал с `depChangelog` или `hostChangelog`, отдельно не пишется. Проверка `hostAlreadyIncludesDep` (строки 732-739) сохраняется как есть (при флаге она избыточна, но безвредна).
2. Порядок записи: (а) заголовок `databaseChangeLog` как сейчас и два `<property name="uuid.type" .../>` (`dbms="oracle"` → `varchar2(32)`, `dbms="!oracle"` → `uuid`), идентичные мастерам парка (core, cryptocore, balance, gps, uniteller): changelog модуля может использовать `${uuid.type}`, не определяя его; (б) changelog зависимости **первым**, если он не совпадает с changelog какого-либо модуля из шага 1.4; если совпадает (пример: `ru/thedevs/liquibase/changelog.xml` у `coreui` — это changelog core), он пишется в своей топологической позиции среди модулей и повторно не пишется; (в) остальные changelog модулей в топологическом порядке; (г) changelog хоста последним.
3. Формат строки: `<include file="/<normalizedPath>" relativeToChangelogFile="false"/>` — с ведущим `/` для модулей (как в мастерах парка); строки зависимости и хоста остаются в текущем формате. Нормализация пути: убрать `classpath:` и ведущий `/`, заменить `\` на `/`.
4. Лог в Gradle-вывод: `[TD-2533] aggregate-changelog for '<dep>': module changelogs=<пути в порядке записи>` и, в `testAddon.doFirst`, `[TD-2533] testAddon_<dep>: liquibase.allowDuplicatedChangesetIdentifiers=true`.
5. Входы `unpackTask` (строки 587-602): добавить `unpackTask.inputs.files(runtimeClasspath)` — агрегат зависит от состава classpath хоста; без этого Gradle признаёт задачу актуальной при смене набора модулей.

## 4. Контрактный тест `tests/test-setup-addon-tests.sh`

Фикстуры вымышленные. Структура секций скрипта: upstream (`settings.gradle`, строка 25), downstream (consumer-mod), проверки (секция 4, строка 717).

1. Upstream: добавить подпроект `transit-lib` (группа `ru.thedevs`, `include 'transit-lib'` в `settings.gradle` upstream, публикация в тот же локальный репозиторий, что `itink-mod`) с ресурсом `ru/thedevs/transit/liquibase/changelog.xml` (свойство `uuid.type`, один changeSet и вложенный `<include file="/ru/thedevs/nested/liquibase/changelog.xml" contextFilter="@jmix-addon"/>`) и подпроект `nested-lib` с `ru/thedevs/nested/liquibase/changelog.xml` (один changeSet). `itink-mod` получает `api project(':transit-lib')`, `transit-lib` — `api project(':nested-lib')`, чтобы downstream получил оба **транзитивно** (через `upstream-starter` → itink, как cryptocore приходит через cryptocollector). Добавить ещё один транзитивный модуль без `module.properties` (`ru/thedevs/nomodprops/liquibase/changelog.xml`), зависящий от `transit-lib`, чтобы проверить обнаружение по пути и порядок.
2. Проверки в секции 4 по `$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/aggregate-changelog.xml`: (а) include `/ru/thedevs/transit/liquibase/changelog.xml`, `/ru/thedevs/nested/liquibase/changelog.xml` и `/ru/thedevs/nomodprops/liquibase/changelog.xml` присутствуют, каждый **ровно один раз**; (б) порядок строк: `nested` раньше `transit`, `transit` раньше `nomodprops`; changelog зависимости (`ru/thedevs/itink/liquibase/changelog.xml`) раньше `transit`; changelog хоста (`ru/thedevs/consumer/liquibase/changelog.xml`) последний; (в) свойства `uuid.type` определены в начале агрегата; (г) в сохранённом логе downstream-сборки (через `tee`, как сделано для `[TD-2526]`) присутствуют строки `[TD-2533] aggregate-changelog for 'itink'` и `[TD-2533] testAddon_itink: liquibase.allowDuplicatedChangesetIdentifiers=true`.
3. Существующие проверки секции 4 (`ru/thedevs/itink/liquibase/changelog.xml`, `ru/thedevs/consumer/liquibase/changelog.xml`) остаются зелёными. Фактическое прохождение валидации Liquibase с вложенным дублем фикстура не проверяет (в ней нет СУБД) — оно подтверждается критерием готовности 3 на CI хостов.

## 5. Документация

В `AGENTS.md` (раздел 2, после подраздела «Оверлей persistence.xml и затенение orm.xml (TD-2521)») добавить подраздел «Схема БД testAddon: changelog транзитивных модулей (TD-2533)»: зачем нужно (схема должна соответствовать PU после оверлея), как обнаруживаются changelog (путь `<pkg>/liquibase/changelog.xml`, группы `ru.thedevs*`/`io.jmix*`, проектные зависимости; `module.properties` не используется и почему), порядок (топологический по графу `runtimeClasspath`; зависимость — в своей позиции или первой; хост — последним), `uuid.type`, флаг `liquibase.allowDuplicatedChangesetIdentifiers=true` (что делает, область действия — только JVM `testAddon_*`, почему не используется анализ контекстов и замыкания include), строки диагностики, **контракт модуля** («changelog модуля лежит в `<basePackage>/liquibase/changelog.xml`»), ограничения (раздел «Компромиссы»). В списке контрактных тестов (раздел 3 `AGENTS.md`) добавить пункт про агрегат миграций. В `README.md`, если там описан `setup-addon-tests`, добавить одну ссылку на новый подраздел.

## Затрагиваемые файлы

1. `actions/setup-addon-tests/ci-addon-tests.init.gradle` — новые функции (после строки 179), замена блока генерации агрегата (741-756), входы `unpackTask` (587-602), системное свойство в `testAddon.doFirst` (после строки 1200)
2. `tests/test-setup-addon-tests.sh`
3. `AGENTS.md`
4. `README.md` — только если в нём есть описание `setup-addon-tests`

# Что уже есть

- Харнесс TD-2039/TD-2499/TD-2521/TD-2526 в `actions/setup-addon-tests/ci-addon-tests.init.gradle`; контрактный тест с фикстурами `itink-mod`/`consumer-mod`; `AGENTS.md` с разделом 2.
- Уже работающее обнаружение зависимостей по графу `runtimeClasspath` (строки 485-560), чтение jar через `ZipFile` (строки 908-925), безопасный разбор XML (строка 31), передача системных свойств Liquibase в `testAddon` (`liquibase.duplicateFileMode`, строка 1200).
- Мастера аддонов уже подготовлены к вложенному подключению под `@jmix-addon` (core, cryptocore).

## Проверенные API

- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:498` (`runtimeClasspath.incoming.resolutionResult.root.dependencies`)
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:550` (`ResolvedDependencyResult.selected.moduleVersion`, `group`/`name`/`version`)
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:883` (`resolvedConfiguration.resolvedArtifacts`, `art.moduleVersion.id.group`, `art.file`)
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:908` (обход записей jar через `ZipFile`)
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:720` (`depChangelog`, `hostChangelog`, `hostAlreadyIncludesDep` до строки 739), `:1198` (`main.liquibase.change-log`), `:1200` (`liquibase.duplicateFileMode`)
- `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:31` (`createSafeDocumentBuilder`), `:158` (`resolveHostMainLiquibaseChangelog`)
- `dep-sources/org.liquibase/liquibase-core-5.0.2@local:liquibase/GlobalConfiguration.java:250` (`ALLOW_DUPLICATED_CHANGESETS_IDENTIFIERS`, `allowDuplicatedChangesetIdentifiers`)
- `dep-sources/org.liquibase/liquibase-core-5.0.2@local:liquibase/changelog/ChangeLogIterator.java:123` (`alreadySaw`), `:215` (определение `alreadySaw`), `:228` (`createKey`), `:199` (`markSeen`)
- `dep-sources/org.liquibase/liquibase-core-5.0.2@local:liquibase/changelog/DatabaseChangeLog.java:364` (`validate`), `:1303` (`normalizePath`)
- `dep-sources/org.liquibase/liquibase-core-5.0.2@local:liquibase/changelog/visitor/ValidatingVisitor.java:208`
- `dep-sources/org.liquibase/liquibase-core-5.0.2@local:liquibase/configuration/core/SystemPropertyValueProvider.java:27`
- `dep-sources/org.liquibase/liquibase-core-5.0.2@local:liquibase/util/ExpressionMatcher.java:101`
- `THEDEVS-RU/addon-core@dev:core/src/main/resources/ru/thedevs/liquibase/changelog.xml:12` (вложенные include под `@jmix-addon`), `THEDEVS-RU/addon-core-crypto@dev:cryptocore/src/main/resources/ru/thedevs/crypto/liquibase/changelog.xml:12`
- `THEDEVS-RU/addon-coinex@dev:coinex/src/test/resources/liquibase/test-changelog.xml:11`
- `THEDEVS-RU/.github@dev:tests/test-setup-addon-tests.sh:25` (`settings.gradle` upstream), `:35` (`group = 'ru.thedevs'`), `:717` (секция 4)

## Альтернативы (рассмотрены и отклонены)

1. **Только модули, чьи классы реально добавил оверлей** (отображение `<class>` → jar → changelog). Точнее по формулировке постановки, но требует результата оверлея внутри `unpackTask` (сейчас оверлей — отдельная задача, выполняющаяся позже) либо выделения генерации агрегата в отдельную задачу; пропускает миграции без собственных сущностей (патчи данных, регистрация Quartz-job, правки таблиц других модулей), которые в production есть. Выбранный вариант даёт надмножество: PU после оверлея выводится из дескрипторов полного графа хоста, поэтому все модули с сущностями входят заведомо; лишние таблицы безвредны.
2. **Обнаружение по `module.properties` / ключу `main.liquibase.change-log`.** Отклонено: у jmix-data и jmix-audit нет `module.properties`, у core/cryptocore/balance нет ключа, ключ — скаляр уровня приложения.
3. **Вычислять в харнессе замыкание вложенных include с учётом активных контекстов и не писать вложенные модули отдельно.** Отклонено: это повторная реализация `ExpressionMatcher` (`liquibase/util/ExpressionMatcher.java:89-125`) и чтения changelog на Groovy, причём неполная (выражения с `!`, `and`, скобками); активные контексты в харнессе известны лишь приблизительно (`@TestPropertySource` отдельного теста их переопределяет), и при расхождении замыкание даёт тихий пропуск вложенного модуля — тот самый класс дефекта, который чинит TD-2533. Штатный флаг Liquibase даёт тот же результат независимо от контекстов и порядка (`ChangeLogIterator.java:47,123,215-222`) и не требует поиска вложенных файлов в `addonTestClasspath`/`runtimeClasspath`.
4. **Включать changelog всех модулей без флага.** Отклонено: при активном `jmix-addon` (cryptocore → balance, core → Jmix) валидация падает на `duplicateChangeSets` (`ValidatingVisitor.java:208,226`).
5. **Зафиксировать контекст `jmix-addon` системным свойством харнесса.** Отклонено: меняет набор выполняемых changeSet'ов у зависимостей, не объявивших контекст.
6. **Явные списки модулей/changelog в харнессе или правки coinex/coreui.** Запрещено постановкой.

## Компромиссы и риски (не проверены запуском — arch сборки не запускает; подтверждаются impl и CI хостов)

- Флаг пропускает любой повторный changeSet с тем же ключом в JVM `testAddon_*`, в том числе случайный дубль id в двух файлах одного пути-идентификатора; в тестовой JVM зависимости это приемлемо (production не затрагивается), но маскирует такие дубли — они по-прежнему ловятся собственными тестами модулей и production-запуском.
- Флаг читается при создании `ChangeLogIterator` (`ChangeLogIterator.java:47`) из системных свойств JVM; свойство ставится в `testAddon.doFirst` до старта тестовой JVM, поэтому действует на все контексты Spring теста.
- Порядок: первое вхождение выигрывает. Для существующих мастеров парка (core → Jmix, cryptocore → balance) зависимость стоит раньше родителя; для модуля, вложенного в мастер, но стоящего в топологическом порядке позже его родителя, порядок определяется родителем — как у самого модуля в production.
- `${offsetDateTime.type}` используется в core (`ru/thedevs/liquibase/changelog/2026/03/008-business-role.xml`) и нигде не определён (поиск по jar core, cryptocore, Liquibase, Jmix). Это существующее обстоятельство: changelog зависимости для coreui уже сейчас — мастер core (`coreui-tests-3.0.0.185:META-INF/thedevs-test.properties`, `thedevs.test.liquibase.change-log=ru/thedevs/liquibase/changelog.xml`), и `008-business-role` уже выполняется в текущем `testAddon_coreui`. Проверке подлежат только новые changelog (cryptocore, balance и др.): impl на первом локальном прогоне `:coinex:testAddon_coreui` убеждается, что они не вводят неразрешённых параметров; при необходимости параметр определяется в агрегате по тому же принципу, что `uuid.type`, и описывается в AGENTS.md.
- Добавление changelog модулей, чьи таблицы раньше не создавались, может вскрыть ранее скрытые ошибки миграций на PostgreSQL CI; это ожидаемая цена соответствия production.
- Старые опубликованные `<dep>-tests.jar` обрабатываются без перепубликации: используются только их файлы и `META-INF/thedevs-test.properties`.

# Критерии готовности

1. В `ci-addon-tests.init.gradle` агрегат содержит changelog всех Jmix-модулей `runtimeClasspath` хоста (по пути `<pkg>/liquibase/changelog.xml`) в топологическом порядке, без дублей с changelog зависимости и хоста; `testAddon_<dep>` получает `liquibase.allowDuplicatedChangesetIdentifiers=true`; coinex, coreui и прочие репозитории не изменены.
2. `tests/test-setup-addon-tests.sh` содержит фикстуры и проверки п.4 «Что сделать»; `AGENTS.md` содержит подраздел «Схема БД testAddon: changelog транзитивных модулей (TD-2533)» с описанием флага, области его действия и причины отказа от анализа контекстов.
3. Верификация после доставки в `dev` (CI хостов, отдельный перезапуск): `:coinex:testAddon_coreui` в addon-coinex PR #3 (TD-2453) зелёный без правок в coinex и coreui; нет регресса у addon-core-gps PR #44 (`testAddon_coreui`), addon-core-crypto `testAddon_balance`, addon-cryptoconnector, addon-uniteller.
4. Спецификация проходит `validate-spec-format.sh` с кодом 0.

# Не трогать

- Оверлей persistence (`buildHostPersistenceOverlay_*`, TD-2521) и видимость замен в тестах зависимостей (TD-2447); объединение хранилищ (TD-2526); фильтрацию `AutoConfiguration.imports` (TD-2499).
- `thedevs.tests.disabled`, `thedevs.tests.strict`, пропуск тестов.
- Репозитории addon-coinex, addon-core-ui (coreui), addon-core, addon-core-crypto и любые хосты; хардкод списков модулей и changelog.
