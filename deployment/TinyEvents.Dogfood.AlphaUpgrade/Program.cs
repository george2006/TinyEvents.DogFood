using System.Text.Json;

var settings = UpgradeSettings.Load();

if (args.Length != 1)
{
    WriteUsage();
    return 2;
}

switch (args[0].ToLowerInvariant())
{
    case "create-alpha-state":
        await AlphaStateSeeder.CreateAsync(settings);
        return 0;
    case "migrate-and-drain":
        await CandidateStateDrainer.ExecuteAsync(settings);
        return 0;
    case "inspect":
        var observation = await UpgradeStateObservationReader.ReadAsync(settings);
        Console.WriteLine(JsonSerializer.Serialize(observation));
        return 0;
    default:
        WriteUsage();
        return 2;
}

static void WriteUsage()
{
    Console.Error.WriteLine("Expected create-alpha-state, migrate-and-drain, or inspect.");
}
