targetScope = 'resourceGroup'

param parVpnGateways array

resource vpnGateways 'Microsoft.Network/vpnGateways@2023-11-01' = [for vpn in parVpnGateways: {
  name: vpn.name
  location: vpn.location
  properties: {
    virtualHub: {
      id: resourceId('Microsoft.Network/virtualHubs', vpn.vHubName)
    }
    vpnGatewayScaleUnit: vpn.scaleUnit
    bgpSettings: {
      asn: vpn.asn 
    }
  }
}]
