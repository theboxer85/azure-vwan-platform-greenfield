targetScope = 'resourceGroup'

@description('List of Landing Zone VNets to connect to specific Virtual Hubs')
param parVhubConnections array

resource hubConnections 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = [for connection in parVhubConnections: {
  // The name format is: VirtualHubName/ConnectionName
  name: '${connection.vHubName}/${connection.lzVnetName}-connection'
  properties: {
    remoteVirtualNetwork: {
      // Points to the Landing Zone VNet being connected
      id: resourceId(connection.lzSubscriptionId, connection.lzResourceGroup, 'Microsoft.Network/virtualNetworks', connection.lzVnetName)
    }
    // routingConfiguration is usually left as default when using Routing Intent
    // as the Hub Policy overrides specific connection settings.
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
  }
}]
