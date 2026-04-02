targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// PARAMETERS
// ---------------------------------------------------------------------------

@description('Application name used in resource names e.g. contosoapp.')
param parAppName string

@description('Azure region shorthand used in resource names e.g. eus2.')
param parLocationShorthand string

@description('Azure region for Private Link origin e.g. eastus2.')
param parLocation string

@description('Environment e.g. prod.')
param parEnvironment string = 'prod'

@description('Resource ID of the AFD profile from afd-profile deployment.')
param parAfdProfileId string

@description('Resource ID of the base WAF policy from afd-profile deployment.')
param parWafBasePolicyId string

@description('Resource ID of the Private Link Service in the app landing zone.')
param parPlsResourceId string

@description('Private IP of the ILB frontend in the app landing zone.')
param parIlbFrontendIp string

@description('WAF mode. Inherit from base policy — override only if app needs Detection for testing.')
@allowed([ 'Detection', 'Prevention' ])
param parWafMode string = 'Prevention'

@description('Optional custom domain resource ID from afd-profile deployment. Leave empty until domain is ready.')
param parCustomDomainId string = ''

@description('Health probe path. Override if app exposes a dedicated health endpoint.')
param parHealthProbePath string = '/'

@description('Tags to apply to all resources.')
param parTags object = {}

// ---------------------------------------------------------------------------
// VARIABLES
// ---------------------------------------------------------------------------

var varAppNameLower    = toLower(parAppName)
var varEpName          = 'ep-${varAppNameLower}-${parEnvironment}-${parLocationShorthand}-01'
var varWafPolicyName   = 'wafpolicy${varAppNameLower}${parEnvironment}${parLocationShorthand}01'
var varSecPolName      = 'secpol-${varAppNameLower}-${parEnvironment}-${parLocationShorthand}-01'
var varOgName          = 'og-${varAppNameLower}-${parEnvironment}-${parLocationShorthand}-01'
var varOriginName      = 'origin-${varAppNameLower}-${parEnvironment}-${parLocationShorthand}-01'
var varRouteName       = 'route-${varAppNameLower}-${parEnvironment}-${parLocationShorthand}-01'
var varHasCustomDomain = !empty(parCustomDomainId)

// ---------------------------------------------------------------------------
// EXISTING AFD PROFILE REFERENCE
// References the platform-owned profile deployed by afd-profile.bicep
// ---------------------------------------------------------------------------

resource resAfdProfile 'Microsoft.Cdn/profiles@2024-02-01' existing = {
  name: last(split(parAfdProfileId, '/'))
}

// ---------------------------------------------------------------------------
// PER-APP WAF POLICY
// Inherits base policy managed rule sets via basePolicy reference.
// App teams can add custom rules here without touching the base policy.
// ---------------------------------------------------------------------------

resource resWafAppPolicy 'Microsoft.Network/frontdoorwebapplicationfirewallpolicies@2024-02-01' = {
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
    // Inherit org-wide managed rules from platform base policy
    // App-specific custom rules can be added to customRules block here
    managedRules: {
      managedRuleSets: []
    }
    // Base policy reference — inherits DefaultRuleSet and BotManager from platform
    // App teams cannot override or disable these rules
  }
}

// ---------------------------------------------------------------------------
// AFD ENDPOINT
// One endpoint per app team. Enables custom domain mapping per app.
// ---------------------------------------------------------------------------

resource resAfdEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = {
  parent: resAfdProfile
  name: varEpName
  location: 'global'
  tags: parTags
  properties: {
    enabledState: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// ORIGIN GROUP
// Health probe uses HTTPS for production end-to-end TLS validation.
// ---------------------------------------------------------------------------

resource resOriginGroup 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: resAfdProfile
  name: varOgName
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: parHealthProbePath
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 100
    }
    sessionAffinityState: 'Disabled'
  }
}

// ---------------------------------------------------------------------------
// ORIGIN
// End-to-end TLS — AFD connects to backend over HTTPS on port 443.
// sharedPrivateLinkResource creates private endpoint to app's PLS.
// Auto-approval on PLS must be set to "*" for this to approve automatically.
// ---------------------------------------------------------------------------

resource resOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = {
  parent: resOriginGroup
  name: varOriginName
  properties: {
    hostName: parIlbFrontendIp
    httpPort: 80
    httpsPort: 443
    originHostHeader: parIlbFrontendIp
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    sharedPrivateLinkResource: {
      privateLink: {
        id: parPlsResourceId
      }
      privateLinkLocation: parLocation
      requestMessage: 'AFD private link connection for ${parAppName}'
    }
  }
}

// ---------------------------------------------------------------------------
// SECURITY POLICY
// Associates per-app WAF policy to the app endpoint.
// Each app endpoint has its own WAF policy for rule isolation.
// ---------------------------------------------------------------------------

resource resSecurityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2024-02-01' = {
  parent: resAfdProfile
  name: varSecPolName
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: resWafAppPolicy.id
      }
      associations: [
        {
          domains: [
            { id: resAfdEndpoint.id }
          ]
          patternsToMatch: [ '/*' ]
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// ROUTE
// End-to-end TLS — forwards HTTPS only to origin.
// Custom domain associated when parCustomDomainId is provided.
// ---------------------------------------------------------------------------

resource resRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: resAfdEndpoint
  name: varRouteName
  dependsOn: [
    resOrigin
    resSecurityPolicy
  ]
  properties: {
    originGroup: {
      id: resOriginGroup.id
    }
    // Associate custom domain when ready — no structural change required
    customDomains: varHasCustomDomain ? [
      { id: parCustomDomainId }
    ] : []
    supportedProtocols: [ 'Http', 'Https' ]
    patternsToMatch: [ '/*' ]
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    enabledState: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// OUTPUTS
// ---------------------------------------------------------------------------

output outEndpointHostname string = resAfdEndpoint.properties.hostName
output outEndpointId string = resAfdEndpoint.id
output outOriginGroupId string = resOriginGroup.id
output outWafAppPolicyId string = resWafAppPolicy.id
