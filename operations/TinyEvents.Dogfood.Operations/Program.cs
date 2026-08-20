using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using TinyEvents;
using TinyEvents.Dogfood.Operations;
using TinyEvents.SqlServer.EntityFrameworkCore;

if (args.Length == 0)
{
    Console.Error.WriteLine("Expected reset, publish <scenario> <count>, inspect, worker, or worker-for.");
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
        return await RunWorkerAsync(args, settings);

    case "worker-for":
        return await RunTimedWorkerAsync(args, settings);

    default:
        Console.Error.WriteLine($"Unknown command '{args[0]}'.");
        return 1;
}

static async Task<int> RunWorkerAsync(
    string[] arguments,
    DogfoodSettings settings)
{
    var hasExpectedArgumentCount = arguments.Length is >= 2 and <= 4;
    var hasWorkerId =
        arguments.Length >= 2 &&
        !string.IsNullOrWhiteSpace(arguments[1]);
    var hasConsumerTiming = TryParseConsumerTiming(
        arguments,
        2,
        out var consumerTiming);

    if (!hasExpectedArgumentCount || !hasWorkerId || !hasConsumerTiming)
    {
        Console.Error.WriteLine("Expected worker <worker-id> [before-effect-delay-ms] [after-effect-delay-ms].");
        return 1;
    }

    using var host = DogfoodHost.Build(settings, arguments[1], consumerTiming);
    await host.RunAsync();
    return 0;
}

static async Task<int> RunTimedWorkerAsync(
    string[] arguments,
    DogfoodSettings settings)
{
    var hasExpectedArgumentCount = arguments.Length is >= 3 and <= 5;
    var hasWorkerId =
        arguments.Length >= 2 &&
        !string.IsNullOrWhiteSpace(arguments[1]);
    var runDurationMilliseconds = 0;
    var hasRunDuration =
        arguments.Length >= 3 &&
        int.TryParse(arguments[2], out runDurationMilliseconds) &&
        runDurationMilliseconds > 0;
    var hasConsumerTiming = TryParseConsumerTiming(
        arguments,
        3,
        out var consumerTiming);

    if (!hasExpectedArgumentCount ||
        !hasWorkerId ||
        !hasRunDuration ||
        !hasConsumerTiming)
    {
        Console.Error.WriteLine("Expected worker-for <worker-id> <positive-run-duration-ms> [before-effect-delay-ms] [after-effect-delay-ms].");
        return 1;
    }

    using var shutdown = new CancellationTokenSource(
        TimeSpan.FromMilliseconds(runDurationMilliseconds));
    using var host = DogfoodHost.Build(settings, arguments[1], consumerTiming);
    await host.RunAsync(shutdown.Token);
    return 0;
}

static bool TryParseConsumerTiming(
    string[] arguments,
    int firstDelayIndex,
    out ConsumerExecutionTiming consumerTiming)
{
    var beforeEffectDelayIsValid = TryParseOptionalDelay(
        arguments,
        firstDelayIndex,
        out var beforeEffectDelay);
    var afterEffectDelayIsValid = TryParseOptionalDelay(
        arguments,
        firstDelayIndex + 1,
        out var afterEffectDelay);

    consumerTiming = new ConsumerExecutionTiming(
        beforeEffectDelay,
        afterEffectDelay);
    return beforeEffectDelayIsValid && afterEffectDelayIsValid;
}

static bool TryParseOptionalDelay(
    string[] arguments,
    int index,
    out TimeSpan delay)
{
    if (arguments.Length <= index)
    {
        delay = TimeSpan.Zero;
        return true;
    }

    var delayIsValid =
        int.TryParse(arguments[index], out var delayMilliseconds) &&
        delayMilliseconds >= 0;
    delay = delayIsValid
        ? TimeSpan.FromMilliseconds(delayMilliseconds)
        : TimeSpan.Zero;
    return delayIsValid;
}
