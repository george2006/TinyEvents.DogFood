using Microsoft.Data.SqlClient;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using TinyEvents;
using TinyEvents.Dogfood.Identity.Rename.V2;
using TinyEvents.SqlServer.AdoNet;
using TinyEvents.Worker;

var connectionString = TinyEvents.Dogfood.Identity.Worker.DogfoodSettings.GetConnectionString();
var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddSingleton(new TinyEvents.Dogfood.Identity.Worker.DogfoodEffectRecorder(connectionString));
builder.Services.UseSqlServerAdoNetOutbox(options =>
{
    options.UseWorkerConnectionFactory(async (_, cancellationToken) =>
    {
        var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        return connection;
    });
});
builder.Services.UseTinyEvents(options =>
{
    options.MaxAttempts = 1;
    options.RetryDelay = TimeSpan.Zero;
    options.AcceptPreviousEventName<RenamedEvent>(
        "TinyEvents.Dogfood.Identity.Rename.V1.RenamedEvent");
});
builder.Services.AddTinyEventsWorker(options =>
{
    options.BatchSize = 10;
    options.ClaimTimeout = TimeSpan.FromSeconds(10);
    options.PollingInterval = TimeSpan.FromMilliseconds(50);
});

using var host = builder.Build();
await host.RunAsync();
