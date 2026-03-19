/*
  Imports the Azure OpenAI API spec into APIM and wires the backend
  to the Foundry/CognitiveServices endpoint.

  Deploy AFTER the APIM instance is fully provisioned.
*/

@description('Name of the existing APIM instance')
param apimName string = 'apim-modelgateway-jn'

@description('Azure OpenAI / Foundry endpoint base (no trailing slash). Must include /openai so APIM appends /deployments/... correctly.')
param backendUrl string = 'https://my-foundry-project-jn-resource.cognitiveservices.azure.com/openai'

// ------------------------------------------------------------------
// Reference existing APIM — enable system-assigned managed identity
// ------------------------------------------------------------------
resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// ------------------------------------------------------------------
// Grant APIM managed identity "Cognitive Services OpenAI User" on the
// Foundry/AI Services account so it can call Azure OpenAI APIs
// ------------------------------------------------------------------
var cognitiveServicesOpenAIUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

resource aiServicesAccount 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = {
  name: 'my-foundry-project-jn-resource'
}

resource apimRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServicesAccount.id, apim.id, cognitiveServicesOpenAIUserRoleId)
  scope: aiServicesAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAIUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ------------------------------------------------------------------
// Backend pointing at the Foundry / Azure OpenAI endpoint.
// Uses APIM system-assigned managed identity for authentication.
// ------------------------------------------------------------------
resource aoaiBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-aoai-backend'
  properties: {
    description: 'Azure OpenAI backend (Foundry account my-foundry-project-jn-resource)'
    url: backendUrl
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
  dependsOn: [apimRoleAssignment]
}

// ------------------------------------------------------------------
// API — Azure OpenAI (deployment-name-in-path convention)
// ------------------------------------------------------------------
resource aoaiApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'azure-openai'
  properties: {
    displayName: 'Azure OpenAI'
    description: 'Azure OpenAI chat completions API forwarded to Foundry'
    subscriptionRequired: true
    path: 'openai'
    protocols: ['https']
    // Import from the public OpenAI spec so all operations are pre-created
    format: 'openapi+json-link'
    value: 'https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-02-01/inference.json'
  }
  dependsOn: [aoaiBackend]
}

// ------------------------------------------------------------------
// Inbound policy: route to Foundry backend using managed identity.
// APIM acquires an Entra token for cognitiveservices.azure.com and
// forwards it as Authorization: Bearer <token>.
// The api-version is passed through from Foundry (set via
// inferenceAPIVersion on the Foundry connection).
// ------------------------------------------------------------------
resource aoaiApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: aoaiApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '''
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="foundry-aoai-backend" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
'''
  }
}

// ------------------------------------------------------------------
// Outputs
// ------------------------------------------------------------------
output apimGatewayUrl string = apim.properties.gatewayUrl
output apiPath string = aoaiApi.properties.path
output backendId string = aoaiBackend.name
