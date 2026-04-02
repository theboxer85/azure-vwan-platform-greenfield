targetScope = 'resourceGroup'

@description('The Resource ID of the other team\'s Log Analytics Workspace')
param parLogAnalyticsWorkspaceId string

@description('List of Firewall Engines')
param parFirewallNames array

@description('List of Firewall Policies')
param parPolicyNames array

@description('List of Bastion Hosts')
param parBastionNames array

// 1. Reference Existing Resources
resource existingFirewalls 'Microsoft.Network/azureFirewalls@2023-11-01' existing = [for name in parFirewallNames: {
  name: name
}]

resource existingPolicies 'Microsoft.Network/firewallPolicies@2023-11-01' existing = [for name in parPolicyNames: {
  name: name
}]

resource existingBastions 'Microsoft.Network/bastionHosts@2023-11-01' existing = [for name in parBastionNames: {
  name: name
}]

// 2. Diagnostics for Firewalls
resource fwDiags 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (name, i) in parFirewallNames: {
  name: 'diag-fw-${name}'
  scope: existingFirewalls[i]
  properties: {
    workspaceId: parLogAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}]

// 3. Diagnostics for Firewall Policies
resource policyDiags 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (name, i) in parPolicyNames: {
  name: 'diag-policy-${name}'
  scope: existingPolicies[i]
  properties: {
    workspaceId: parLogAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}]

// 4. Diagnostics for Bastion Hosts
resource bastionDiags 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (name, i) in parBastionNames: {
  name: 'diag-bas-${name}'
  scope: existingBastions[i]
  properties: {
    workspaceId: parLogAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs' // Captures Communication, Audit, and Session logs
        enabled: true
      }
    ]
  }
}]
