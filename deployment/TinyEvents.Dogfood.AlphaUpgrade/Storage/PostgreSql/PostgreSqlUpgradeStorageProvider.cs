using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using TinyEvents.PostgreSql.AdoNet;

internal sealed class PostgreSqlUpgradeStorageProvider : IUpgradeStorageProvider
{
    public UpgradeSettings LoadSettings()
    {
        return PostgreSqlUpgradeSettingsLoader.Load();
    }

    public void AddPublisherServices(
        IServiceCollection services,
        UpgradeSettings settings)
    {
        services.AddScoped(_ =>
            new PostgreSqlUpgradeTransaction(settings.ConnectionString));
        services.AddScoped<IUpgradeTransaction>(provider =>
            provider.GetRequiredService<PostgreSqlUpgradeTransaction>());
        services.UsePostgreSqlAdoNetOutbox(options =>
        {
            options.UseCurrentTransaction(provider =>
            {
                var transaction = provider.GetRequiredService<PostgreSqlUpgradeTransaction>();
                return new TinyPostgreSqlAdoNetTransactionContext(
                    transaction.Connection,
                    transaction.Transaction);
            });
            options.UseWorkerConnectionFactory((_, cancellationToken) =>
                OpenConnectionAsync(settings.ConnectionString, cancellationToken));
        });
    }

    public void AddProcessorServices(
        IServiceCollection services,
        UpgradeSettings settings)
    {
        services.AddSingleton<UpgradeEffectRecorder>(
            new PostgreSqlUpgradeEffectRecorder(settings.ConnectionString));
        services.UsePostgreSqlAdoNetOutbox(options =>
        {
            options.UseWorkerConnectionFactory((_, cancellationToken) =>
                OpenConnectionAsync(settings.ConnectionString, cancellationToken));
        });
    }

    public ValueTask ResetAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken)
    {
        return PostgreSqlUpgradeDatabaseReset.ExecuteAsync(
            settings,
            cancellationToken);
    }

    public ValueTask CreateEvidenceSchemaAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken)
    {
        return PostgreSqlUpgradeEvidenceSchema.CreateAsync(
            settings,
            cancellationToken);
    }

    public ValueTask<UpgradeStateObservation> ReadObservationAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken)
    {
        return PostgreSqlUpgradeStateObservationReader.ReadAsync(
            settings,
            cancellationToken);
    }

    private static async ValueTask<System.Data.Common.DbConnection> OpenConnectionAsync(
        string connectionString,
        CancellationToken cancellationToken)
    {
        var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        return connection;
    }
}
