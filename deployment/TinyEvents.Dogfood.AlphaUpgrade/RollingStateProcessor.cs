using Microsoft.Extensions.DependencyInjection;
using TinyEvents;

internal static class RollingStateProcessor
{
    public static async Task ExecuteAsync(
        IUpgradeStorageProvider storage,
        UpgradeSettings settings,
        string workerId,
        int iterationCount,
        TimeSpan effectDelay)
    {
        await using var services = CreateServices(
            storage,
            settings,
            workerId,
            effectDelay);
        await services.MigrateTinyEventsAsync();

        await using var scope = services.CreateAsyncScope();
        var processor = scope.ServiceProvider.GetRequiredService<ITinyOutboxProcessor>();

        for (var iteration = 0; iteration < iterationCount; iteration++)
        {
            await processor.ProcessPendingAsync();
        }
    }

    private static ServiceProvider CreateServices(
        IUpgradeStorageProvider storage,
        UpgradeSettings settings,
        string workerId,
        TimeSpan effectDelay)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddSingleton(new UpgradeWorkerIdentity(workerId, effectDelay));
        storage.AddProcessorServices(services, settings);
        services.UseTinyEvents(options =>
        {
            options.BatchSize = 1;
            options.MaxAttempts = 1;
            options.ClaimTimeout = TimeSpan.FromSeconds(10);
            options.RetryDelay = TimeSpan.Zero;
            options.WorkerId = workerId;
        });

        return services.BuildServiceProvider();
    }
}
