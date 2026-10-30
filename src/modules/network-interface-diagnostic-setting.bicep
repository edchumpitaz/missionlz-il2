/*
Copyright (c) Microsoft Corporation.
Licensed under the MIT License.
*/

param delimiter string
param logAnalyticsWorkspaceResourceId string
param logs array
param metrics array
param networkInterfaceResourceId string
param storageAccountResourceIds array
param tiers array
param tokens object

var networkInterfaceDiagnosticSettingName = replace(tiers[tierIndex].namingConvention.virtualMachineNetworkInterfaceDiagnosticSetting, '${delimiter}${tokens.purpose}', '')
var storageAccountResourceId = storageAccountResourceIds[tierIndex]
var tierIndex = indexOf(
  map(tiers, tier => toLower(tier.subnetResourceId)),
  toLower(networkInterface.properties.ipConfigurations[0].properties.subnet.id)
)

resource networkInterface 'Microsoft.Network/networkInterfaces@2021-02-01' existing = {
 name: split(networkInterfaceResourceId, '/')[8]
}

// Resolve subnet ownership before starting the deployment that names the diagnostic setting.
module diagnosticSetting 'network-interface-diagnostic-resource.bicep' = {
  name: 'deploy-nic-diag-${uniqueString(networkInterfaceResourceId)}'
  params: {
    networkInterfaceName: networkInterface.name
    diagnosticSettingName: networkInterfaceDiagnosticSettingName
    logs: logs
    metrics: metrics
    storageAccountId: storageAccountResourceId
    workspaceId: logAnalyticsWorkspaceResourceId
  }
}
