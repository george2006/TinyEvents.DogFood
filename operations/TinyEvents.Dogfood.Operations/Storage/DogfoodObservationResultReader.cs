using System.Data.Common;

namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodObservationResultReader
{
    public static async ValueTask<ScenarioObservation> ReadAsync(
        DbDataReader reader,
        CancellationToken cancellationToken)
    {
        await reader.ReadAsync(cancellationToken);
        var databaseUtcNow = ReadDateTimeOffset(reader, 0);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        var businessOperations = ReadInt32(reader, 0);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        var outboxMessages = ReadInt32(reader, 0);
        var pendingMessages = ReadInt32(reader, 1);
        var processingMessages = ReadInt32(reader, 2);
        var processedMessages = ReadInt32(reader, 3);
        var failedMessages = ReadInt32(reader, 4);
        var failedAttempts = ReadInt32(reader, 5);
        var earliestClaimExpiresAtUtc = ReadNullableDateTimeOffset(reader, 6);
        var earliestNextAttemptAtUtc = ReadNullableDateTimeOffset(reader, 7);
        var terminalError = reader.IsDBNull(8)
            ? null
            : reader.GetString(8);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        var effects = ReadInt32(reader, 0);
        var duplicateEffects = ReadInt32(reader, 1);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        var consumerAttempts = ReadInt32(reader, 0);
        var latestConsumerAttemptAtUtc = ReadNullableDateTimeOffset(reader, 1);

        await reader.NextResultAsync(cancellationToken);
        var workerClaims = await ReadCountsAsync(reader, cancellationToken);

        await reader.NextResultAsync(cancellationToken);
        var workerEffects = await ReadCountsAsync(reader, cancellationToken);

        await reader.NextResultAsync(cancellationToken);
        var workerAttempts = await ReadCountsAsync(reader, cancellationToken);

        await reader.NextResultAsync(cancellationToken);
        var processEffects = await ReadCountsAsync(reader, cancellationToken);

        await reader.NextResultAsync(cancellationToken);
        var scenarioEffects = await ReadCountsAsync(reader, cancellationToken);

        await reader.NextResultAsync(cancellationToken);
        var scenarioAttempts = await ReadCountsAsync(reader, cancellationToken);

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

    private static async ValueTask<IReadOnlyDictionary<string, int>> ReadCountsAsync(
        DbDataReader reader,
        CancellationToken cancellationToken)
    {
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);

        while (await reader.ReadAsync(cancellationToken))
        {
            counts.Add(reader.GetString(0), ReadInt32(reader, 1));
        }

        return counts;
    }

    private static int ReadInt32(DbDataReader reader, int ordinal)
    {
        return Convert.ToInt32(reader.GetValue(ordinal));
    }

    private static DateTimeOffset? ReadNullableDateTimeOffset(
        DbDataReader reader,
        int ordinal)
    {
        return reader.IsDBNull(ordinal)
            ? null
            : ReadDateTimeOffset(reader, ordinal);
    }

    private static DateTimeOffset ReadDateTimeOffset(
        DbDataReader reader,
        int ordinal)
    {
        return reader.GetValue(ordinal) switch
        {
            DateTimeOffset value => value,
            DateTime value => new DateTimeOffset(value.ToUniversalTime()),
            var value => throw new InvalidOperationException(
                $"Expected a database timestamp but received '{value.GetType().FullName}'.")
        };
    }
}
