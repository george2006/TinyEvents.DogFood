using Microsoft.Data.SqlClient;
using Microsoft.Extensions.DependencyInjection;
using TinyEvents;
using TinyEvents.SqlServer.AdoNet;

internal static class CandidateStateDrainer
{
    public static async Task ExecuteAsync(UpgradeSettings settings)
    {
        await using var services = CreateServices(settings);
        await services.MigrateTinyEventsAsync();

        await using var scope = services.CreateAsyncScope();
        var processor = scope.ServiceProvider.GetRequiredService<ITinyOutboxProcessor>();
        await processor.ProcessPendingAsync();
    }

    private static ServiceProvider CreateServices(UpgradeSettings settings)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddSingleton(new UpgradeEffectRecorder(settings.ConnectionString));
        services.UseSqlServerAdoNetOutbox(options =>
        {
            options.UseWorkerConnectionFactory(async (_, cancellationToken) =>
            {
                var connection = new SqlConnection(settings.ConnectionString);
                await connection.OpenAsync(cancellationToken);
                return connection;
            });
        });
        services.UseTinyEvents(options =>
        {
            options.BatchSize = 10;
            options.MaxAttempts = 1;
            options.ClaimTimeout = TimeSpan.FromSeconds(10);
            options.RetryDelay = TimeSpan.Zero;
            options.WorkerId = "upgrade-candidate";
        });

        return services.BuildServiceProvider();
    }
}
