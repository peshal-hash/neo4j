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
 * Checks whether a user is allowed to open transactions against a specific database.
 * Implemented by DatabaseLifecycles in the community edition.
 */
@FunctionalInterface
public interface DatabaseAccessChecker {
    /**
     * Returns true if the given user is permitted to access the given database.
     *
     * @param username     the authenticated username (empty string means auth is disabled)
     * @param databaseName the normalised database name
     */
    boolean canUserAccessDatabase(String username, String databaseName);

    /**
     * Records that {@code username} is allowed to access {@code databaseName}.
     * This updates only the in-memory access map; the caller is responsible for
     * persisting the corresponding {@code HAS_ACCESS} relationship in the system graph.
     */
    default void grantUserAccessToDatabase(String username, String databaseName) {}

    /**
     * Removes the in-memory access grant for {@code username} on {@code databaseName}.
     */
    default void revokeUserAccessToDatabase(String username, String databaseName) {}
}
