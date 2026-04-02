targetScope = 'resourceGroup'

@description('The Resource ID of the existing vWAN Hub.')
param parVwanHubId string

@description('The array of regional configurations.')
param parDeployments array

@description('Global Front Door and WAF Configuration.')
param parGlobalAfdConfig object

// --- 1. REGIONAL NETWORKING (LOOPED) ---
resource vnetOnline 'Microsoft.Network/virtualNetworks@2023-05-01' = [for item in parDeployments: {
  name: item.networkConfig.onlineVnet.name
  location: item.location
  properties: {
    addressSpace: { addressPrefixes: item.networkConfig.onlineVnet.prefixes }
    subnets: [for subnet in item.networkConfig.onlineVnet.subnets: {
      name: subnet.name
      properties: {
        addressPrefix: subnet.addressPrefix
        privateLinkServiceNetworkPolicies: (subnet.?isNatSubnet ?? false) ? 'Disabled' : 'Enabled'
      }
    }]
  }
}]

resource vnetPrivate 'Microsoft.Network/virtualNetworks@2023-05-01' = [for item in parDeployments: {
  name: item.networkConfig.privateVnet.name
  location: item.location
  properties: {
    addressSpace: { addressPrefixes: item.networkConfig.privateVnet.prefixes }
    subnets: [for subnet in item.networkConfig.privateVnet.subnets: {
      name: subnet.name
      properties: { addressPrefix: subnet.addressPrefix }
    }]
  }
}]

// --- 2. REGIONAL SECURITY (ASGs & NSGs) ---
resource resAsgs 'Microsoft.Network/applicationSecurityGroups@2023-05-01' = [for item in parDeployments: {
  name: item.securityConfig.asgName
  location: item.location
}]

resource resNsgs 'Microsoft.Network/networkSecurityGroups@2023-05-01' = [for (item, i) in parDeployments: {
  name: item.securityConfig.nsgName
  location: item.location
  properties: {
    securityRules: [for rule in item.securityConfig.rules: {
      name: rule.name
      properties: {
        priority: rule.priority
        direction: rule.direction
        access: rule.access
        protocol: rule.protocol
        sourcePortRange: '*'
        destinationPortRange: rule.port
        sourceAddressPrefix: rule.source
        destinationApplicationSecurityGroups: rule.useAsg ? [ { id: resAsgs[i].id } ] : null
        destinationAddressPrefix: rule.useAsg ? null : rule.destination
      }
    }]
  }
}]

// --- 3. REGIONAL LOAD BALANCERS & PRIVATE LINK SERVICES ---
resource resIlb 'Microsoft.Network/loadBalancers@2023-05-01' = [for (item, i) in parDeployments: {
  name: item.ingressConfig.lbName
  location: item.location
  sku: { name: 'Standard' }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'lb-frontend'
        properties: {
          subnet: { id: '${vnetOnline[i].id}/subnets/${item.ingressConfig.lbSubnetName}' }
          privateIPAddress: item.ingressConfig.staticIp
          privateIPAllocationMethod: 'Static'
        }
      }
    ]
    backendAddressPools: [ { name: item.ingressConfig.backendPoolName } ]
    loadBalancingRules: [for rule in item.ingressConfig.lbRules: {
      name: rule.name
      properties: {
        frontendIPConfiguration: { id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', item.ingressConfig.lbName, 'lb-frontend') }
        backendAddressPool: { id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', item.ingressConfig.lbName, item.ingressConfig.backendPoolName) }
        protocol: rule.protocol
        frontendPort: rule.frontendPort
        backendPort: rule.backendPort
        probe: { id: resourceId('Microsoft.Network/loadBalancers/probes', item.ingressConfig.lbName, rule.probeName) }
      }
    }]
    probes: [for probe in item.ingressConfig.lbProbes: {
      name: probe.name
      properties: { protocol: probe.protocol, port: probe.port, intervalInSeconds: probe.interval }
    }]
  }
}]

resource resPls 'Microsoft.Network/privateLinkServices@2023-05-01' = [for (item, i) in parDeployments: {
  name: item.ingressConfig.plsName
  location: item.location
  properties: {
    visibility: { subscriptions: [ subscription().subscriptionId ] }
    autoApproval: { subscriptions: [ subscription().subscriptionId ] }
    loadBalancerFrontendIpConfigurations: [ { id: resIlb[i].properties.frontendIPConfigurations[0].id } ]
    ipConfigurations: [
      {
        name: 'pls-nat-config'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${vnetOnline[i].id}/subnets/${item.networkConfig.onlineVnet.natSubnetName}' }
        }
      }
    ]
  }
}]

// --- 4. GLOBAL FRONT DOOR & WAF (FULLY PARAMETERIZED) ---
resource resAfdProfile 'Microsoft.Network/frontdoorprofiles@2025-10-01' = {
  name: parGlobalAfdConfig.profileName
  location: 'global'
  sku: { name: parGlobalAfdConfig.skuName }
}

resource resWaf 'Microsoft.Network/frontdoorwebapplicationfirewallpolicies@2025-10-01' = {
  name: parGlobalAfdConfig.wafName
  location: 'global'
  sku: { name: parGlobalAfdConfig.skuName }
  properties: {
    policySettings: { 
      enabledState: parGlobalAfdConfig.wafEnabledState 
      mode: parGlobalAfdConfig.wafMode 
    }
    managedRules: {
      managedRuleSets: [for set in parGlobalAfdConfig.wafRuleSets: { 
        ruleSetType: set.type
        ruleSetVersion: set.version 
      }]
    }
  }
}

resource resAfdEndpoint 'Microsoft.Network/frontdoorprofiles/frontendendpoints@2025-10-01' = {
  parent: resAfdProfile
  name: parGlobalAfdConfig.endpointName
  properties: { hostname: '${parGlobalAfdConfig.profileName}.azurefd.net' }
}

resource resAfdOriginGroup 'Microsoft.Network/frontdoorprofiles/origingroups@2025-10-01' = {
  parent: resAfdProfile
  name: parGlobalAfdConfig.originGroupName
  properties: {
    healthProbeSettings: parGlobalAfdConfig.healthProbe
    loadBalancingSettings: parGlobalAfdConfig.loadBalancing
  }
}

resource resAfdOrigins 'Microsoft.Network/frontdoorprofiles/origingroups/origins@2025-10-01' = [for (item, i) in parDeployments: {
  parent: resAfdOriginGroup
  name: 'origin-${item.suffix}'
  properties: {
    hostName: item.ingressConfig.staticIp
    httpPort: parGlobalAfdConfig.originHttpPort
    httpsPort: parGlobalAfdConfig.originHttpsPort
    originHostHeader: item.ingressConfig.staticIp
    priority: 1
    weight: 1000
    sharedPrivateLinkResource: {
      privateLink: { id: resPls[i].id }
      privateLinkLocation: item.location
      requestMessage: 'AFD Private Link for ${item.location}'
    }
  }
}]

resource resAfdRoute 'Microsoft.Network/frontdoorprofiles/routes@2025-10-01' = {
  parent: resAfdProfile
  name: parGlobalAfdConfig.routeName
  dependsOn: [ resAfdOrigins ]
  properties: {
    originGroup: { id: resAfdOriginGroup.id }
    supportedProtocols: parGlobalAfdConfig.routeProtocols
    patternsToMatch: parGlobalAfdConfig.routePatterns
    forwardingProtocol: parGlobalAfdConfig.forwardingProtocol
    linkToDefaultDomain: parGlobalAfdConfig.linkToDefaultDomain
    httpsRedirect: parGlobalAfdConfig.httpsRedirect
  }
}

output regionalVnetIds array = [for i in range(0, length(parDeployments)): {
  location: parDeployments[i].location
  onlineVnetId: vnetOnline[i].id
  privateVnetId: vnetPrivate[i].id
}]
