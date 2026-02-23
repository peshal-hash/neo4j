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

/**
 * Interface for runtime database management operations — creating and dropping databases
 * without requiring a server restart. Implemented by DatabaseLifecycles in the community edition.
 */
public interface DatabaseRuntimeManager {
    /**
     * Creates and starts a database at runtime, attributing ownership to {@code ownerUsername}.
     * Safe to call concurrently — silently skips if the database is already loaded.
     */
    void createAndStartDatabase(String name, String uuidStr, String ownerUsername);

    /**
     * Creates and starts a database at runtime with no specific owner (admin-only access).
     * Delegates to {@link #createAndStartDatabase(String, String, String)} with an empty owner.
     */
    default void createAndStartDatabase(String name, String uuidStr) {
        createAndStartDatabase(name, uuidStr, "");
    }

    /**
     * Stops and removes a database from the runtime registry.
     * Idempotent — silently skips if the database is not currently loaded.
     */
    void dropDatabase(String name);
}
