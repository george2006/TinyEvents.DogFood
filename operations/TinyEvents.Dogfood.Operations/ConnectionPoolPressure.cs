using Microsoft.Data.SqlClient;

namespace TinyEvents.Dogfood.Operations;

internal sealed class ConnectionPoolPressure : IAsyncDisposable
{
    private readonly IReadOnlyList<SqlConnection> connections;

    private ConnectionPoolPressure(
        IReadOnlyList<SqlConnection> connections)
    {
        this.connections = connections;
    }

    public static async ValueTask<ConnectionPoolPressure> AcquireAsync(
        string connectionString,
        int connectionCount,
        CancellationToken cancellationToken = default)
    {
        var connections = new List<SqlConnection>();

        try
        {
            for (var index = 0; index < connectionCount; index++)
            {
                var connection = new SqlConnection(connectionString);
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
        IEnumerable<SqlConnection> connections)
    {
        foreach (var connection in connections)
        {
            await connection.DisposeAsync();
        }
    }
}
