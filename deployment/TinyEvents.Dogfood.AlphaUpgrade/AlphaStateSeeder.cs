using Microsoft.Data.SqlClient;
using Microsoft.Extensions.DependencyInjection;
using TinyEvents;
using TinyEvents.Dogfood.AlphaUpgrade.Contracts;
using TinyEvents.SqlServer.AdoNet;

internal static class AlphaStateSeeder
{
    private const string SeederWorkerId = "alpha-state-seeder";

    public static async Task CreateAsync(UpgradeSettings settings)
    {
        await UpgradeDatabaseReset.ExecuteAsync(settings);

        await using var services = CreateServices(settings);
        await services.MigrateTinyEventsAsync();
        await UpgradeEvidenceSchema.CreateAsync(settings);

        await PublishAsync(services, "failed");
        await MarkOnlyPendingMessageFailedAsync(services);

        await PublishAsync(services, "processing");
        await LeaveOnlyPendingMessageProcessingAsync(services);

        await PublishAsync(services, "pending");
    }

    private static async Task PublishAsync(
        ServiceProvider services,
        string state)
    {
        await using var scope = services.CreateAsyncScope();
        var publisher = scope.ServiceProvider.GetRequiredService<ITinyEventPublisher>();
        await publisher.PublishAsync(new UpgradeProbeEvent(state));

        var transaction = scope.ServiceProvider.GetRequiredService<UpgradeTransaction>();
        await transaction.CommitAsync();
    }

    private static async Task MarkOnlyPendingMessageFailedAsync(
        ServiceProvider services)
    {
        await using var scope = services.CreateAsyncScope();
        var store = scope.ServiceProvider.GetRequiredService<ITinyOutboxStore>();
        var message = await ClaimOnlyPendingMessageAsync(store);

        await store.MarkFailedAsync(
            message.Id,
            SeederWorkerId,
            "Seeded terminal failure from published alpha.",
            attemptCount: 1,
            nextAttemptAtUtc: null,
            CancellationToken.None);
    }

    private static async Task LeaveOnlyPendingMessageProcessingAsync(
        ServiceProvider services)
    {
        await using var scope = services.CreateAsyncScope();
        var store = scope.ServiceProvider.GetRequiredService<ITinyOutboxStore>();
        await ClaimOnlyPendingMessageAsync(store);
    }

    private static async Task<TinyOutboxMessage> ClaimOnlyPendingMessageAsync(
        ITinyOutboxStore store)
    {
        var messages = await store.ClaimPendingAsync(
            maxCount: 1,
            SeederWorkerId,
            DateTimeOffset.UtcNow,
            claimTimeout: TimeSpan.Zero,
            CancellationToken.None);

        return messages.Single();
    }

    private static ServiceProvider CreateServices(UpgradeSettings settings)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddScoped(_ => new UpgradeTransaction(settings.ConnectionString));
        services.UseSqlServerAdoNetOutbox(options =>
        {
            options.UseCurrentTransaction(provider =>
            {
                var transaction = provider.GetRequiredService<UpgradeTransaction>();
                return new TinyAdoNetTransactionContext(
                    transaction.Connection,
                    transaction.Transaction);
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
