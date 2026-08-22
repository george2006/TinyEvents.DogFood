using Microsoft.Extensions.DependencyInjection;
using TinyEvents;
using TinyEvents.Dogfood.AlphaUpgrade.Contracts;

internal static class RollingStateSeeder
{
    public static async Task CreateAsync(
        IUpgradeStorageProvider storage,
        UpgradeSettings settings,
        int messageCount)
    {
        await storage.ResetAsync(settings, CancellationToken.None);

        await using var services = CreateServices(storage, settings);
        await services.MigrateTinyEventsAsync();
        await storage.CreateEvidenceSchemaAsync(
            settings,
            CancellationToken.None);

        for (var index = 0; index < messageCount; index++)
        {
            await PublishAsync(services);
        }
    }

    private static async Task PublishAsync(ServiceProvider services)
    {
        await using var scope = services.CreateAsyncScope();
        var publisher = scope.ServiceProvider.GetRequiredService<ITinyEventPublisher>();
        await publisher.PublishAsync(new UpgradeProbeEvent(
            Guid.NewGuid(),
            "rolling"));

        var transaction = scope.ServiceProvider.GetRequiredService<IUpgradeTransaction>();
        await transaction.CommitAsync();
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
