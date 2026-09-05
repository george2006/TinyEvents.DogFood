using System.Diagnostics;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace TinyEvents.Dogfood.Operations;

// These commands belong to the laboratory, not the TinyEvents product API.
internal static class SoakCommands
{
    public static async Task<int> PublishAsync(string[] args, DogfoodSettings settings)
    {
        if (args.Length is not (5 or 6) ||
            !int.TryParse(args[1], out var duration) || duration is < 1 or > 259200 ||
            !int.TryParse(args[2], out var rate) || rate is < 20 or > 2000 || rate % 20 != 0 ||
            !int.TryParse(args[3], out var window) || window is < 1 or > 10)
        {
            Console.Error.WriteLine("Expected publish-soak <seconds:1-259200> <rate:20-2000,multiple-of-20> <window-seconds:1-10> <new-output.jsonl> [new-ready.json].");
            return 1;
        }

        // CreateNew protects evidence; AutoFlush preserves completed windows on death.
        await using var stream = new FileStream(args[4], FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        await using var writer = new StreamWriter(stream) { AutoFlush = true };
        using var host = DogfoodHost.Build(settings, "soak-publisher");
        var runner = host.Services.GetRequiredService<PublishingLoadRunner>();
        PublishingLoadDefinition[] mix =
        [
            new("TE-SOAK-success", rate * 80 / 100),
            new("TE-SOAK-transient", rate * 10 / 100),
            new("TE-SOAK-permanent", rate * 5 / 100),
            new("TE-SOAK-slow", rate * 5 / 100)
        ];
        using var cancellation = new CancellationTokenSource();
        ConsoleCancelEventHandler onCancel = (_, e) => { e.Cancel = true; cancellation.Cancel(); };
        Console.CancelKeyPress += onCancel;
        WriteReadiness(args.Length == 6 ? args[5] : null, "publisher");
        var elapsed = Stopwatch.StartNew();
        var scheduledSeconds = 0;
        var sequence = 0;
        try
        {
            while (scheduledSeconds < duration)
            {
                // Retain at most rate * window results, independent of total duration.
                // Settle before scheduling another window: overload slows the generator.
                var seconds = Math.Min(window, duration - scheduledSeconds);
                var started = DateTimeOffset.UtcNow;
                var results = await runner.ExecuteMixedAsync(mix, seconds, cancellation.Token);
                await writer.WriteLineAsync(JsonSerializer.Serialize(new
                {
                    Sequence = ++sequence,
                    ProcessId = Environment.ProcessId,
                    StartedAtUtc = started,
                    CompletedAtUtc = DateTimeOffset.UtcNow,
                    ScheduledSeconds = seconds,
                    Results = results
                }));
                if (results.Any(result => result.Load.FailedRequests != 0))
                {
                    // A slow/leaking soak must not quietly continue after lost input.
                    return 2;
                }

                scheduledSeconds += seconds;
                var remainingWindowTime = TimeSpan.FromSeconds(scheduledSeconds) - elapsed.Elapsed;
                if (remainingWindowTime > TimeSpan.Zero)
                    await Task.Delay(remainingWindowTime, cancellation.Token);
            }
        }
        finally
        {
            Console.CancelKeyPress -= onCancel;
        }

        return 0;
    }

    public static async Task<int> WorkAsync(string[] args, DogfoodSettings settings)
    {
        if (args.Length is not (2 or 3) || string.IsNullOrWhiteSpace(args[1]))
        {
            Console.Error.WriteLine("Expected worker-soak <unique-worker-id> [new-ready.json].");
            return 1;
        }

        using var host = DogfoodHost.Build(
            settings,
            args[1],
            new ConsumerExecutionTiming(TimeSpan.Zero, TimeSpan.FromMilliseconds(100), "TE-SOAK-slow"),
            new ConsumerFailureRules([
                new("TE-SOAK-transient", 2),
                new("TE-SOAK-permanent", int.MaxValue)]),
            batchSize: 10,
            cleanupSettings: new(TimeSpan.FromHours(1), 1000, TimeSpan.FromSeconds(1)),
            claimTimeout: TimeSpan.FromMinutes(5));
        await host.StartAsync();
        WriteReadiness(args.Length == 3 ? args[2] : null, "worker");
        await host.WaitForShutdownAsync();
        return 0;
    }

    private static void WriteReadiness(string? path, string role)
    {
        if (path is null) return;

        // The collector must attach after managed startup, not race runtime
        // initialization. Publish atomically so the supervisor never reads half a JSON.
        var temporaryPath = path + ".tmp";
        using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write))
        {
            JsonSerializer.Serialize(stream, new
            {
                ProcessId = Environment.ProcessId,
                Role = role,
                ReadyAtUtc = DateTimeOffset.UtcNow
            });
        }
        File.Move(temporaryPath, path, overwrite: false);
    }
}
