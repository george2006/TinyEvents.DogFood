using Microsoft.Data.SqlClient;
using TinyEvents;

namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodObservationReader
{
    public static async ValueTask<ScenarioObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken = default)
    {
        const string sql = """
            SELECT COUNT(*)
            FROM dbo.DogfoodBusinessOperations;

            SELECT
                COUNT(*),
                COALESCE(SUM(CASE WHEN Status = @PendingStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN Status = @ProcessingStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN Status = @ProcessedStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN Status = @FailedStatus THEN 1 ELSE 0 END), 0)
            FROM dbo.TinyOutbox;

            SELECT
                COUNT(*),
                COUNT(*) - COUNT(DISTINCT OperationId)
            FROM dbo.DogfoodEffects;
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue(
            "@PendingStatus",
            (int)TinyOutboxMessageStatus.Pending);
        command.Parameters.AddWithValue(
            "@ProcessingStatus",
            (int)TinyOutboxMessageStatus.Processing);
        command.Parameters.AddWithValue(
            "@ProcessedStatus",
            (int)TinyOutboxMessageStatus.Processed);
        command.Parameters.AddWithValue(
            "@FailedStatus",
            (int)TinyOutboxMessageStatus.Failed);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        await reader.ReadAsync(cancellationToken);
        var businessOperations = reader.GetInt32(0);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        var outboxMessages = reader.GetInt32(0);
        var pendingMessages = reader.GetInt32(1);
        var processingMessages = reader.GetInt32(2);
        var processedMessages = reader.GetInt32(3);
        var failedMessages = reader.GetInt32(4);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        var effects = reader.GetInt32(0);
        var duplicateEffects = reader.GetInt32(1);

        return new ScenarioObservation(
            businessOperations,
            outboxMessages,
            pendingMessages,
            processingMessages,
            processedMessages,
            failedMessages,
            effects,
            duplicateEffects);
    }
}
