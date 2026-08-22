using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal sealed class SqlServerMigrationInterruption : IMigrationInterruption
{
    private const string TriggerName =
        "TinyEventsDogfoodBlockMigrationDdl";

    public async ValueTask InstallAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        var sql = $"""
            CREATE OR ALTER TRIGGER {TriggerName}
            ON DATABASE
            FOR CREATE_TABLE
            AS
            BEGIN
                SET NOCOUNT ON;

                DECLARE @ObjectName nvarchar(128) =
                    EVENTDATA().value('(/EVENT_INSTANCE/ObjectName)[1]', 'nvarchar(128)');

                IF @ObjectName IN (N'TinyOutbox', N'TinyOutboxMigrations')
                BEGIN
                    WAITFOR DELAY '00:00:10';
                END;
            END;
            """;

        await ExecuteAsync(settings.ConnectionString, sql, cancellationToken);
    }

    public async ValueTask<MigrationInterruptionObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                CASE WHEN EXISTS
                (
                    SELECT 1
                    FROM sys.triggers
                    WHERE parent_class = 0
                      AND name = @TriggerName
                ) THEN 1 ELSE 0 END,
                (
                    SELECT COUNT(*)
                    FROM sys.dm_exec_requests AS request
                    WHERE request.database_id = DB_ID()
                      AND request.wait_type = N'WAITFOR'
                ),
                (
                    SELECT COUNT(*)
                    FROM sys.dm_exec_requests AS request
                    WHERE request.database_id = DB_ID()
                      AND request.wait_type = N'WAITFOR'
                      AND EXISTS
                      (
                          SELECT 1
                          FROM sys.dm_tran_locks AS migrationLock
                          WHERE migrationLock.request_session_id = request.session_id
                            AND migrationLock.resource_type = N'APPLICATION'
                            AND migrationLock.request_status = N'GRANT'
                      )
                ),
                (
                    SELECT COUNT(DISTINCT migrationLock.request_session_id)
                    FROM sys.dm_tran_locks AS migrationLock
                    WHERE migrationLock.resource_database_id = DB_ID()
                      AND migrationLock.resource_type = N'APPLICATION'
                      AND migrationLock.request_status = N'GRANT'
                );
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@TriggerName", TriggerName);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);

        return new MigrationInterruptionObservation(
            reader.GetInt32(0) == 1,
            reader.GetInt32(1),
            reader.GetInt32(2),
            reader.GetInt32(3));
    }

    public ValueTask RemoveAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        var sql = $"""
            DROP TRIGGER IF EXISTS {TriggerName} ON DATABASE;
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
        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
