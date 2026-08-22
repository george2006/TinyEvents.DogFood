using System.Diagnostics;
using Microsoft.Extensions.DependencyInjection;

namespace TinyEvents.Dogfood.Operations;

internal sealed class PublishingLoadRunner(
    IServiceScopeFactory scopeFactory)
{
    public async Task<PublishingLoadResult> ExecuteAsync(
        string scenarioId,
        int targetRequestsPerSecond,
        int durationSeconds,
        CancellationToken cancellationToken = default)
    {
        var requestCount = checked(targetRequestsPerSecond * durationSeconds);
        var requestTasks = new List<Task<PublishingRequestResult>>(requestCount);
        var execution = Stopwatch.StartNew();

        for (var requestIndex = 0; requestIndex < requestCount; requestIndex++)
        {
            var scheduledAt = TimeSpan.FromSeconds(
                (double)requestIndex / targetRequestsPerSecond);
            var scheduleDelay = scheduledAt - execution.Elapsed;
            var requestShouldWait = scheduleDelay > TimeSpan.Zero;

            if (requestShouldWait)
            {
                await Task.Delay(scheduleDelay, cancellationToken);
            }

            requestTasks.Add(PublishOneAsync(scenarioId, cancellationToken));
        }

        var requestResults = await Task.WhenAll(requestTasks);
        execution.Stop();
        return CreateResult(
            targetRequestsPerSecond,
            durationSeconds,
            execution.Elapsed,
            requestResults);
    }

    private async Task<PublishingRequestResult> PublishOneAsync(
        string scenarioId,
        CancellationToken cancellationToken)
    {
        var request = Stopwatch.StartNew();

        try
        {
            await using var scope = scopeFactory.CreateAsyncScope();
            var publisher = scope.ServiceProvider.GetRequiredService<DogfoodPublisher>();
            await publisher.PublishAsync(scenarioId, count: 1, cancellationToken);
            return PublishingRequestResult.Committed(request.Elapsed);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            var rootCause = exception.GetBaseException();
            return PublishingRequestResult.Failed(
                request.Elapsed,
                rootCause.GetType().FullName ?? rootCause.GetType().Name,
                rootCause.Message);
        }
    }

    private static PublishingLoadResult CreateResult(
        int targetRequestsPerSecond,
        int durationSeconds,
        TimeSpan completionDuration,
        IReadOnlyList<PublishingRequestResult> requestResults)
    {
        var committedRequests = requestResults.Count(result => result.WasCommitted);
        var failedRequests = requestResults.Count - committedRequests;
        var committedLatencyMilliseconds = requestResults
            .Where(result => result.WasCommitted)
            .Select(result => result.Duration.TotalMilliseconds)
            .Order()
            .ToArray();
        var errorTypes = requestResults
            .Where(result => result.ErrorType is not null)
            .GroupBy(result => result.ErrorType!)
            .ToDictionary(group => group.Key, group => group.Count());
        var representativeErrors = requestResults
            .Where(result => result.ErrorType is not null)
            .GroupBy(result => result.ErrorType!)
            .ToDictionary(
                group => group.Key,
                group => group.First().ErrorMessage!);
        var completionSeconds = Math.Max(completionDuration.TotalSeconds, 0.001);

        return new PublishingLoadResult(
            targetRequestsPerSecond,
            durationSeconds,
            requestResults.Count,
            committedRequests,
            failedRequests,
            completionDuration.TotalMilliseconds,
            Math.Round(committedRequests / completionSeconds, 2),
            Percentile(committedLatencyMilliseconds, 0.50),
            Percentile(committedLatencyMilliseconds, 0.95),
            Percentile(committedLatencyMilliseconds, 0.99),
            errorTypes,
            representativeErrors);
    }

    private static double Percentile(
        IReadOnlyList<double> orderedValues,
        double percentile)
    {
        if (orderedValues.Count == 0)
        {
            return 0;
        }

        var nearestRank = (int)Math.Ceiling(percentile * orderedValues.Count);
        var index = Math.Clamp(nearestRank - 1, 0, orderedValues.Count - 1);
        return Math.Round(orderedValues[index], 2);
    }

    private sealed record PublishingRequestResult(
        bool WasCommitted,
        TimeSpan Duration,
        string? ErrorType,
        string? ErrorMessage)
    {
        public static PublishingRequestResult Committed(TimeSpan duration)
        {
            return new PublishingRequestResult(
                true,
                duration,
                ErrorType: null,
                ErrorMessage: null);
        }

        public static PublishingRequestResult Failed(
            TimeSpan duration,
            string errorType,
            string errorMessage)
        {
            return new PublishingRequestResult(
                false,
                duration,
                errorType,
                errorMessage);
        }
    }
}
