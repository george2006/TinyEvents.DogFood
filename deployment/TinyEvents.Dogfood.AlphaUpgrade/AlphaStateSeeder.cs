using Microsoft.Extensions.DependencyInjection;
using TinyEvents;
using TinyEvents.Dogfood.AlphaUpgrade.Contracts;

internal static class AlphaStateSeeder
{
    private const string SeederWorkerId = "alpha-state-seeder";

    public static async Task CreateAsync(
        IUpgradeStorageProvider storage,
        UpgradeSettings settings)
    {
        await storage.ResetAsync(settings, CancellationToken.None);

        await using var services = CreateServices(storage, settings);
        await services.MigrateTinyEventsAsync();
        await storage.CreateEvidenceSchemaAsync(
            settings,
            CancellationToken.None);

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

        var transaction = scope.ServiceProvider.GetRequiredService<IUpgradeTransaction>();
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

    private static ServiceProvider CreateServices(
        IUpgradeStorageProvider storage,
        UpgradeSettings settings)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        storage.AddPublisherServices(services, settings);

        return services.BuildServiceProvider();
    }
}
