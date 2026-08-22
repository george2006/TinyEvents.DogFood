using Microsoft.Data.SqlClient;
using Microsoft.Extensions.DependencyInjection;
using TinyEvents.SqlServer.AdoNet;

internal sealed class SqlServerUpgradeStorageProvider : IUpgradeStorageProvider
{
    public UpgradeSettings LoadSettings()
    {
        return SqlServerUpgradeSettingsLoader.Load();
    }

    public void AddPublisherServices(
        IServiceCollection services,
        UpgradeSettings settings)
    {
        services.AddScoped(_ =>
            new SqlServerUpgradeTransaction(settings.ConnectionString));
        services.AddScoped<IUpgradeTransaction>(provider =>
            provider.GetRequiredService<SqlServerUpgradeTransaction>());
        services.UseSqlServerAdoNetOutbox(options =>
        {
            options.UseCurrentTransaction(provider =>
            {
                var transaction = provider.GetRequiredService<SqlServerUpgradeTransaction>();
                return new TinyAdoNetTransactionContext(
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
            new SqlServerUpgradeEffectRecorder(settings.ConnectionString));
        services.UseSqlServerAdoNetOutbox(options =>
        {
            options.UseWorkerConnectionFactory((_, cancellationToken) =>
                OpenConnectionAsync(settings.ConnectionString, cancellationToken));
        });
    }

    public ValueTask ResetAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken)
    {
        return SqlServerUpgradeDatabaseReset.ExecuteAsync(
            settings,
            cancellationToken);
    }

    public ValueTask CreateEvidenceSchemaAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken)
    {
        return SqlServerUpgradeEvidenceSchema.CreateAsync(
            settings,
            cancellationToken);
    }

    public ValueTask<UpgradeStateObservation> ReadObservationAsync(
        UpgradeSettings settings,
        CancellationToken cancellationToken)
    {
        return SqlServerUpgradeStateObservationReader.ReadAsync(
            settings,
            cancellationToken);
    }

    private static async ValueTask<System.Data.Common.DbConnection> OpenConnectionAsync(
        string connectionString,
        CancellationToken cancellationToken)
    {
        var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        return connection;
    }
}
