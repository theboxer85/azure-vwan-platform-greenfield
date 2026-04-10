targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// PARAMETERS
// App teams fill out the corresponding parameters/{appName}/lz-network.parameters.json
// and deploy via their own pipeline. This template is owned by platform engineering
// and must not be modified by app teams.
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param parLocation string = resourceGroup().location

@description('Short environment suffix used in resource names.')
param parEnvironment string = 'prod'

@description('Application name used in resource names. Lowercase alphanumeric.')
param parAppName string

@description('VNet address space.')
param parVnetAddressPrefix string

@description('Subnet address prefixes.')
param parSubnetPrefixes object

@description('Static private IP for the ILB frontend. Must fall within parSubnetPrefixes.lb.')
param parIlbFrontendIp string

@description('Tags to apply to all resources.')
param parTags object = {}

// ---------------------------------------------------------------------------
// VARIABLES
// ---------------------------------------------------------------------------

var varVnetName        = 'vnet-${parAppName}-${parEnvironment}-${parLocation}-01'
var varNsgLbName       = 'nsg-${parAppName}-lb-${parEnvironment}-${parLocation}-01'
var varNsgWebName      = 'nsg-${parAppName}-web-${parEnvironment}-${parLocation}-01'
var varNsgAppName      = 'nsg-${parAppName}-app-${parEnvironment}-${parLocation}-01'
var varNsgDbName       = 'nsg-${parAppName}-db-${parEnvironment}-${parLocation}-01'
var varAsgWebName      = 'asg-${parAppName}-web-${parEnvironment}-${parLocation}-01'
var varAsgAppName      = 'asg-${parAppName}-app-${parEnvironment}-${parLocation}-01'
var varAsgDbName       = 'asg-${parAppName}-db-${parEnvironment}-${parLocation}-01'
var varIlbName         = 'lbi-${parAppName}-${parEnvironment}-${parLocation}-01'
var varIlbFrontendName = 'frontend-${parAppName}'
var varIlbBackendName  = 'backend-${parAppName}'
var varIlbProbeName    = 'probe-https-${parAppName}'
var varPlsName         = 'pls-${parAppName}-${parEnvironment}-${parLocation}-01'

// ---------------------------------------------------------------------------
// ASGs
// Declared before NSGs so NSG rules can reference ASG resource IDs
// ---------------------------------------------------------------------------

resource resAsgWeb 'Microsoft.Network/applicationSecurityGroups@2024-05-01' = {
  name: varAsgWebName
  location: parLocation
  tags: parTags
}

resource resAsgApp 'Microsoft.Network/applicationSecurityGroups@2024-05-01' = {
  name: varAsgAppName
  location: parLocation
  tags: parTags
}

resource resAsgDb 'Microsoft.Network/applicationSecurityGroups@2024-05-01' = {
  name: varAsgDbName
  location: parLocation
  tags: parTags
}

// ---------------------------------------------------------------------------
// NSGs
// ---------------------------------------------------------------------------

// LB subnet — AFD Backend service tag + AzureLoadBalancer health probes
resource resNsgLb 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: varNsgLbName
  location: parLocation
  tags: parTags
  properties: {
    securityRules: [
      {
        name: 'Allow-AFD-Backend-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureFrontDoor.Backend'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [ '80', '443' ]
          description: 'Allow AFD backend traffic to ILB frontend'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer-Inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Allow Azure Load Balancer health probes'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deny all other inbound traffic'
        }
      }
    ]
  }
}

// Web subnet — AzureLoadBalancer + PLS NAT subnet as source
// PLS NAT source: AFD-forwarded traffic arrives from snet-pls-nat CIDR, not AzureLoadBalancer tag
// Bastion: add a rule allowing AzureBastionSubnet CIDR on 22/3389 for management access
resource resNsgWeb 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: varNsgWebName
  location: parLocation
  tags: parTags
  properties: {
    securityRules: [
      {
        name: 'Allow-LB-To-Web-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: resAsgWeb.id } ]
          destinationPortRange: '443'
          description: 'Allow ILB health probes and forwarded traffic to web ASG'
        }
      }
      {
        name: 'Allow-PLS-NAT-Inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: parSubnetPrefixes.plsNat
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: resAsgWeb.id } ]
          destinationPortRange: '443'
          description: 'Allow AFD-forwarded traffic from PLS NAT subnet to web ASG'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deny all other inbound traffic'
        }
      }
    ]
  }
}

// App subnet — only web subnet CIDR may reach app tier
resource resNsgApp 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: varNsgAppName
  location: parLocation
  tags: parTags
  properties: {
    securityRules: [
      {
        name: 'Allow-Web-To-App-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: parSubnetPrefixes.web
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: resAsgApp.id } ]
          destinationPortRange: '8080'
          description: 'Allow web tier to reach app tier'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// DB subnet — only app subnet CIDR may reach DB tier
resource resNsgDb 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: varNsgDbName
  location: parLocation
  tags: parTags
  properties: {
    securityRules: [
      {
        name: 'Allow-App-To-DB-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: parSubnetPrefixes.app
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: resAsgDb.id } ]
          destinationPortRange: '1433'
          description: 'Allow app tier to reach DB tier'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// VIRTUAL NETWORK
// All five subnets deployed in a single resource to avoid ARM sequencing issues
// ---------------------------------------------------------------------------

resource resVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: varVnetName
  location: parLocation
  tags: parTags
  properties: {
    addressSpace: {
      addressPrefixes: [ parVnetAddressPrefix ]
    }
    subnets: [
      // PLS NAT subnet — privateLinkServiceNetworkPolicies MUST be Disabled
      // Source NAT pool for AFD → PLS private endpoint connections
      {
        name: 'snet-pls-nat'
        properties: {
          addressPrefix: parSubnetPrefixes.plsNat
          privateLinkServiceNetworkPolicies: 'Disabled'
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      // LB subnet — ILB frontend IP lives here
      {
        name: 'snet-lb'
        properties: {
          addressPrefix: parSubnetPrefixes.lb
          networkSecurityGroup: { id: resNsgLb.id }
        }
      }
      // Web tier — VM NICs associated to resAsgWeb after deployment
      {
        name: 'snet-web'
        properties: {
          addressPrefix: parSubnetPrefixes.web
          networkSecurityGroup: { id: resNsgWeb.id }
        }
      }
      // App tier — VM NICs associated to resAsgApp after deployment
      {
        name: 'snet-app'
        properties: {
          addressPrefix: parSubnetPrefixes.app
          networkSecurityGroup: { id: resNsgApp.id }
        }
      }
      // DB tier — VM NICs associated to resAsgDb after deployment
      {
        name: 'snet-db'
        properties: {
          addressPrefix: parSubnetPrefixes.db
          networkSecurityGroup: { id: resNsgDb.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// INTERNAL LOAD BALANCER
// Standard SKU required for Private Link Service association
// ---------------------------------------------------------------------------

resource resIlb 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: varIlbName
  location: parLocation
  tags: parTags
  sku: { name: 'Standard' }
  properties: {
    frontendIPConfigurations: [
      {
        name: varIlbFrontendName
        properties: {
          subnet: {
            id: '${resVnet.id}/subnets/snet-lb'
          }
          privateIPAddress: parIlbFrontendIp
          privateIPAllocationMethod: 'Static'
        }
      }
    ]
    backendAddressPools: [
      { name: varIlbBackendName }
    ]
    loadBalancingRules: [
      {
        name: 'rule-https'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', varIlbName, varIlbFrontendName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', varIlbName, varIlbBackendName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', varIlbName, varIlbProbeName)
          }
          protocol: 'Tcp'
          frontendPort: 443
          backendPort: 443
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
        }
      }
    ]
    probes: [
      {
        name: varIlbProbeName
        properties: {
          protocol: 'Tcp'
          port: 443
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// PRIVATE LINK SERVICE
// Fronts the ILB. AFD connects via sharedPrivateLinkResource in afd-onboard.bicep.
// visibility and autoApproval MUST be "*" — AFD private endpoints originate from
// Microsoft-managed subscriptions outside the customer tenant. Scoping to a specific
// subscription ID will cause the PE connection to fail silently.
// ---------------------------------------------------------------------------

resource resPls 'Microsoft.Network/privateLinkServices@2024-05-01' = {
  name: varPlsName
  location: parLocation
  tags: parTags
  properties: {
    visibility: {
      subscriptions: [ '*' ]
    }
    autoApproval: {
      subscriptions: [ '*' ]
    }
    loadBalancerFrontendIpConfigurations: [
      { id: resIlb.properties.frontendIPConfigurations[0].id }
    ]
    ipConfigurations: [
      {
        name: 'pls-nat-ipconfig-01'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${resVnet.id}/subnets/snet-pls-nat'
          }
          primary: true
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// OUTPUTS
// outPLSId and outIlbFrontendIp are required inputs for the platform team's
// afd-onboard.bicep deployment in the connectivity subscription.
// Share these values with the platform team after Stage 1 completes.
// ---------------------------------------------------------------------------

output outVnetId string = resVnet.id
output outVnetName string = resVnet.name
output outPLSId string = resPls.id
output outPLSName string = resPls.name
output outIlbFrontendIp string = parIlbFrontendIp
output outSubnetIds object = {
  plsNat: '${resVnet.id}/subnets/snet-pls-nat'
  lb: '${resVnet.id}/subnets/snet-lb'
  web: '${resVnet.id}/subnets/snet-web'
  app: '${resVnet.id}/subnets/snet-app'
  db: '${resVnet.id}/subnets/snet-db'
}
