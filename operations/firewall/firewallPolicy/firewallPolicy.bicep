targetScope = 'resourceGroup'

@description('List of Firewall Policies to manage')
param parFirewallPolicies array

resource fwPolicies 'Microsoft.Network/firewallPolicies@2023-11-01' = [for policy in parFirewallPolicies: {
  name: policy.name
  location: policy.location
  // Adding this line ensures tags are managed/preserved
  tags: contains(policy, 'tags') ? policy.tags : null
  properties: {
    // Basic settings commonly managed in a Hub
    threatIntelMode: policy.threatIntelMode
    dnsSettings: {
      enableProxy: policy.dnsProxyEnabled
      servers: contains(policy, 'dnsServers') ? policy.dnsServers : []
    }
    intrusionDetection: {
      mode: policy.idpsMode
    }
    sku: {
      tier: policy.skuTier // Usually 'Standard' or 'Premium'
    }
  }
}]
