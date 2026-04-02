// ============================================================================
// Platform Connectivity – Azure Front Door (Shared Platform Profile)
// ============================================================================
// Deploys a single AFD Premium profile with a shared WAF baseline.
// Each application in the parApplications array gets its own:
//   - Endpoint (public hostname)
//   - Origin group + Private Link origin (to the app's PLS)
//   - Route (wired to that origin group)
//   - Security policy (associates the shared WAF to that endpoint)
//
// USE THIS when the platform team manages ingress centrally and app teams
// request onboarding via a PR that adds an entry to parApplications.
//
// For app teams that need independent WAF control, custom domains, or
// isolated blast radius, use the landing zone module (frontdoor-lz.bicep)
// deployed into the app team's own subscription.
// ============================================================================

targetScope = 'resourceGroup'

metadata name = 'Platform Connectivity – Shared Front Door Module'
metadata description = 'Deploys a shared AFD Premium profile with per-app endpoints and Private Link origins.'

// ---------------------------------------------------------------------------
// TYPES
// ---------------------------------------------------------------------------

@description('Per-application configuration for the shared AFD profile.')
type applicationType = {
  @description('Short application name. Used in resource naming (alphanumeric, lowercase).')
  name: string

  @description('Resource ID of the Private Link Service in the app landing zone.')
  plsResourceId: string

  @description('Private IP of the ILB frontend behind the PLS.')
  ilbFrontendIp: string

  @description('Azure region where the PLS lives.')
  plsLocation: string

  @description('Health probe path for this application.')
  healthProbePath: string?

  @description('Enable or disable this application endpoint.')
  enabled: bool?
}

// ---------------------------------------------------------------------------
// PARAMETERS
// ---------------------------------------------------------------------------

@description('Platform profile name prefix.')
param parProfileName string = 'afd-platform-prod-01'

@description('Short environment suffix.')
param parEnvironment string = 'prod'

@description('WAF mode for the shared baseline policy. Prevention for production.')
@allowed(['Detection', 'Prevention'])
param parWafMode string = 'Prevention'

@description('Array of applications to onboard. Each entry creates an endpoint + origin + route.')
param parApplications applicationType[] = []

@description('Tags applied to all resources.')
param parTags object = {}

// ---------------------------------------------------------------------------
// VARIABLES
// ---------------------------------------------------------------------------

var varWafPolicyName = 'wafplatform${parEnvironment}01'

// ---------------------------------------------------------------------------
// FRONT DOOR PROFILE (single, shared across all apps)
// ---------------------------------------------------------------------------

resource resAfdProfile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: parProfileName
  location: 'global'
  tags: parTags
  sku: { name: 'Premium_AzureFrontDoor' }
}

// ---------------------------------------------------------------------------
// WAF POLICY (shared baseline — all apps get this)
// ---------------------------------------------------------------------------

resource resWafPolicy 'Microsoft.Network/frontdoorwebapplicationfirewallpolicies@2024-02-01' = {
  name: varWafPolicyName
  location: 'global'
  tags: parTags
  sku: { name: 'Premium_AzureFrontDoor' }
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
// PER-APPLICATION RESOURCES
// Each app gets: endpoint → origin group → origin (PLS) → route + security policy
// ---------------------------------------------------------------------------

// Endpoints
resource resEndpoints 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = [
  for app in parApplications: {
    parent: resAfdProfile
    name: 'ep-${app.name}-${parEnvironment}-01'
    location: 'global'
    tags: parTags
    properties: {
      enabledState: (app.?enabled ?? true) ? 'Enabled' : 'Disabled'
    }
  }
]

// Origin groups
resource resOriginGroups 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = [
  for app in parApplications: {
    parent: resAfdProfile
    name: 'og-${app.name}-${parEnvironment}-01'
    properties: {
      loadBalancingSettings: {
        sampleSize: 4
        successfulSamplesRequired: 3
        additionalLatencyInMilliseconds: 50
      }
      healthProbeSettings: {
        probePath: app.?healthProbePath ?? '/'
        probeRequestType: 'HEAD'
        probeProtocol: 'Https'
        probeIntervalInSeconds: 100
      }
      sessionAffinityState: 'Disabled'
    }
  }
]

// Origins (Private Link to each app's PLS)
resource resOrigins 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = [
  for (app, i) in parApplications: {
    parent: resOriginGroups[i]
    name: 'origin-${app.name}-${parEnvironment}-01'
    properties: {
      hostName: app.ilbFrontendIp
      httpPort: 80
      httpsPort: 443
      originHostHeader: app.ilbFrontendIp
      priority: 1
      weight: 1000
      enabledState: 'Enabled'
      sharedPrivateLinkResource: {
        privateLink: { id: app.plsResourceId }
        privateLinkLocation: app.plsLocation
        requestMessage: 'AFD private link connection for ${app.name}'
      }
    }
  }
]

// Security policies (associate shared WAF to each endpoint)
resource resSecurityPolicies 'Microsoft.Cdn/profiles/securityPolicies@2024-02-01' = [
  for (app, i) in parApplications: {
    parent: resAfdProfile
    name: 'secpol-${app.name}-${parEnvironment}-01'
    properties: {
      parameters: {
        type: 'WebApplicationFirewall'
        wafPolicy: { id: resWafPolicy.id }
        associations: [
          {
            domains: [{ id: resEndpoints[i].id }]
            patternsToMatch: ['/*']
          }
        ]
      }
    }
  }
]

// Routes (wire each endpoint to its origin group)
resource resRoutes 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = [
  for (app, i) in parApplications: {
    parent: resEndpoints[i]
    name: 'route-${app.name}-${parEnvironment}-01'
    dependsOn: [
      resOrigins[i]
      resSecurityPolicies[i]
    ]
    properties: {
      originGroup: { id: resOriginGroups[i].id }
      supportedProtocols: ['Http', 'Https']
      patternsToMatch: ['/*']
      forwardingProtocol: 'HttpsOnly'
      linkToDefaultDomain: 'Enabled'
      httpsRedirect: 'Enabled'
      enabledState: 'Enabled'
    }
  }
]

// ---------------------------------------------------------------------------
// OUTPUTS
// ---------------------------------------------------------------------------

output outAfdProfileName string = resAfdProfile.name
output outAfdProfileId string = resAfdProfile.id
output outWafPolicyId string = resWafPolicy.id

output outApplicationEndpoints array = [
  for (app, i) in parApplications: {
    name: app.name
    endpointHostname: resEndpoints[i].properties.hostName
    endpointId: resEndpoints[i].id
    originGroupId: resOriginGroups[i].id
  }
]
