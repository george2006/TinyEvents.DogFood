using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using TinyEvents;
using TinyEvents.SqlServer.EntityFrameworkCore;
using TinyEvents.Worker;

namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodHost
{
    public static IHost Build(
        DogfoodSettings settings,
        string workerId)
    {
        var builder = Host.CreateApplicationBuilder();

        builder.Services.AddSingleton(settings);
        builder.Services.AddSingleton(new WorkerIdentity(workerId));
        builder.Services.AddSingleton<DogfoodEffectRecorder>();
        builder.Services.AddScoped<DogfoodPublisher>();
        builder.Services.AddDbContext<DogfoodDbContext>(options =>
        {
            options.UseSqlServer(settings.ConnectionString);
        });
        builder.Services.UseSqlServerEntityFrameworkCoreOutbox<DogfoodDbContext>();
        builder.Services.UseTinyEvents(options =>
        {
            options.MaxAttempts = 3;
            options.RetryDelay = TimeSpan.FromMilliseconds(250);
        });
        builder.Services.AddTinyEventsWorker(options =>
        {
            options.WorkerId = workerId;
            options.BatchSize = 50;
            options.ClaimTimeout = TimeSpan.FromSeconds(5);
            options.PollingInterval = TimeSpan.FromMilliseconds(50);
        });

        return builder.Build();
    }
}

internal sealed record WorkerIdentity(string Value);
