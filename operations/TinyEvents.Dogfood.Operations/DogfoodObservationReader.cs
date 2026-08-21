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
            SELECT SYSDATETIMEOFFSET();

            SELECT COUNT(*)
            FROM dbo.DogfoodBusinessOperations;

            SELECT
                COUNT(*),
                COALESCE(SUM(CASE WHEN Status = @PendingStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN Status = @ProcessingStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN Status = @ProcessedStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN Status = @FailedStatus THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(AttemptCount), 0),
                MIN(ClaimExpiresAtUtc),
                MIN(NextAttemptAtUtc),
                MAX(CASE WHEN Status = @FailedStatus THEN LastError END)
            FROM dbo.TinyOutbox;

            SELECT
                COUNT(*),
                COUNT(*) - COUNT(DISTINCT OperationId)
            FROM dbo.DogfoodEffects;

            SELECT
                COUNT(*),
                MAX(RecordedAtUtc)
            FROM dbo.DogfoodConsumerAttempts;

            SELECT ClaimedBy, COUNT(*)
            FROM dbo.TinyOutbox
            WHERE ClaimedBy IS NOT NULL
            GROUP BY ClaimedBy
            ORDER BY ClaimedBy;

            SELECT WorkerId, COUNT(*)
            FROM dbo.DogfoodEffects
            GROUP BY WorkerId
            ORDER BY WorkerId;

            SELECT WorkerId, COUNT(*)
            FROM dbo.DogfoodConsumerAttempts
            GROUP BY WorkerId
            ORDER BY WorkerId;

            SELECT CONVERT(NVARCHAR(16), ProcessId), COUNT(*)
            FROM dbo.DogfoodEffects
            GROUP BY ProcessId
            ORDER BY ProcessId;

            SELECT ScenarioId, COUNT(*)
            FROM dbo.DogfoodEffects
            GROUP BY ScenarioId
            ORDER BY ScenarioId;

            SELECT ScenarioId, COUNT(*)
            FROM dbo.DogfoodConsumerAttempts
            GROUP BY ScenarioId
            ORDER BY ScenarioId;
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
        var databaseUtcNow = reader.GetFieldValue<DateTimeOffset>(0);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        var businessOperations = reader.GetInt32(0);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        var outboxMessages = reader.GetInt32(0);
        var pendingMessages = reader.GetInt32(1);
        var processingMessages = reader.GetInt32(2);
        var processedMessages = reader.GetInt32(3);
        var failedMessages = reader.GetInt32(4);
        var failedAttempts = reader.GetInt32(5);
        DateTimeOffset? earliestClaimExpiresAtUtc = reader.IsDBNull(6)
            ? null
            : reader.GetFieldValue<DateTimeOffset>(6);
        DateTimeOffset? earliestNextAttemptAtUtc = reader.IsDBNull(7)
            ? null
            : reader.GetFieldValue<DateTimeOffset>(7);
        var terminalError = reader.IsDBNull(8)
            ? null
            : reader.GetString(8);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        var effects = reader.GetInt32(0);
        var duplicateEffects = reader.GetInt32(1);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        var consumerAttempts = reader.GetInt32(0);
        DateTimeOffset? latestConsumerAttemptAtUtc = reader.IsDBNull(1)
            ? null
            : reader.GetFieldValue<DateTimeOffset>(1);

        await reader.NextResultAsync(cancellationToken);
        var workerClaims = await ReadWorkerCountsAsync(reader, cancellationToken);

        await reader.NextResultAsync(cancellationToken);
        var workerEffects = await ReadWorkerCountsAsync(reader, cancellationToken);

        await reader.NextResultAsync(cancellationToken);
        var workerAttempts = await ReadWorkerCountsAsync(reader, cancellationToken);

        await reader.NextResultAsync(cancellationToken);
        var processEffects = await ReadWorkerCountsAsync(reader, cancellationToken);

        await reader.NextResultAsync(cancellationToken);
        var scenarioEffects = await ReadWorkerCountsAsync(reader, cancellationToken);

        await reader.NextResultAsync(cancellationToken);
        var scenarioAttempts = await ReadWorkerCountsAsync(reader, cancellationToken);

        return new ScenarioObservation(
            databaseUtcNow,
            earliestClaimExpiresAtUtc,
            earliestNextAttemptAtUtc,
            terminalError,
            businessOperations,
            outboxMessages,
            pendingMessages,
            processingMessages,
            processedMessages,
            failedMessages,
            failedAttempts,
            effects,
            duplicateEffects,
            consumerAttempts,
            latestConsumerAttemptAtUtc,
            workerClaims,
            workerEffects,
            workerAttempts,
            processEffects,
            scenarioEffects,
            scenarioAttempts);
    }

    private static async ValueTask<IReadOnlyDictionary<string, int>> ReadWorkerCountsAsync(
        SqlDataReader reader,
        CancellationToken cancellationToken)
    {
        var workerCounts = new Dictionary<string, int>(StringComparer.Ordinal);

        while (await reader.ReadAsync(cancellationToken))
        {
            workerCounts.Add(reader.GetString(0), reader.GetInt32(1));
        }

        return workerCounts;
    }
}
