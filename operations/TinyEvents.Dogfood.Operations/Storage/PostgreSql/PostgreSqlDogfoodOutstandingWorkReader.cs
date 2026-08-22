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

        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        command.Parameters.AddWithValue(
            "PendingStatus",
            (int)TinyOutboxMessageStatus.Pending);
        command.Parameters.AddWithValue(
            "ProcessingStatus",
            (int)TinyOutboxMessageStatus.Processing);
        var result = await command.ExecuteScalarAsync(cancellationToken);
        return Convert.ToBoolean(result);
    }
}
