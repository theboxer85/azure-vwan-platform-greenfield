targetScope = 'resourceGroup'

@description('Array of VPN Sites for on-premise locations')
param parVpnSites array

resource vpnSites 'Microsoft.Network/vpnSites@2023-11-01' = [for site in parVpnSites: {
  name: site.name
  location: site.location
  properties: {
    virtualWan: {
      id: resourceId('Microsoft.Network/virtualWans', site.vWanName)
    }
    // siteLinks define the actual IP and BGP info for the on-prem device
    vpnSiteLinks: [
      {
        name: 'Link1'
        properties: {
          ipAddress: site.publicIp
          bgpProperties: {
            asn: site.peerAsn
            bgpPeeringAddress: site.peerBgpIp
          }
        }
      }
      ]
    }
  }
]
