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
package org.neo4j.cypher.internal

import org.neo4j.common.DependencyResolver
import org.neo4j.configuration.Config
import org.neo4j.cypher.internal.AdministrationCommandRuntime.getNameFields
import org.neo4j.cypher.internal.AdministrationCommandRuntime.internalKey
import org.neo4j.cypher.internal.AdministrationCommandRuntime.makeRenameExecutionPlan
import org.neo4j.cypher.internal.AdministrationCommandRuntime.runtimeStringValue
import org.neo4j.cypher.internal.AdministrationCommandRuntime.userNamePropKey
import org.neo4j.cypher.internal.administration.AlterUserExecutionPlanner
import org.neo4j.cypher.internal.administration.CreateUserExecutionPlanner
import org.neo4j.cypher.internal.administration.DoNothingExecutionPlanner
import org.neo4j.cypher.internal.administration.DropUserExecutionPlanner
import org.neo4j.cypher.internal.administration.EnsureNodeExistsExecutionPlanner
import org.neo4j.cypher.internal.administration.SetOwnPasswordExecutionPlanner
import org.neo4j.cypher.internal.administration.ShowDatabasesExecutionPlanner
import org.neo4j.cypher.internal.administration.ShowUsersExecutionPlanner
import org.neo4j.cypher.internal.administration.SystemProcedureCallPlanner
import org.neo4j.cypher.internal.ast.AdministrationAction
import org.neo4j.cypher.internal.ast.DbmsAction
import org.neo4j.cypher.internal.ast.DumpData
import org.neo4j.cypher.internal.ast.StartDatabaseAction
import org.neo4j.cypher.internal.ast.StopDatabaseAction
import org.neo4j.cypher.internal.ast.UnassignableAction
import org.neo4j.cypher.internal.expressions.Parameter
import org.neo4j.cypher.internal.logical.plans.AllowedNonAdministrationCommands
import org.neo4j.cypher.internal.logical.plans.AlterUser
import org.neo4j.cypher.internal.logical.plans.AssertAllowedDatabaseAction
import org.neo4j.cypher.internal.logical.plans.AssertAllowedDbmsActions
import org.neo4j.cypher.internal.logical.plans.AssertAllowedDbmsActionsOrSelf
import org.neo4j.cypher.internal.logical.plans.AssertCanDropDatabase
import org.neo4j.cypher.internal.logical.plans.AssertNotCurrentUser
import org.neo4j.cypher.internal.logical.plans.CheckNativeAuthentication
import org.neo4j.cypher.internal.logical.plans.CreateUser
import org.neo4j.cypher.internal.logical.plans.DoNothingIfDatabaseExists
import org.neo4j.cypher.internal.logical.plans.DoNothingIfDatabaseNotExists
import org.neo4j.cypher.internal.logical.plans.DoNothingIfExists
import org.neo4j.cypher.internal.logical.plans.DoNothingIfNotExists
import org.neo4j.cypher.internal.logical.plans.DropUser
import org.neo4j.cypher.internal.logical.plans.EnsureNodeExists
import org.neo4j.cypher.internal.logical.plans.LogSystemCommand
import org.neo4j.cypher.internal.logical.plans.LogicalPlan
import org.neo4j.cypher.internal.logical.plans.NameValidator
import org.neo4j.cypher.internal.logical.plans.PrivilegePlan
import org.neo4j.cypher.internal.logical.plans.RenameUser
import org.neo4j.cypher.internal.logical.plans.SetOwnPassword
import org.neo4j.cypher.internal.logical.plans.ShowCurrentUser
import org.neo4j.cypher.internal.logical.plans.ShowDatabase
import org.neo4j.cypher.internal.logical.plans.ShowUsers
import org.neo4j.cypher.internal.logical.plans.AssertDatabasePrivilegeCanBeMutated
import org.neo4j.cypher.internal.logical.plans.AssertDbmsPrivilegeCanBeMutated
import org.neo4j.cypher.internal.logical.plans.AssertGraphPrivilegeCanBeMutated
import org.neo4j.cypher.internal.logical.plans.AssertManagementActionNotBlocked
import org.neo4j.cypher.internal.logical.plans.CreateDatabase
import org.neo4j.cypher.internal.logical.plans.DenyDatabaseAction
import org.neo4j.cypher.internal.logical.plans.DenyDbmsAction
import org.neo4j.cypher.internal.logical.plans.DenyGraphAction
import org.neo4j.cypher.internal.logical.plans.DenyLoadAction
import org.neo4j.cypher.internal.logical.plans.DropDatabase
import org.neo4j.cypher.internal.logical.plans.EnsureDatabaseSafeToDelete
import org.neo4j.cypher.internal.logical.plans.EnsureNameIsNotAmbiguous
import org.neo4j.cypher.internal.logical.plans.EnsureValidNonSystemDatabase
import org.neo4j.cypher.internal.logical.plans.EnsureValidNumberOfDatabases
import org.neo4j.cypher.internal.logical.plans.GrantDatabaseAction
import org.neo4j.cypher.internal.logical.plans.GrantDbmsAction
import org.neo4j.cypher.internal.logical.plans.GrantGraphAction
import org.neo4j.cypher.internal.logical.plans.GrantLoadAction
import org.neo4j.cypher.internal.logical.plans.NamedScope
import org.neo4j.cypher.internal.logical.plans.RevokeDatabaseAction
import org.neo4j.cypher.internal.logical.plans.RevokeDbmsAction
import org.neo4j.cypher.internal.logical.plans.RevokeGraphAction
import org.neo4j.cypher.internal.logical.plans.RevokeLoadAction
import org.neo4j.cypher.internal.logical.plans.SystemProcedureCall
import org.neo4j.cypher.internal.logical.plans.WaitForCompletion
import org.neo4j.dbms.database.DatabaseAccessChecker
import org.neo4j.dbms.database.DatabaseRuntimeManager
import org.neo4j.cypher.internal.procs.ActionMapper
import org.neo4j.cypher.internal.procs.AuthorizationAndPredicateExecutionPlan
import org.neo4j.cypher.internal.procs.Continue
import org.neo4j.cypher.internal.procs.ParameterTransformer
import org.neo4j.cypher.internal.procs.PredicateExecutionPlan
import org.neo4j.cypher.internal.procs.QueryHandler
import org.neo4j.cypher.internal.procs.SystemCommandExecutionPlan
import org.neo4j.cypher.internal.procs.ThrowException
import org.neo4j.cypher.internal.procs.UpdatingSystemCommandExecutionPlan
import org.neo4j.cypher.rendering.QueryRenderer
import org.neo4j.dbms.systemgraph.TopologyGraphDbmsModel.DATABASE_LABEL
import org.neo4j.dbms.systemgraph.TopologyGraphDbmsModel.DATABASE_NAME_LABEL
import org.neo4j.exceptions.CantCompileQueryException
import org.neo4j.exceptions.CypherExecutionException
import org.neo4j.exceptions.DatabaseAdministrationOnFollowerException
import org.neo4j.exceptions.InvalidArgumentException
import org.neo4j.exceptions.Neo4jException
import org.neo4j.graphdb.security.AuthorizationViolationException
import org.neo4j.internal.kernel.api.security.AbstractSecurityLog
import org.neo4j.internal.kernel.api.security.AccessMode
import org.neo4j.internal.kernel.api.security.AdminActionOnResource
import org.neo4j.internal.kernel.api.security.AdminActionOnResource.DatabaseScope
import org.neo4j.internal.kernel.api.security.PermissionState
import org.neo4j.internal.kernel.api.security.SecurityAuthorizationHandler
import org.neo4j.internal.kernel.api.security.SecurityContext
import org.neo4j.internal.kernel.api.security.Segment
import org.neo4j.kernel.api.exceptions.Status
import org.neo4j.kernel.api.exceptions.Status.HasStatus
import org.neo4j.kernel.database.NormalizedDatabaseName
import org.neo4j.kernel.impl.api.security.RestrictedAccessMode
import org.neo4j.kernel.impl.query.TransactionalContext.DatabaseMode
import org.neo4j.server.security.systemgraph.UserSecurityGraphComponent
import java.util.UUID
import org.neo4j.values.AnyValue
import org.neo4j.values.storable.BooleanValue
import org.neo4j.values.storable.TextValue
import org.neo4j.values.storable.Values
import org.neo4j.values.virtual.MapValue
import org.neo4j.values.virtual.VirtualValues

/**
 * This runtime takes on queries that work on the system database, such as multidatabase and security administration commands.
 * The planning requirements for these are much simpler than normal Cypher commands, and as such the runtime stack is also different.
 */
case class CommunityAdministrationCommandRuntime(
  normalExecutionEngine: ExecutionEngine,
  resolver: DependencyResolver,
  extraLogicalToExecutable: PartialFunction[LogicalPlan, AdministrationCommandRuntimeContext => ExecutionPlan] =
    CommunityAdministrationCommandRuntime.emptyLogicalToExecutable
) extends AdministrationCommandRuntime {
  override def name: String = "community administration-commands"

  private lazy val securityAuthorizationHandler =
    new SecurityAuthorizationHandler(resolver.resolveDependency(classOf[AbstractSecurityLog]))
  private val config: Config = resolver.resolveDependency(classOf[Config])

  private lazy val userSecurity: UserSecurityGraphComponent =
    resolver.resolveDependency(classOf[UserSecurityGraphComponent])

  private lazy val databaseLifecycles: DatabaseRuntimeManager =
    resolver.resolveDependency(classOf[DatabaseRuntimeManager])

  private lazy val databaseAccessChecker: DatabaseAccessChecker =
    resolver.resolveDependency(classOf[DatabaseAccessChecker])

  def throwCantCompile(unknownPlan: LogicalPlan): Nothing = {
    throw new CantCompileQueryException(
      s"Plan is not a recognized database administration command in community edition: ${unknownPlan.getClass.getSimpleName}"
    )
  }

  override def compileToExecutable(
    state: LogicalQuery,
    context: RuntimeContext,
    databaseMode: DatabaseMode
  ): ExecutionPlan = {
    // Either the logical plan is a command that the partial function logicalToExecutable provides/understands OR we throw an error
    logicalToExecutable.applyOrElse(state.logicalPlan, throwCantCompile).apply(
      AdministrationCommandRuntimeContext(context)
    )
  }

  // When the community commands are run within enterprise, this allows the enterprise commands to be chained
  private def fullLogicalToExecutable = extraLogicalToExecutable orElse logicalToExecutable

  val checkShowUserPrivilegesText: String =
    "Try executing SHOW USER PRIVILEGES to determine the missing or denied privileges. " +
      "In case of missing privileges, they need to be granted (See GRANT). In case of denied privileges, they need to be revoked (See REVOKE) and granted."

  def prettifyActionName(actions: AdministrationAction*): String = {
    actions.map {
      case StartDatabaseAction => "START DATABASE"
      case StopDatabaseAction  => "STOP DATABASE"
      case a                   => a.name
    }.sorted.mkString(" and/or ")
  }

  private[internal] def adminActionErrorMessage(
    permissionState: PermissionState,
    actions: Seq[AdministrationAction]
  ) = {
    val allUnassignable = actions.forall(_.isInstanceOf[UnassignableAction])
    val missingPrivilegeHelpMessageSuffix = if (allUnassignable) "" else s" $checkShowUserPrivilegesText"

    permissionState match {
      case PermissionState.EXPLICIT_DENY =>
        s"Permission denied for ${prettifyActionName(actions: _*)}.$missingPrivilegeHelpMessageSuffix"
      case PermissionState.NOT_GRANTED =>
        val reason = if (allUnassignable) "cannot be" else "has not been"
        s"Permission $reason granted for ${prettifyActionName(actions: _*)}.$missingPrivilegeHelpMessageSuffix"
      case PermissionState.EXPLICIT_GRANT => ""
    }
  }

  private def getSource(
    maybeSource: Option[PrivilegePlan],
    context: AdministrationCommandRuntimeContext
  ): Option[ExecutionPlan] =
    maybeSource match {
      case Some(source) => Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
      case _            => None
    }

  private[internal] def checkActions(
    actions: Seq[DbmsAction],
    securityContext: SecurityContext
  ): Seq[(DbmsAction, PermissionState)] =
    actions.map { action =>
      (
        action,
        securityContext.allowsAdminAction(new AdminActionOnResource(
          ActionMapper.asKernelAction(action),
          DatabaseScope.ALL,
          Segment.ALL
        ))
      )
    }

  private def checkAdminRightsForDBMSOrSelf(
    user: Either[String, Parameter],
    actions: Seq[DbmsAction]
  ): AdministrationCommandRuntimeContext => ExecutionPlan = _ => {
    AuthorizationAndPredicateExecutionPlan(
      securityAuthorizationHandler,
      (params, securityContext) => {
        if (securityContext.subject().hasUsername(runtimeStringValue(user, params)))
          Seq((null, PermissionState.EXPLICIT_GRANT))
        else checkActions(actions, securityContext)
      },
      violationMessage = adminActionErrorMessage
    )
  }

  def logicalToExecutable: PartialFunction[LogicalPlan, AdministrationCommandRuntimeContext => ExecutionPlan] = {
    // Check Admin Rights for DBMS commands
    case AssertAllowedDbmsActions(maybeSource, actions) => context =>
        AuthorizationAndPredicateExecutionPlan(
          securityAuthorizationHandler,
          (_, securityContext) => checkActions(actions, securityContext),
          violationMessage = adminActionErrorMessage,
          source = getSource(maybeSource, context)
        )

    // Check Admin Rights for DBMS commands or self
    case AssertAllowedDbmsActionsOrSelf(user, actions) =>
      context => checkAdminRightsForDBMSOrSelf(user, actions)(context)

    // Check that the specified user is not the logged in user (eg. for some CREATE/DROP/ALTER USER commands)
    case AssertNotCurrentUser(source, userName, verb, violationMessage, errorGqlStatusObject) => context =>
        PredicateExecutionPlan(
          (params, sc) => !sc.subject().hasUsername(runtimeStringValue(userName, params)),
          onViolation = (_, _, sc) =>
            new InvalidArgumentException(
              errorGqlStatusObject,
              s"Failed to $verb the specified user '${sc.subject().executingUser()}': $violationMessage."
            ),
          source = Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
        )

    // Check Admin Rights for some Database commands
    case AssertAllowedDatabaseAction(action, database, maybeSource) => context =>
        AuthorizationAndPredicateExecutionPlan(
          securityAuthorizationHandler,
          (params, securityContext) =>
            Seq((
              action,
              securityContext.allowsAdminAction(
                new AdminActionOnResource(
                  ActionMapper.asKernelAction(action),
                  new DatabaseScope(runtimeStringValue(database, params)),
                  Segment.ALL
                )
              )
            )),
          violationMessage = adminActionErrorMessage,
          source = getSource(maybeSource, context)
        )

    // Community custom multi-database flow: only the linked user (HAS_ACCESS) or
    // built-in admin may drop a database.
    case AssertCanDropDatabase(source, databaseName, _) => context =>
        PredicateExecutionPlan(
          (params, sc) => {
            val dbName = runtimeStringValue(databaseName, params)
            val username = sc.subject().executingUser()
            databaseAccessChecker.canUserDropDatabase(username, dbName)
          },
          onViolation = (params, _, sc) => {
            val dbName = runtimeStringValue(databaseName, params)
            val username = sc.subject().executingUser()
            new AuthorizationViolationException(
              s"Permission denied to DROP DATABASE '$dbName' for user '$username'. " +
                "Only the linked user or admin can drop this database."
            )
          },
          source = Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
        )

    // SHOW USERS
    case ShowUsers(source, withAuth, symbols, yields, returns) => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
        ShowUsersExecutionPlanner(normalExecutionEngine, securityAuthorizationHandler).planShowUsers(
          symbols,
          withAuth,
          yields,
          returns,
          sourcePlan
        )

    // SHOW CURRENT USER
    case ShowCurrentUser(symbols, yields, returns) => _ =>
        ShowUsersExecutionPlanner(normalExecutionEngine, securityAuthorizationHandler).planShowCurrentUser(
          symbols,
          yields,
          returns
        )

      // CREATE [OR REPLACE] USER foo [IF NOT EXISTS] SET [PLAINTEXT | ENCRYPTED] PASSWORD 'password'
    // CREATE [OR REPLACE] USER foo [IF NOT EXISTS] SET [PLAINTEXT | ENCRYPTED] PASSWORD $password
    case createUser: CreateUser => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(createUser.source, throwCantCompile).apply(context))
        CreateUserExecutionPlanner(
          normalExecutionEngine,
          securityAuthorizationHandler,
          config
        ).planCreateUser(
          createUser,
          sourcePlan
        )

    // RENAME USER
    case RenameUser(source, fromUserName, toUserName) => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
        makeRenameExecutionPlan(
          PrivilegeGQLCodeEntity.User(),
          userNamePropKey,
          fromUserName,
          toUserName,
          params => {
            val toName = runtimeStringValue(toUserName, params)
            NameValidator.assertValidUsername(toName)
          }
        )(sourcePlan, normalExecutionEngine, securityAuthorizationHandler)

    // ALTER USER foo [SET [PLAINTEXT | ENCRYPTED] PASSWORD pw] [CHANGE [NOT] REQUIRED]
    case alterUser: AlterUser => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(alterUser.source, throwCantCompile).apply(context))
        AlterUserExecutionPlanner(
          normalExecutionEngine,
          securityAuthorizationHandler,
          userSecurity,
          config
        ).planAlterUser(
          alterUser,
          sourcePlan
        )

    // DROP USER foo [IF EXISTS]
    case DropUser(source, userName) => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
        DropUserExecutionPlanner(normalExecutionEngine, securityAuthorizationHandler).planDropUser(userName, sourcePlan)

    // ALTER CURRENT USER SET PASSWORD FROM 'currentPassword' TO 'newPassword'
    // ALTER CURRENT USER SET PASSWORD FROM 'currentPassword' TO $newPassword
    // ALTER CURRENT USER SET PASSWORD FROM $currentPassword TO 'newPassword'
    // ALTER CURRENT USER SET PASSWORD FROM $currentPassword TO $newPassword
    case SetOwnPassword(source, newPassword, currentPassword) => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
        SetOwnPasswordExecutionPlanner(normalExecutionEngine, securityAuthorizationHandler, config).planSetOwnPassword(
          newPassword,
          currentPassword,
          sourcePlan
        )

    // SHOW DATABASES | SHOW DEFAULT DATABASE | SHOW HOME DATABASE | SHOW DATABASE foo
    case ShowDatabase(scope, verbose, symbols, yields, returns) => _ =>
        ShowDatabasesExecutionPlanner(
          resolver,
          normalExecutionEngine,
          securityAuthorizationHandler
        )
          .planShowDatabases(scope, verbose, symbols, yields, returns)

    case DoNothingIfNotExists(source, command, entity, name, operation, valueMapper) => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
        DoNothingExecutionPlanner(normalExecutionEngine, securityAuthorizationHandler).planDoNothingIfNotExists(
          command,
          entity,
          name,
          valueMapper,
          operation,
          sourcePlan
        )

    case DoNothingIfExists(source, command, entity, name, valueMapper) => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
        DoNothingExecutionPlanner(normalExecutionEngine, securityAuthorizationHandler).planDoNothingIfExists(
          command,
          entity,
          name,
          valueMapper,
          sourcePlan
        )

    case DoNothingIfDatabaseNotExists(source, command, name, operation, databaseTypeFilter) => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
        DoNothingExecutionPlanner(normalExecutionEngine, securityAuthorizationHandler).planDoNothingIfDatabaseNotExists(
          command,
          name,
          operation,
          sourcePlan,
          databaseTypeFilter
        )

    case DoNothingIfDatabaseExists(source, command, name, databaseTypeFilter) => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
        DoNothingExecutionPlanner(normalExecutionEngine, securityAuthorizationHandler).planDoNothingIfDatabaseExists(
          command,
          name,
          sourcePlan,
          databaseTypeFilter
        )

    // Ensure that the role or user exists before being dropped
    case EnsureNodeExists(source, command, entity, name, valueMapper, extraFilter, labelDescription, action) =>
      context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context))
        EnsureNodeExistsExecutionPlanner(normalExecutionEngine, securityAuthorizationHandler)
          .planEnsureNodeExists(command, entity, name, valueMapper, extraFilter, labelDescription, action, sourcePlan)

    // SUPPORT PROCEDURES (need to be cleared before here)
    case SystemProcedureCall(_, call, returns, _, checkCredentialsExpired) => _ =>
        SystemProcedureCallPlanner(normalExecutionEngine, securityAuthorizationHandler).planSystemProcedureCall(
          call,
          returns,
          checkCredentialsExpired
        )

    case CheckNativeAuthentication() => _ =>
        val usernameKey = internalKey("username")
        val nativeAuth = internalKey("nativelyAuthenticated")

        def currentUser(p: MapValue): String = p.get(usernameKey).asInstanceOf[TextValue].stringValue()

        UpdatingSystemCommandExecutionPlan(
          "CheckNativeAuthentication",
          normalExecutionEngine,
          securityAuthorizationHandler,
          s"RETURN $$`$nativeAuth` AS nativelyAuthenticated",
          MapValue.EMPTY,
          QueryHandler
            .handleError {
              case (error: HasStatus, p) if error.status() == Status.Cluster.NotALeader =>
                DatabaseAdministrationOnFollowerException.notALeader(
                  "ALTER CURRENT USER SET PASSWORD",
                  s"User '${currentUser(p)}' failed to alter their own password",
                  error
                )
              case (error: Neo4jException, _) => error
              case (error, p) =>
                CypherExecutionException.alterOwnPassword(currentUser(p), error)
            }
            .handleResult((_, value, _) => {
              if (value eq BooleanValue.TRUE) Continue
              else ThrowException(new AuthorizationViolationException("`ALTER CURRENT USER` is not permitted."))
            }),
          parameterTransformer = ParameterTransformer((_, securityContext, _) =>
            VirtualValues.map(
              Array(nativeAuth, usernameKey),
              Array(
                Values.booleanValue(securityContext.nativelyAuthenticated()),
                Values.utf8Value(securityContext.subject().executingUser())
              )
            )
          ),
          checkCredentialsExpired = false
        )

    // Non-administration commands that are allowed on system database, e.g. SHOW PROCEDURES
    case AllowedNonAdministrationCommands(statement) => context =>
        // While running against system will override most pre-parser options.
        // However, we shouldn't override the Cypher version,
        // so let's prepend the inner query with the relevant Cypher version.
        val versionName = context.runtimeContext.cypherVersion.versionName
        val versionString = s"CYPHER $versionName "

        SystemCommandExecutionPlan(
          "AllowedNonAdministrationCommand",
          normalExecutionEngine,
          securityAuthorizationHandler,
          versionString + QueryRenderer.render(statement),
          MapValue.EMPTY,
          // If we have a non admin command executing in the system database, forbid it to make reads / writes
          // from the system graph. This is to prevent queries such as SHOW PROCEDURES YIELD * RETURN ()--()
          // from leaking nodes from the system graph: the ()--() would return empty results
          modeConverter = s => s.withMode(new RestrictedAccessMode(s.mode(), AccessMode.Static.ACCESS))
        )

    // Management actions are never blocked in community edition
    case AssertManagementActionNotBlocked(_) => _ =>
        AuthorizationAndPredicateExecutionPlan(
          securityAuthorizationHandler,
          (_, _) => Seq((null, PermissionState.EXPLICIT_GRANT)),
          violationMessage = adminActionErrorMessage
        )

    // In community edition there is only one namespace, so names are never ambiguous
    case EnsureNameIsNotAmbiguous(source, _, _) => context =>
        fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context)

    // CREATE [OR REPLACE] DATABASE foo [IF NOT EXISTS] - write the database entry to the system graph
    case createDb: CreateDatabase => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(createDb.source, throwCantCompile).apply(context))
        val dbNameFields = getNameFields("dbName", createDb.databaseName, new NormalizedDatabaseName(_).name())
        val uuidKey = internalKey("uuid")
        val uuidValue = Values.utf8Value(UUID.randomUUID().toString)
        val currentUserKey = internalKey("currentUser")
        val database = DATABASE_LABEL.name()
        val databaseName = DATABASE_NAME_LABEL.name()
        UpdatingSystemCommandExecutionPlan(
          "CreateDatabase",
          normalExecutionEngine,
          securityAuthorizationHandler,
          s"""CREATE (db:$database {
             |  name: $$`${dbNameFields.nameKey}`,
             |  uuid: $$`$uuidKey`,
             |  status: 'online',
             |  access: 'READ_WRITE',
             |  default: false,
             |  created_at: datetime(),
             |  started_at: datetime(),
             |  store_random_id: toInteger(rand() * 9007199254740992)
             |})
             |WITH db
             |CREATE (:$databaseName {
             |  name: $$`${dbNameFields.nameKey}`,
             |  namespace: 'system-root',
             |  displayName: $$`${dbNameFields.nameKey}`,
             |  primary: true
             |})-[:TARGETS]->(db)
             |WITH db
             |OPTIONAL MATCH (u:User {name: $$`$currentUserKey`})
             |FOREACH (_ IN CASE WHEN u IS NOT NULL THEN [1] ELSE [] END |
             |  MERGE (u)-[:HAS_ACCESS]->(db))
             |RETURN db.name""".stripMargin,
          VirtualValues.map(
            Array(dbNameFields.nameKey, uuidKey),
            Array[AnyValue](dbNameFields.nameValue, uuidValue)
          ),
          QueryHandler
            .handleResult { (offset, value, params) =>
              if (offset == 0) {
                val dbName = value.asInstanceOf[TextValue].stringValue()
                val owner = params.get(currentUserKey) match {
                  case tv: TextValue => tv.stringValue()
                  case _             => ""
                }
                try {
                  databaseLifecycles.createAndStartDatabase(dbName, uuidValue.stringValue(), owner)
                } catch {
                  case _: Exception => // failure already logged inside createAndStartDatabase
                }
              }
              Continue
            }
            .handleNoResult(_ =>
              Some(ThrowException(new InvalidArgumentException("Failed to create the specified database.")))
            )
            .handleError { (error, _) =>
              new InvalidArgumentException(
                s"Failed to create the specified database: ${error.getMessage}",
                error
              )
            },
          sourcePlan,
          parameterTransformer = ParameterTransformer()
            .convert(dbNameFields.nameConverter)
            .generate((_, sc, _) =>
              VirtualValues.map(
                Array(currentUserKey),
                Array[AnyValue](Values.utf8Value(sc.subject().executingUser()))
              )
            )
        )

    // Database count limit is bypassed in community edition to allow multiple databases
    case EnsureValidNumberOfDatabases(source) => context =>
        fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context)

    // Wait for completion is a no-op in community edition (no cluster coordination)
    case WaitForCompletion(source, _, _) => context =>
        fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context)

    // Safety checks for drop are pass-through in community (no aliases, no composite dbs)
    case EnsureDatabaseSafeToDelete(source, _, _) => context =>
        fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context)

    // Non-system database validation is a pass-through in community (only one system database)
    case EnsureValidNonSystemDatabase(source, _, _, _, _) => context =>
        fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context)

    // -----------------------------------------------------------------------
    // Privilege management — simplified community implementation
    //
    // In community edition we do not support roles, so "role names" supplied
    // in GRANT/REVOKE commands are treated directly as usernames.
    //
    // GRANT ... ON DATABASE foo TO username  →  write HAS_ACCESS in system
    //                                            graph + update in-memory map
    // REVOKE ... ON DATABASE foo FROM username  →  remove HAS_ACCESS + map
    //
    // Graph-level and DBMS-level grants have no effect (access is controlled
    // at the database level via HAS_ACCESS), but they succeed silently so
    // that client code using enterprise-style grant sequences does not break.
    // -----------------------------------------------------------------------

    // Assert plans are pass-through in community (no privilege metadata to validate)
    case plan: AssertDatabasePrivilegeCanBeMutated => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    case plan: AssertDbmsPrivilegeCanBeMutated => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    case plan: AssertGraphPrivilegeCanBeMutated => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    // GRANT ... ON DATABASE foo TO username
    case grantDb: GrantDatabaseAction => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(grantDb.source, throwCantCompile).apply(context))
        grantDb.database match {
          case NamedScope(dbNameObj) =>
            val dbNameFields =
              getNameFields("grantDbName", dbNameObj.asLegacyName, new NormalizedDatabaseName(_).name())
            val (usernameKey, usernameValue: AnyValue) = grantDb.roleName match {
              case Left(name)   => (internalKey("grantUsername"), Values.utf8Value(name))
              case Right(param) => (param.name, Values.NO_VALUE)
            }
            val database = DATABASE_LABEL.name()
            UpdatingSystemCommandExecutionPlan(
              "GrantDatabaseAccess",
              normalExecutionEngine,
              securityAuthorizationHandler,
              s"""MATCH (u:User {name: $$`$usernameKey`}), (db:$database {name: $$`${dbNameFields.nameKey}`})
                 |MERGE (u)-[:HAS_ACCESS]->(db)
                 |RETURN u.name AS username""".stripMargin,
              VirtualValues.map(
                Array(usernameKey, dbNameFields.nameKey),
                Array[AnyValue](usernameValue, dbNameFields.nameValue)
              ),
              QueryHandler
                .handleResult { (offset, value, params) =>
                  if (offset == 0) {
                    val grantedUser = value.asInstanceOf[TextValue].stringValue()
                    val grantedDb = params.get(dbNameFields.nameKey) match {
                      case tv: TextValue => tv.stringValue()
                      case _             => ""
                    }
                    if (grantedUser.nonEmpty && grantedDb.nonEmpty) {
                      databaseAccessChecker.grantUserAccessToDatabase(grantedUser, grantedDb)
                    }
                  }
                  Continue
                }
                .handleNoResult(_ => None) // user or db not found — succeed silently
                .handleError { (error, _) =>
                  new InvalidArgumentException(
                    s"Failed to grant database access: ${error.getMessage}",
                    error
                  )
                },
              sourcePlan,
              parameterTransformer = ParameterTransformer().convert(dbNameFields.nameConverter)
            )
          case _ =>
            // AllScope / HomeScope — not meaningfully isolatable; pass through
            fullLogicalToExecutable.applyOrElse(grantDb.source, throwCantCompile).apply(context)
        }

    // REVOKE ... ON DATABASE foo FROM username
    case revokeDb: RevokeDatabaseAction => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(revokeDb.source, throwCantCompile).apply(context))
        revokeDb.database match {
          case NamedScope(dbNameObj) =>
            val dbNameFields =
              getNameFields("revokeDbName", dbNameObj.asLegacyName, new NormalizedDatabaseName(_).name())
            val (usernameKey, usernameValue: AnyValue) = revokeDb.roleName match {
              case Left(name)   => (internalKey("revokeUsername"), Values.utf8Value(name))
              case Right(param) => (param.name, Values.NO_VALUE)
            }
            val database = DATABASE_LABEL.name()
            UpdatingSystemCommandExecutionPlan(
              "RevokeDatabaseAccess",
              normalExecutionEngine,
              securityAuthorizationHandler,
              s"""MATCH (u:User {name: $$`$usernameKey`})-[r:HAS_ACCESS]->(db:$database {name: $$`${dbNameFields.nameKey}`})
                 |DELETE r
                 |RETURN u.name AS username""".stripMargin,
              VirtualValues.map(
                Array(usernameKey, dbNameFields.nameKey),
                Array[AnyValue](usernameValue, dbNameFields.nameValue)
              ),
              QueryHandler
                .handleResult { (offset, value, params) =>
                  if (offset == 0) {
                    val revokedUser = value.asInstanceOf[TextValue].stringValue()
                    val revokedDb = params.get(dbNameFields.nameKey) match {
                      case tv: TextValue => tv.stringValue()
                      case _             => ""
                    }
                    if (revokedUser.nonEmpty && revokedDb.nonEmpty) {
                      databaseAccessChecker.revokeUserAccessToDatabase(revokedUser, revokedDb)
                    }
                  }
                  Continue
                }
                .handleNoResult(_ => None) // relationship already absent — succeed silently
                .handleError { (error, _) =>
                  new InvalidArgumentException(
                    s"Failed to revoke database access: ${error.getMessage}",
                    error
                  )
                },
              sourcePlan,
              parameterTransformer = ParameterTransformer().convert(dbNameFields.nameConverter)
            )
          case _ =>
            fullLogicalToExecutable.applyOrElse(revokeDb.source, throwCantCompile).apply(context)
        }

    // Graph-level grants/denies/revokes — no-op in community (access is at DB level)
    case plan: GrantGraphAction  => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    case plan: RevokeGraphAction => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    case plan: DenyGraphAction   => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    // DBMS-level grants/denies/revokes — no-op in community
    case plan: GrantDbmsAction  => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    case plan: RevokeDbmsAction => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    case plan: DenyDbmsAction   => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    // Database DENY — no-op in community (only positive grants are tracked)
    case plan: DenyDatabaseAction => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    // Load/data-exchange grants — no-op in community
    case plan: GrantLoadAction  => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    case plan: RevokeLoadAction => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    case plan: DenyLoadAction   => context =>
        fullLogicalToExecutable.applyOrElse(plan.source, throwCantCompile).apply(context)

    // DROP DATABASE foo [IF EXISTS] [DESTROY DATA|DUMP DATA]
    case dropDb: DropDatabase => context =>
        val sourcePlan: Option[ExecutionPlan] =
          Some(fullLogicalToExecutable.applyOrElse(dropDb.source, throwCantCompile).apply(context))
        val dbNameFields = getNameFields("dbName", dropDb.databaseName.asLegacyName, new NormalizedDatabaseName(_).name())
        val database = DATABASE_LABEL.name()
        val databaseName = DATABASE_NAME_LABEL.name()
        UpdatingSystemCommandExecutionPlan(
          "DropDatabase",
          normalExecutionEngine,
          securityAuthorizationHandler,
          s"""MATCH (db:$database {name: $$`${dbNameFields.nameKey}`})
             |OPTIONAL MATCH (dn:$databaseName)-[:TARGETS]->(db)
             |WITH db, dn, db.name AS deletedName
             |DETACH DELETE db, dn
             |RETURN deletedName""".stripMargin,
          VirtualValues.map(
            Array(dbNameFields.nameKey),
            Array[AnyValue](dbNameFields.nameValue)
          ),
          QueryHandler
            .handleResult { (offset, value, _) =>
              if (offset == 0) {
                val dbName = value.asInstanceOf[TextValue].stringValue()
                val destroyData = dropDb.additionalAction != DumpData
                try {
                  databaseLifecycles.dropDatabase(dbName, destroyData)
                } catch {
                  case _: Exception => // failure already logged inside dropDatabase
                }
              }
              Continue
            }
            .handleError { (error, _) =>
              new InvalidArgumentException(
                s"Failed to drop the specified database: ${error.getMessage}",
                error
              )
            },
          sourcePlan,
          parameterTransformer = ParameterTransformer().convert(dbNameFields.nameConverter)
        )

    // Ignore the log command in community
    case LogSystemCommand(source, _) => context =>
        fullLogicalToExecutable.applyOrElse(source, throwCantCompile).apply(context)
  }

  override def isApplicableAdministrationCommand(logicalPlanArg: LogicalPlan): Boolean = {
    val logicalPlan = logicalPlanArg match {
      // Ignore the log command in community
      case LogSystemCommand(source, _) => source
      case plan                        => plan
    }
    logicalToExecutable.isDefinedAt(logicalPlan)
  }
}

object DatabaseStatus extends Enumeration {
  type Status = TextValue

  val Online: TextValue = Values.utf8Value("online")
  val Offline: TextValue = Values.utf8Value("offline")
}

object CommunityAdministrationCommandRuntime {

  def emptyLogicalToExecutable: PartialFunction[LogicalPlan, AdministrationCommandRuntimeContext => ExecutionPlan] =
    new PartialFunction[LogicalPlan, AdministrationCommandRuntimeContext => ExecutionPlan] {
      override def isDefinedAt(x: LogicalPlan): Boolean = false

      override def apply(v1: LogicalPlan): AdministrationCommandRuntimeContext => ExecutionPlan = ???
    }
}
