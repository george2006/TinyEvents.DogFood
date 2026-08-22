using Microsoft.Extensions.DependencyInjection;
using TinyEvents;

internal static class CandidateStateDrainer
{
    private const string WorkerId = "upgrade-candidate";

    public static async Task ExecuteAsync(
        IUpgradeStorageProvider storage,
        UpgradeSettings settings)
    {
        await using var services = CreateServices(storage, settings);
        await services.MigrateTinyEventsAsync();

        await using var scope = services.CreateAsyncScope();
        var processor = scope.ServiceProvider.GetRequiredService<ITinyOutboxProcessor>();
        await processor.ProcessPendingAsync();
    }

    private static ServiceProvider CreateServices(
        IUpgradeStorageProvider storage,
        UpgradeSettings settings)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddSingleton(new UpgradeWorkerIdentity(
            WorkerId,
            TimeSpan.Zero));
        storage.AddProcessorServices(services, settings);
        services.UseTinyEvents(options =>
        {
            options.BatchSize = 10;
            options.MaxAttempts = 1;
            options.ClaimTimeout = TimeSpan.FromSeconds(10);
            options.RetryDelay = TimeSpan.Zero;
            options.WorkerId = WorkerId;
        });

        return services.BuildServiceProvider();
    }
}
