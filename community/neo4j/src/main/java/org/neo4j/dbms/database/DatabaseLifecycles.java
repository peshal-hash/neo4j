/*
 * Copyright (c) "Neo4j"
 * Neo4j Sweden AB [https://neo4j.com]
 *
 * This file is part of Neo4j.
 *
 * Neo4j is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
package org.neo4j.dbms.database;

import static java.lang.String.format;
import static org.neo4j.function.ThrowingAction.executeAll;
import static org.neo4j.kernel.database.NamedDatabaseId.NAMED_SYSTEM_DATABASE_ID;
import static org.neo4j.kernel.database.NamedDatabaseId.SYSTEM_DATABASE_NAME;

import java.util.ArrayList;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import org.neo4j.dbms.api.DatabaseManagementException;
import org.neo4j.dbms.api.DatabaseNotFoundHelper;
import org.neo4j.dbms.systemgraph.TopologyGraphDbmsModel;
import org.neo4j.graphdb.Direction;
import org.neo4j.graphdb.Label;
import org.neo4j.graphdb.RelationshipType;
import org.neo4j.kernel.api.security.AuthManager;
import org.neo4j.kernel.database.Database;
import org.neo4j.kernel.database.DatabaseIdFactory;
import org.neo4j.kernel.database.NamedDatabaseId;
import org.neo4j.kernel.lifecycle.Lifecycle;
import org.neo4j.kernel.lifecycle.LifecycleAdapter;
import org.neo4j.logging.Log;
import org.neo4j.logging.LogProvider;

/**
 * System and default database manged only by lifecycles.
 */
public final class DatabaseLifecycles implements DatabaseRuntimeManager, DatabaseAccessChecker {
    private static final Label USER_NODE_LABEL = Label.label("User");
    private static final RelationshipType HAS_ACCESS_REL = RelationshipType.withName("HAS_ACCESS");

    private final DatabaseRepository<StandaloneDatabaseContext> databaseRepository;
    private final String defaultDatabaseName;
    private final DatabaseContextFactory<StandaloneDatabaseContext, Optional<?>> databaseContextFactory;
    private final Log log;

    /**
     * In-memory map: database name → set of usernames that may access it.
     * Populated when databases are created at runtime or on startup via
     * {@link #initialiseAdditionalDatabases()}.
     */
    private final ConcurrentHashMap<String, Set<String>> databaseUserAccess = new ConcurrentHashMap<>();

    public DatabaseLifecycles(
            DatabaseRepository<StandaloneDatabaseContext> databaseRepository,
            String defaultDatabaseName,
            DatabaseContextFactory<StandaloneDatabaseContext, Optional<?>> databaseContextFactory,
            LogProvider logProvider) {
        this.databaseRepository = databaseRepository;
        this.defaultDatabaseName = defaultDatabaseName;
        this.databaseContextFactory = databaseContextFactory;
        this.log = logProvider.getLog(getClass());
    }

    public Lifecycle systemDatabaseStarter() {
        return new SystemDatabaseStarter();
    }

    public Lifecycle defaultDatabaseStarter() {
        return new DefaultDatabaseStarter();
    }

    public Lifecycle allDatabaseShutdown() {
        return new AllDatabaseStopper();
    }

    private StandaloneDatabaseContext systemContext() {
        return databaseRepository
                .getDatabaseContext(NAMED_SYSTEM_DATABASE_ID)
                .orElseThrow(() -> DatabaseNotFoundHelper.databaseNotFound(SYSTEM_DATABASE_NAME));
    }

    private Optional<StandaloneDatabaseContext> defaultContext() {
        return databaseRepository.getDatabaseContext(defaultDatabaseName);
    }

    private synchronized void initialiseDefaultDatabase() {
        var defaultDatabaseId = databaseRepository
                .databaseIdRepository()
                .getByName(defaultDatabaseName)
                .orElseThrow(() -> DatabaseNotFoundHelper.defaultDatabaseNotFound(defaultDatabaseName));
        if (databaseRepository.getDatabaseContext(defaultDatabaseId).isPresent()) {
            throw new DatabaseManagementException(
                    "Cannot initialize " + defaultDatabaseId + " because it already exists");
        }
        var context = createDatabase(defaultDatabaseId);
        startDatabase(context);
    }

    // -------------------------------------------------------------------------
    // DatabaseAccessChecker implementation
    // -------------------------------------------------------------------------

    /**
     * Returns {@code true} when the given user is permitted to open transactions against
     * the given database.
     *
     * <p>Always grants access for:
     * <ul>
     *   <li>auth-disabled connections (empty username)</li>
     *   <li>the built-in admin user ({@code neo4j})</li>
     *   <li>the {@code system} database (needed for admin commands)</li>
     *   <li>the default database (shared general-purpose database)</li>
     * </ul>
     * For every other database, access is granted only when the user appears in the
     * in-memory {@link #databaseUserAccess} map (populated on database creation or
     * server startup).
     */
    @Override
    public boolean canUserAccessDatabase(String username, String databaseName) {
        // Auth is disabled — allow everything.
        if (username == null || username.isEmpty()) {
            return true;
        }
        // The built-in admin user always has unrestricted access.
        if (AuthManager.INITIAL_USER_NAME.equals(username)) {
            return true;
        }
        // The system database must be reachable by all authenticated users so that
        // administration commands (CREATE DATABASE, SHOW DATABASES, …) can be executed.
        if ("system".equals(databaseName)) {
            return true;
        }
        // The default (shared) database retains its original behaviour.
        if (defaultDatabaseName.equals(databaseName)) {
            return true;
        }
        // Custom databases: consult the in-memory access map.
        Set<String> allowed = databaseUserAccess.get(databaseName);
        return allowed != null && allowed.contains(username);
    }

    @Override
    public void grantUserAccessToDatabase(String username, String databaseName) {
        if (username == null || username.isEmpty() || databaseName == null || databaseName.isEmpty()) {
            return;
        }
        databaseUserAccess.computeIfAbsent(databaseName, k -> ConcurrentHashMap.newKeySet()).add(username);
    }

    @Override
    public void revokeUserAccessToDatabase(String username, String databaseName) {
        if (username == null || username.isEmpty() || databaseName == null || databaseName.isEmpty()) {
            return;
        }
        Set<String> users = databaseUserAccess.get(databaseName);
        if (users != null) {
            users.remove(username);
        }
    }

    // -------------------------------------------------------------------------
    // DatabaseRuntimeManager implementation
    // -------------------------------------------------------------------------

    /**
     * Stops and removes a database from the runtime registry without requiring a server restart.
     * Also idempotent — silently skips if the database is not currently loaded.
     */
    public synchronized void dropDatabase(String name) {
        databaseRepository.getDatabaseContext(name).ifPresent(context -> {
            stopDatabase(context);
            databaseRepository.remove(context.database().getNamedDatabaseId());
        });
        databaseUserAccess.remove(name);
    }

    /**
     * Creates and starts a database at runtime, recording {@code ownerUsername} as an
     * authorised accessor. Safe to call concurrently — skips silently if the database
     * is already loaded.
     */
    @Override
    public synchronized void createAndStartDatabase(String name, String uuidStr, String ownerUsername) {
        var namedDatabaseId = DatabaseIdFactory.from(name, UUID.fromString(uuidStr));
        if (databaseRepository.getDatabaseContext(namedDatabaseId).isEmpty()) {
            var context = createDatabase(namedDatabaseId);
            startDatabase(context);
        }
        if (ownerUsername != null && !ownerUsername.isEmpty()) {
            databaseUserAccess
                    .computeIfAbsent(name, k -> ConcurrentHashMap.newKeySet())
                    .add(ownerUsername);
        }
    }

    private void initialiseAdditionalDatabases() {
        try {
            var systemFacade = systemContext().databaseFacade();
            try (var tx = systemFacade.beginTx()) {
                var nodes = tx.findNodes(TopologyGraphDbmsModel.DATABASE_LABEL);
                while (nodes.hasNext()) {
                    var node = nodes.next();
                    var name = (String) node.getProperty(TopologyGraphDbmsModel.DATABASE_NAME_PROPERTY);
                    var uuidStr = (String) node.getProperty(TopologyGraphDbmsModel.DATABASE_UUID_PROPERTY);
                    var dbId = DatabaseIdFactory.from(name, UUID.fromString(uuidStr));
                    var isExtra = !dbId.isSystemDatabase() && !dbId.name().equals(defaultDatabaseName);
                    var notLoaded = databaseRepository.getDatabaseContext(dbId).isEmpty();
                    if (isExtra && notLoaded) {
                        try {
                            var context = createDatabase(dbId);
                            startDatabase(context);
                        } catch (Exception e) {
                            log.error("Failed to initialise additional database '" + name + "'", e);
                        }
                    }
                    // Rebuild the in-memory access map from HAS_ACCESS relationships in the
                    // system graph, regardless of whether this is a new or already-loaded DB.
                    // getRelationships() returns ResourceIterable — use try-with-resources +
                    // for-each (it implements Iterable, not Iterator directly).
                    if (isExtra) {
                        try (var rels = node.getRelationships(Direction.INCOMING, HAS_ACCESS_REL)) {
                            for (var rel : rels) {
                                var userNode = rel.getStartNode();
                                if (userNode.hasLabel(USER_NODE_LABEL)) {
                                    var username = (String) userNode.getProperty("name", null);
                                    if (username != null && !username.isEmpty()) {
                                        databaseUserAccess
                                                .computeIfAbsent(name, k -> ConcurrentHashMap.newKeySet())
                                                .add(username);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch (Exception e) {
            log.error("Failed to scan system graph for additional databases", e);
        }
    }

    private StandaloneDatabaseContext createDatabase(NamedDatabaseId namedDatabaseId) {
        log.info("Creating '%s'.", namedDatabaseId);
        checkDatabaseLimit(namedDatabaseId);
        StandaloneDatabaseContext databaseContext = databaseContextFactory.create(namedDatabaseId, Optional.empty());
        databaseRepository.add(namedDatabaseId, databaseContext);
        return databaseContext;
    }

    private void stopDatabase(StandaloneDatabaseContext context) {
        var namedDatabaseId = context.database().getNamedDatabaseId();
        // Make sure that any failure (typically database panic) that happened until now is not interpreted as shutdown
        // failure
        context.clearFailure();
        try {
            log.info("Stopping '%s'.", namedDatabaseId);
            Database database = context.database();

            database.stop();
            log.info("Stopped '%s' successfully.", namedDatabaseId);
        } catch (Throwable t) {
            log.error("Failed to stop " + namedDatabaseId, t);
            context.fail(new DatabaseManagementException(
                    format("An error occurred! Unable to stop `%s`.", namedDatabaseId), t));
        }
    }

    private void startDatabase(StandaloneDatabaseContext context) {
        var namedDatabaseId = context.database().getNamedDatabaseId();
        try {
            log.info("Starting '%s'.", namedDatabaseId);
            Database database = context.database();
            database.start();
        } catch (Throwable t) {
            log.error("Failed to start " + namedDatabaseId, t);
            context.fail(UnableToStartDatabaseException.unableToStartDb(namedDatabaseId, t));
        }
    }

    private void checkDatabaseLimit(NamedDatabaseId namedDatabaseId) {
        // Database limit removed: multiple databases are supported in community edition
    }

    private class SystemDatabaseStarter extends LifecycleAdapter {
        @Override
        public void init() {
            createDatabase(NAMED_SYSTEM_DATABASE_ID);
        }

        @Override
        public void start() {
            startDatabase(systemContext());
        }
    }

    private class AllDatabaseStopper extends LifecycleAdapter {
        @Override
        public void stop() throws Exception {
            // Stop all registered non-system databases (default + any additional ones)
            var nonSystemContexts = new ArrayList<StandaloneDatabaseContext>();
            for (var entry : databaseRepository.registeredDatabases().entrySet()) {
                if (!entry.getKey().isSystemDatabase()) {
                    nonSystemContexts.add(entry.getValue());
                }
            }
            nonSystemContexts.forEach(DatabaseLifecycles.this::stopDatabase);

            StandaloneDatabaseContext systemContext = systemContext();
            stopDatabase(systemContext);

            executeAll(
                    () -> nonSystemContexts.forEach(this::throwIfUnableToStop),
                    () -> throwIfUnableToStop(systemContext));
        }

        private void throwIfUnableToStop(StandaloneDatabaseContext ctx) {

            if (!ctx.isFailed()) {
                return;
            }

            // If we have not been able to start the database instance, then
            // we do not want to add a compounded error due to not being able
            // to stop the database.
            if (ctx.failureCause() instanceof UnableToStartDatabaseException) {
                return;
            }

            throw new DatabaseManagementException(
                    "Failed to stop " + ctx.database().getNamedDatabaseId().name() + " database.", ctx.failureCause());
        }
    }

    private class DefaultDatabaseStarter extends LifecycleAdapter {
        @Override
        public void start() {
            initialiseDefaultDatabase();
            initialiseAdditionalDatabases();
        }
    }
}
