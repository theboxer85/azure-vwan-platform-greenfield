# Landing Zone Reference Template

> **Ownership:** This template is maintained by the platform engineering team as a reference standard. App teams deploy it from their own repositories and pipelines — they do not deploy from this repo.
>
> **What to copy:** App teams should copy `lz-network.bicep` and create a parameter file under `parameters/{appName}/lz-network.parameters.json` in their own repo. The Bicep template must not be modified. Only the parameter file changes per app team.

---

## What this template deploys

A single `lz-network.bicep` deployment creates the complete network foundation for one application landing zone:

| Resource | Notes |
|---|---|
| Virtual Network | Five subnets deployed atomically in one resource |
| snet-pls-nat `/27` | PLS NAT IPs — `privateLinkServiceNetworkPolicies: Disabled` required |
| snet-lb `/28` | ILB frontend — NSG allows `AzureFrontDoor.Backend` + `AzureLoadBalancer` |
| snet-web `/26` | Web tier VMs — NSG allows ILB + PLS NAT subnet inbound on 443 |
| snet-app `/26` | App tier — NSG allows web subnet CIDR only |
| snet-db `/26` | DB tier — NSG allows app subnet CIDR only |
| NSG (×4) | One per subnet except snet-pls-nat |
| ASG (×3) | web · app · db — associate VM NICs post-deployment |
| Internal Load Balancer | Standard SKU, static frontend IP in snet-lb |
| Private Link Service | Fronts the ILB, visibility and autoApproval set to `*` for AFD connectivity |

## What the app team provides

Only five values need to be filled out in the parameter file:

| Parameter | Description | Example |
|---|---|---|
| `parAppName` | Lowercase alphanumeric app name — drives all resource naming | `contosoapp` |
| `parVnetAddressPrefix` | VNet CIDR allocated by platform team via IPAM | `10.16.10.0/24` |
| `parSubnetPrefixes` | Five subnet CIDRs carved from the VNet space | see parameter file |
| `parIlbFrontendIp` | Static IP for ILB frontend — must be within `snet-lb` range | `10.16.10.36` |
| `parTags` | Workload tags per org tagging policy | see parameter file |

Everything else — subnet segmentation, NSG rules, ASG definitions, ILB configuration, PLS setup — is handled by the template automatically.

## Deployment

App teams deploy Stage 1 from their own subscription and pipeline:

```bash
APP="contosoapp"
DEPLOYMENT_NAME="lz-network-$(date +%Y%m%d%H%M%S)"

az deployment group create \
  --resource-group rg-lz-${APP} \
  --template-file landingZone/lz-network.bicep \
  --parameters @landingZone/parameters/${APP}/lz-network.parameters.json \
  --name "$DEPLOYMENT_NAME"
```

After deployment, extract the outputs and share with the platform team for AFD onboarding:

```bash
PLS_ID=$(az deployment group show \
  --resource-group rg-lz-${APP} \
  --name "$DEPLOYMENT_NAME" \
  --query "properties.outputs.outPLSId.value" \
  --output tsv)

ILB_IP=$(az deployment group show \
  --resource-group rg-lz-${APP} \
  --name "$DEPLOYMENT_NAME" \
  --query "properties.outputs.outIlbFrontendIp.value" \
  --output tsv)

echo "PLS ID:  $PLS_ID"
echo "ILB IP:  $ILB_IP"
```

> **Note:** Output key names are case-sensitive. `outPLSId` not `outPlsId`.

## Platform team steps after Stage 1

Once the app team shares their `PLS_ID` and `ILB_IP`, the platform team:

1. Runs `operations/vhubConnection/vhubConnection.bicep` to connect the landing zone VNet to the vWAN hub — **`enableInternetSecurity: true` is required**
2. Creates `operations/frontdoor/afd-onboard/parameters/{appName}/afd-onboard.parameters.prod.json` with the PLS ID and ILB IP
3. Raises a PR — merge triggers the AFD onboarding pipeline automatically

## Post-deployment steps (app team)

After the network is deployed:

1. Deploy VMs into `snet-web` with no public IP
2. Associate VM NICs to `asg-{appName}-web-prod-{location}-01`
3. Add VMs to the ILB backend pool via NIC IP configuration — not by raw IP address
4. Verify ILB health probe shows **Up** in the portal before expecting AFD traffic to flow
5. Add a Bastion-inbound NSG rule on `snet-web` if management access via Bastion is needed:
   - Source: `AzureBastionSubnet` CIDR
   - Destination: `snet-web` CIDR
   - Port: 22 / 3389

## Important notes

**PLS visibility** — `visibility` and `autoApproval` are set to `*`. This is required because AFD private endpoints originate from Microsoft-managed subscriptions outside the customer tenant. Scoping to a specific subscription ID causes the connection to fail silently.

**ILB hairpin** — A VM in the ILB backend pool cannot reach the ILB frontend IP from within itself. This is expected Standard ILB behavior. Test ILB forwarding from an external source, not from within a backend VM.

**AFD health probes and TLS** — AFD cannot validate self-signed certificates. Backends must use a CA-signed certificate or the health probe will fail and the origin will be marked unhealthy, returning 503 to all requests. Use a CA-signed cert or implement SSL offload — AFD terminates HTTPS externally and forwards HTTP internally.

**Hub connection** — The platform team must set `enableInternetSecurity: true` on the vWAN hub connection. Without it, the landing zone VNet receives a direct `0.0.0.0/0 → Internet` route and egress bypasses the firewall, defeating routing intent.
