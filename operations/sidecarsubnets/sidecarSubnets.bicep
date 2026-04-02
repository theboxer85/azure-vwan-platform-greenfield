targetScope = 'resourceGroup'

@description('A flat list of subnets including their parent VNet name.')
param parSubnets array

// One simple loop
resource subnets 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = [for s in parSubnets: {
  name: '${s.vnetName}/${s.name}'
  properties: {
    addressPrefix: s.addressPrefix
    // Logic: If nsgName exists, create the ID dynamically using the current subscription and RG.
    networkSecurityGroup: contains(s, 'nsgName') ? {
      id: resourceId('Microsoft.Network/networkSecurityGroups', s.nsgName)
    } : null
  }
}]

output outSubnetIds array = [for s in parSubnets: resourceId('Microsoft.Network/virtualNetworks/subnets', s.vnetName, s.name)]
