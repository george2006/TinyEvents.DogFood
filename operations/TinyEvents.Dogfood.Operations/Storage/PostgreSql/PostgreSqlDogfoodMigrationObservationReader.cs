using Npgsql;

namespace TinyEvents.Dogfood.Operations;

internal static class PostgreSqlDogfoodMigrationObservationReader
{
    public static async ValueTask<MigrationObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        var (outboxTableExists, historyTableExists) =
            await ReadTablePresenceAsync(connection, cancellationToken);
        var history = historyTableExists
            ? await ReadHistoryAsync(connection, cancellationToken)
            : [];

        return new MigrationObservation(
            outboxTableExists,
            historyTableExists,
            history);
    }

    private static async ValueTask<(bool Outbox, bool History)> ReadTablePresenceAsync(
        NpgsqlConnection connection,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                to_regclass('public."TinyOutbox"') IS NOT NULL,
                to_regclass('public."TinyOutboxMigrations"') IS NOT NULL;
            """;

        await using var command = new NpgsqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        return (reader.GetBoolean(0), reader.GetBoolean(1));
    }

    private static async ValueTask<IReadOnlyList<MigrationHistoryEntry>> ReadHistoryAsync(
        NpgsqlConnection connection,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT "Version", "Name", "Checksum", "AppliedAtUtc"
            FROM "TinyOutboxMigrations"
            ORDER BY "Version";
            """;

        await using var command = new NpgsqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var history = new List<MigrationHistoryEntry>();

        while (await reader.ReadAsync(cancellationToken))
        {
            history.Add(new MigrationHistoryEntry(
                reader.GetInt64(0),
                reader.GetString(1),
                reader.GetString(2),
                new DateTimeOffset(reader.GetDateTime(3).ToUniversalTime())));
        }

        return history;
    }
}
