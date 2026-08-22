internal sealed record UpgradeSettings(
    string ConnectionString,
    string DatabaseName,
    string AdministrationConnectionString);
