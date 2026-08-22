using Microsoft.Data.SqlClient;

internal static class DogfoodOutboxFaultInjector
{
    private const string MalformedPayload = "not-json";

    public static async Task CorruptOnlyPayloadAsync(DogfoodSettings settings)
    {
        const string sql = """
            IF (SELECT COUNT_BIG(*) FROM dbo.TinyOutbox) <> 1
            BEGIN
                THROW 51000, 'Payload corruption requires exactly one outbox message.', 1;
            END;

            UPDATE dbo.TinyOutbox
            SET Payload = @MalformedPayload;
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync();
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@MalformedPayload", MalformedPayload);
        await command.ExecuteNonQueryAsync();
    }
}
