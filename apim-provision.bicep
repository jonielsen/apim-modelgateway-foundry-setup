@description('Name for the APIM instance')
param apimName string = 'apim-modelgateway-jn'

@description('Azure region')
param location string = 'eastus2'

@description('Publisher email')
param publisherEmail string = 'jonielse@microsoft.com'

@description('Publisher name')
param publisherName string = 'jonielse'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: 'StandardV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

output apimResourceId string = apim.id
output apimGatewayUrl string = apim.properties.gatewayUrl
output apimName string = apim.name
