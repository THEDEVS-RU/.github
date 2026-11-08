id: 2026-11-08-github-mobi2-391-addon-tests-overlay-nonentity-diagnostics
product: thedevs-ci
repo: THEDEVS-RU/.github
branch: dev
depends_on: []
complexity: simple
stage: detailed
external_content: false
impl_model: sonnet
impl_effort: high

# Context

This is the base task for MOBI2-391. PR THEDEVS-RU/addon-gssoft#31 (head 5824647) is held, by operator decision, until the CI step "Run addon dependency tests" is green again.

Evidence:
- Run 42462400635 (addon-gssoft PR #31, 2026-11-08): `testAddon_limiter` fails in `LimiterPostgresSmokeTest`, 2 of 331 tests. The Spring context fails in `EntityManagerSetupImpl` with `org.eclipse.persistence.exceptions.ValidationException at ValidationException.java:1420`. That line is inside `nonEntityTargetInRelationship(...)` (`dep-sources/org.eclipse.persistence/org.eclipse.persistence.core-5.0.0-1-jmix@local:org/eclipse/persistence/exceptions/ValidationException.java:1417-1421`), error code `NON_ENTITY_AS_TARGET_IN_RELATIONSHIP`. The CI log shows only exception classes and `file:line`, not the message: `testAddon_<dep>` has no `testLogging` configuration (`grep testLogging` over `actions/setup-addon-tests/ci-addon-tests.init.gradle` → no match). So the source entity, attribute and target class are not visible in CI. The impl stage of MOBI2-391 reported the target as `GpsPhone` from a local run; that has no CI source.
- The same log prints `[TD-2521] Persistence overlay for 'limiter': ru/thedevs/limiter/persistence.xml (+86 host classes)` and `ru/thedevs/orm.xml (-1 entity entries superseded by host)`.
- The last green run of the same suite on addon-gssoft PR CI was run 40921058131 (2026-10-29T17:24Z). Since then, nothing changed in `actions/setup-addon-tests` (last commit 30bf4f3, 2026-10-29T02:07Z), in `LimiterPostgresSmokeTest` (a6cb4c0, 2026-10-28) or in the addon-gssoft entities. What did change after that run is the external dependencies: addon-core TD-2592 (3341bf7, 2026-10-29T23:20) added `NotifyUserContact.phone` → `CorePhone` and `NotifyUserContact.email` → `CoreEmail`, and addon-limiter was republished (commits 2026-10-30, 11-05, 11-06).
- Host mapping file in the published `ru.thedevs.integration:glonasssoft:3.0.0.28` jar (`unzip -p glonasssoft-3.0.0.28.jar ru/thedevs/integration/gssoft/orm.xml`): `CoreUserEntity.phone` and `GsUser.phone` have `target-entity="ru.thedevs.core.gps.entity.GpsPhone"`. `NotifyUserContact` has no entry. The host `persistence.xml` in the same jar lists `ru.thedevs.core.gps.entity.GpsPhone` (143 `<class>` entries).
- `JmixBaseEntityManagerFactoryBean.setupPersistenceUnit` uses the `persistence.xml` of the last Jmix module that has one (`dep-sources/io.jmix.data/jmix-data-3.0.0@local:io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:38-46`). In the limiter test context the last module is `ru.thedevs.limiter.test` (`THEDEVS-RU/addon-limiter@dev:limiter/src/test/java/ru/thedevs/limiter/LIMTestConfiguration.java:14`), base package `ru.thedevs.limiter`, so the descriptor is `ru/thedevs/limiter/persistence.xml`. That is one of the overlaid files.

**The root cause is not confirmed.** It cannot be read from CI output, and this spec does not propose a fix. Hypotheses to separate:
- **H1 — target class missing from the effective PU or loaded from a different root.** The merged descriptor should list `GpsPhone` (the host PU lists it and the overlay copies host classes, `ci-addon-tests.init.gradle:1249-1261`). If EclipseLink still treats it as a non-entity, then either the descriptor actually loaded is not the overlaid copy, or `GpsPhone` (or its parent `CorePhone`) comes from a different classpath root than expected. The overlay is first on the classpath only when it has files (`:1388-1390`), followed by `addonTestClasspath` before the host classes (`:1391-1392`).
- **H2 — a new relationship not covered by the host orm.xml.** TD-2592 added `NotifyUserContact.phone` → `CorePhone` (`THEDEVS-RU/addon-core@dev:core/src/main/java/ru/thedevs/entity/notification/NotifyUserContact.java:74`). `GpsPhone` is `@ReplaceEntity(CorePhone.class)` (`THEDEVS-RU/addon-core-gps@dev:gpscore/src/main/java/ru/thedevs/core/gps/entity/GpsPhone.java:20`). The failing relationship may be one that the published host orm.xml (3.0.0.28) does not redirect.
- **H3 — version skew between the host and the republished limiter test artifact.** The dependency test jar's POM pins runtime versions at publish time (`THEDEVS-RU/.github@dev:AGENTS.md:149`). TD-2544 aligns `addonTestClasspath_<dep>` with the host test classpath (`ci-addon-tests.init.gradle:786-796`), and the check is whether that alignment covers `ru.thedevs` core/gpscore artifacts on this run.

# What to do

### 1. Full exception output for `testAddon_<dep>`
In `actions/setup-addon-tests/ci-addon-tests.init.gradle`, where each `testAddon_<dep>` `Test` task is created (`:799`), configure test logging the same way host tests already do: failed events, full exception format, stack traces and causes (precedent `THEDEVS-RU/addon-gssoft@dev:glonasssoft/glonasssoft.gradle:30-35`). Then the EclipseLink message (source class, attribute, target) appears in the CI log. Do not change which tests run or how failures are classified.

### 2. Overlay consistency diagnostic
In the overlay task (`buildHostPersistenceOverlay_<dep>`, `:1035-1365`), after the merged descriptors and shadow mapping files are written, print one diagnostic line per relationship target found in the mapping files listed by each merged PU (host mapping files and shadow copies). Read the `target-entity` attribute of `many-to-one`, `one-to-one`, `one-to-many` and `many-to-many` elements. Line format:
`[TD-2521] overlay check '<dep>': <entity class>.<attribute> -> <target> listed=<true|false> root=<first classpath root that contains the target .class, or 'missing'>`
Also print the first classpath root of the target's direct superclass when the target's class file is found. The roots are scanned in the same order as the `testAddon_<dep>` classpath (`:1384-1397`). This is diagnostic only: it never fails the task and never changes the overlay output. Put it under the existing `[TD-2521]` log prefix and document it in `AGENTS.md` §2 "Диагностика".

### 3. Fixture test
Extend `tests/test-setup-addon-tests.sh` (TD-2521 block, around line 224 and the overlay checks around line 1225). Assert that the diagnostic line is printed for a fixture relationship whose target is listed (`listed=true`) and for one whose target is not listed (`listed=false`). Follow the existing fixture style of that script.

### 4. Evidence and root cause
After items 1-3 are merged to `dev`, re-run PR CI of THEDEVS-RU/addon-gssoft#31 (`gh run rerun 42462400635 --failed`; the workflow takes the action from `@dev`). Collect the full EclipseLink message and the overlay-check lines for `limiter`, decide which of H1/H2/H3 holds (or record a different cause), and hand the task back with that evidence via `next_stage(stage: "SPEC")`, using the line `Escalation: impl — root cause evidence for testAddon_limiter non-entity target`. The fix is specified by arch from that evidence. It may land in this repository or in a library (addon-core / addon-core-gps / addon-limiter), depending on the confirmed cause.

## Affected files
1. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
2. `tests/test-setup-addon-tests.sh`
3. `AGENTS.md`

# What already exists

- The TD-2521 overlay (merged PU + shadow mapping files) with `[TD-2521]` log lines (`ci-addon-tests.init.gradle:1023-1365`), documented in `AGENTS.md` §2.
- The TD-2544 consistent-resolution log line `[TD-2544] addonTestClasspath_<dep>: consistent with ...` (`ci-addon-tests.init.gradle:796`).
- Fixture-based script tests in `tests/test-setup-addon-tests.sh`.

## Verified APIs
1. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:799` — `testAddon_<dep>` created via `p.tasks.maybeCreate(testTaskName, Test)`.
2. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:1035` — overlay task `doLast`; host classes merged at lines 1249-1261; shadow copies at lines 1318-1363.
3. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:1384` — `testAddon.classpath` order (overlay, dep classes, `addonTestClasspath`, host outputs, `runtimeClasspath`).
4. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:55` — helper `localXmlTag(Node)`; `textValues(Element, String)` at line 73.
5. `THEDEVS-RU/addon-gssoft@dev:glonasssoft/glonasssoft.gradle:30` — `testLogging { events 'failed'; exceptionFormat = 'full'; showStackTraces = true; showCauses = true }` precedent.
6. `dep-sources/io.jmix.data/jmix-data-3.0.0@local:io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:38` — PU descriptor selection by last module.
7. `dep-sources/org.eclipse.persistence/org.eclipse.persistence.core-5.0.0-1-jmix@local:org/eclipse/persistence/exceptions/ValidationException.java:1417` — `nonEntityTargetInRelationship`.
8. `THEDEVS-RU/addon-core-gps@dev:gpscore/src/main/java/ru/thedevs/core/gps/entity/GpsPhone.java:20` — `@ReplaceEntity(CorePhone.class)`.
9. `THEDEVS-RU/addon-core@dev:core/src/main/java/ru/thedevs/entity/notification/NotifyUserContact.java:74` — `phone` → `CorePhone` (TD-2592).
10. `THEDEVS-RU/addon-core@dev:core/src/main/java/ru/thedevs/entity/CoreUserEntity.java:95` — `phone` → `CorePhone`.
11. `THEDEVS-RU/addon-limiter@dev:limiter/src/test/java/ru/thedevs/limiter/LIMTestConfiguration.java:14` — `@JmixModule(id = "ru.thedevs.limiter.test", dependsOn = LIMConfiguration.class)`.

# Acceptance criteria

- `testAddon_<dep>` failures print the full exception chain with messages in the CI log.
- `buildHostPersistenceOverlay_<dep>` prints one `[TD-2521] overlay check` line per relationship target in the merged PU's mapping files, with `listed` and `root`. Overlay output files are byte-identical to before for the existing fixtures.
- `tests/test-setup-addon-tests.sh` covers the `listed=true` and `listed=false` lines.
- `AGENTS.md` §2 "Диагностика" documents the new lines.
- The task returns to SPEC with the full EclipseLink message and the `limiter` overlay-check lines from a re-run of addon-gssoft PR #31 CI, plus the hypothesis they confirm.

# Out of scope

- Any fix to the overlay merge rules, to library entities or to addon-limiter tests before the cause is confirmed (item 4 hands back for that).
- Disabling or excluding `testAddon_limiter` or any other dependency suite.
- MOBI2-391 code (PR #31) — it waits for this task.
