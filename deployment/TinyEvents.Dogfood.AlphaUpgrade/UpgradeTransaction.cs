internal interface IUpgradeTransaction : IAsyncDisposable
{
    Task CommitAsync();
}
