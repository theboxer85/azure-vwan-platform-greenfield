targetScope = 'resourceGroup'

@description('The list of bastion configurations from the JSON file')
param parBastionConfigs array

// 1. Create Public IPs for each region defined in the JSON
resource publicIps 'Microsoft.Network/publicIPAddresses@2023-11-01' = [for config in parBastionConfigs: {
  name: 'pip-${config.bastionName}'
  location: config.location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}]

// 2. Create Bastion Hosts for each region
resource bastions 'Microsoft.Network/bastionHosts@2023-11-01' = [for (config, i) in parBastionConfigs: {
  name: config.bastionName
  location: config.location
  sku: {
    name: 'Standard'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          // This points to the AzureBastionSubnet in the VNet specified in the JSON
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', config.vnetName, 'AzureBastionSubnet')
          }
          publicIPAddress: {
            id: publicIps[i].id
          }
        }
      }
    ]
  }
}]
