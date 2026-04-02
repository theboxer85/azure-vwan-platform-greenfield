targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// PARAMETERS
// ---------------------------------------------------------------------------

@description('Azure region shorthand used in resource names e.g. eus2.')
param parLocationShorthand string

@description('Environment e.g. prod.')
param parEnvironment string = 'prod'

@description('WAF mode. Prevention for production.')
@allowed([ 'Detection', 'Prevention' ])
param parWafMode string = 'Prevention'

@description('Optional custom domain FQDN e.g. api.tntreasury.gov. Leave empty until domain is ready.')
param parCustomDomain string = ''

@description('Optional Key Vault secret URI for custom TLS certificate. Leave empty until cert is ready.')
param parCertificateSecretUri string = ''

@description('Tags to apply to all resources.')
param parTags object = {}

// ---------------------------------------------------------------------------
// VARIABLES
// ---------------------------------------------------------------------------

var varAfdProfileName  = 'afd-platform-${parEnvironment}-${parLocationShorthand}-01'
var varWafPolicyName   = 'wafpolicyplatform${parEnvironment}${parLocationShorthand}01'
var varSecPolName      = 'secpol-platform-${parEnvironment}-${parLocationShorthand}-01'

var varHasCustomDomain = !empty(parCustomDomain)
var varHasCert         = !empty(parCertificateSecretUri)

// ---------------------------------------------------------------------------
// AFD PROFILE
// Premium SKU required for Private Link origin and WAF policy inheritance
// ---------------------------------------------------------------------------

resource resAfdProfile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: varAfdProfileName
  location: 'global'
  tags: parTags
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
}

// ---------------------------------------------------------------------------
// BASE WAF POLICY
// Platform-owned. All app-level WAF policies reference this as basePolicy.
// App teams cannot override managed rule sets defined here.
// ---------------------------------------------------------------------------

resource resWafBasePolicy 'Microsoft.Network/frontdoorwebapplicationfirewallpolicies@2024-02-01' = {
  name: varWafPolicyName
  location: 'global'
  tags: parTags
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: parWafMode
      requestBodyCheck: 'Enabled'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
          ruleSetAction: 'Block'
          ruleGroupOverrides: []
          exclusions: []
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.1'
          ruleGroupOverrides: []
          exclusions: []
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// CUSTOM DOMAIN
// Deployed conditionally — only when parCustomDomain is provided.
// TLS uses customer-managed cert from Key Vault via parCertificateSecretUri.
// Both parCustomDomain and parCertificateSecretUri must be set together.
// ---------------------------------------------------------------------------

resource resCustomDomain 'Microsoft.Cdn/profiles/customDomains@2024-02-01' = if (varHasCustomDomain && varHasCert) {
  parent: resAfdProfile
  name: replace(parCustomDomain, '.', '-')
  properties: {
    hostName: parCustomDomain
    tlsSettings: {
      certificateType: 'CustomerCertificate'
      minimumTlsVersion: 'TLS12'
      secret: {
        id: parCertificateSecretUri
      }
    }
  }
}

// ---------------------------------------------------------------------------
// OUTPUTS
// Consumed by afd-onboard.bicep deployments and GitHub Actions workflows
// ---------------------------------------------------------------------------

output outAfdProfileName string = resAfdProfile.name
output outAfdProfileId string = resAfdProfile.id
output outWafBasePolicyId string = resWafBasePolicy.id
output outWafBasePolicyName string = resWafBasePolicy.name
output outCustomDomainId string = (varHasCustomDomain && varHasCert) ? resCustomDomain.id : ''
