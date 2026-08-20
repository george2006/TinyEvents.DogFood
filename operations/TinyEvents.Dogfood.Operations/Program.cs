using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using TinyEvents;
using TinyEvents.Dogfood.Operations;
using TinyEvents.SqlServer.EntityFrameworkCore;

if (args.Length == 0)
{
    Console.Error.WriteLine("Expected reset, publish <scenario> <count>, inspect, or worker <worker-id> [before-effect-delay-ms] [after-effect-delay-ms].");
    return 1;
}

var settings = DogfoodSettings.Load();

switch (args[0].ToLowerInvariant())
{
    case "reset":
        await DogfoodDatabaseReset.ExecuteAsync(settings);
        using (var host = DogfoodHost.Build(settings, "migration"))
        {
            await host.Services.MigrateTinyEventsAsync();
        }

        return 0;

    case "publish":
        if (args.Length != 3 || !int.TryParse(args[2], out var count) || count <= 0)
        {
            Console.Error.WriteLine("Expected publish <scenario> <positive-count>.");
            return 1;
        }

        using (var host = DogfoodHost.Build(settings, "publisher"))
        using (var scope = host.Services.CreateScope())
        {
            var publisher = scope.ServiceProvider.GetRequiredService<DogfoodPublisher>();
            await publisher.PublishAsync(args[1], count);
        }

        return 0;

    case "inspect":
        var observation = await DogfoodObservationReader.ReadAsync(settings);
        Console.WriteLine(JsonSerializer.Serialize(observation));
        return 0;

    case "worker":
        if (args.Length is < 2 or > 4 || string.IsNullOrWhiteSpace(args[1]))
        {
            Console.Error.WriteLine("Expected worker <worker-id> [before-effect-delay-ms] [after-effect-delay-ms].");
            return 1;
        }

        var beforeEffectDelayMilliseconds = 0;
        var afterEffectDelayMilliseconds = 0;

        if (args.Length >= 3 &&
            (!int.TryParse(args[2], out beforeEffectDelayMilliseconds) ||
             beforeEffectDelayMilliseconds < 0))
        {
            Console.Error.WriteLine("Before-effect delay must be a non-negative integer.");
            return 1;
        }

        if (args.Length == 4 &&
            (!int.TryParse(args[3], out afterEffectDelayMilliseconds) ||
             afterEffectDelayMilliseconds < 0))
        {
            Console.Error.WriteLine("After-effect delay must be a non-negative integer.");
            return 1;
        }

        var consumerTiming = new ConsumerExecutionTiming(
            TimeSpan.FromMilliseconds(beforeEffectDelayMilliseconds),
            TimeSpan.FromMilliseconds(afterEffectDelayMilliseconds));

        using (var host = DogfoodHost.Build(settings, args[1], consumerTiming))
        {
            await host.RunAsync();
        }

        return 0;

    default:
        Console.Error.WriteLine($"Unknown command '{args[0]}'.");
        return 1;
}
