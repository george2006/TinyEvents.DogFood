using Microsoft.Data.SqlClient;
using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal static class SqlServerDogfoodOutstandingWorkReader
{
    public static async ValueTask<bool> HasOutstandingMessagesAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT CASE WHEN EXISTS
            (
                SELECT 1
                FROM dbo.TinyOutbox
                WHERE Status = @PendingStatus OR Status = @ProcessingStatus
            )
            THEN CAST(1 AS bit)
            ELSE CAST(0 AS bit)
            END;
            """;

        var result = await ExecuteAsync(
            settings,
            sql,
            cancellationToken);
        return Convert.ToBoolean(result);
    }

    public static async ValueTask<int> CountOutstandingMessagesAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT COUNT(*)
            FROM dbo.TinyOutbox
            WHERE Status = @PendingStatus OR Status = @ProcessingStatus;
            """;

        var result = await ExecuteAsync(
            settings,
            sql,
            cancellationToken);
        return Convert.ToInt32(result);
    }

    private static async ValueTask<object?> ExecuteAsync(
        DogfoodSettings settings,
        string sql,
        CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue(
            "@PendingStatus",
            (int)TinyOutboxMessageStatus.Pending);
        command.Parameters.AddWithValue(
            "@ProcessingStatus",
            (int)TinyOutboxMessageStatus.Processing);
        return await command.ExecuteScalarAsync(cancellationToken);
    }
}
