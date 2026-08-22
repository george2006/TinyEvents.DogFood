using Npgsql;

internal sealed class PostgreSqlUpgradeEffectRecorder(string connectionString)
    : UpgradeEffectRecorder
{
    public override async ValueTask RecordAsync(
        Guid operationId,
        string messageState,
        string workerId,
        CancellationToken cancellationToken)
    {
        const string sql = """
            INSERT INTO "UpgradeProbeEffects"
            (
                "OperationId",
                "MessageState",
                "WorkerId",
                "RecordedAtUtc"
            )
            VALUES
            (
                @OperationId,
                @MessageState,
                @WorkerId,
                @RecordedAtUtc
            );
            """;

        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection);
        command.Parameters.AddWithValue("OperationId", operationId);
        command.Parameters.AddWithValue("MessageState", messageState);
        command.Parameters.AddWithValue("WorkerId", workerId);
        command.Parameters.AddWithValue("RecordedAtUtc", DateTimeOffset.UtcNow);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
