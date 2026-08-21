using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using TinyEvents;
using TinyEvents.Worker;

namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodHost
{
    public static IHost Build(
        DogfoodSettings settings,
        string workerId)
    {
        return Build(
            settings,
            workerId,
            ConsumerExecutionTiming.None,
            ConsumerFailureRules.None);
    }

    public static IHost Build(
        DogfoodSettings settings,
        string workerId,
        ConsumerExecutionTiming consumerTiming)
    {
        return Build(
            settings,
            workerId,
            consumerTiming,
            ConsumerFailureRules.None);
    }

    public static IHost Build(
        DogfoodSettings settings,
        string workerId,
        ConsumerExecutionTiming consumerTiming,
        ConsumerFailureRules failureRules)
    {
        var builder = Host.CreateApplicationBuilder();

        builder.Services.AddSingleton(settings);
        builder.Services.AddSingleton(new WorkerIdentity(workerId));
        builder.Services.AddSingleton(consumerTiming);
        builder.Services.AddSingleton(failureRules);
        builder.Services.AddSingleton<DogfoodConsumerFailurePlan>();
        builder.Services.AddScoped<DogfoodPublisher>();
        builder.Services.AddDogfoodStorage(settings);
        builder.Services.UseTinyEvents(options =>
        {
            options.MaxAttempts = 3;
            options.RetryDelay = TimeSpan.FromSeconds(3);
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

internal sealed record ConsumerExecutionTiming(
    TimeSpan BeforeEffectDelay,
    TimeSpan AfterEffectDelay,
    string? TargetScenarioId = null)
{
    public static ConsumerExecutionTiming None { get; } = new(
        TimeSpan.Zero,
        TimeSpan.Zero);

    public ConsumerExecutionTiming ResolveFor(string scenarioId)
    {
        var targetsEveryScenario = TargetScenarioId is null;
        var targetsCurrentScenario = string.Equals(
            TargetScenarioId,
            scenarioId,
            StringComparison.Ordinal);

        return targetsEveryScenario || targetsCurrentScenario
            ? this
            : None;
    }
}
