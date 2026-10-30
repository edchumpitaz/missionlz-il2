BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $PSScriptRoot 'helpers\Resolve-ArmTestExpression.ps1')
    $arm = Get-Content (Join-Path $repo 'src\mlz.json') -Raw | ConvertFrom-Json -AsHashtable
    $abbreviations = Get-Content (Join-Path $repo 'src\data\resource-abbreviations.json') -Raw | ConvertFrom-Json -AsHashtable
    $locations = Get-Content (Join-Path $repo 'src\data\locations.json') -Raw | ConvertFrom-Json -AsHashtable
    $ui = Get-Content (Join-Path $repo 'src\mlz.uiDefinition.json') -Raw | ConvertFrom-Json -AsHashtable

    function Get-NamingModule {
        param($Template, [string]$Fragment)
        $modules = @($Template.resources | Where-Object { $_.name -eq $Fragment -or $_.name -like "*'$Fragment*" })
        if ($modules.Count -ne 1) { throw "Expected one compiled naming consumer: $Fragment" }
        return $modules[0]
    }

    $networkModule = Get-NamingModule $arm 'deploy-networking-'
    $networking = $networkModule.properties.template
    $logicModule = Get-NamingModule $networking 'get-logic-'
    $logic = $logicModule.properties.template
    $namingModule = $logic.resources | Where-Object { $_.copy.name -eq 'namingConventions' }
    $naming = $namingModule.properties.template
    $hubModule = Get-NamingModule $networking 'deploy-vnet-hub-'
    $hub = $hubModule.properties.template
    $spoke = ($networking.resources | Where-Object { $_.copy.name -eq 'spokeNetworks' }).properties.template
    $monitor = (Get-NamingModule $arm 'deploy-monitoring-').properties.template
    $diagnostics = (Get-NamingModule $arm 'deploy-diagnostic-settings-').properties.template
    $groups = (Get-NamingModule $networking 'deploy-resource-groups-').properties.template
    $storage = (Get-NamingModule $arm 'deploy-diag-storage-').properties.template
    $cmk = (Get-NamingModule $storage 'deploy-st-cmk-').properties.template
    $storageAccount = ($storage.resources | Where-Object { $_.copy.name -eq 'storageAccounts' }).properties.template

    function Get-Names {
        param([string]$Tier, [hashtable]$Overrides = @{})
        $parameters = @{
            deploymentProfile = 'customer-il2'; delimiter = '-'
            identifier = 'mlz'; environmentAbbreviation = 'dev'; networkName = $Tier
            locationAbbreviation = $locations.AzureUSGovernment.usgovvirginia.abbreviation
            resourceAbbreviations = $abbreviations
        }
        foreach ($key in $Overrides.Keys) { $parameters[$key] = $Overrides[$key] }
        return Resolve-ArmTestExpression $naming.outputs.names.value @{ Template = $naming; Parameters = $parameters }
    }

    $tokens = Resolve-ArmTestExpression $naming.outputs.tokens.value @{ Template = $naming; Parameters = @{} }
    $customerHub = Get-Names 'hub'
    $customerOperations = Get-Names 'operations'
    $tiers = @(
        @{ name = 'hub'; namingConvention = $customerHub },
        @{ name = 'operations'; namingConvention = $customerOperations }
    )
    $consumers = @{ hub = $hub; spoke = $spoke; monitor = $monitor; diagnostics = $diagnostics; groups = $groups }

    function Get-ConsumerContext {
        param($Template, [int]$TierIndex = 0)
        return @{
            Template = $Template; CopyIndex = $TierIndex
            Parameters = @{ tier = $tiers[$TierIndex]; tiers = $tiers; delimiter = '-'; tokens = $tokens }
        }
    }
}

Describe 'Exact customer names through compiled core consumers' {
    It 'generates <Expected>' -ForEach @(
        @{ Consumer = 'hub'; Module = 'deploy-hub-fw-{'; Parameter = 'name'; Tier = 0; Expected = 'afw-scca-va-il2-mlz' }
        @{ Consumer = 'hub'; Module = 'deploy-hub-fw-{'; Parameter = 'firewallPolicyName'; Tier = 0; Expected = 'afwp-scca-va-il2-mlz' }
        @{ Consumer = 'hub'; Module = 'deploy-hub-fw-client-pip-'; Parameter = 'name'; Tier = 0; Expected = 'pip-scca-va-il2-afw-client-mlz' }
        @{ Consumer = 'hub'; Module = 'deploy-hub-fw-mgmt-pip-'; Parameter = 'name'; Tier = 0; Expected = 'pip-scca-va-il2-afw-management-mlz' }
        @{ Consumer = 'groups'; Module = 'deploy-rg-'; Parameter = 'name'; Tier = 0; Expected = 'rg-scca-va-il2-hub-mlz' }
        @{ Consumer = 'hub'; Module = 'deploy-hub-vnet-'; Parameter = 'name'; Tier = 0; Expected = 'vnet-scca-va-il2-hub-mlz' }
        @{ Consumer = 'hub'; Module = 'deploy-hub-nsg-'; Parameter = 'name'; Tier = 0; Expected = 'nsg-scca-va-il2-hub-mlz' }
        @{ Consumer = 'hub'; Module = 'deploy-hub-rt-'; Parameter = 'name'; Tier = 0; Expected = 'rt-scca-va-il2-hub-mlz' }
        @{ Consumer = 'groups'; Module = 'deploy-rg-'; Parameter = 'name'; Tier = 1; Expected = 'rg-scca-va-il2-operations-mlz' }
        @{ Consumer = 'spoke'; Module = 'virtualNetwork'; Parameter = 'name'; Tier = 1; Expected = 'vnet-scca-va-il2-operations-mlz' }
        @{ Consumer = 'spoke'; Module = 'networkSecurityGroup'; Parameter = 'name'; Tier = 1; Expected = 'nsg-scca-va-il2-operations-mlz' }
        @{ Consumer = 'spoke'; Module = 'routeTable'; Parameter = 'name'; Tier = 1; Expected = 'rt-scca-va-il2-operations-mlz' }
        @{ Consumer = 'monitor'; Module = 'deploy-law-'; Parameter = 'name'; Tier = 1; Expected = 'log-scca-va-il2-operations-mlz' }
        @{ Consumer = 'monitor'; Module = 'deploy-private-link-scope-'; Parameter = 'name'; Tier = 1; Expected = 'pls-scca-va-il2-operations-mlz' }
        @{ Consumer = 'monitor'; Module = 'deploy-private-endpoint-'; Parameter = 'name'; Tier = 1; Expected = 'pe-scca-va-il2-operations-pls-mlz' }
        @{ Consumer = 'monitor'; Module = 'deploy-private-endpoint-'; Parameter = 'networkInterfaceName'; Tier = 1; Expected = 'nic-scca-va-il2-operations-pls-mlz' }
        @{ Consumer = 'diagnostics'; Module = 'deploy-law-diag-'; Parameter = 'logAnalyticsWorkspaceDiagnosticSettingName'; Tier = 1; Expected = 'diag-scca-va-il2-operations-log-mlz' }
        @{ Consumer = 'diagnostics'; Module = 'deploy-vnet-diag-'; Parameter = 'virtualNetworkDiagnosticSettingName'; Tier = 0; Expected = 'diag-scca-va-il2-hub-vnet-mlz' }
    ) {
        $template = $consumers[$Consumer]
        $module = Get-NamingModule $template $Module
        $context = Get-ConsumerContext $template $Tier
        if ($Consumer -eq 'groups') { $context.Parameters.purpose = 'network' }
        Resolve-ArmTestExpression $module.properties.parameters[$Parameter].value $context | Should -BeExactly $Expected
    }

    It 'preserves service and role tokens, suffix position, and distinct tier resources' {
        $tokens.Count | Should -Be 3
        $tokens.purpose | Should -BeExactly 'purpose_token'
        $tokens.resource | Should -BeExactly 'resource_token'
        $tokens.service | Should -BeExactly 'service_token'
        $customerHub.userAssignedIdentity.Replace($tokens.purpose, 'cmk') | Should -BeExactly 'id-scca-va-il2-hub-cmk-mlz'
        $customerHub.keyVaultPrivateEndpoint.Replace($tokens.purpose, 'cmk') | Should -BeExactly 'pe-scca-va-il2-hub-kv-cmk-mlz'
        $customerHub.keyVaultNetworkInterface.Replace($tokens.purpose, 'cmk') | Should -BeExactly 'nic-scca-va-il2-hub-kv-cmk-mlz'
        $customerHub.bastionHost.Replace('-purpose_token', '') | Should -BeExactly 'bas-scca-va-il2-mlz'
        $customerHub.subnet.Replace('-purpose_token', '') | Should -BeExactly 'snet-scca-va-il2-hub-mlz'
        $customerOperations.subnet.Replace('-purpose_token', '') | Should -BeExactly 'snet-scca-va-il2-operations-mlz'
        $customerHub.networkWatcherFlowLogsNetworkSecurityGroup.Replace('-purpose_token', '') |
            Should -BeExactly 'fl-scca-va-il2-hub-nsg-mlz'
        $customerOperations.networkWatcherFlowLogsVirtualNetwork.Replace('-purpose_token', '') |
            Should -BeExactly 'fl-scca-va-il2-operations-vnet-mlz'
        foreach ($key in $naming.variables.customerNames.Keys) {
            $customerHub[$key] | Should -Match '-mlz$'
            $customerOperations[$key] | Should -Match '-mlz$'
        }
        foreach ($key in @('resourceGroup', 'virtualNetwork', 'subnet', 'networkSecurityGroup', 'routeTable')) {
            $customerHub[$key] | Should -Not -BeExactly $customerOperations[$key]
        }
    }

    It 'uses the identifier input rather than hardcoding mlz' {
        $names = Get-Names 'hub' @{ identifier = 'abc12' }
        $names.azureFirewall.Replace('-purpose_token', '') | Should -BeExactly 'afw-scca-va-il2-abc12'
        $names.resourceGroup | Should -BeExactly 'rg-scca-va-il2-hub-abc12'
        $names.azureFirewallPublicIPAddress.Replace($tokens.purpose, 'management') |
            Should -BeExactly 'pip-scca-va-il2-afw-management-abc12'
    }

    It 'ignores environment for every customer override but retains environment tags and settings' {
        foreach ($tierName in @('hub', 'operations')) {
            $dev = Get-Names $tierName
            foreach ($environmentName in @('test', 'prod')) {
                $other = Get-Names $tierName @{ environmentAbbreviation = $environmentName }
                foreach ($key in $naming.variables.customerNames.Keys) { $other[$key] | Should -BeExactly $dev[$key] }
            }
        }
        $logic.variables.mlzTags.environment | Should -Match "environmentAbbreviation"
        $storageAccount.resources[0].properties.accessTier | Should -Match "environmentAbbreviation"
    }

    It 'flows the profile and real location abbreviation through the core naming path' {
        $networkModule.properties.parameters.deploymentProfile.value | Should -BeExactly "[parameters('deploymentProfile')]"
        $logicModule.properties.parameters.deploymentProfile.value | Should -BeExactly "[parameters('deploymentProfile')]"
        $namingModule.properties.parameters.deploymentProfile.value | Should -BeExactly "[parameters('deploymentProfile')]"
        $hubModule.properties.parameters.deploymentProfile.value | Should -BeExactly "[parameters('deploymentProfile')]"
        $namingModule.properties.parameters.locationAbbreviation.value |
            Should -BeExactly "[variables('locations')[parameters('location')].abbreviation]"
        $locations.AzureUSGovernment.usgovvirginia.abbreviation | Should -BeExactly 'va'
        $names = Get-Names 'hub' @{ locationAbbreviation = 'az' }
        $names.azureFirewall.Replace('-purpose_token', '') | Should -BeExactly 'afw-scca-az-il2-mlz'
        $networkModule.properties.parameters.location.value | Should -BeExactly "[parameters('location')]"
    }
}

Describe 'Additional Firewall public IP naming and attachment' {
    It 'keeps indexes before the customer suffix and preserves legacy indexes' -ForEach @(
        @{ Profile = 'customer-il2'; Expected = @('pip-scca-va-il2-afw-client-1-mlz', 'pip-scca-va-il2-afw-client-2-mlz') }
        @{ Profile = 'legacy'; Expected = @('mlz-dev-va-hub-afw-pip-client-1', 'mlz-dev-va-hub-afw-pip-client-2') }
    ) {
        $context = Get-ConsumerContext $hub
        $context.Parameters.tier = @{ namingConvention = (Get-Names 'hub' @{ deploymentProfile = $Profile }) }
        $context.Parameters.deploymentProfile = $Profile
        $context.Parameters.firewallCustomPipCount = 2
        $names = Resolve-ArmTestExpression "[variables('customPublicIPAddressNames')]" $context
        $names | Should -Be $Expected
        $firewallModule = Get-NamingModule $hub 'deploy-hub-fw-{'
        $firewallModule.properties.parameters.customPublicIPAddressNames.value |
            Should -BeExactly "[variables('customPublicIPAddressNames')]"
        $pipModule = $hub.resources | Where-Object { $_.copy.name -eq 'firewallCustomPublicIPAddresses' }
        for ($i = 0; $i -lt 2; $i++) {
            $context.CopyIndex = $i
            Resolve-ArmTestExpression $pipModule.properties.parameters.name.value $context | Should -BeExactly $Expected[$i]
        }
        $firewall = $firewallModule.properties.template
        $copy = $firewall.variables.copy | Where-Object name -eq 'customIpConfigurations'
        $copy.input.properties.publicIPAddress.id | Should -Match "customPublicIPAddressNames.*copyIndex"
        $firewall.parameters.customPublicIPAddressNames.defaultValue.Count | Should -Be 0
    }
}

Describe 'Legacy, specialized, and workload exceptions' {
    It 'preserves representative legacy names for every upstream tier' -ForEach @(
        @{ TierName = 'hub' }, @{ TierName = 'operations' }, @{ TierName = 'sharedServices' }, @{ TierName = 'identity' }
    ) {
        $names = Get-Names $TierName @{ deploymentProfile = 'legacy' }
        $names.resourceGroup.Replace($tokens.purpose, 'network') | Should -BeExactly "mlz-dev-va-$TierName-rg-network"
        $names.virtualNetwork.Replace('-purpose_token', '') | Should -BeExactly "mlz-dev-va-$TierName-vnet"
        $names.azureFirewallPublicIPAddress.Replace($tokens.purpose, 'management') |
            Should -BeExactly "mlz-dev-va-$TierName-afw-pip-management"
        $names.privateLinkScopePrivateEndpoint.Replace('-purpose_token', '') |
            Should -BeExactly "mlz-dev-va-$TierName-pls-pe"
    }

    It 'keeps shared module defaults legacy and retains stamp/delimiter behavior for add-ons' {
        foreach ($template in @($networking, $logic, $naming, $hub)) {
            $template.parameters.deploymentProfile.defaultValue | Should -BeExactly 'legacy'
        }
        $names = Get-Names 'sharedServices' @{ deploymentProfile = 'legacy'; stampIndex = '2'; delimiter = '' }
        $names.virtualNetwork | Should -BeExactly 'mlzdevvasharedServicesvnetpurpose_token2'
        $names.virtualMachine | Should -BeExactly 'mlzdvavmpurpose_token2'
        foreach ($tierName in @('sharedServices', 'identity')) {
            $legacy = Get-Names $tierName @{ deploymentProfile = 'legacy' }
            $notCustomerOwned = Get-Names $tierName
            foreach ($key in $legacy.Keys) { $notCustomerOwned[$key] | Should -BeExactly $legacy[$key] }
        }
    }

    It 'does not rename VM/computer-name, disk, VM NIC, or other workload templates' {
        foreach ($tierName in @('hub', 'operations')) {
            $legacy = Get-Names $tierName @{ deploymentProfile = 'legacy' }
            $customer = Get-Names $tierName
            foreach ($key in $legacy.Keys) {
                if (-not $naming.variables.customerNames.ContainsKey($key)) { $customer[$key] | Should -BeExactly $legacy[$key] }
            }
        }
        $context = Get-ConsumerContext $cmk
        Resolve-ArmTestExpression "[variables('virtualMachineName')]" $context | Should -BeExactly 'mlzdvavmcmk'
        ($cmk.resources | Where-Object type -eq 'Microsoft.Compute/virtualMachines').properties.osProfile.computerName |
            Should -BeExactly "[variables('virtualMachineName')]"
    }

    It 'preserves hash algorithms and scope while supplying the customer context as the seed' {
        $vault = $cmk.resources | Where-Object type -eq 'Microsoft.KeyVault/vaults'
        $vault.name | Should -BeExactly "[format('{0}{1}', parameters('resourceAbbreviations').keyVaults, uniqueString(parameters('tier').subscriptionId, variables('resourceGroupName'), replace(parameters('tier').namingConvention.keyVault, parameters('tokens').purpose, variables('workload'))))]"
        $account = $storageAccount.resources | Where-Object type -eq 'Microsoft.Storage/storageAccounts'
        $account.name | Should -BeExactly "[uniqueString(replace(parameters('tier').namingConvention.storageAccount, parameters('tokens').purpose, parameters('purpose')), resourceGroup().id)]"
        $customerHub.keyVault.Replace($tokens.purpose, 'cmk') | Should -BeExactly 'kv-scca-va-il2-hub-cmk-mlz'
        $customerHub.storageAccount.Replace($tokens.purpose, 'diag') | Should -BeExactly 'st-scca-va-il2-hub-diag-mlz'
        $customerOperations.storageAccount.Replace($tokens.purpose, 'diag') | Should -BeExactly 'st-scca-va-il2-operations-diag-mlz'
        # uniqueString returns 13 lowercase alphanumeric characters; the existing names remain within Azure limits.
        (13 + $abbreviations.keyVaults.Length) | Should -BeLessOrEqual 24
        13 | Should -BeLessOrEqual 24
    }

    It 'keeps Azure-required subnet names in the compiled Hub subnet construction' {
        $vnet = Get-NamingModule $hub 'deploy-hub-vnet-'
        $subnetExpression = $vnet.properties.parameters.subnets.value
        foreach ($name in @('AzureFirewallSubnet', 'AzureFirewallManagementSubnet', 'AzureBastionSubnet', 'GatewaySubnet')) {
            $subnetExpression | Should -Match ([regex]::Escape("'name', '$name'"))
        }
    }
}

Describe 'Customer suffix portal contract' {
    It 'keeps identifier validation and location authoritative without extra naming inputs' {
        $basics = $ui.view.properties.steps | Where-Object name -eq 'basics'
        $namingSection = $basics.elements | Where-Object name -eq 'namingSection'
        $identifier = $namingSection.elements | Where-Object name -eq 'identifier'
        $identifier.label | Should -Match 'suffix'
        $identifier.toolTip | Should -Match '1 to 5'
        $identifier.toolTip | Should -Match 'ending in -mlz'
        $identifier.constraints.validations[0].regex | Should -BeExactly '^[a-z0-9]{1,5}$'
        $ui.view.outputs.parameters.identifier | Should -BeExactly "[steps('basics').namingSection.identifier]"
        $ui.view.outputs.location | Should -BeExactly "[steps('basics').resourceScope.location.name]"
        $namingSection.elements.name | Should -Be @('identifier', 'environmentAbbreviation')
        $arm.parameters.identifier.minLength | Should -Be 1
        $arm.parameters.identifier.maxLength | Should -Be 5
    }
}
