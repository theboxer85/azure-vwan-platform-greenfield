targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// PARAMETERS
// ---------------------------------------------------------------------------

@description('The name of the Private DNS Zone e.g. privatelink.azurewebsites.net')
param parPrivateDnsZoneName string

@description('Array of VNet resource IDs to link to the Private DNS Zone.')
param parVnetLinks array

@description('Array of A records to create in the Private DNS Zone.')
param parARecords array

@description('Tags to apply to all resources.')
param parTags object = {}

// ---------------------------------------------------------------------------
// PRIVATE DNS ZONE
// ---------------------------------------------------------------------------

resource resPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: parPrivateDnsZoneName
  location: 'global'
  tags: parTags
}

// ---------------------------------------------------------------------------
// VNET LINKS
// Links the zone to one or more VNets so DNS queries from those VNets
// are resolved against this zone. Auto-registration is disabled —
// we manage A records explicitly.
// ---------------------------------------------------------------------------

resource resVnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for link in parVnetLinks: {
  parent: resPrivateDnsZone
  name: link.name
  location: 'global'
  tags: parTags
  properties: {
    virtualNetwork: {
      id: link.vnetId
    }
    registrationEnabled: false
  }
}]

// ---------------------------------------------------------------------------
// A RECORDS
// Each record points a hostname to a private endpoint IP.
// TTL of 300 seconds is standard for private DNS.
// ---------------------------------------------------------------------------

resource resARecords 'Microsoft.Network/privateDnsZones/A@2020-06-01' = [for record in parARecords: {
  parent: resPrivateDnsZone
  name: record.name
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: record.ip
      }
    ]
  }
}]

// ---------------------------------------------------------------------------
// OUTPUTS
// ---------------------------------------------------------------------------

output outPrivateDnsZoneId string = resPrivateDnsZone.id
output outPrivateDnsZoneName string = resPrivateDnsZone.name

