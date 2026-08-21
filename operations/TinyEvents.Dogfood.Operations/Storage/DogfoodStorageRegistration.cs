using Microsoft.Extensions.DependencyInjection;

namespace TinyEvents.Dogfood.Operations;

internal static class DogfoodStorageRegistration
{
    public static void AddDogfoodStorage(
        this IServiceCollection services,
        DogfoodSettings settings)
    {
        settings.StorageProvider.AddServices(services, settings);
    }
}
