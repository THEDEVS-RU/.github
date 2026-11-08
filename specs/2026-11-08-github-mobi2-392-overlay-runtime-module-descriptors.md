id: 2026-11-08-github-mobi2-392-overlay-runtime-module-descriptors
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

This is the fix stage of MOBI2-392, the base task for MOBI2-391. It follows an investigation of how Jmix 3 assembles the persistence unit. The earlier MOBI2-392 stages are already on `dev`: PR #39 (overlay diagnostics), PR #40 (module-class merge), PR #41 (candidate, merged-list and entity diagnostics), head 5b6640f.

Evidence: THEDEVS-RU/addon-gssoft run 42462400635, attempt 4 (action `THEDEVS-RU/.github@dev` 5b6640f):
- `testAddon_limiter`, `LimiterPostgresSmokeTest`: 331 tests, 2 failed. The error is EclipseLink-7250 `[class ru.thedevs.entity.notification.NotifyPreference] uses a non-entity [class ru.thedevs.entity.notification.NotifyTenantSubscription] as target entity in the relationship attribute [field subscription]`.
- The overlay for `limiter` sees only two candidate descriptors. One is `ru/thedevs/limiter/persistence.xml` (limiter-tests-3.0.0.32, 59 classes). The other is `ru/thedevs/persistence.xml` (core-3.0.0.98.jar, 59 classes). The merged `ru/thedevs/limiter/persistence.xml` lists 145 classes, including `NotifyTenantSubscription`, with `listed=145 entity-ok=142`; the 3 non-entities are Jmix converters. The overlay therefore produces a correct descriptor, but EclipseLink does not use it.

How Jmix 3 selects the descriptor (sources: `io.jmix.data:jmix-data:3.0.0`, `io.jmix.core:jmix-core:3.0.0`, local Gradle cache):
- `io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:38-47`: `setupPersistenceUnit()` walks `jmixModules.getAll()` from the last module backwards. It uses the first `classpath:<module base package>/persistence.xml` that exists.
- `io/jmix/core/JmixModulesProcessor.java:62-123`: every bean definition annotated `@JmixModule` becomes a module, and that includes modules imported by auto-configurations. `io/jmix/core/impl/JmixModulesSorter.java` then sorts the modules topologically in bean-definition order. A module outside the test configuration's dependency closure is appended after that closure, so it ends up last.
- The limiter test module is `@JmixModule(id = "ru.thedevs.limiter.test", dependsOn = LIMConfiguration.class)` (`THEDEVS-RU/addon-limiter@dev:limiter/src/test/java/ru/thedevs/limiter/LIMTestConfiguration.java`). `LIMConfiguration` depends only on `CoreConfiguration` (`THEDEVS-RU/addon-limiter@dev:limiter/src/main/java/ru/thedevs/limiter/LIMConfiguration.java:30`).
- The host (addon-gssoft) puts gpscore on its runtime classpath. `GpscoreAutoConfiguration` imports `GpscoreConfiguration` (`THEDEVS-RU/addon-core-gps@dev:gpscore-starter/src/main/java/ru/thedevs/core/gps/autoconfigure/core/GpscoreAutoConfiguration.java:13-15`), which is `@JmixModule(dependsOn = {CoreUIConfiguration.class})` (`THEDEVS-RU/addon-core-gps@dev:gpscore/src/main/java/ru/thedevs/core/gps/GpscoreConfiguration.java:26`). gpscore sits outside the limiter closure and depends on coreui, so it is sorted after limiter.test and coreui. EclipseLink therefore reads `ru/thedevs/core/gps/persistence.xml`.
- That file comes from the published `gpscore-3.0.0.9.jar` (released 2026-10-29T00:46Z, `THEDEVS-RU/addon-core-gps@dev` commit da22d19). It lists 139 classes, including `NotifyPreference` (line 49), but not `NotifyTenantSubscription`. `NotifyTenantSubscription` and `NotifyPreference.subscription` were added later, in addon-core TD-2592 (3341bf7, 2026-10-29T22:20Z), between the last green run 40921058131 and the first red run.
- The overlay never rewrites `ru/thedevs/core/gps/persistence.xml` for `limiter`. Candidate roots are only `classesDir` plus the `ru.thedevs` jars of `addonTestClasspath_limiter` (`ci-addon-tests.init.gradle:1303-1321`), and gpscore reaches the test classpath only through the host `runtimeClasspath` (`ci-addon-tests.init.gradle:1843-1857`).

Root cause: the overlay merges only the descriptors found in the dependency's own roots. Jmix uses the descriptor of the last module in the runtime module graph, and in a host-composed test context that can be a host-only module (here gpscore) whose published descriptor predates newer library entities.

Approaches considered:
1. **Chosen:** widen overlay candidate discovery to every `ru.thedevs` module descriptor on the `testAddon_<dep>` runtime classpath. Whichever module Jmix picks as last, its descriptor is then merged with the host classes and the module-class union from PR #40.
2. Republish gpscore against the current core. This only removes this one instance: the next entity added to core breaks again, and it does not address the harness rule.
3. Force Jmix module order or point the test at a specific descriptor through a property. Neither is possible: `setupPersistenceUnit()` takes no override, and the module order comes from the bean graph.

# What to do

### 1. Candidate roots from the host runtime classpath
In `actions/setup-addon-tests/ci-addon-tests.init.gradle`, overlay task `buildHostPersistenceOverlay_<dep>`, step "2. Candidate Roots in Dependency" (`:1303-1321`): after the `addonTestClasspath` jars, append the jar files of the host `runtimeClasspath` (the variable already used at `:1857`) whose resolved artifact group starts with `ru.thedevs` and which are not already in `depRoots`. Build the group map the same way, from `resolvedConfiguration.resolvedArtifacts`. Keep the existing order: `classesDir`, then `addonTestClasspath` jars, then host-runtime jars. Earlier roots keep precedence for duplicate relPaths, and `withResourceInputStream` resolves in the same order. Also register the host `runtimeClasspath` files as an input of `overlayTask`, next to `:1209`, so that the task re-runs when they change. A failed resolution prints `::warning::[TD-2521] Could not resolve host runtime artifacts for candidate roots: <message>` and must not fail the task.

### 2. Diagnostics
Each new candidate is printed by the existing `overlay candidate` line (`:1373-1376`). Add the suffix ` source=host-runtime` for candidates whose root came from step 1. Candidates from the dependency roots print ` source=dependency`.

### 3. Fixture test
In `tests/test-setup-addon-tests.sh`, add a new upstream fixture library, following the `transit-lib` fixture style (`:476-540`). Group `ru.thedevs`, published to the fixture repository, containing:
- its own `persistence.xml` under its base package, listing an entity class that is not listed by the `itink` dependency descriptors;
- no dependency from `itink` on it.

Declare it only as a dependency of the downstream host project, so that it is on the host `runtimeClasspath` but not on `addonTestClasspath_itink`. Assert the following:
- the downstream log contains `[TD-2521] overlay candidate 'itink': <its relPath> root=<its jar> classes=1 source=host-runtime`;
- an overlay copy of its descriptor is written (`Persistence overlay for 'itink': <its relPath> (+<N> host classes)`), and the test-side classloader sees the merged copy listing the itink entity;
- every existing assertion still passes, and the existing candidate lines carry `source=dependency`.

### 4. Documentation
In `AGENTS.md` §2 "Диагностика" (`:94-95`), document the `source=` suffix. Add one short paragraph explaining the rule: Jmix uses the `persistence.xml` of the last module in the runtime module graph (`JmixBaseEntityManagerFactoryBean.setupPersistenceUnit`), so the overlay covers the descriptors of all `ru.thedevs` modules on the test runtime classpath.

### 5. Verification on the consumer
After merge to `dev`, re-run the failed jobs of THEDEVS-RU/addon-gssoft workflow run 42462400635 (`gh run rerun 42462400635 -R THEDEVS-RU/addon-gssoft --failed`). In the handoff, quote:
- the `overlay candidate 'limiter': ru/thedevs/core/gps/persistence.xml root=gpscore-3.0.0.9.jar ... source=host-runtime` line;
- the "Run addon dependency tests" result (`testAddon_limiter` expected green).

If the rerun is still red, escalate to SPEC with the full EclipseLink message.

## Affected files
1. `actions/setup-addon-tests/ci-addon-tests.init.gradle`
2. `tests/test-setup-addon-tests.sh`
3. `AGENTS.md`

# What already exists

- Overlay candidate discovery, merge with host classes, module-class union, and the candidate/merged/entity diagnostics (`ci-addon-tests.init.gradle:1303-1840`).
- The `testAddon_<dep>` classpath order: overlay, then dependency roots, `addonTestClasspath`, host outputs, host `runtimeClasspath` (`ci-addon-tests.init.gradle:1843-1857`).
- The `transit-lib` upstream fixture (`tests/test-setup-addon-tests.sh:476-540`).

## Verified APIs
1. `io.jmix.data:jmix-data:3.0.0@local:io/jmix/data/impl/JmixBaseEntityManagerFactoryBean.java:38` — `setupPersistenceUnit()` takes the last module's `<basePackage>/persistence.xml`.
2. `io.jmix.core:jmix-core:3.0.0@local:io/jmix/core/JmixModulesProcessor.java:62` — modules collected from `@JmixModule` bean definitions and sorted by `JmixModulesSorter.sort` (`:123`).
3. `io.jmix.core:jmix-core:3.0.0@local:io/jmix/core/impl/JmixModulesSorter.java:34` — topological sort in bean-definition order.
4. `THEDEVS-RU/addon-core-gps@dev:gpscore/src/main/java/ru/thedevs/core/gps/GpscoreConfiguration.java:26` — `@JmixModule(dependsOn = {CoreUIConfiguration.class})`.
5. `THEDEVS-RU/addon-limiter@dev:limiter/src/main/java/ru/thedevs/limiter/LIMConfiguration.java:30` — `@JmixModule(dependsOn = {CoreConfiguration.class})`.
6. `THEDEVS-RU/.github@dev:actions/setup-addon-tests/ci-addon-tests.init.gradle:1303` — `depRoots` construction; `:1373` — candidate line; `:1857` — host `runtimeClasspath` in `testAddon.classpath`.

# Acceptance criteria

- The overlay candidates include the `ru.thedevs` module descriptors from the host runtime classpath, marked `source=host-runtime`, and merged overlay copies are written for them. Dependency-root candidates keep precedence and are marked `source=dependency`.
- The fixture covers a host-runtime-only module descriptor, and all existing assertions pass. PR CI is green.
- `AGENTS.md` §2 documents the rule and the `source=` suffix.
- After merge, the rerun of THEDEVS-RU/addon-gssoft run 42462400635 is green on "Run addon dependency tests".

# Out of scope

- Republishing addon-core-gps or any other library.
- Disabling or excluding `testAddon_limiter` or any other dependency suite.
- MOBI2-391 code (addon-gssoft PR #31).
