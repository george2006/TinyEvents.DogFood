using Microsoft.Data.SqlClient;

internal sealed class SqlServerUpgradeEffectRecorder(string connectionString)
    : UpgradeEffectRecorder
{
    public override async ValueTask RecordAsync(
        Guid operationId,
        string messageState,
        string workerId,
        CancellationToken cancellationToken)
    {
        const string sql = """
            INSERT INTO dbo.UpgradeProbeEffects
            (
                OperationId,
                MessageState,
                WorkerId,
                RecordedAtUtc
            )
            VALUES
            (
                @OperationId,
                @MessageState,
                @WorkerId,
                SYSUTCDATETIME()
            );
            """;

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@OperationId", operationId);
        command.Parameters.AddWithValue("@MessageState", messageState);
        command.Parameters.AddWithValue("@WorkerId", workerId);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
