using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.DependencyInjection;
using TinyEvents;
using TinyEvents.Dogfood.Identity.Contracts;
using TinyEvents.Dogfood.Identity.Moved;
using TinyEvents.Dogfood.Identity.Nested;
using TinyEvents.Dogfood.Identity.Rename.V1;
using TinyEvents.SqlServer.AdoNet;

return await IdentityProducer.RunAsync(args);

internal static class IdentityProducer
{
    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Expected reset, publish <event-kind> <scenario-id>, or inspect.");
            return 2;
        }

        var settings = DogfoodSettings.Load();

        switch (args[0].ToLowerInvariant())
        {
            case "reset":
                await ResetAsync(settings);
                return 0;
            case "publish" when args.Length == 3:
                await PublishAsync(settings, args[1], args[2]);
                return 0;
            case "inspect":
                await InspectAsync(settings);
                return 0;
            default:
                Console.Error.WriteLine("Expected reset, publish <event-kind> <scenario-id>, or inspect.");
                return 2;
        }
    }

    private static async Task ResetAsync(DogfoodSettings settings)
    {
        await DogfoodDatabase.ResetAsync(settings);

        await using var services = CreateServices(settings);
        await services.MigrateTinyEventsAsync();
        await DogfoodDatabase.CreateEvidenceTableAsync(settings);
    }

    private static async Task PublishAsync(
        DogfoodSettings settings,
        string eventKind,
        string scenarioId)
    {
        await using var services = CreateServices(settings);
        await using var scope = services.CreateAsyncScope();
        var publisher = scope.ServiceProvider.GetRequiredService<ITinyEventPublisher>();

        await PublishEventAsync(publisher, eventKind, scenarioId);

        var transaction = scope.ServiceProvider.GetRequiredService<DogfoodTransaction>();
        await transaction.CommitAsync();
    }

    private static ValueTask PublishEventAsync(
        ITinyEventPublisher publisher,
        string eventKind,
        string scenarioId)
    {
        return eventKind switch
        {
            "normal" => publisher.PublishAsync(new NormalEvent(scenarioId)),
            "nested" => publisher.PublishAsync(new EventContainer.NestedEvent(scenarioId)),
            "renamed" => publisher.PublishAsync(new RenamedEvent(scenarioId)),
            "moved" => publisher.PublishAsync(new MovedEvent(scenarioId)),
            _ => throw new ArgumentException($"Unknown event kind '{eventKind}'.", nameof(eventKind))
        };
    }

    private static async Task InspectAsync(DogfoodSettings settings)
    {
        await using var connection = new SqlConnection(settings.ConnectionString);
        await connection.OpenAsync();

        var observation = await ReadObservationAsync(connection);
        Console.WriteLine(JsonSerializer.Serialize(observation));
    }

    private static async Task<ScenarioObservation> ReadObservationAsync(SqlConnection connection)
    {
        const string sql = """
            SELECT TOP (1)
                o.EventType,
                o.Status,
                o.AttemptCount,
                o.LastError,
                (SELECT COUNT(*) FROM dbo.DogfoodEffects) AS EffectCount,
                (SELECT TOP (1) ConsumerName FROM dbo.DogfoodEffects ORDER BY Id) AS ConsumerName
            FROM dbo.TinyOutbox AS o
            ORDER BY o.CreatedAtUtc;
            """;

        await using var command = new SqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync();

        if (!await reader.ReadAsync())
        {
            return ScenarioObservation.Empty;
        }

        var status = (TinyOutboxMessageStatus)reader.GetInt32(1);

        return new ScenarioObservation(
            reader.GetString(0),
            status.ToString(),
            reader.GetInt32(2),
            reader.IsDBNull(3) ? null : reader.GetString(3),
            reader.GetInt32(4),
            reader.IsDBNull(5) ? null : reader.GetString(5));
    }

    private static ServiceProvider CreateServices(DogfoodSettings settings)
    {
        var services = new ServiceCollection();
        services.AddSingleton(settings);
        services.AddScoped(_ => new DogfoodTransaction(settings.ConnectionString));
        services.UseSqlServerAdoNetOutbox(options =>
        {
            options.UseCurrentTransaction(provider =>
            {
                var transaction = provider.GetRequiredService<DogfoodTransaction>();
                return new TinyAdoNetTransactionContext(transaction.Connection, transaction.Transaction);
            });
            options.UseWorkerConnectionFactory(async (_, cancellationToken) =>
            {
                var connection = new SqlConnection(settings.ConnectionString);
                await connection.OpenAsync(cancellationToken);
                return connection;
            });
        });

        return services.BuildServiceProvider();
    }
}
