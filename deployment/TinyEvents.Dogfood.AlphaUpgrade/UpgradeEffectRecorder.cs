using Microsoft.Data.SqlClient;

public sealed class UpgradeEffectRecorder(string connectionString)
{
    public async ValueTask RecordAsync(
        string messageState,
        CancellationToken cancellationToken)
    {
        const string sql = """
            INSERT INTO dbo.UpgradeProbeEffects
            (
                MessageState,
                RecordedAtUtc
            )
            VALUES
            (
                @MessageState,
                SYSUTCDATETIME()
            );
            """;

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@MessageState", messageState);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
