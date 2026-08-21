using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using TinyEvents;
using TinyEvents.Dogfood.Operations;
using TinyEvents.SqlServer.EntityFrameworkCore;

if (args.Length == 0)
{
    Console.Error.WriteLine("Expected prepare, migrate, reset, publish, publish-then-rollback, publish-multi-consumer, inspect, inspect-migrations, worker, worker-with-failures, worker-with-plan, worker-under-pressure, or worker-for.");
    return 1;
}

var settings = DogfoodSettings.Load();

switch (args[0].ToLowerInvariant())
{
    case "prepare":
        await DogfoodDatabaseReset.ExecuteAsync(settings);
        return 0;

    case "migrate":
        await MigrateAsync(settings);
        return 0;

    case "reset":
        await DogfoodDatabaseReset.ExecuteAsync(settings);
        await MigrateAsync(settings);

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

    case "publish-then-rollback":
        if (args.Length != 2)
        {
            Console.Error.WriteLine(
                "Expected publish-then-rollback <scenario>.");
            return 1;
        }

        using (var host = DogfoodHost.Build(settings, "rollback-publisher"))
        using (var scope = host.Services.CreateScope())
        {
            var publisher = scope.ServiceProvider.GetRequiredService<DogfoodPublisher>();
            await publisher.PublishThenRollbackAsync(args[1]);
        }

        return 0;

    case "publish-multi-consumer":
        if (args.Length != 3 ||
            !int.TryParse(args[2], out var multiConsumerCount) ||
            multiConsumerCount <= 0)
        {
            Console.Error.WriteLine(
                "Expected publish-multi-consumer <scenario> <positive-count>.");
            return 1;
        }

        using (var host = DogfoodHost.Build(settings, "publisher"))
        using (var scope = host.Services.CreateScope())
        {
            var publisher = scope.ServiceProvider.GetRequiredService<DogfoodPublisher>();
            await publisher.PublishMultiConsumerAsync(
                args[1],
                multiConsumerCount);
        }

        return 0;

    case "inspect":
        var observation = await DogfoodObservationReader.ReadAsync(settings);
        Console.WriteLine(JsonSerializer.Serialize(observation));
        return 0;

    case "inspect-migrations":
        var migrationObservation =
            await DogfoodMigrationObservationReader.ReadAsync(settings);
        Console.WriteLine(JsonSerializer.Serialize(migrationObservation));
        return 0;

    case "worker":
        return await RunWorkerAsync(args, settings);

    case "worker-with-failures":
        return await RunWorkerWithFailuresAsync(args, settings);

    case "worker-with-plan":
        return await RunWorkerWithPlanAsync(args, settings);

    case "worker-under-pressure":
        return await RunWorkerUnderPressureAsync(args, settings);

    case "worker-for":
        return await RunTimedWorkerAsync(args, settings);

    default:
        Console.Error.WriteLine($"Unknown command '{args[0]}'.");
        return 1;
}

static async ValueTask MigrateAsync(DogfoodSettings settings)
{
    using var host = DogfoodHost.Build(settings, "migration");
    await host.Services.MigrateTinyEventsAsync();
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

static async Task<int> RunWorkerWithFailuresAsync(
    string[] arguments,
    DogfoodSettings settings)
{
    var hasExpectedArgumentCount = arguments.Length == 4;
    var hasWorkerId =
        arguments.Length >= 2 &&
        !string.IsNullOrWhiteSpace(arguments[1]);
    var hasTargetScenarioId =
        arguments.Length >= 3 &&
        !string.IsNullOrWhiteSpace(arguments[2]);
    var rejectedAttemptCount = 0;
    var hasRejectedAttemptCount =
        arguments.Length == 4 &&
        int.TryParse(arguments[3], out rejectedAttemptCount) &&
        rejectedAttemptCount > 0;

    if (!hasExpectedArgumentCount ||
        !hasWorkerId ||
        !hasTargetScenarioId ||
        !hasRejectedAttemptCount)
    {
        Console.Error.WriteLine(
            "Expected worker-with-failures <worker-id> <target-scenario-id> <positive-rejected-attempt-count>.");
        return 1;
    }

    var failureRules = new ConsumerFailureRules(
        [new ConsumerFailureRule(arguments[2], rejectedAttemptCount)]);
    using var host = DogfoodHost.Build(
        settings,
        arguments[1],
        ConsumerExecutionTiming.None,
        failureRules);
    await host.RunAsync();
    return 0;
}

static async Task<int> RunWorkerWithPlanAsync(
    string[] arguments,
    DogfoodSettings settings)
{
    var hasWorkerId =
        arguments.Length >= 2 &&
        !string.IsNullOrWhiteSpace(arguments[1]);
    var hasSlowScenarioId =
        arguments.Length >= 3 &&
        !string.IsNullOrWhiteSpace(arguments[2]);
    var afterEffectDelayMilliseconds = 0;
    var hasAfterEffectDelay =
        arguments.Length >= 4 &&
        int.TryParse(arguments[3], out afterEffectDelayMilliseconds) &&
        afterEffectDelayMilliseconds >= 0;
    var failureRulesAreValid = TryParseFailureRules(
        arguments,
        4,
        out var failureRules);

    if (!hasWorkerId ||
        !hasSlowScenarioId ||
        !hasAfterEffectDelay ||
        !failureRulesAreValid)
    {
        Console.Error.WriteLine(
            "Expected worker-with-plan <worker-id> <slow-scenario-id> <after-effect-delay-ms> <failure-scenario-id> <positive-rejected-attempt-count> [...].");
        return 1;
    }

    var consumerTiming = new ConsumerExecutionTiming(
        TimeSpan.Zero,
        TimeSpan.FromMilliseconds(afterEffectDelayMilliseconds),
        arguments[2]);
    var consumerFailureRules = new ConsumerFailureRules(failureRules);
    using var host = DogfoodHost.Build(
        settings,
        arguments[1],
        consumerTiming,
        consumerFailureRules);
    await host.RunAsync();
    return 0;
}

static async Task<int> RunWorkerUnderPressureAsync(
    string[] arguments,
    DogfoodSettings settings)
{
    var hasWorkerId =
        arguments.Length == 4 &&
        !string.IsNullOrWhiteSpace(arguments[1]);
    var heldConnectionCount = 0;
    var hasHeldConnectionCount =
        arguments.Length == 4 &&
        int.TryParse(arguments[2], out heldConnectionCount) &&
        heldConnectionCount > 0;
    var pressureDurationMilliseconds = 0;
    var hasPressureDuration =
        arguments.Length == 4 &&
        int.TryParse(arguments[3], out pressureDurationMilliseconds) &&
        pressureDurationMilliseconds > 0;

    if (!hasWorkerId ||
        !hasHeldConnectionCount ||
        !hasPressureDuration)
    {
        Console.Error.WriteLine(
            "Expected worker-under-pressure <worker-id> <positive-held-connection-count> <positive-pressure-duration-ms>.");
        return 1;
    }

    using var host = DogfoodHost.Build(settings, arguments[1]);

    await using (var pressure = await ConnectionPoolPressure.AcquireAsync(
        settings.StorageProvider,
        settings.ConnectionString,
        heldConnectionCount))
    {
        Console.WriteLine(
            $"Connection pool pressure acquired {heldConnectionCount} connections.");
        await host.StartAsync();
        await Task.Delay(pressureDurationMilliseconds);
    }

    Console.WriteLine("Connection pool pressure released.");
    await host.WaitForShutdownAsync();
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

static bool TryParseFailureRules(
    string[] arguments,
    int firstRuleIndex,
    out IReadOnlyList<ConsumerFailureRule> rules)
{
    var ruleArgumentCount = arguments.Length - firstRuleIndex;
    var hasCompleteRulePairs =
        ruleArgumentCount >= 2 &&
        ruleArgumentCount % 2 == 0;

    if (!hasCompleteRulePairs)
    {
        rules = [];
        return false;
    }

    var parsedRules = new List<ConsumerFailureRule>();

    for (var index = firstRuleIndex; index < arguments.Length; index += 2)
    {
        var scenarioId = arguments[index];
        var rejectedAttemptCount = 0;
        var rejectedAttemptCountIsValid =
            !string.IsNullOrWhiteSpace(scenarioId) &&
            int.TryParse(arguments[index + 1], out rejectedAttemptCount) &&
            rejectedAttemptCount > 0;

        if (!rejectedAttemptCountIsValid)
        {
            rules = [];
            return false;
        }

        parsedRules.Add(new ConsumerFailureRule(
            scenarioId,
            rejectedAttemptCount));
    }

    rules = parsedRules;
    return true;
}
