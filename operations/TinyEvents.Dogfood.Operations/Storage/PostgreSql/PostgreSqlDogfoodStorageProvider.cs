using System.Data.Common;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using TinyEvents.PostgreSql.EntityFrameworkCore;

namespace TinyEvents.Dogfood.Operations;

internal sealed class PostgreSqlDogfoodStorageProvider : IDogfoodStorageProvider
{
    public DogfoodSettings LoadSettings()
    {
        return PostgreSqlDogfoodSettingsLoader.Load(this);
    }

    public void AddServices(
        IServiceCollection services,
        DogfoodSettings settings)
    {
        PostgreSqlDogfoodStorageRegistration.Add(
            services,
            settings.ConnectionString);
    }

    public void ConfigureModel(ModelBuilder modelBuilder)
    {
        modelBuilder.UseTinyEventsOutbox();
    }

    public DbConnection CreateConnection(string connectionString)
    {
        return new NpgsqlConnection(connectionString);
    }

    public ValueTask ResetAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        return PostgreSqlDogfoodDatabaseReset.ExecuteAsync(
            settings,
            cancellationToken);
    }

    public ValueTask<ScenarioObservation> ReadObservationAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        return PostgreSqlDogfoodObservationReader.ReadAsync(
            settings,
            cancellationToken);
    }

    public ValueTask<MigrationObservation> ReadMigrationObservationAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        return PostgreSqlDogfoodMigrationObservationReader.ReadAsync(
            settings,
            cancellationToken);
    }

    public ValueTask<StorageObservation> ReadStorageObservationAsync(
        DogfoodSettings settings,
        CancellationToken cancellationToken)
    {
        return PostgreSqlDogfoodStorageObservationReader.ReadAsync(
            settings,
            cancellationToken);
    }
}
