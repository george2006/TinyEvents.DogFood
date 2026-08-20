using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodDatabaseReset
{
    public static async ValueTask ExecuteAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken = default)
    {
        await RecreateDatabaseAsync(settings, cancellationToken);
        await CreateDogfoodTablesAsync(settings, cancellationToken);
    }

    private static async ValueTask RecreateDatabaseAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        var quotedDatabaseName = new SqlCommandBuilder().QuoteIdentifier(settings.DatabaseName);
        var sql = $"""
            IF DB_ID(@DatabaseName) IS NOT NULL
            BEGIN
                ALTER DATABASE {quotedDatabaseName} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                DROP DATABASE {quotedDatabaseName};
            END;

            CREATE DATABASE {quotedDatabaseName};
            """;

        await using var connection = new SqlConnection(settings.MasterConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@DatabaseName", settings.DatabaseName);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async ValueTask CreateDogfoodTablesAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        const string sql = """
            CREATE TABLE dbo.DogfoodBusinessOperations
            (
                Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
                ScenarioId NVARCHAR(32) NOT NULL,
                CreatedAtUtc DATETIMEOFFSET NOT NULL
            );

            CREATE TABLE dbo.DogfoodEffects
            (
                Id BIGINT IDENTITY(1, 1) NOT NULL PRIMARY KEY,
                OperationId UNIQUEIDENTIFIER NOT NULL,
                ScenarioId NVARCHAR(32) NOT NULL,
                WorkerId NVARCHAR(256) NOT NULL,
                RecordedAtUtc DATETIMEOFFSET NOT NULL
            );

            CREATE INDEX IX_DogfoodEffects_OperationId
                ON dbo.DogfoodEffects (OperationId);
            """;

        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
