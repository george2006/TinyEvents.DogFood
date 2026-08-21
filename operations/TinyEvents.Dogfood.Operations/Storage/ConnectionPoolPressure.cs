using System.Data.Common;

namespace TinyEvents.Dogfood.Operations;

internal sealed class ConnectionPoolPressure : IAsyncDisposable
{
    private readonly IReadOnlyList<DbConnection> connections;

    private ConnectionPoolPressure(
        IReadOnlyList<DbConnection> connections)
    {
        this.connections = connections;
    }

    public static async ValueTask<ConnectionPoolPressure> AcquireAsync(
        IDogfoodStorageProvider storageProvider,
        string connectionString,
        int connectionCount,
        CancellationToken cancellationToken = default)
    {
        var connections = new List<DbConnection>();

        try
        {
            for (var index = 0; index < connectionCount; index++)
            {
                var connection = storageProvider.CreateConnection(
                    connectionString);
                await connection.OpenAsync(cancellationToken);
                connections.Add(connection);
            }

            return new ConnectionPoolPressure(connections);
        }
        catch
        {
            await DisposeConnectionsAsync(connections);
            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        await DisposeConnectionsAsync(connections);
    }

    private static async ValueTask DisposeConnectionsAsync(
        IEnumerable<DbConnection> connections)
    {
        foreach (var connection in connections)
        {
            await connection.DisposeAsync();
        }
    }
}
