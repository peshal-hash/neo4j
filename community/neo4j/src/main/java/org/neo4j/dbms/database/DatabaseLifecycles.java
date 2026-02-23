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
import java.util.UUID;
import org.neo4j.dbms.api.DatabaseManagementException;
import org.neo4j.dbms.api.DatabaseNotFoundHelper;
import org.neo4j.dbms.systemgraph.TopologyGraphDbmsModel;
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
public final class DatabaseLifecycles implements DatabaseRuntimeManager {
    private final DatabaseRepository<StandaloneDatabaseContext> databaseRepository;
    private final String defaultDatabaseName;
    private final DatabaseContextFactory<StandaloneDatabaseContext, Optional<?>> databaseContextFactory;
    private final Log log;

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

    /**
     * Stops and removes a database from the runtime registry without requiring a server restart.
     * Also idempotent — silently skips if the database is not currently loaded.
     */
    public synchronized void dropDatabase(String name) {
        databaseRepository.getDatabaseContext(name).ifPresent(context -> {
            stopDatabase(context);
            databaseRepository.remove(context.database().getNamedDatabaseId());
        });
    }

    /**
     * Creates and starts a database at runtime without requiring a server restart.
     * Safe to call concurrently — skips silently if the database is already loaded.
     */
    public synchronized void createAndStartDatabase(String name, String uuidStr) {
        var namedDatabaseId = DatabaseIdFactory.from(name, UUID.fromString(uuidStr));
        if (databaseRepository.getDatabaseContext(namedDatabaseId).isEmpty()) {
            var context = createDatabase(namedDatabaseId);
            startDatabase(context);
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
