// ============================================================================
// Platform Connectivity – Virtual WAN Module (v2)
// ============================================================================
// Deploys: vWAN, Virtual Hubs, Azure Firewall with parent/child policy
//          hierarchy, Routing Intent, Sidecar VNets, and optionally DDoS.
//
// FIREWALL POLICY HIERARCHY:
//   - One PARENT (global) policy for org-wide rules (DNS, threat intel, SNAT)
//   - One CHILD (regional) policy per hub for region-specific rules
//   - CONSTRAINT: Parent and child policies MUST reside in the same region.
//     However, a policy can be associated with firewalls in ANY region.
//     So all policies live in parLocation; firewalls live in their hub region.
//   - Firewall Manager surfaces this hierarchy automatically in the portal.
//
// OUT OF SCOPE (day-2 operations modules):
//   - VPN Gateway         → modules/operations/vpn-gateway.bicep
//   - ExpressRoute Gateway → modules/operations/er-gateway.bicep
//   - Private DNS Zones   → separate module or landing-zone concern
// ============================================================================

metadata name = 'Platform Connectivity – vWAN Module'
metadata description = 'Deploys Azure Virtual WAN hub infrastructure with Azure Firewall parent/child policy hierarchy and routing intent.'

// ---------------------------------------------------------------------------
// USER-DEFINED TYPES
// ---------------------------------------------------------------------------

type lockType = {
  @description('Lock name.')
  name: string?

  @description('Lock kind: CanNotDelete, ReadOnly, or None.')
  kind: ('CanNotDelete' | 'ReadOnly' | 'None')

  @description('Lock notes.')
  notes: string?
}

type azFirewallAvailabilityZones = ('1' | '2' | '3')[]

type sidecarVirtualNetworkType = {
  @description('Enable the sidecar virtual network for this hub.')
  enabled: bool

  @description('Display name of the sidecar VNet.')
  name: string?

  @description('Address space of the sidecar VNet.')
  addressPrefixes: string[]

  @description('Location override (defaults to hub location).')
  location: string?

  @description('Subnets to create in the sidecar VNet.')
  subnets: array?

  @description('Additional VNet peerings beyond the primary vWAN peering.')
  peerings: array?

  @description('Diagnostic settings for the VNet.')
  diagnosticSettings: array?

  @description('DNS servers for the VNet.')
  dnsServers: array?

  @description('Resource lock override for the sidecar VNet.')
  lock: lockType?
}

@description('Per-hub configuration object.')
type virtualWanHubType = {
  @description('CIDR for the Virtual Hub address space.')
  addressPrefix: string

  @description('Azure region for this hub.')
  location: string

  @description('Hub routing preference: ExpressRoute, VpnGateway, or ASPath.')
  routingPreference: ('ExpressRoute' | 'VpnGateway' | 'ASPath')

  @description('Virtual router min capacity (2–50).')
  @minValue(2)
  @maxValue(50)
  routerAutoScaleMin: int

  @description('Routing intent destinations. Empty array = no routing intent (falls back to default route table).')
  routingIntentDestinations: ('Internet' | 'PrivateTraffic')[]

  @description('Custom hub name override.')
  hubName: string?

  @description('Custom Azure Firewall name override.')
  firewallName: string?

  @description('Custom name for the CHILD (regional) Firewall Policy.')
  firewallPolicyName: string?

  @description('Azure Firewall tier. Must match the parent policy tier.')
  firewallTier: ('Standard' | 'Premium')

  @description('Azure Firewall availability zones.')
  firewallAvailabilityZones: azFirewallAvailabilityZones

  @description('Firewall threat intel mode (child can only be equal or stricter than parent).')
  firewallIntelMode: ('Alert' | 'Deny' | 'Off')

  @description('Enable DNS proxy on the child firewall policy.')
  firewallDnsProxyEnabled: bool

  @description('Custom DNS servers for this hub firewall.')
  firewallDnsServers: array?

  @description('Sidecar VNet configuration.')
  sidecarVirtualNetwork: sidecarVirtualNetworkType
}

// ---------------------------------------------------------------------------
// PARAMETERS
// ---------------------------------------------------------------------------

@description('Primary deployment region. Also used as the region for ALL firewall policies (parent + children must be co-located).')
param parLocation string = resourceGroup().location

@description('Company/org prefix for resource naming.')
param parCompanyPrefix string = 'alz'

@description('Tags applied to all resources.')
param parTags object = {}

// --- vWAN ---

@description('Virtual WAN resource name.')
param parVirtualWanName string = '${parCompanyPrefix}-vwan-${parLocation}'

// --- Hubs ---

@description('Hub name prefix (hub location is appended).')
param parHubNamePrefix string = '${parCompanyPrefix}-vhub'

@description('Default route name for hub route tables (used only when routing intent is NOT configured).')
param parDefaultRouteName string = 'default-to-azfw'

@description('Array of hub configurations. Each entry deploys a hub + firewall + child policy.')
param parHubs virtualWanHubType[] = []

// --- Azure Firewall - Parent (Global) Policy ---

@description('Name of the PARENT (global) firewall policy. Org-wide rules go here.')
param parParentFirewallPolicyName string = '${parCompanyPrefix}-azfwpolicy-global'

@description('Firewall tier for the parent policy. All child policies inherit this.')
param parParentFirewallPolicyTier string = 'Premium'

@description('Threat intelligence mode for the parent policy. Children can only be equal or stricter.')
param parParentFirewallIntelMode string = 'Alert'

@description('Enable DNS proxy on the parent policy.')
param parParentFirewallDnsProxyEnabled bool = true

@description('DNS servers for the parent policy.')
param parParentFirewallDnsServers array = []

@description('SNAT auto-learn private ranges on the parent policy.')
@allowed(['Disabled', 'Enabled'])
param parParentFirewallSnatAutoLearn string = 'Disabled'

@description('Private IP ranges that should not be SNATed (parent policy level).')
param parParentFirewallSnatPrivateRanges array = []

// --- Azure Firewall - Child (Regional) Policies ---

@description('Child firewall policy name prefix (hub location is appended).')
param parChildFirewallPolicyNamePrefix string = '${parCompanyPrefix}-azfwpolicy'

@description('Firewall name prefix (hub location is appended).')
param parFirewallNamePrefix string = '${parCompanyPrefix}-fw'

// --- DDoS ---

@description('Enable DDoS Protection Plan.')
param parDdosEnabled bool = true

@description('DDoS Protection Plan name.')
param parDdosPlanName string = '${parCompanyPrefix}-ddos-plan'

// --- Locks ---

@description('Global resource lock. If kind != None, overrides all individual locks.')
param parGlobalResourceLock lockType = { kind: 'None', notes: 'Created by platform vWAN module.' }

@description('vWAN resource lock.')
param parVirtualWanLock lockType = { kind: 'None', notes: 'Created by platform vWAN module.' }

@description('Hub resource lock.')
param parHubLock lockType = { kind: 'None', notes: 'Created by platform vWAN module.' }

@description('Azure Firewall and firewall policy resource lock.')
param parFirewallLock lockType = { kind: 'None', notes: 'Created by platform vWAN module.' }

@description('DDoS Plan resource lock.')
param parDdosLock lockType = { kind: 'None', notes: 'Created by platform vWAN module.' }

// --- Telemetry ---

@description('Opt out of deployment telemetry.')
param parTelemetryOptOut bool = false

// ---------------------------------------------------------------------------
// VARIABLES
// ---------------------------------------------------------------------------

var varEffectiveLockKind = parGlobalResourceLock.kind != 'None' ? parGlobalResourceLock.kind : 'None'
var varLockEnabled = varEffectiveLockKind != 'None'

// =========================================================================
// VIRTUAL WAN
// =========================================================================

resource resVwan 'Microsoft.Network/virtualWans@2024-05-01' = {
  name: parVirtualWanName
  location: parLocation
  tags: parTags
  properties: {
    allowBranchToBranchTraffic: true
    allowVnetToVnetTraffic: true
    disableVpnEncryption: false
    type: 'Standard'
  }
}

resource resVwanLock 'Microsoft.Authorization/locks@2020-05-01' = if (varLockEnabled || parVirtualWanLock.kind != 'None') {
  scope: resVwan
  name: parVirtualWanLock.?name ?? '${resVwan.name}-lock'
  properties: {
    level: varLockEnabled ? varEffectiveLockKind : parVirtualWanLock.kind
    notes: varLockEnabled ? parGlobalResourceLock.?notes : parVirtualWanLock.?notes
  }
}

// =========================================================================
// VIRTUAL HUBS
// =========================================================================

resource resHub 'Microsoft.Network/virtualHubs@2024-05-01' = [
  for hub in parHubs: {
    name: hub.?hubName ?? '${parHubNamePrefix}-${hub.location}'
    location: hub.location
    tags: parTags
    properties: {
      addressPrefix: hub.addressPrefix
      sku: 'Standard'
      virtualWan: { id: resVwan.id }
      virtualRouterAutoScaleConfiguration: { minCapacity: hub.routerAutoScaleMin }
      hubRoutingPreference: hub.routingPreference
    }
  }
]

resource resHubLock 'Microsoft.Authorization/locks@2020-05-01' = [
  for (hub, i) in parHubs: if (varLockEnabled || parHubLock.kind != 'None') {
    scope: resHub[i]
    name: parHubLock.?name ?? '${resHub[i].name}-lock'
    properties: {
      level: varLockEnabled ? varEffectiveLockKind : parHubLock.kind
      notes: varLockEnabled ? parGlobalResourceLock.?notes : parHubLock.?notes
    }
  }
]

// =========================================================================
// FIREWALL POLICY HIERARCHY
// =========================================================================
//
// Architecture:
//   resParentFirewallPolicy (global, in parLocation)
//     ├── resChildFirewallPolicy[0]  (child for hub 0, also in parLocation)
//     └── resChildFirewallPolicy[1]  (child for hub 1, also in parLocation)
//
// The parent holds org-wide rules: DNS, threat intel mode, SNAT config.
// Child policies inherit everything from the parent and add region/hub rules.
// Changes to the parent auto-propagate to all children immediately.
//
// NAT rule collections are NOT inherited — they must be defined per-child.
//
// In Firewall Manager portal, this shows as a proper hierarchy you can
// manage centrally without deploying a separate "Firewall Manager" resource.
// =========================================================================

resource resParentFirewallPolicy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: parParentFirewallPolicyName
  location: parLocation
  tags: parTags
  properties: {
    sku: { tier: parParentFirewallPolicyTier }
    threatIntelMode: parParentFirewallIntelMode
    dnsSettings: {
      enableProxy: parParentFirewallDnsProxyEnabled
      servers: parParentFirewallDnsServers
    }
    snat: !empty(parParentFirewallSnatPrivateRanges)
      ? {
          autoLearnPrivateRanges: parParentFirewallSnatAutoLearn
          privateRanges: parParentFirewallSnatPrivateRanges
        }
      : null
  }
}

resource resParentFirewallPolicyLock 'Microsoft.Authorization/locks@2020-05-01' = if (varLockEnabled || parFirewallLock.kind != 'None') {
  scope: resParentFirewallPolicy
  name: parFirewallLock.?name ?? '${resParentFirewallPolicy.name}-lock'
  properties: {
    level: varLockEnabled ? varEffectiveLockKind : parFirewallLock.kind
    notes: varLockEnabled ? parGlobalResourceLock.?notes : parFirewallLock.?notes
  }
}

// --- Child (Regional) Policies ---
resource resChildFirewallPolicy 'Microsoft.Network/firewallPolicies@2024-05-01' = [
  for (hub, i) in parHubs: {
    name: hub.?firewallPolicyName ?? '${parChildFirewallPolicyNamePrefix}-${hub.location}'
    location: parLocation // MUST match parent region — Azure requirement
    tags: parTags
    properties: {
      basePolicy: { id: resParentFirewallPolicy.id }
      sku: { tier: hub.firewallTier }
      threatIntelMode: hub.firewallIntelMode
      dnsSettings: {
        enableProxy: hub.firewallDnsProxyEnabled
        servers: hub.?firewallDnsServers ?? []
      }
    }
  }
]

resource resChildFirewallPolicyLock 'Microsoft.Authorization/locks@2020-05-01' = [
  for (hub, i) in parHubs: if (varLockEnabled || parFirewallLock.kind != 'None') {
    scope: resChildFirewallPolicy[i]
    name: parFirewallLock.?name ?? '${resChildFirewallPolicy[i].name}-lock'
    properties: {
      level: varLockEnabled ? varEffectiveLockKind : parFirewallLock.kind
      notes: varLockEnabled ? parGlobalResourceLock.?notes : parFirewallLock.?notes
    }
  }
]

// =========================================================================
// AZURE FIREWALLS
// =========================================================================

resource resFirewall 'Microsoft.Network/azureFirewalls@2024-05-01' = [
  for (hub, i) in parHubs: {
    name: hub.?firewallName ?? '${parFirewallNamePrefix}-${hub.location}'
    location: hub.location
    tags: parTags
    zones: !empty(hub.firewallAvailabilityZones) ? hub.firewallAvailabilityZones : null
    properties: {
      hubIPAddresses: { publicIPs: { count: 1 } }
      sku: { name: 'AZFW_Hub', tier: hub.firewallTier }
      virtualHub: { id: resHub[i].id }
      firewallPolicy: { id: resChildFirewallPolicy[i].id }
    }
  }
]

resource resFirewallLock 'Microsoft.Authorization/locks@2020-05-01' = [
  for (hub, i) in parHubs: if (varLockEnabled || parFirewallLock.kind != 'None') {
    scope: resFirewall[i]
    name: parFirewallLock.?name ?? '${resFirewall[i].name}-lock'
    properties: {
      level: varLockEnabled ? varEffectiveLockKind : parFirewallLock.kind
      notes: varLockEnabled ? parGlobalResourceLock.?notes : parFirewallLock.?notes
    }
  }
]

// =========================================================================
// ROUTING
// =========================================================================

// Option A: Routing Intent (both Internet + PrivateTraffic)
resource resRoutingIntent 'Microsoft.Network/virtualHubs/routingIntent@2024-05-01' = [
  for (hub, i) in parHubs: if (!empty(hub.routingIntentDestinations)) {
    parent: resHub[i]
    name: '${resHub[i].name}-Routing-Intent'
    properties: {
      routingPolicies: [
        for dest in hub.routingIntentDestinations: {
          name: dest == 'Internet' ? 'PublicTraffic' : 'PrivateTraffic'
          destinations: [dest]
          nextHop: resFirewall[i].id
        }
      ]
    }
  }
]

// Option B: Default route table fallback (only when routing intent is NOT configured)
resource resDefaultRouteTable 'Microsoft.Network/virtualHubs/hubRouteTables@2024-05-01' = [
  for (hub, i) in parHubs: if (empty(hub.routingIntentDestinations)) {
    parent: resHub[i]
    name: 'defaultRouteTable'
    properties: {
      labels: ['default']
      routes: [
        {
          name: parDefaultRouteName
          destinations: ['0.0.0.0/0']
          destinationType: 'CIDR'
          nextHop: resFirewall[i].id
          nextHopType: 'ResourceID'
        }
      ]
    }
  }
]

// =========================================================================
// SIDECAR VIRTUAL NETWORKS
// =========================================================================

module modSidecarVnet 'br/public:avm/res/network/virtual-network:0.7.0' = [
  for (hub, i) in parHubs: if (hub.sidecarVirtualNetwork.enabled) {
    name: 'deploy-sidecar-vnet-${hub.location}'
    params: {
      name: hub.sidecarVirtualNetwork.?name ?? '${parCompanyPrefix}-sidecar-vnet-${hub.location}'
      addressPrefixes: hub.sidecarVirtualNetwork.addressPrefixes
      location: hub.sidecarVirtualNetwork.?location ?? hub.location
      lock: varLockEnabled
  ? {
      name: hub.sidecarVirtualNetwork.?lock.?name ?? 'sidecar-vnet-lock'
      kind: varEffectiveLockKind
    }
  : (hub.sidecarVirtualNetwork.?lock != null && hub.sidecarVirtualNetwork.?lock.?kind != 'None')
    ? {
        name: hub.sidecarVirtualNetwork.?lock.?name ?? 'sidecar-vnet-lock'
        kind: hub.sidecarVirtualNetwork.?lock.?kind
      }
    : null
      subnets: hub.sidecarVirtualNetwork.?subnets ?? []
      peerings: hub.sidecarVirtualNetwork.?peerings ?? []
      diagnosticSettings: hub.sidecarVirtualNetwork.?diagnosticSettings ?? []
      dnsServers: hub.sidecarVirtualNetwork.?dnsServers ?? []
      ddosProtectionPlanResourceId: parDdosEnabled ? resDdosPlan.id : ''
      tags: parTags
      enableTelemetry: !parTelemetryOptOut
    }
  }
]

module modSidecarVnetPeering '../vnetPeeringVwan/vnetPeeringVwan.bicep' = [
  for (hub, i) in parHubs: if (hub.sidecarVirtualNetwork.enabled) {
    name: 'deploy-sidecar-peering-${hub.location}'
    scope: subscription()
    params: {
      parRemoteVirtualNetworkResourceId: modSidecarVnet[i].outputs.resourceId
      parVirtualWanHubResourceId: resHub[i].id
    }
  }
]

// =========================================================================
// DDOS PROTECTION PLAN
// =========================================================================

resource resDdosPlan 'Microsoft.Network/ddosProtectionPlans@2024-05-01' = if (parDdosEnabled) {
  name: parDdosPlanName
  location: parLocation
  tags: parTags
}

resource resDdosPlanLock 'Microsoft.Authorization/locks@2020-05-01' = if (parDdosEnabled && (varLockEnabled || parDdosLock.kind != 'None')) {
  scope: resDdosPlan
  name: parDdosLock.?name ?? '${resDdosPlan.name}-lock'
  properties: {
    level: varLockEnabled ? varEffectiveLockKind : parDdosLock.kind
    notes: varLockEnabled ? parGlobalResourceLock.?notes : parDdosLock.?notes
  }
}

// =========================================================================
// OUTPUTS
// =========================================================================

output outVwanName string = resVwan.name
output outVwanId string = resVwan.id

output outHubs array = [
  for (hub, i) in parHubs: {
    name: resHub[i].name
    id: resHub[i].id
    location: hub.location
  }
]

output outParentFirewallPolicyId string = resParentFirewallPolicy.id
output outParentFirewallPolicyName string = resParentFirewallPolicy.name

output outChildFirewallPolicies array = [
  for (hub, i) in parHubs: {
    hub: resHub[i].name
    policyName: resChildFirewallPolicy[i].name
    policyId: resChildFirewallPolicy[i].id
    parentPolicyId: resParentFirewallPolicy.id
  }
]

output outFirewallPrivateIps array = [
  for (hub, i) in parHubs: {
    hub: resHub[i].name
    privateIp: resFirewall[i].properties.hubIPAddresses.privateIPAddress
  }
]

output outDdosPlanId string = parDdosEnabled ? resDdosPlan.id : ''

output outSidecarVnetIds array = [
  for (hub, i) in parHubs: hub.sidecarVirtualNetwork.enabled
    ? {
        hub: resHub[i].name
        vnetId: modSidecarVnet[i].outputs.resourceId
      }
    : {
        hub: resHub[i].name
        vnetId: ''
      }
]
