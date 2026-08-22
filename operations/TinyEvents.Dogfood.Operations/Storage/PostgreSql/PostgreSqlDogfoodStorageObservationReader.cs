using Npgsql;

namespace TinyEvents.Dogfood.Operations;

internal static class PostgreSqlDogfoodStorageObservationReader
{
    public static async ValueTask<StorageObservation> ReadAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                COUNT(*)::bigint,
                COALESCE(SUM(octet_length("Payload")), 0)::bigint
            FROM "TinyOutbox";

            SELECT
                pg_table_size('"TinyOutbox"')::bigint,
                pg_indexes_size('"TinyOutbox"')::bigint,
                pg_total_relation_size('"TinyOutbox"')::bigint;
            """;

        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        await reader.ReadAsync(cancellationToken);
        var rowCount = reader.GetInt64(0);
        var payloadBytes = reader.GetInt64(1);

        await reader.NextResultAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        return new StorageObservation(
            rowCount,
            payloadBytes,
            reader.GetInt64(0),
            reader.GetInt64(1),
            reader.GetInt64(2));
    }
}
