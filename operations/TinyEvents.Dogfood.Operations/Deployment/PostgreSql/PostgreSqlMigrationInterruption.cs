using Npgsql;

namespace TinyEvents.Dogfood.Operations;

internal sealed class PostgreSqlMigrationInterruption : IMigrationInterruption
{
    private const string TriggerName =
        "tiny_events_dogfood_block_migration_ddl";
    private const string FunctionName =
        "tiny_events_dogfood_block_migration_ddl";

    public async ValueTask InstallAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        var sql = $"""
            CREATE OR REPLACE FUNCTION {FunctionName}()
            RETURNS event_trigger
            LANGUAGE plpgsql
            AS $function$
            BEGIN
                PERFORM pg_catalog.pg_sleep(10);
            END;
            $function$;

            DROP EVENT TRIGGER IF EXISTS {TriggerName};

            CREATE EVENT TRIGGER {TriggerName}
            ON ddl_command_start
            WHEN TAG IN ('CREATE TABLE')
            EXECUTE FUNCTION {FunctionName}();
            """;

        await ExecuteAsync(settings.ConnectionString, sql, cancellationToken);
    }

    public async ValueTask<MigrationInterruptionObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                EXISTS
                (
                    SELECT 1
                    FROM pg_catalog.pg_event_trigger
                    WHERE evtname = @TriggerName
                ),
                (
                    SELECT COUNT(*)::integer
                    FROM pg_catalog.pg_stat_activity AS activity
                    WHERE activity.datname = current_database()
                      AND activity.pid <> pg_catalog.pg_backend_pid()
                      AND activity.wait_event = 'PgSleep'
                ),
                (
                    SELECT COUNT(*)::integer
                    FROM pg_catalog.pg_stat_activity AS activity
                    WHERE activity.datname = current_database()
                      AND activity.pid <> pg_catalog.pg_backend_pid()
                      AND activity.wait_event = 'PgSleep'
                      AND EXISTS
                      (
                          SELECT 1
                          FROM pg_catalog.pg_locks AS migration_lock
                          WHERE migration_lock.pid = activity.pid
                            AND migration_lock.locktype = 'advisory'
                            AND migration_lock.granted
                      )
                ),
                (
                    SELECT COUNT(DISTINCT migration_lock.pid)::integer
                    FROM pg_catalog.pg_locks AS migration_lock
                    INNER JOIN pg_catalog.pg_stat_activity AS activity
                        ON activity.pid = migration_lock.pid
                    WHERE activity.datname = current_database()
                      AND migration_lock.locktype = 'advisory'
                      AND migration_lock.granted
                );
            """;

        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        command.Parameters.AddWithValue("TriggerName", TriggerName);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);

        return new MigrationInterruptionObservation(
            reader.GetBoolean(0),
            reader.GetInt32(1),
            reader.GetInt32(2),
            reader.GetInt32(3));
    }

    public ValueTask RemoveAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        var sql = $"""
            DROP EVENT TRIGGER IF EXISTS {TriggerName};
            DROP FUNCTION IF EXISTS {FunctionName}();
            """;

        return ExecuteAsync(
            settings.ConnectionString,
            sql,
            cancellationToken);
    }

    private static async ValueTask ExecuteAsync(
        string connectionString,
        string sql,
        CancellationToken cancellationToken)
    {
        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
