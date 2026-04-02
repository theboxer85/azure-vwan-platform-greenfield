targetScope = 'resourceGroup'

@description('List of Rule Collection Groups to apply to specific policies')
param parRuleCollectionGroups array

resource ruleGroups 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = [for rg in parRuleCollectionGroups: {
  // Name format: FirewallPolicyName/RuleCollectionGroupName
  name: '${rg.firewallPolicyName}/${rg.name}'
  properties: {
    priority: rg.priority
    ruleCollections: rg.ruleCollections
  }
}]
