namespace TinyEvents.Dogfood.Operations;

internal sealed record DogfoodSettings(
    IDogfoodStorageProvider StorageProvider,
    string ConnectionString,
    string AdministrationConnectionString,
    string DatabaseName)
{
    public static DogfoodSettings Load()
    {
        var storageProvider = DogfoodStorageProviderSelector.Load();
        return storageProvider.LoadSettings();
    }
}
