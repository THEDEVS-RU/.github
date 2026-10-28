#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_SCRIPT="${SCRIPT_DIR}/../actions/setup-addon-tests/ci-addon-tests.init.gradle"

if [ ! -f "$INIT_SCRIPT" ]; then
  echo "Error: init script not found at $INIT_SCRIPT" >&2
  exit 1
fi

echo "=== TD-2039: Contract Tests for setup-addon-tests ==="

TEST_DIR=$(mktemp -d -t td2039-tests-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

REPO_DIR="$TEST_DIR/local-repo"
mkdir -p "$REPO_DIR"

UPSTREAM_DIR="$TEST_DIR/upstream"
mkdir -p "$UPSTREAM_DIR"

# 1. Upstream Fixture Setup
# Fixture includes a module with archivesName != moduleName (like addon-tinkoff: base.archivesName = 'itink')
cat > "$UPSTREAM_DIR/settings.gradle" <<'EOF'
rootProject.name = 'addon-upstream'
include 'itink-mod'
include 'upstream-starter'
include 'helper-test'
include 'sample-lib'
include 'transit-lib'
include 'nested-lib'
include 'nomodprops'
include 'topodep-mod'
EOF

cat > "$UPSTREAM_DIR/build.gradle" <<'EOF'
allprojects {
    group = 'ru.thedevs'
    version = '1.0.0'
    repositories {
        mavenCentral()
    }
}
EOF

# itink-mod: archivesName is 'itink'
mkdir -p "$UPSTREAM_DIR/itink-mod/src/main/java/ru/thedevs/itink"
cat > "$UPSTREAM_DIR/itink-mod/src/main/java/ru/thedevs/itink/ItinkService.java" <<'EOF'
package ru.thedevs.itink;
public class ItinkService {
    public String message() { return "hello from itink"; }
}
EOF

cat > "$UPSTREAM_DIR/itink-mod/src/main/java/ru/thedevs/itink/ItinkEntity.java" <<'EOF'
package ru.thedevs.itink;
public class ItinkEntity {
}
EOF

cat > "$UPSTREAM_DIR/itink-mod/src/main/java/ru/thedevs/itink/ItinkOnlyEntity.java" <<'EOF'
package ru.thedevs.itink;
public class ItinkOnlyEntity {
}
EOF

cat > "$UPSTREAM_DIR/itink-mod/src/main/java/ru/thedevs/itink/ItinkAutoConfiguration.java" <<'EOF'
package ru.thedevs.itink;
public class ItinkAutoConfiguration {
}
EOF

mkdir -p "$UPSTREAM_DIR/itink-mod/src/main/resources/ru/thedevs/itink"
cat > "$UPSTREAM_DIR/itink-mod/src/main/resources/ru/thedevs/itink/persistence.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<persistence xmlns="http://xmlns.jcp.org/xml/ns/persistence" version="2.2">
    <persistence-unit name="main">
        <provider>io.jmix.data.impl.JmixPersistenceProvider</provider>
        <mapping-file>ru/thedevs/itink/orm.xml</mapping-file>
        <class>ru.thedevs.itink.ItinkEntity</class>
        <exclude-unlisted-classes/>
        <properties>
            <property name="eclipselink.weaving" value="static"/>
            <property name="io.jmix.enhancing.converters-list" value="ru.thedevs.itink.ItinkConverter"/>
        </properties>
    </persistence-unit>
</persistence>
EOF

cat > "$UPSTREAM_DIR/itink-mod/src/main/resources/ru/thedevs/itink/orm.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<entity-mappings xmlns="http://xmlns.jcp.org/xml/ns/persistence/orm" version="2.2">
    <entity class="ru.thedevs.itink.ItinkEntity">
        <attributes>
            <many-to-one name="ref" target-entity="ru.thedevs.itink.A"/>
        </attributes>
    </entity>
    <entity class="ru.thedevs.itink.ItinkOnlyEntity">
        <attributes>
            <basic name="foo"/>
        </attributes>
    </entity>
</entity-mappings>
EOF

mkdir -p "$UPSTREAM_DIR/itink-mod/src/main/resources/META-INF/spring"
cat > "$UPSTREAM_DIR/itink-mod/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports" <<'EOF'
ru.thedevs.itink.ItinkAutoConfiguration
EOF

# Upstream module.properties in main jar (TD-2526 jar/zip classpath resolution)
cat > "$UPSTREAM_DIR/itink-mod/src/main/resources/ru/thedevs/itink/module.properties" <<'EOF'
jmix.core.additional-stores=itinkjar
EOF

mkdir -p "$UPSTREAM_DIR/itink-mod/src/test/java/ru/thedevs/itink"
cat > "$UPSTREAM_DIR/itink-mod/src/test/java/ru/thedevs/itink/ItinkTest.java" <<'EOF'
package ru.thedevs.itink;

import org.junit.jupiter.api.Test;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

public class ItinkTest {
    @Test
    void testItinkService() throws Exception {
        assertEquals("hello from itink", new ItinkService().message());
        String changelog = System.getProperty("main.liquibase.change-log");
        assertNotNull(changelog, "main.liquibase.change-log must be set");
        assertTrue(changelog.startsWith("classpath:") || changelog.startsWith("file:"), "changelog must have classpath: or file: prefix");
        if (changelog.startsWith("classpath:")) {
            String res = changelog.substring("classpath:".length());
            while (res.startsWith("/")) res = res.substring(1);
            assertNotNull(getClass().getClassLoader().getResource(res), "Changelog resource must be resolvable via ClassLoader: " + res);
        }

        boolean expectHostEntities = !"false".equalsIgnoreCase(System.getProperty("itink.expectHostEntities"));

        if (expectHostEntities) {
            assertNotNull(getClass().getClassLoader().getResource("ru/thedevs/consumer/liquibase/changelog.xml"),
                    "Host changelog must be resolvable via ClassLoader from host-resources");
            assertNotNull(getClass().getClassLoader().getResource("ru/thedevs/consumer/starter/starter-resource.txt"),
                    "Host starter resource must be resolvable via ClassLoader from host-resources");
            assertNotNull(getClass().getClassLoader().getResource("ru/thedevs/consumer/orm.xml"),
                    "Host generated output dir (sourceSets.main.output.dir, e.g. Jmix orm.xml) must stay on classpath");

            // (a) Verify host autoconfiguration imports descriptors are excluded, while dependency descriptor is present
            Enumeration<URL> importsUrls = getClass().getClassLoader().getResources(
                    "META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports");
            List<String> importsEntries = new ArrayList<>();
            while (importsUrls.hasMoreElements()) {
                URL url = importsUrls.nextElement();
                try (BufferedReader reader = new BufferedReader(new InputStreamReader(url.openStream(), StandardCharsets.UTF_8))) {
                    String line;
                    while ((line = reader.readLine()) != null) {
                        line = line.trim();
                        if (!line.isEmpty() && !line.startsWith("#")) {
                            importsEntries.add(line);
                        }
                    }
                }
            }
            assertTrue(importsEntries.contains("ru.thedevs.itink.ItinkAutoConfiguration"),
                    "Dependency autoconfiguration must be present on classpath: " + importsEntries);
            assertFalse(importsEntries.contains("ru.thedevs.consumer.ConsumerMainAutoConfiguration"),
                    "Host main autoconfiguration descriptor must be excluded from classpath: " + importsEntries);
            assertFalse(importsEntries.contains("ru.thedevs.consumer.starter.ConsumerAutoConfiguration"),
                    "Host starter autoconfiguration descriptor must be excluded from classpath: " + importsEntries);

            // (б) Verify host classes are preserved and loadable from classpath
            assertNotNull(Class.forName("ru.thedevs.consumer.starter.ConsumerAutoConfiguration"),
                    "Host starter class must be loadable");
            assertNotNull(Class.forName("ru.thedevs.consumer.ConsumerService"),
                    "Host main class must be loadable");
        }

        // (в) Verify dependency test system properties are preserved without being overwritten by harness
        assertEquals("ru.thedevs.itink.CustomExcludedAutoConfiguration",
                System.getProperty("spring.autoconfigure.exclude"),
                "Dependency spring.autoconfigure.exclude system property must be preserved");

        // TD-2526: Verify jmix.core.additional-stores merging from host and dependency
        String additionalStores = System.getProperty("jmix.core.additional-stores");
        assertNotNull(additionalStores, "jmix.core.additional-stores must be set");
        List<String> parsedStores = java.util.Arrays.stream(additionalStores.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .collect(Collectors.toList());
        if (expectHostEntities) {
            assertEquals(java.util.Set.of("hostsys", "itinkprop", "itinkfile", "itinkjar", "consumerdata", "starterdata"),
                    new java.util.HashSet<>(parsedStores),
                    "jmix.core.additional-stores must contain all host and dependency stores without losing any");
            assertEquals(6, parsedStores.size(),
                    "jmix.core.additional-stores must not contain duplicate stores: " + additionalStores);
        } else {
            assertEquals(java.util.Set.of("itinkprop", "itinkfile", "itinkjar"),
                    new java.util.HashSet<>(parsedStores),
                    "In negative scenario, jmix.core.additional-stores must contain only dependency stores");
            assertEquals(3, parsedStores.size(),
                    "jmix.core.additional-stores must not contain duplicates: " + additionalStores);
        }

        assertNull(System.getProperty("jmix.core.store-descriptor-consumerdata"),
                "jmix.core.store-descriptor-consumerdata must not leak from module.properties");
        assertNull(System.getProperty("jmix.data-store.consumerdata.jdbc-url"),
                "jmix.data-store.consumerdata.jdbc-url must not leak from module.properties");
        assertNull(System.getProperty("thedevs.fixture.leak"),
                "thedevs.fixture.leak must not leak from module.properties");

        // TD-2521: Persistence Unit Overlay & Orm.xml Shadowing checks
        URL puUrl = getClass().getClassLoader().getResource("ru/thedevs/itink/persistence.xml");
        assertNotNull(puUrl, "ru/thedevs/itink/persistence.xml must be resolvable via ClassLoader");
        String puText;
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(puUrl.openStream(), StandardCharsets.UTF_8))) {
            puText = reader.lines().collect(Collectors.joining("\n"));
        }

        URL ormUrl = getClass().getClassLoader().getResource("ru/thedevs/itink/orm.xml");
        assertNotNull(ormUrl, "ru/thedevs/itink/orm.xml must be resolvable via ClassLoader");
        String ormText;
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(ormUrl.openStream(), StandardCharsets.UTF_8))) {
            ormText = reader.lines().collect(Collectors.joining("\n"));
        }

        if (expectHostEntities) {
            // (3.3.a) First persistence.xml contains both ItinkEntity, ConsumerEntity, itink orm.xml, consumer orm.xml,
            // exactly one occurrence of each class, and exclude-unlisted-classes
            assertTrue(puText.contains("ru.thedevs.itink.ItinkEntity"), "Merged persistence.xml must contain ItinkEntity");
            assertTrue(puText.contains("ru.thedevs.consumer.ConsumerEntity"), "Merged persistence.xml must contain ConsumerEntity");
            assertTrue(puText.contains("ru/thedevs/itink/orm.xml"), "Merged persistence.xml must contain itink orm.xml");
            assertTrue(puText.contains("ru/thedevs/consumer/orm.xml"), "Merged persistence.xml must contain consumer orm.xml");
            assertTrue(puText.contains("<exclude-unlisted-classes"), "Merged persistence.xml must contain exclude-unlisted-classes");

            int countItinkCls = (puText.length() - puText.replace("<class>ru.thedevs.itink.ItinkEntity</class>", "").length()) / "<class>ru.thedevs.itink.ItinkEntity</class>".length();
            assertEquals(1, countItinkCls, "Exactly one occurrence of <class>ru.thedevs.itink.ItinkEntity</class>");
            int countConsumerCls = (puText.length() - puText.replace("<class>ru.thedevs.consumer.ConsumerEntity</class>", "").length()) / "<class>ru.thedevs.consumer.ConsumerEntity</class>".length();
            assertEquals(1, countConsumerCls, "Exactly one occurrence of <class>ru.thedevs.consumer.ConsumerEntity</class>");

            // (3.3.b, d) converters-list contains elements of dependency and host, separated by ;, without duplicates
            assertTrue(puText.contains("ru.thedevs.itink.ItinkConverter"), "Converters list must contain ItinkConverter");
            assertTrue(puText.contains("ru.thedevs.consumer.ConsumerConverter"), "Converters list must contain ConsumerConverter");
            assertTrue(puText.contains("value=\"ru.thedevs.itink.ItinkConverter;ru.thedevs.consumer.ConsumerConverter\"") ||
                       puText.contains("value=\"ru.thedevs.consumer.ConsumerConverter;ru.thedevs.itink.ItinkConverter\""),
                       "Converters list must be separated by ; and contain both converters without duplicates");

            // (3.3.c) Host descriptor ru/thedevs/consumer/persistence.xml remains accessible and NOT modified
            URL hostPuUrl = getClass().getClassLoader().getResource("ru/thedevs/consumer/persistence.xml");
            assertNotNull(hostPuUrl, "Host descriptor ru/thedevs/consumer/persistence.xml must remain accessible via ClassLoader");
            String hostPuText;
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(hostPuUrl.openStream(), StandardCharsets.UTF_8))) {
                hostPuText = reader.lines().collect(Collectors.joining("\n"));
            }
            assertTrue(hostPuText.contains("ru.thedevs.consumer.ConsumerEntity"),
                    "Host descriptor must contain ConsumerEntity");
            assertTrue(hostPuText.contains("ru/thedevs/consumer/orm.xml"),
                    "Host descriptor must contain ru/thedevs/consumer/orm.xml");
            assertTrue(hostPuText.contains("ru.thedevs.consumer.ConsumerConverter"),
                    "Host descriptor must contain ConsumerConverter");
            assertFalse(hostPuText.contains("ru.thedevs.itink.ItinkEntity"),
                    "Host descriptor must not be modified by overlay (no ItinkEntity)");
            assertFalse(hostPuText.contains("ru/thedevs/itink/orm.xml"),
                    "Host descriptor must not be modified by overlay (no ru/thedevs/itink/orm.xml)");
            assertFalse(hostPuText.contains("ru.thedevs.itink.ItinkConverter"),
                    "Host descriptor must not be modified by overlay (no ItinkConverter)");

            // (3.5) Conflict fixture: ru/thedevs/itink/orm.xml does NOT contain ItinkEntity, but DOES contain ItinkOnlyEntity
            assertFalse(ormText.contains("ru.thedevs.itink.ItinkEntity"), "Shadowed orm.xml must not contain ItinkEntity superseded by host");
            assertTrue(ormText.contains("ru.thedevs.itink.ItinkOnlyEntity"), "Shadowed orm.xml must preserve ItinkOnlyEntity");

            // Host orm.xml remains intact and contains target-entity="ru.thedevs.consumer.B"
            URL hostOrmUrl = getClass().getClassLoader().getResource("ru/thedevs/consumer/orm.xml");
            assertNotNull(hostOrmUrl, "Host orm.xml must remain accessible via ClassLoader");
            String hostOrmText;
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(hostOrmUrl.openStream(), StandardCharsets.UTF_8))) {
                hostOrmText = reader.lines().collect(Collectors.joining("\n"));
            }
            assertTrue(hostOrmText.contains("target-entity=\"ru.thedevs.consumer.B\""), "Host orm.xml must contain target-entity ru.thedevs.consumer.B");
        } else {
            // (3.6) Negative scenario (host without entities): ClassLoader returns original dependency descriptors untouched
            assertTrue(puText.contains("ru.thedevs.itink.ItinkEntity"), "Original persistence.xml must contain ItinkEntity");
            assertFalse(puText.contains("ConsumerEntity"), "Original persistence.xml must not contain ConsumerEntity");
            assertTrue(puText.contains("ru.thedevs.itink.ItinkConverter"), "Original converters list must contain ItinkConverter");
            assertFalse(puText.contains("ConsumerConverter"), "Original converters list must not contain ConsumerConverter");

            assertTrue(ormText.contains("ru.thedevs.itink.ItinkEntity"), "Original orm.xml must contain ItinkEntity when host has no entities");
            assertTrue(ormText.contains("ru.thedevs.itink.ItinkOnlyEntity"), "Original orm.xml must contain ItinkOnlyEntity");
        }
    }
}
EOF

mkdir -p "$UPSTREAM_DIR/itink-mod/src/test/resources"
cat > "$UPSTREAM_DIR/itink-mod/src/test/resources/test-itink.properties" <<'EOF'
main.liquibase.change-log=ru/thedevs/itink/liquibase/changelog.xml
jmix.core.additional-stores=itinkfile
EOF

cat > "$UPSTREAM_DIR/itink-mod/build.gradle" <<EOF
plugins {
    id 'java-library'
    id 'maven-publish'
}
base {
    archivesName = 'itink'
}
dependencies {
    api project(':nomodprops')
    api project(':transit-lib')
    testImplementation 'org.junit.jupiter:junit-jupiter-api:5.10.2'
    testRuntimeOnly 'org.junit.jupiter:junit-jupiter-engine:5.10.2'
    testRuntimeOnly 'org.junit.platform:junit-platform-launcher:1.10.2'
    testImplementation(dependencies.create(project(':helper-test')) {
        exclude group: 'org.slf4j', module: 'slf4j-api'
    })
}
test {
    systemProperty 'spring.autoconfigure.exclude', 'ru.thedevs.itink.CustomExcludedAutoConfiguration'
    systemProperty 'jmix.core.additional-stores', 'itinkprop'
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            artifactId = base.archivesName.get()
            from components.java
        }
    }
    repositories {
        maven {
            name = 'localRepo'
            url = uri("${REPO_DIR}")
        }
    }
}
EOF

# upstream-starter
mkdir -p "$UPSTREAM_DIR/upstream-starter/src/main/java/ru/thedevs/starter"
cat > "$UPSTREAM_DIR/upstream-starter/src/main/java/ru/thedevs/starter/UpstreamAutoConfiguration.java" <<'EOF'
package ru.thedevs.starter;
public class UpstreamAutoConfiguration {
    public static final String ACTIVE = "true";
}
EOF

cat > "$UPSTREAM_DIR/upstream-starter/build.gradle" <<EOF
plugins {
    id 'java'
    id 'maven-publish'
}
dependencies {
    implementation project(':itink-mod')
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            from components.java
        }
    }
    repositories {
        maven {
            name = 'localRepo'
            url = uri("${REPO_DIR}")
        }
    }
}
EOF

# helper-test
mkdir -p "$UPSTREAM_DIR/helper-test/src/main/java/ru/thedevs/helper"
cat > "$UPSTREAM_DIR/helper-test/src/main/java/ru/thedevs/helper/Helper.java" <<'EOF'
package ru.thedevs.helper;
public class Helper {
    public static String get() { return "helper"; }
}
EOF

cat > "$UPSTREAM_DIR/helper-test/build.gradle" <<EOF
plugins {
    id 'java'
    id 'maven-publish'
}
dependencies {
    implementation 'org.slf4j:slf4j-api:2.0.16'
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            from components.java
        }
    }
    repositories {
        maven {
            name = 'localRepo'
            url = uri("${REPO_DIR}")
        }
    }
}
EOF

# sample-lib: library published without tests (used to test strict vs pre-rollout)
mkdir -p "$UPSTREAM_DIR/sample-lib/src/main/java/ru/thedevs/sample"
cat > "$UPSTREAM_DIR/sample-lib/src/main/java/ru/thedevs/sample/Sample.java" <<'EOF'
package ru.thedevs.sample;
public class Sample {
    public static String get() { return "sample"; }
}
EOF

cat > "$UPSTREAM_DIR/sample-lib/build.gradle" <<EOF
plugins {
    id 'java'
    id 'maven-publish'
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            from components.java
        }
    }
    repositories {
        maven {
            name = 'localRepo'
            url = uri("${REPO_DIR}")
        }
    }
}
EOF

# TD-2533 upstream fixtures: nested-lib, transit-lib, nomodprops
mkdir -p "$UPSTREAM_DIR/nested-lib/src/main/resources/ru/thedevs/nested/liquibase"
cat > "$UPSTREAM_DIR/nested-lib/src/main/resources/ru/thedevs/nested/liquibase/changelog.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<databaseChangeLog
    xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
        http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-latest.xsd">
    <changeSet id="1-nested" author="thedevs">
        <createTable tableName="NESTED_TABLE">
            <column name="ID" type="${uuid.type}">
                <constraints primaryKey="true" nullable="false"/>
            </column>
        </createTable>
    </changeSet>
</databaseChangeLog>
EOF

cat > "$UPSTREAM_DIR/nested-lib/build.gradle" <<EOF
plugins {
    id 'java-library'
    id 'maven-publish'
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            from components.java
        }
    }
    repositories {
        maven {
            name = 'localRepo'
            url = uri("${REPO_DIR}")
        }
    }
}
EOF

mkdir -p "$UPSTREAM_DIR/transit-lib/src/main/resources/ru/thedevs/transit/liquibase"
cat > "$UPSTREAM_DIR/transit-lib/src/main/resources/ru/thedevs/transit/liquibase/changelog.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<databaseChangeLog
    xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
        http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-latest.xsd">
    <property name="uuid.type" dbms="oracle" value="varchar2(32)"/>
    <property name="uuid.type" dbms="!oracle" value="uuid"/>
    <include file="/ru/thedevs/nested/liquibase/changelog.xml" contextFilter="@jmix-addon"/>
    <changeSet id="1-transit" author="thedevs">
        <createTable tableName="TRANSIT_TABLE">
            <column name="ID" type="${uuid.type}">
                <constraints primaryKey="true" nullable="false"/>
            </column>
        </createTable>
    </changeSet>
</databaseChangeLog>
EOF

cat > "$UPSTREAM_DIR/transit-lib/build.gradle" <<EOF
plugins {
    id 'java-library'
    id 'maven-publish'
}
dependencies {
    api project(':nested-lib')
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            from components.java
        }
    }
    repositories {
        maven {
            name = 'localRepo'
            url = uri("${REPO_DIR}")
        }
    }
}
EOF

mkdir -p "$UPSTREAM_DIR/nomodprops/src/main/resources/ru/thedevs/nomodprops/liquibase"
cat > "$UPSTREAM_DIR/nomodprops/src/main/resources/ru/thedevs/nomodprops/liquibase/changelog.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<databaseChangeLog
    xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
        http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-latest.xsd">
    <changeSet id="1-nomodprops" author="thedevs">
        <createTable tableName="NOMODPROPS_TABLE">
            <column name="ID" type="${uuid.type}">
                <constraints primaryKey="true" nullable="false"/>
            </column>
        </createTable>
    </changeSet>
</databaseChangeLog>
EOF

cat > "$UPSTREAM_DIR/nomodprops/build.gradle" <<EOF
plugins {
    id 'java-library'
    id 'maven-publish'
}
dependencies {
    api project(':transit-lib')
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            from components.java
        }
    }
    repositories {
        maven {
            name = 'localRepo'
            url = uri("${REPO_DIR}")
        }
    }
}
EOF

# TD-2533 upstream fixture: topodep-mod (covers depMatchesModule=true and hostAlreadyIncludesDep=true)
mkdir -p "$UPSTREAM_DIR/topodep-mod/src/main/java/ru/thedevs/topodep"
cat > "$UPSTREAM_DIR/topodep-mod/src/main/java/ru/thedevs/topodep/TopodepService.java" <<'EOF'
package ru.thedevs.topodep;
public class TopodepService {
    public String message() { return "hello from topodep"; }
}
EOF

mkdir -p "$UPSTREAM_DIR/topodep-mod/src/test/java/ru/thedevs/topodep"
cat > "$UPSTREAM_DIR/topodep-mod/src/test/java/ru/thedevs/topodep/TopodepTest.java" <<'EOF'
package ru.thedevs.topodep;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

public class TopodepTest {
    @Test
    void testTopodepService() {
        assertEquals("hello from topodep", new TopodepService().message());
    }
}
EOF

mkdir -p "$UPSTREAM_DIR/topodep-mod/src/test/resources"
cat > "$UPSTREAM_DIR/topodep-mod/src/test/resources/test-topodep.properties" <<'EOF'
main.liquibase.change-log=ru/thedevs/transit/liquibase/changelog.xml
EOF

cat > "$UPSTREAM_DIR/topodep-mod/build.gradle" <<EOF
plugins {
    id 'java-library'
    id 'maven-publish'
}
base {
    archivesName = 'topodep'
}
dependencies {
    api project(':transit-lib')
    testImplementation 'org.junit.jupiter:junit-jupiter-api:5.10.2'
    testRuntimeOnly 'org.junit.jupiter:junit-jupiter-engine:5.10.2'
    testRuntimeOnly 'org.junit.platform:junit-platform-launcher:1.10.2'
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            artifactId = base.archivesName.get()
            from components.java
        }
    }
    repositories {
        maven {
            name = 'localRepo'
            url = uri("${REPO_DIR}")
        }
    }
}
EOF

echo "Building and publishing upstream fixtures via ci-addon-tests.init.gradle..."
(
  cd "$UPSTREAM_DIR"
  # Publish itink-mod, upstream-starter, helper-test, transit-lib, nested-lib, nomodprops, topodep-mod via ci-addon-tests.init.gradle
  gradle -I "$INIT_SCRIPT" :nested-lib:publishAllPublicationsToLocalRepoRepository :transit-lib:publishAllPublicationsToLocalRepoRepository :nomodprops:publishAllPublicationsToLocalRepoRepository :topodep-mod:publishAllPublicationsToLocalRepoRepository :itink-mod:publishAllPublicationsToLocalRepoRepository :upstream-starter:publishAllPublicationsToLocalRepoRepository :helper-test:publishAllPublicationsToLocalRepoRepository --no-daemon
  # Publish sample-lib WITHOUT init script so it has NO -tests artifact published
  gradle :sample-lib:publishAllPublicationsToLocalRepoRepository --no-daemon
)

# 2. Validate Published Artifacts and POM
echo "Validating published upstream artifacts..."
ITINK_TESTS_DIR="$REPO_DIR/ru/thedevs/itink-tests/1.0.0"
if [ ! -d "$ITINK_TESTS_DIR" ]; then
  echo "FAIL: itink-tests directory not found at $ITINK_TESTS_DIR" >&2
  exit 1
fi

if [ ! -f "$ITINK_TESTS_DIR/itink-tests-1.0.0.jar" ]; then
  echo "FAIL: itink-tests-1.0.0.jar not found at $ITINK_TESTS_DIR" >&2
  exit 1
fi

if [ ! -f "$ITINK_TESTS_DIR/itink-tests-1.0.0.pom" ]; then
  echo "FAIL: itink-tests-1.0.0.pom not found at $ITINK_TESTS_DIR" >&2
  exit 1
fi

# GMM must be disabled
if [ -f "$ITINK_TESTS_DIR/itink-tests-1.0.0.module" ]; then
  echo "FAIL: GMM module metadata file found at $ITINK_TESTS_DIR/itink-tests-1.0.0.module, but GMM must be disabled!" >&2
  exit 1
fi

POM_CONTENT=$(cat "$ITINK_TESTS_DIR/itink-tests-1.0.0.pom")

# Must contain dependency on main module itink with compile scope
if ! echo "$POM_CONTENT" | grep -q "<artifactId>itink</artifactId>"; then
  echo "FAIL: POM missing main module dependency <artifactId>itink</artifactId>" >&2
  exit 1
fi

if ! echo "$POM_CONTENT" | grep -A 4 "<artifactId>itink</artifactId>" | grep -q "<scope>compile</scope>"; then
  echo "FAIL: POM main module dependency missing <scope>compile</scope>" >&2
  exit 1
fi

# Must contain dependency on helper-test with runtime scope
if ! echo "$POM_CONTENT" | grep -q "<artifactId>helper-test</artifactId>"; then
  echo "FAIL: POM missing test project dependency <artifactId>helper-test</artifactId>" >&2
  exit 1
fi

# Must preserve declared exclusions (org.slf4j / slf4j-api)
if ! echo "$POM_CONTENT" | grep -q "<groupId>org.slf4j</groupId>"; then
  echo "FAIL: POM missing exclusion for org.slf4j under helper-test" >&2
  exit 1
fi

if ! echo "$POM_CONTENT" | grep -q "<artifactId>slf4j-api</artifactId>"; then
  echo "FAIL: POM missing exclusion for slf4j-api under helper-test" >&2
  exit 1
fi

# Validate META-INF/thedevs-test.properties inside itink-tests-1.0.0.jar
unzip -q -o "$ITINK_TESTS_DIR/itink-tests-1.0.0.jar" -d "$TEST_DIR/unpacked-itink-tests"
TEST_PROPS_FILE="$TEST_DIR/unpacked-itink-tests/META-INF/thedevs-test.properties"
if [ ! -f "$TEST_PROPS_FILE" ]; then
  echo "FAIL: META-INF/thedevs-test.properties not found inside itink-tests-1.0.0.jar" >&2
  exit 1
fi

TEST_PROPS=$(cat "$TEST_PROPS_FILE")
if ! echo "$TEST_PROPS" | grep -q "thedevs.tests.disabled=false"; then
  echo "FAIL: thedevs.tests.disabled=false not found in $TEST_PROPS_FILE" >&2
  exit 1
fi

if ! echo "$TEST_PROPS" | grep -q "thedevs.test.liquibase.change-log=ru/thedevs/itink/liquibase/changelog.xml"; then
  echo "FAIL: thedevs.test.liquibase.change-log not found or incorrect in $TEST_PROPS_FILE" >&2
  exit 1
fi

if ! echo "$TEST_PROPS" | grep -q "thedevs.test.systemProperties.spring.autoconfigure.exclude=ru.thedevs.itink.CustomExcludedAutoConfiguration"; then
  echo "FAIL: thedevs.test.systemProperties.spring.autoconfigure.exclude not found or incorrect in $TEST_PROPS_FILE" >&2
  exit 1
fi

if ! echo "$TEST_PROPS" | grep -q "thedevs.test.systemProperties.jmix.core.additional-stores=itinkprop"; then
  echo "FAIL: thedevs.test.systemProperties.jmix.core.additional-stores not found or incorrect in $TEST_PROPS_FILE" >&2
  exit 1
fi

# Validate ru/thedevs/itink/module.properties inside published main jar itink-1.0.0.jar (TD-2526)
unzip -q -o "$REPO_DIR/ru/thedevs/itink/1.0.0/itink-1.0.0.jar" -d "$TEST_DIR/unpacked-itink-main"
if ! grep -q "jmix.core.additional-stores=itinkjar" "$TEST_DIR/unpacked-itink-main/ru/thedevs/itink/module.properties"; then
  echo "FAIL: ru/thedevs/itink/module.properties missing or incorrect in itink-1.0.0.jar" >&2
  exit 1
fi

echo "Published upstream artifacts and POM validation: PASSED"

# 3. Downstream Fixture Setup
# Downstream depends on upstream-starter.
# Starter mapping should map upstream-starter -> itink.
# afterEvaluate configuration mutation (emulating io.jmix) should not break resolution.
DOWNSTREAM_DIR="$TEST_DIR/downstream"
mkdir -p "$DOWNSTREAM_DIR"

cat > "$DOWNSTREAM_DIR/settings.gradle" <<'EOF'
rootProject.name = 'addon-downstream'
include 'consumer-mod'
include 'consumer-starter'
EOF

cat > "$DOWNSTREAM_DIR/build.gradle" <<EOF
allprojects {
    group = 'ru.thedevs'
    version = '1.0.0'
    repositories {
        maven { url = uri("${REPO_DIR}") }
        mavenCentral()
    }
}
EOF

mkdir -p "$DOWNSTREAM_DIR/consumer-mod/src/main/java/ru/thedevs/consumer"
cat > "$DOWNSTREAM_DIR/consumer-mod/src/main/java/ru/thedevs/consumer/ConsumerService.java" <<'EOF'
package ru.thedevs.consumer;
public class ConsumerService {
    public String status() { return "consumer-ok"; }
}
EOF

cat > "$DOWNSTREAM_DIR/consumer-mod/src/main/java/ru/thedevs/consumer/ConsumerEntity.java" <<'EOF'
package ru.thedevs.consumer;
public class ConsumerEntity {
}
EOF

cat > "$DOWNSTREAM_DIR/consumer-mod/src/main/java/ru/thedevs/consumer/ConsumerMainAutoConfiguration.java" <<'EOF'
package ru.thedevs.consumer;
public class ConsumerMainAutoConfiguration {
}
EOF

mkdir -p "$DOWNSTREAM_DIR/consumer-mod/src/main/resources/META-INF/spring"
cat > "$DOWNSTREAM_DIR/consumer-mod/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports" <<'EOF'
ru.thedevs.consumer.ConsumerMainAutoConfiguration
EOF

mkdir -p "$DOWNSTREAM_DIR/consumer-mod/src/test/java/ru/thedevs/consumer"
cat > "$DOWNSTREAM_DIR/consumer-mod/src/test/java/ru/thedevs/consumer/ConsumerTest.java" <<'EOF'
package ru.thedevs.consumer;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertTrue;

public class ConsumerTest {
    @Test
    void testConsumer() {
        assertTrue(true);
    }
}
EOF

# Host changelog in main resources (not test resources!)
# Includes transit-lib changelog to emulate real hosts (addon-balance, addon-core-gps, etc.) including core changelog
mkdir -p "$DOWNSTREAM_DIR/consumer-mod/src/main/resources/ru/thedevs/consumer/liquibase"
cat > "$DOWNSTREAM_DIR/consumer-mod/src/main/resources/ru/thedevs/consumer/liquibase/changelog.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<databaseChangeLog
    xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
        http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-latest.xsd">
    <include file="/ru/thedevs/transit/liquibase/changelog.xml" relativeToChangelogFile="false"/>
</databaseChangeLog>
EOF

# Host module.properties (TD-2526)
cat > "$DOWNSTREAM_DIR/consumer-mod/src/main/resources/ru/thedevs/consumer/module.properties" <<'EOF'
jmix.core.additional-stores=consumerdata
jmix.core.store-descriptor-consumerdata=consumer_descriptor
jmix.data-store.consumerdata.jdbc-url=jdbc:fixture://unreachable
thedevs.fixture.leak=must-not-apply
EOF

cat > "$DOWNSTREAM_DIR/consumer-mod/build.gradle" <<'EOF'
plugins {
    id 'java'
    id 'maven-publish'
}
dependencies {
    implementation 'ru.thedevs:upstream-starter:1.0.0'
    implementation 'ru.thedevs:topodep:1.0.0'
    testImplementation 'org.junit.jupiter:junit-jupiter-api:5.10.2'
    testRuntimeOnly 'org.junit.jupiter:junit-jupiter-engine:5.10.2'
    testRuntimeOnly 'org.junit.platform:junit-platform-launcher:1.10.2'
}
tasks.withType(Test).configureEach {
    systemProperty 'jmix.core.additional-stores', 'hostsys'
}
// Emulate Jmix plugin mutating configurations in afterEvaluate
project.afterEvaluate {
    project.dependencies.add('implementation', 'org.slf4j:slf4j-api:2.0.16')
}
// Emulate Jmix plugin registerGeneratedDescriptors: persistence.xml & orm.xml generated outside processResources, exposed via output.dir
def generatedDescriptorsDir = layout.buildDirectory.dir('tmp/entitiesEnhancing/main').get().asFile
def generateDescriptors = tasks.register('generateDescriptors') {
    outputs.dir(generatedDescriptorsDir)
    doLast {
        def orm = new File(generatedDescriptorsDir, 'ru/thedevs/consumer/orm.xml')
        orm.parentFile.mkdirs()
        orm.text = '''<?xml version="1.0" encoding="UTF-8"?>
<entity-mappings xmlns="http://xmlns.jcp.org/xml/ns/persistence/orm" version="2.2">
    <entity class="ru.thedevs.itink.ItinkEntity">
        <attributes>
            <many-to-one name="ref" target-entity="ru.thedevs.consumer.B"/>
        </attributes>
    </entity>
</entity-mappings>
'''
        def pu = new File(generatedDescriptorsDir, 'ru/thedevs/consumer/persistence.xml')
        pu.parentFile.mkdirs()
        pu.text = '''<?xml version="1.0" encoding="UTF-8"?>
<persistence xmlns="http://xmlns.jcp.org/xml/ns/persistence" version="2.2">
    <persistence-unit name="main">
        <provider>io.jmix.data.impl.JmixPersistenceProvider</provider>
        <mapping-file>ru/thedevs/consumer/orm.xml</mapping-file>
        <class>ru.thedevs.consumer.ConsumerEntity</class>
        <exclude-unlisted-classes/>
        <properties>
            <property name="eclipselink.weaving" value="static"/>
            <property name="io.jmix.enhancing.converters-list" value="ru.thedevs.consumer.ConsumerConverter"/>
        </properties>
    </persistence-unit>
</persistence>
'''
    }
}
sourceSets.main.output.dir(generatedDescriptorsDir, builtBy: generateDescriptors)
publishing {
    publications {
        javaMaven(MavenPublication) {
            from components.java
        }
    }
}
EOF

mkdir -p "$DOWNSTREAM_DIR/consumer-starter/src/main/java/ru/thedevs/consumer/starter"
cat > "$DOWNSTREAM_DIR/consumer-starter/src/main/java/ru/thedevs/consumer/starter/ConsumerAutoConfiguration.java" <<'EOF'
package ru.thedevs.consumer.starter;
public class ConsumerAutoConfiguration {
    public static final String ACTIVE = "true";
}
EOF

mkdir -p "$DOWNSTREAM_DIR/consumer-starter/src/main/resources/ru/thedevs/consumer/starter"
cat > "$DOWNSTREAM_DIR/consumer-starter/src/main/resources/ru/thedevs/consumer/starter/module.properties" <<'EOF'
jmix.core.additional-stores=starterdata
EOF

cat > "$DOWNSTREAM_DIR/consumer-starter/src/main/resources/ru/thedevs/consumer/starter/starter-resource.txt" <<'EOF'
starter-ok
EOF

mkdir -p "$DOWNSTREAM_DIR/consumer-starter/src/main/resources/META-INF/spring"
cat > "$DOWNSTREAM_DIR/consumer-starter/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports" <<'EOF'
ru.thedevs.consumer.starter.ConsumerAutoConfiguration
EOF

cat > "$DOWNSTREAM_DIR/consumer-starter/build.gradle" <<'EOF'
plugins {
    id 'java'
}
dependencies {
    implementation project(':consumer-mod')
}
EOF

echo "Running downstream build and testAddonDependencies with ci-addon-tests.init.gradle..."
DOWNSTREAM_LOG="$TEST_DIR/downstream.log"
(cd "$DOWNSTREAM_DIR" && gradle -I "$INIT_SCRIPT" :consumer-mod:testAddonDependencies --no-daemon 2>&1) | tee "$DOWNSTREAM_LOG"

# 4. Validate Downstream Execution Results
echo "Validating downstream testAddon execution results..."

AGGREGATE_CHANGELOG="$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/aggregate-changelog.xml"
if [ ! -f "$AGGREGATE_CHANGELOG" ]; then
  echo "FAIL: Aggregate changelog was not created at $AGGREGATE_CHANGELOG" >&2
  exit 1
fi

if ! grep -q "ru/thedevs/itink/liquibase/changelog.xml" "$AGGREGATE_CHANGELOG"; then
  echo "FAIL: Aggregate changelog missing dependency changelog" >&2
  exit 1
fi

if ! grep -q "ru/thedevs/consumer/liquibase/changelog.xml" "$AGGREGATE_CHANGELOG"; then
  echo "FAIL: Aggregate changelog missing host changelog" >&2
  exit 1
fi

# TD-2533: Module Liquibase changelogs in aggregate
for inc in "/ru/thedevs/transit/liquibase/changelog.xml" "/ru/thedevs/nested/liquibase/changelog.xml" "/ru/thedevs/nomodprops/liquibase/changelog.xml"; do
  count=$(grep -c "file=\"$inc\"" "$AGGREGATE_CHANGELOG" || true)
  if [ "$count" -ne 1 ]; then
    echo "FAIL: Expected $inc to appear exactly once in $AGGREGATE_CHANGELOG, found $count times" >&2
    exit 1
  fi
done

line_itink=$(grep -n "ru/thedevs/itink/liquibase/changelog.xml" "$AGGREGATE_CHANGELOG" | cut -d: -f1 | head -1)
line_nested=$(grep -n "ru/thedevs/nested/liquibase/changelog.xml" "$AGGREGATE_CHANGELOG" | cut -d: -f1 | head -1)
line_transit=$(grep -n "ru/thedevs/transit/liquibase/changelog.xml" "$AGGREGATE_CHANGELOG" | cut -d: -f1 | head -1)
line_nomodprops=$(grep -n "ru/thedevs/nomodprops/liquibase/changelog.xml" "$AGGREGATE_CHANGELOG" | cut -d: -f1 | head -1)
line_consumer=$(grep -n "ru/thedevs/consumer/liquibase/changelog.xml" "$AGGREGATE_CHANGELOG" | cut -d: -f1 | head -1)

if [ "$line_nested" -ge "$line_transit" ]; then
  echo "FAIL: nested (line $line_nested) must appear before transit (line $line_transit)" >&2
  exit 1
fi
if [ "$line_transit" -ge "$line_nomodprops" ]; then
  echo "FAIL: transit (line $line_transit) must appear before nomodprops (line $line_nomodprops)" >&2
  exit 1
fi
if [ "$line_itink" -ge "$line_transit" ]; then
  echo "FAIL: itink (line $line_itink) must appear before transit (line $line_transit)" >&2
  exit 1
fi
if [ "$line_nomodprops" -ge "$line_consumer" ]; then
  echo "FAIL: nomodprops (line $line_nomodprops) must appear before host changelog consumer (line $line_consumer)" >&2
  exit 1
fi

if ! grep -q '<property name="uuid.type" dbms="oracle" value="varchar2(32)"/>' "$AGGREGATE_CHANGELOG"; then
  echo "FAIL: Aggregate changelog missing uuid.type property for oracle" >&2
  exit 1
fi
if ! grep -q '<property name="uuid.type" dbms="!oracle" value="uuid"/>' "$AGGREGATE_CHANGELOG"; then
  echo "FAIL: Aggregate changelog missing uuid.type property for !oracle" >&2
  exit 1
fi

line_uuid=$(grep -n 'property name="uuid.type"' "$AGGREGATE_CHANGELOG" | cut -d: -f1 | head -1)
if [ "$line_uuid" -ge "$line_itink" ] || [ "$line_uuid" -ge "$line_nested" ]; then
  echo "FAIL: uuid.type properties must appear at the beginning before changelog includes" >&2
  exit 1
fi

if ! grep -q "\[TD-2533\] aggregate-changelog for 'itink'" "$DOWNSTREAM_LOG"; then
  echo "FAIL: Expected '[TD-2533] aggregate-changelog for '\''itink'\''' in $DOWNSTREAM_LOG" >&2
  exit 1
fi
if ! grep -q "\[TD-2533\] testAddon_itink: liquibase.allowDuplicatedChangesetIdentifiers=true" "$DOWNSTREAM_LOG"; then
  echo "FAIL: Expected '[TD-2533] testAddon_itink: liquibase.allowDuplicatedChangesetIdentifiers=true' in $DOWNSTREAM_LOG" >&2
  exit 1
fi

# TD-2533: Validate topodep aggregate (depMatchesModule=true and hostAlreadyIncludesDep=true scenario)
TOPO_AGGREGATE="$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/topodep/aggregate-changelog.xml"
if [ ! -f "$TOPO_AGGREGATE" ]; then
  echo "FAIL: Aggregate changelog was not created at $TOPO_AGGREGATE" >&2
  exit 1
fi

topo_line_nested=$(grep -n "ru/thedevs/nested/liquibase/changelog.xml" "$TOPO_AGGREGATE" | cut -d: -f1 | head -1)
topo_line_transit=$(grep -n "ru/thedevs/transit/liquibase/changelog.xml" "$TOPO_AGGREGATE" | cut -d: -f1 | head -1)
topo_line_nomodprops=$(grep -n "ru/thedevs/nomodprops/liquibase/changelog.xml" "$TOPO_AGGREGATE" | cut -d: -f1 | head -1)
topo_line_consumer=$(grep -n "ru/thedevs/consumer/liquibase/changelog.xml" "$TOPO_AGGREGATE" | cut -d: -f1 | head -1)

# Check transit appears in module includes exactly once (plus once inside host changelog)
topo_count_transit=$(grep -c 'file="/ru/thedevs/transit/liquibase/changelog.xml"' "$TOPO_AGGREGATE" || true)
if [ "$topo_count_transit" -ne 1 ]; then
  echo "FAIL: Expected /ru/thedevs/transit/liquibase/changelog.xml to appear exactly once in $TOPO_AGGREGATE module includes, found $topo_count_transit times" >&2
  exit 1
fi

if [ "$topo_line_nested" -ge "$topo_line_transit" ]; then
  echo "FAIL: topodep aggregate: nested (line $topo_line_nested) must appear before transit (line $topo_line_transit)" >&2
  exit 1
fi

if [ "$topo_line_transit" -ge "$topo_line_nomodprops" ]; then
  echo "FAIL: topodep aggregate: transit (line $topo_line_transit) must appear before nomodprops (line $topo_line_nomodprops)" >&2
  exit 1
fi

if [ "$topo_line_nomodprops" -ge "$topo_line_consumer" ]; then
  echo "FAIL: topodep aggregate: nomodprops (line $topo_line_nomodprops) must appear before host changelog consumer (line $topo_line_consumer)" >&2
  exit 1
fi

if ! grep -q "ru/thedevs/consumer/liquibase/changelog.xml" "$TOPO_AGGREGATE"; then
  echo "FAIL: topodep aggregate missing host changelog" >&2
  exit 1
fi

if ! grep -q "\[TD-2533\] aggregate-changelog for 'topodep': dep changelog position=topological" "$DOWNSTREAM_LOG"; then
  echo "FAIL: Expected '[TD-2533] aggregate-changelog for '\''topodep'\'': dep changelog position=topological' in $DOWNSTREAM_LOG" >&2
  exit 1
fi
if ! grep -q "\[TD-2533\] testAddon_topodep: liquibase.allowDuplicatedChangesetIdentifiers=true" "$DOWNSTREAM_LOG"; then
  echo "FAIL: Expected '[TD-2533] testAddon_topodep: liquibase.allowDuplicatedChangesetIdentifiers=true' in $DOWNSTREAM_LOG" >&2
  exit 1
fi

# Verify host resources were filtered into isolated directories without autoconfiguration imports
HOST_MAIN_CHANGELOG="$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/host-resources/main/ru/thedevs/consumer/liquibase/changelog.xml"
if [ ! -f "$HOST_MAIN_CHANGELOG" ]; then
  echo "FAIL: Host main changelog not found in host-resources/main at $HOST_MAIN_CHANGELOG" >&2
  exit 1
fi

if [ -f "$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/host-resources/main/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports" ]; then
  echo "FAIL: Host main autoconfiguration descriptor found in host-resources/main, but must be excluded!" >&2
  exit 1
fi

if [ -f "$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/host-resources/starter/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports" ]; then
  echo "FAIL: Host starter autoconfiguration descriptor found in host-resources/starter, but must be excluded!" >&2
  exit 1
fi

HOST_STARTER_RESOURCE="$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/host-resources/starter/ru/thedevs/consumer/starter/starter-resource.txt"
if [ ! -f "$HOST_STARTER_RESOURCE" ]; then
  echo "FAIL: Host starter resource not found in host-resources/starter at $HOST_STARTER_RESOURCE" >&2
  exit 1
fi

# Verify unpacked classes
UNPACKED_TEST_CLASS="$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/classes/ru/thedevs/itink/ItinkTest.class"
if [ ! -f "$UNPACKED_TEST_CLASS" ]; then
  echo "FAIL: Unpacked dependency test class not found at $UNPACKED_TEST_CLASS" >&2
  exit 1
fi

# Verify persistence overlay files (TD-2521)
OVERLAY_PU="$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/persistence-overlay/ru/thedevs/itink/persistence.xml"
if [ ! -f "$OVERLAY_PU" ]; then
  echo "FAIL: Overlay persistence.xml was not created at $OVERLAY_PU" >&2
  exit 1
fi

OVERLAY_ORM="$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/persistence-overlay/ru/thedevs/itink/orm.xml"
if [ ! -f "$OVERLAY_ORM" ]; then
  echo "FAIL: Shadowing overlay orm.xml was not created at $OVERLAY_ORM" >&2
  exit 1
fi

# Verify original published itink-1.0.0.jar is intact
ORIG_PU_FILE="$TEST_DIR/orig-pu.xml"
unzip -p "$REPO_DIR/ru/thedevs/itink/1.0.0/itink-1.0.0.jar" ru/thedevs/itink/persistence.xml > "$ORIG_PU_FILE"
if grep -q "ConsumerEntity" "$ORIG_PU_FILE"; then
  echo "FAIL: Original published itink-1.0.0.jar was modified to include ConsumerEntity!" >&2
  exit 1
fi

if ! grep -q -- "(-1 entity entries superseded by host)" "$DOWNSTREAM_LOG"; then
  echo "FAIL: Gradle log missing '(-1 entity entries superseded by host)'" >&2
  exit 1
fi

if ! grep -q '\[TD-2526\] testAddon_itink: jmix.core.additional-stores=' "$DOWNSTREAM_LOG"; then
  echo "FAIL: Expected [TD-2526] testAddon_itink: jmix.core.additional-stores= not found in downstream log" >&2
  exit 1
fi

if ! grep -q 'itinkjar' "$DOWNSTREAM_LOG"; then
  echo "FAIL: Expected itinkjar in downstream log jmix.core.additional-stores" >&2
  exit 1
fi

# Verify test report confirms actual execution (tests="1", failures="0", errors="0")
REPORT_FILE="$DOWNSTREAM_DIR/consumer-mod/build/test-results/testAddon_itink/TEST-ru.thedevs.itink.ItinkTest.xml"
if [ ! -f "$REPORT_FILE" ]; then
  echo "FAIL: Test report file not found at $REPORT_FILE" >&2
  exit 1
fi

if ! grep -q 'tests="1"' "$REPORT_FILE" || ! grep -q 'failures="0"' "$REPORT_FILE" || ! grep -q 'errors="0"' "$REPORT_FILE"; then
  echo "FAIL: Test report does not indicate exactly 1 passing test without failures or errors" >&2
  cat "$REPORT_FILE" >&2
  exit 1
fi

echo "Downstream testAddon execution validation: PASSED"

# 5. Validate Negative Scenario: host without entities has empty/absent persistence-overlay (TD-2521)
echo "Testing negative scenario: host without entities..."
NOENTITY_DIR="$TEST_DIR/noentity-consumer"
mkdir -p "$NOENTITY_DIR"
cat > "$NOENTITY_DIR/settings.gradle" <<'EOF'
rootProject.name = 'noentity-consumer'
include 'noentity-mod'
EOF

cat > "$NOENTITY_DIR/build.gradle" <<EOF
allprojects {
    group = 'ru.thedevs'
    version = '1.0.0'
    repositories {
        maven { url = uri("${REPO_DIR}") }
        mavenCentral()
    }
}
EOF

mkdir -p "$NOENTITY_DIR/noentity-mod/src/main/java/ru/thedevs/noentity"
cat > "$NOENTITY_DIR/noentity-mod/src/main/java/ru/thedevs/noentity/NoEntityService.java" <<'EOF'
package ru.thedevs.noentity;
public class NoEntityService {
}
EOF

mkdir -p "$NOENTITY_DIR/noentity-mod/src/test/java/ru/thedevs/noentity"
cat > "$NOENTITY_DIR/noentity-mod/src/test/java/ru/thedevs/noentity/NoEntityTest.java" <<'EOF'
package ru.thedevs.noentity;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertTrue;
public class NoEntityTest {
    @Test
    void testOk() { assertTrue(true); }
}
EOF

cat > "$NOENTITY_DIR/noentity-mod/build.gradle" <<'EOF'
plugins {
    id 'java'
}
dependencies {
    implementation 'ru.thedevs:upstream-starter:1.0.0'
    testImplementation 'org.junit.jupiter:junit-jupiter-api:5.10.2'
    testRuntimeOnly 'org.junit.jupiter:junit-jupiter-engine:5.10.2'
    testRuntimeOnly 'org.junit.platform:junit-platform-launcher:1.10.2'
}
tasks.withType(Test).configureEach {
    systemProperty 'itink.expectHostEntities', 'false'
}
// Emulate Jmix plugin generating empty descriptors without classes
def generatedDescriptorsDir = layout.buildDirectory.dir('tmp/entitiesEnhancing/main').get().asFile
def generateDescriptors = tasks.register('generateDescriptors') {
    outputs.dir(generatedDescriptorsDir)
    doLast {
        def pu = new File(generatedDescriptorsDir, 'ru/thedevs/noentity/persistence.xml')
        pu.parentFile.mkdirs()
        pu.text = '''<?xml version="1.0" encoding="UTF-8"?>
<persistence xmlns="http://xmlns.jcp.org/xml/ns/persistence" version="2.2">
    <persistence-unit name="main">
        <provider>io.jmix.data.impl.JmixPersistenceProvider</provider>
        <exclude-unlisted-classes/>
    </persistence-unit>
</persistence>
'''
        def orm = new File(generatedDescriptorsDir, 'ru/thedevs/noentity/orm.xml')
        orm.parentFile.mkdirs()
        orm.text = '<entity-mappings/>\n'
    }
}
sourceSets.main.output.dir(generatedDescriptorsDir, builtBy: generateDescriptors)
EOF

NOENTITY_LOG="$TEST_DIR/noentity.log"
(cd "$NOENTITY_DIR" && gradle -I "$INIT_SCRIPT" :noentity-mod:testAddonDependencies --no-daemon 2>&1) | tee "$NOENTITY_LOG"

NOENTITY_OVERLAY_DIR="$NOENTITY_DIR/noentity-mod/build/addon-tests/itink/persistence-overlay"
if [ -d "$NOENTITY_OVERLAY_DIR" ]; then
    NOENTITY_FILES_COUNT=$(find "$NOENTITY_OVERLAY_DIR" -type f | wc -l)
    if [ "$NOENTITY_FILES_COUNT" -ne 0 ]; then
        echo "FAIL: Expected persistence-overlay to be empty for host without entities, but found $NOENTITY_FILES_COUNT files!" >&2
        exit 1
    fi
fi

if ! grep -q '\[TD-2526\] testAddon_itink: jmix.core.additional-stores=' "$NOENTITY_LOG"; then
    echo "FAIL: Expected [TD-2526] testAddon_itink: jmix.core.additional-stores= not found in noentity log" >&2
    exit 1
fi
if ! grep -q 'itinkjar' "$NOENTITY_LOG"; then
    echo "FAIL: Expected itinkjar in noentity log jmix.core.additional-stores" >&2
    exit 1
fi

NOENTITY_REPORT_FILE="$NOENTITY_DIR/noentity-mod/build/test-results/testAddon_itink/TEST-ru.thedevs.itink.ItinkTest.xml"
if [ ! -f "$NOENTITY_REPORT_FILE" ]; then
    echo "FAIL: Test report file for noentity-mod not found at $NOENTITY_REPORT_FILE" >&2
    exit 1
fi
if ! grep -q 'tests="1"' "$NOENTITY_REPORT_FILE" || ! grep -q 'failures="0"' "$NOENTITY_REPORT_FILE" || ! grep -q 'errors="0"' "$NOENTITY_REPORT_FILE"; then
    echo "FAIL: Test report for noentity-mod does not indicate passing tests without failures" >&2
    cat "$NOENTITY_REPORT_FILE" >&2
    exit 1
fi
echo "Negative scenario (host without entities): PASSED"

# 5. Validate Strict Mode vs Pre-rollout for missing tests artifact
# We verify in the SAME directory that switching to strict mode invalidates UP-TO-DATE and fails.
echo "Testing strict mode vs pre-rollout mode behavior in same consumer directory..."

STRICT_TEST_DIR="$TEST_DIR/strict-consumer"
mkdir -p "$STRICT_TEST_DIR"
cat > "$STRICT_TEST_DIR/settings.gradle" <<'EOF'
rootProject.name = 'strict-consumer'
EOF
cat > "$STRICT_TEST_DIR/build.gradle" <<EOF
plugins {
    id 'java'
}
repositories {
    maven { url = uri("${REPO_DIR}") }
    mavenCentral()
}
dependencies {
    implementation 'ru.thedevs:sample-lib:1.0.0'
}
EOF

# In pre-rollout mode (default), missing tests artifact prints warning and succeeds
set +e
PRE_ROLLOUT_OUTPUT=$(cd "$STRICT_TEST_DIR" && gradle -I "$INIT_SCRIPT" testAddonDependencies --no-daemon 2>&1)
PRE_RC=$?
set -e

if [ "$PRE_RC" -ne 0 ]; then
  echo "FAIL: Build failed in pre-rollout mode with exit code $PRE_RC (expected success with warning)" >&2
  echo "$PRE_ROLLOUT_OUTPUT" >&2
  exit 1
fi

if ! echo "$PRE_ROLLOUT_OUTPUT" | grep -q "Skipped dependency tests for 'ru.thedevs:sample-lib'"; then
  echo "FAIL: Pre-rollout warning not printed for missing tests artifact" >&2
  echo "$PRE_ROLLOUT_OUTPUT" >&2
  exit 1
fi

# In strict mode (-Pthedevs.tests.strict=true), missing tests artifact must fail in the SAME directory
set +e
STRICT_OUTPUT=$(cd "$STRICT_TEST_DIR" && gradle -I "$INIT_SCRIPT" testAddonDependencies -Pthedevs.tests.strict=true --no-daemon 2>&1)
STRICT_RC=$?
set -e

if [ "$STRICT_RC" -eq 0 ]; then
  echo "FAIL: Build succeeded in strict mode with missing tests artifact in same directory, but must fail!" >&2
  echo "$STRICT_OUTPUT" >&2
  exit 1
fi

if ! echo "$STRICT_OUTPUT" | grep -q "Strict mode enabled"; then
  echo "FAIL: Expected strict mode failure message, got:" >&2
  echo "$STRICT_OUTPUT" >&2
  exit 1
fi

echo "Strict mode vs pre-rollout behavior in same directory: PASSED"

echo "=== All Contract Tests for setup-addon-tests PASSED ==="
