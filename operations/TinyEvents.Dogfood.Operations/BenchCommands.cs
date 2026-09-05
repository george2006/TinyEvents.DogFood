using System.Diagnostics;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Npgsql;

namespace TinyEvents.Dogfood.Operations;

// Laboratory-only commands. No product API, schema or instrumentation changes.
internal static class BenchCommands
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    internal sealed record Phase(string Name, int DurationSeconds, int Rate, int ContentBytes = 0);
    internal sealed record WorkerOptions(int BatchSize, bool CleanupEnabled, int RetentionSeconds,
        int SlowMilliseconds, string StartGate);

    public static async Task<int> WorkerAsync(string[] args, DogfoodSettings settings)
    {
        if (args.Length != 4) throw new ArgumentException("worker-bench <worker-id> <config.json> <ready.json>");
        var options = JsonSerializer.Deserialize<WorkerOptions>(await File.ReadAllTextAsync(args[2]), Json)
            ?? throw new ArgumentException("Missing worker configuration.");
        if (options.BatchSize is < 1 or > 100 || options.RetentionSeconds is < 1 or > 86400 ||
            options.SlowMilliseconds is < 0 or > 1000 || string.IsNullOrWhiteSpace(options.StartGate))
            throw new ArgumentException("Invalid bounded worker settings.");
        using var host = DogfoodHost.Build(settings, args[1],
            new ConsumerExecutionTiming(TimeSpan.Zero, TimeSpan.FromMilliseconds(options.SlowMilliseconds), "TE-SOAK-slow"),
            new ConsumerFailureRules([new("TE-SOAK-transient", 2), new("TE-SOAK-permanent", int.MaxValue)]),
            batchSize: options.BatchSize,
            cleanupSettings: options.CleanupEnabled ? new(TimeSpan.FromSeconds(options.RetentionSeconds), 1000, TimeSpan.FromSeconds(1)) : null,
            claimTimeout: TimeSpan.FromMinutes(5));
        SoakCommands.WriteReadiness(args[3], "worker");
        // Collectors attach to managed processes before one shared release gate.
        using var gateTimeout = new CancellationTokenSource(TimeSpan.FromMinutes(20));
        while (!File.Exists(options.StartGate)) await Task.Delay(50, gateTimeout.Token);
        await host.StartAsync();
        await host.WaitForShutdownAsync();
        return 0;
    }

    public static async Task<int> PublishAsync(string[] args, DogfoodSettings settings)
    {
        if (args.Length != 4) throw new ArgumentException("publish-phases <phases.json> <journal.jsonl> <ready.json>");
        var phases = JsonSerializer.Deserialize<Phase[]>(await File.ReadAllTextAsync(args[1]), Json)
            ?? throw new ArgumentException("Missing phases.");
        if (phases.Length is < 1 or > 12 || phases.Sum(p => (long)p.DurationSeconds) > 86400 ||
            phases.Any(p => string.IsNullOrWhiteSpace(p.Name) || p.DurationSeconds is < 1 or > 86400 ||
                p.Rate is < 0 or > 2000 || p.Rate % 20 != 0 || p.ContentBytes is < 0 or > 16384))
            throw new ArgumentException("Invalid bounded phase plan.");
        await using var stream = new FileStream(args[2], FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        await using var writer = new StreamWriter(stream) { AutoFlush = true };
        using var host = DogfoodHost.Build(settings, "phase-publisher");
        var runner = host.Services.GetRequiredService<PublishingLoadRunner>();
        SoakCommands.WriteReadiness(args[3], "publisher");
        var sequence = 0;
        foreach (var phase in phases)
        {
            var elapsed = Stopwatch.StartNew();
            for (var scheduled = 0; scheduled < phase.DurationSeconds;)
            {
                // One-second bounded windows; no unbounded queued tasks under overload.
                var started = DateTimeOffset.UtcNow;
                IReadOnlyList<ScenarioPublishingLoadResult> results = [];
                if (phase.Rate > 0)
                    results = await runner.ExecuteMixedAsync([
                        new("TE-SOAK-success", phase.Rate * 80 / 100),
                        new("TE-SOAK-transient", phase.Rate * 10 / 100),
                        new("TE-SOAK-permanent", phase.Rate * 5 / 100),
                        new("TE-SOAK-slow", phase.Rate * 5 / 100)], 1,
                        contentCharacterCount: phase.ContentBytes);
                await writer.WriteLineAsync(JsonSerializer.Serialize(new {
                    Sequence = ++sequence, ProcessId = Environment.ProcessId, Phase = phase.Name,
                    StartedAtUtc = started, CompletedAtUtc = DateTimeOffset.UtcNow,
                    ScheduledSeconds = 1, TargetRate = phase.Rate, Results = results,
                    Outstanding = await settings.StorageProvider.CountOutstandingMessagesAsync(settings, default)
                }));
                if (results.Any(r => r.Load.FailedRequests != 0)) return 2;
                var wait = TimeSpan.FromSeconds(++scheduled) - elapsed.Elapsed;
                if (wait > TimeSpan.Zero) await Task.Delay(wait);
            }
        }
        return 0;
    }

    public static async Task<int> LatencyAsync(string[] args, DogfoodSettings settings)
    {
        if (args.Length != 2 || settings.StorageProvider is not PostgreSqlDogfoodStorageProvider)
            throw new ArgumentException("inspect-latency <new-output.json> requires PostgreSQL.");
        // Server-side aggregates avoid retaining a full soak's samples in the runner.
        // Each family has its own timestamps and denominator; never label effects as ACKs.
        const string sql = """
            WITH samples AS (
                SELECT 'outbox-created-to-processed' AS metric,
                    "Payload"::jsonb->>'scenarioId' AS kind,
                    EXTRACT(EPOCH FROM ("ProcessedAtUtc" - "CreatedAtUtc"))*1000 AS ms
                FROM "TinyOutbox" WHERE "Status" = 2 AND "ProcessedAtUtc" IS NOT NULL
                UNION ALL
                SELECT 'business-created-to-first-effect', b."ScenarioId",
                    EXTRACT(EPOCH FROM (e.recorded - b."CreatedAtUtc"))*1000
                FROM "DogfoodBusinessOperations" b
                JOIN (SELECT "OperationId", MIN("RecordedAtUtc") AS recorded
                      FROM "DogfoodEffects" GROUP BY "OperationId") e ON e."OperationId" = b."Id"
            )
            SELECT metric, kind, COUNT(*)::bigint,
                percentile_cont(0.50) WITHIN GROUP (ORDER BY ms),
                percentile_cont(0.95) WITHIN GROUP (ORDER BY ms),
                percentile_cont(0.99) WITHIN GROUP (ORDER BY ms), MIN(ms), MAX(ms)
            FROM samples GROUP BY metric, kind ORDER BY metric, kind;
            """;
        await using var connection = new NpgsqlConnection(settings.ConnectionString);
        await connection.OpenAsync();
        await using var command = new NpgsqlCommand(sql, connection) { CommandTimeout = 120 };
        await using var reader = await command.ExecuteReaderAsync();
        var metrics = new List<object>();
        while (await reader.ReadAsync()) metrics.Add(new {
            Metric = reader.GetString(0), Kind = reader.IsDBNull(1) ? "unknown" : reader.GetString(1),
            Count = reader.GetInt64(2), P50Milliseconds = reader.GetDouble(3),
            P95Milliseconds = reader.GetDouble(4), P99Milliseconds = reader.GetDouble(5),
            MinMilliseconds = reader.GetDouble(6), MaxMilliseconds = reader.GetDouble(7)
        });
        await using var output = new FileStream(args[1], FileMode.CreateNew, FileAccess.Write);
        await JsonSerializer.SerializeAsync(output, new {
            SchemaVersion = 1, Metrics = metrics,
            Notes = "Post-run aggregates, not publication ACK latency. Created timestamps precede commit. Processed timestamps precede the status-update commit. Cleanup censors processed rows; compare sample counts to durable totals. Permanent failures have no successful settlement latency."
        });
        return 0;
    }
}
