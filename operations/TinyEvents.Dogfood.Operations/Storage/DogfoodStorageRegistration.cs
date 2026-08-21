using Microsoft.Extensions.DependencyInjection;

namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodStorageRegistration
{
    public static void AddDogfoodStorage(
        this IServiceCollection services,
        DogfoodSettings settings)
    {
        switch (settings.StorageProvider)
        {
            case DogfoodStorageProvider.SqlServer:
                SqlServerDogfoodStorageRegistration.Add(
                    services,
                    settings.ConnectionString);
                return;

            case DogfoodStorageProvider.PostgreSql:
                PostgreSqlDogfoodStorageRegistration.Add(
                    services,
                    settings.ConnectionString);
                return;

            default:
                throw new ArgumentOutOfRangeException(
                    nameof(settings),
                    settings.StorageProvider,
                    "Unknown dogfood storage provider.");
        }
    }
}
