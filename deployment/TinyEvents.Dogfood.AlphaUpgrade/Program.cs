using System.Text.Json;

var storage = UpgradeStorageProviderSelector.Load();
var settings = storage.LoadSettings();

if (args.Length == 0)
{
    WriteUsage();
    return 2;
}

switch (args[0].ToLowerInvariant())
{
    case "create-alpha-state":
        if (args.Length != 1)
        {
            WriteUsage();
            return 2;
        }

        await AlphaStateSeeder.CreateAsync(storage, settings);
        return 0;
    case "migrate-and-drain":
        if (args.Length != 1)
        {
            WriteUsage();
            return 2;
        }

        await CandidateStateDrainer.ExecuteAsync(storage, settings);
        return 0;
    case "create-rolling-state":
        if (args.Length != 2 ||
            !TryReadPositiveInteger(args, 1, out var messageCount))
        {
            Console.Error.WriteLine(
                "Expected create-rolling-state <positive-message-count>.");
            return 2;
        }

        await RollingStateSeeder.CreateAsync(storage, settings, messageCount);
        return 0;
    case "process-rolling":
        if (args.Length != 4 ||
            string.IsNullOrWhiteSpace(args[1]) ||
            !TryReadPositiveInteger(args, 2, out var iterationCount) ||
            !TryReadNonNegativeInteger(args, 3, out var effectDelayMilliseconds))
        {
            Console.Error.WriteLine(
                "Expected process-rolling <worker-id> <positive-iteration-count> <non-negative-effect-delay-ms>.");
            return 2;
        }

        await RollingStateProcessor.ExecuteAsync(
            storage,
            settings,
            args[1],
            iterationCount,
            TimeSpan.FromMilliseconds(effectDelayMilliseconds));
        return 0;
    case "inspect":
        if (args.Length != 1)
        {
            WriteUsage();
            return 2;
        }

        var observation = await storage.ReadObservationAsync(
            settings,
            CancellationToken.None);
        Console.WriteLine(JsonSerializer.Serialize(observation));
        return 0;
    default:
        WriteUsage();
        return 2;
}

static void WriteUsage()
{
    Console.Error.WriteLine(
        "Expected create-alpha-state, migrate-and-drain, create-rolling-state, process-rolling, or inspect.");
}

static bool TryReadPositiveInteger(
    string[] arguments,
    int index,
    out int value)
{
    value = 0;
    return arguments.Length > index &&
        int.TryParse(arguments[index], out value) &&
        value > 0;
}

static bool TryReadNonNegativeInteger(
    string[] arguments,
    int index,
    out int value)
{
    value = 0;
    return arguments.Length > index &&
        int.TryParse(arguments[index], out value) &&
        value >= 0;
}
