/*
Copyright (c) Microsoft Corporation.
Licensed under the MIT License.
*/

param networkInterfaceName string
param diagnosticSettingName string
param logs array
param metrics array
param storageAccountId string
param workspaceId string

resource networkInterface 'Microsoft.Network/networkInterfaces@2021-02-01' existing = {
  name: networkInterfaceName
}

resource diagnosticSetting 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: networkInterface
  name: diagnosticSettingName
  properties: {
    logs: logs
    metrics: metrics
    storageAccountId: storageAccountId
    workspaceId: workspaceId
  }
}
