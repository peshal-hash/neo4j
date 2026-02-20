# syntax=docker/dockerfile:1.7

FROM maven:3.9.9-eclipse-temurin-17 AS builder

WORKDIR /src
COPY . .

# Build Neo4j Community distribution from source and unpack the unix tarball.
RUN mvn -T1C -DskipTests -pl packaging/standalone/standalone-community -am package \
    && DIST_TAR="$(find packaging/standalone/target -maxdepth 1 -type f -name 'neo4j-community-*-unix.tar.gz' | head -n 1)" \
    && test -n "${DIST_TAR}" \
    && mkdir -p /dist \
    && tar -xzf "${DIST_TAR}" -C /dist \
    && mv /dist/neo4j-community-* /dist/neo4j

FROM neo4j:5.26.0-community AS browser-assets

FROM eclipse-temurin:17-jre-jammy

ENV NEO4J_HOME=/opt/neo4j
ENV PATH="${NEO4J_HOME}/bin:${PATH}"

RUN groupadd --gid 7474 neo4j \
    && useradd --uid 7474 --gid 7474 --home-dir "${NEO4J_HOME}" --no-create-home --shell /usr/sbin/nologin neo4j \
    && apt-get update \
    && apt-get install -y --no-install-recommends gosu \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p "${NEO4J_HOME}" /data /logs /import /plugins \
    && chown -R neo4j:neo4j "${NEO4J_HOME}" /data /logs /import /plugins

COPY --from=builder --chown=neo4j:neo4j /dist/neo4j/ ${NEO4J_HOME}/
COPY --chown=neo4j:neo4j docker/entrypoint.sh /docker-entrypoint.sh
COPY --from=browser-assets --chown=neo4j:neo4j /var/lib/neo4j/lib/neo4j-browser-*.jar ${NEO4J_HOME}/lib/

RUN chmod 0755 /docker-entrypoint.sh

VOLUME ["/data", "/logs", "/import", "/plugins"]
EXPOSE 7474 7473 7687

ENTRYPOINT ["/docker-entrypoint.sh"]
