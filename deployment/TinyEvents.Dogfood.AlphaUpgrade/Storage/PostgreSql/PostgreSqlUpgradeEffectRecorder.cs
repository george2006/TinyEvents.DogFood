using Npgsql;

internal sealed class PostgreSqlUpgradeEffectRecorder(string connectionString)
    : UpgradeEffectRecorder
{
    public override async ValueTask RecordAsync(
        string messageState,
        CancellationToken cancellationToken)
    {
        const string sql = """
            INSERT INTO "UpgradeProbeEffects"
            (
                "MessageState",
                "RecordedAtUtc"
            )
            VALUES
            (
                @MessageState,
                @RecordedAtUtc
            );
            """;

        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        command.Parameters.AddWithValue("MessageState", messageState);
        command.Parameters.AddWithValue("RecordedAtUtc", DateTimeOffset.UtcNow);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
