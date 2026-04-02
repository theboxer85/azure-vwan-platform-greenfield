targetScope = 'resourceGroup'

param parVpnConnections array

resource vpnConnections 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = [for conn in parVpnConnections: {
  name: '${conn.vpnGatewayName}/${conn.name}'
  properties: {
    remoteVpnSite: {
      id: resourceId('Microsoft.Network/vpnSites', conn.vpnSiteName)
    }
    enableBgp: true
    vpnLinkConnections: [
      {
        name: 'LinkConnection1'
        properties: {
          vpnSiteLink: {
            id: resourceId('Microsoft.Network/vpnSites/vpnSiteLinks', conn.vpnSiteName, 'OnPrem-Link-01')
          }
          vpnConnectionProtocolType: 'IKEv2'
          ipsecPolicies: [
            {
              ikeEncryption: conn.ikeEnc
              ikeIntegrity: conn.ikeInt
              dhGroup: conn.dhGroup
              ipsecEncryption: conn.ipsecEnc
              ipsecIntegrity: conn.ipsecInt
              pfsGroup: conn.pfsGroup
              saLifeTimeSeconds: 27000
              saDataSizeKilobytes: 102400000
            }
          ]
        }
      }
    ]
  }
}]
