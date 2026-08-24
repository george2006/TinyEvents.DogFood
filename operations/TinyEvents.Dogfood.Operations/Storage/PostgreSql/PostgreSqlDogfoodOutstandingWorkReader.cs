using Npgsql;
using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal static class PostgreSqlDogfoodOutstandingWorkReader
{
    public static async ValueTask<bool> HasOutstandingMessagesAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT EXISTS
            (
                SELECT 1
                FROM "TinyOutbox"
                WHERE "Status" = @PendingStatus OR "Status" = @ProcessingStatus
            );
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
            FROM "TinyOutbox"
            WHERE "Status" = @PendingStatus OR "Status" = @ProcessingStatus;
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
        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        command.Parameters.AddWithValue(
            "PendingStatus",
            (int)TinyOutboxMessageStatus.Pending);
        command.Parameters.AddWithValue(
            "ProcessingStatus",
            (int)TinyOutboxMessageStatus.Processing);
        return await command.ExecuteScalarAsync(cancellationToken);
    }
}
