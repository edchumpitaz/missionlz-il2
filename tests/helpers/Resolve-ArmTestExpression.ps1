# Evaluates only the compiled ARM expression subset used by topology tests.
# Unsupported functions fail rather than substituting success-shaped values.
function Resolve-ArmTestExpression {
    param($Value, [hashtable]$Context)

    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) {
            $result[$key] = Resolve-ArmTestExpression $Value[$key] $Context
        }
        return $result
    }
    if ($Value -is [array]) {
        return ,@($Value | ForEach-Object { Resolve-ArmTestExpression $_ $Context })
    }
    if ($Value -isnot [string] -or -not $Value.StartsWith('[')) { return ,$Value }

    $expression = $Value.Substring(1, $Value.Length - 2)
    $tokens = [System.Collections.Generic.List[object]]::new()
    $pattern = "\G\s*(?:'(?<string>(?:''|[^'])*)'|(?<word>[A-Za-z_][A-Za-z_0-9]*)|(?<number>-?\d+)|(?<punct>[(),.\[\]]))"
    $tokenizer = [regex]::new($pattern, 'None', [timespan]::FromSeconds(1))
    $offset = 0
    while ($offset -lt $expression.Length) {
        $match = $tokenizer.Match($expression, $offset)
        if (-not $match.Success) { throw "Unsupported ARM syntax at offset ${offset}: $Value" }
        $kind = @(@('string', 'word', 'number', 'punct') | Where-Object { $match.Groups[$_].Success })
        $tokens.Add(@{ Kind = $kind[0]; Text = $match.Groups[$kind[0]].Value })
        $offset = $match.Index + $match.Length
    }
    $position = 0
    $node = Read-ArmTestNode $tokens ([ref]$position)
    if ($position -ne $tokens.Count) { throw "Unconsumed ARM tokens: $Value" }
    return ,(Invoke-ArmTestNode $node $Context @{})
}

function Read-ArmTestNode {
    param($Tokens, [ref]$Position)

    $token = $Tokens[$Position.Value++]
    switch ($token.Kind) {
        string { $node = @{ Kind = 'literal'; Value = $token.Text.Replace("''", "'") } }
        number { $node = @{ Kind = 'literal'; Value = [int]$token.Text } }
        word {
            if ($Tokens[$Position.Value++].Text -ne '(') { throw 'Expected ARM function call' }
            $arguments = [System.Collections.Generic.List[object]]::new()
            if ($Tokens[$Position.Value].Text -ne ')') {
                do {
                    $arguments.Add((Read-ArmTestNode $Tokens $Position))
                    $separator = $Tokens[$Position.Value++].Text
                } while ($separator -eq ',')
                if ($separator -ne ')') { throw 'Expected closing ARM parenthesis' }
            } else { $Position.Value++ }
            $node = @{ Kind = 'call'; Name = $token.Text; Arguments = $arguments }
        }
        default { throw "Unexpected ARM token: $($token.Text)" }
    }
    while ($Position.Value -lt $Tokens.Count) {
        $next = $Tokens[$Position.Value].Text
        if ($next -eq '.') {
            $Position.Value++
            $node = @{ Kind = 'property'; Source = $node; Key = @{ Kind = 'literal'; Value = $Tokens[$Position.Value++].Text } }
        } elseif ($next -eq '[') {
            $Position.Value++
            $key = Read-ArmTestNode $Tokens $Position
            if ($Tokens[$Position.Value++].Text -ne ']') { throw 'Expected closing ARM index' }
            $node = @{ Kind = 'property'; Source = $node; Key = $key }
        } else { break }
    }
    return $node
}

function Invoke-ArmTestNode {
    param($Node, [hashtable]$Context, [hashtable]$Locals)

    if ($Node.Kind -eq 'literal') { return ,$Node.Value }
    if ($Node.Kind -eq 'property') {
        $source = Invoke-ArmTestNode $Node.Source $Context $Locals
        $key = Invoke-ArmTestNode $Node.Key $Context $Locals
        if ($source -is [array] -and ($key -lt 0 -or $key -ge $source.Count)) { throw "Invalid ARM index: $key" }
        if ($source -is [hashtable] -and -not $source.ContainsKey($key)) { throw "Missing ARM property: $key" }
        return ,$source[$key]
    }
    $nodes = $Node.Arguments
    if ($Node.Name -eq 'if') {
        $branch = if (Invoke-ArmTestNode $nodes[0] $Context $Locals) { 1 } else { 2 }
        return ,(Invoke-ArmTestNode $nodes[$branch] $Context $Locals)
    }
    if ($Node.Name -in @('map', 'filter', 'toObject')) {
        $items = Invoke-ArmTestNode $nodes[0] $Context $Locals
        $result = [System.Collections.Generic.List[object]]::new()
        $object = @{}
        foreach ($item in $items) {
            $lambda = $nodes[1]
            $nestedLocals = $Locals.Clone()
            $nestedLocals[$lambda.Arguments[0].Value] = $item
            $mapped = Invoke-ArmTestNode $lambda.Arguments[1] $Context $nestedLocals
            switch ($Node.Name) {
                map { $result.Add($mapped) }
                filter { if ($mapped) { $result.Add($item) } }
                toObject {
                    $valueLambda = $nodes[2]
                    $nestedLocals[$valueLambda.Arguments[0].Value] = $item
                    $object[$mapped] = Invoke-ArmTestNode $valueLambda.Arguments[1] $Context $nestedLocals
                }
            }
        }
        if ($Node.Name -eq 'toObject') { return $object }
        return ,$result.ToArray()
    }
    $values = [System.Collections.Generic.List[object]]::new()
    foreach ($argument in $nodes) { $values.Add((Invoke-ArmTestNode $argument $Context $Locals)) }
    switch ($Node.Name) {
        parameters {
            $name = $values[0]
            if ($Context.Parameters.ContainsKey($name)) { return ,$Context.Parameters[$name] }
            $definition = $Context.Template.parameters[$name]
            if (-not $definition.ContainsKey('defaultValue')) { throw "Missing ARM test parameter: $name" }
            return ,(Resolve-ArmTestExpression $definition.defaultValue $Context)
        }
        variables {
            $name = $values[0]
            if ($Context.Template.variables.ContainsKey($name)) {
                return ,(Resolve-ArmTestExpression $Context.Template.variables[$name] $Context)
            }
            $loop = @($Context.Template.variables.copy | Where-Object name -eq $name)
            if ($loop.Count -ne 1) { throw "Missing ARM variable: $name" }
            $count = Resolve-ArmTestExpression $loop[0].count $Context
            $result = @()
            for ($i = 0; $i -lt $count; $i++) {
                $nestedContext = $Context.Clone()
                $nestedContext.CopyIndex = $i
                $result += ,(Resolve-ArmTestExpression $loop[0].input $nestedContext)
            }
            return ,$result
        }
        lambdaVariables { return ,$Locals[$values[0]] }
        copyIndex { return $Context.CopyIndex }
        createArray { return ,$values.ToArray() }
        createObject {
            $result = @{}
            for ($i = 0; $i -lt $values.Count; $i += 2) { $result[$values[$i]] = $values[$i + 1] }
            return $result
        }
        union {
            $result = @{}
            foreach ($value in $values) {
                if ($value -isnot [System.Collections.IDictionary]) { throw 'ARM test union supports naming objects only' }
                foreach ($key in $value.Keys) {
                    if ($value[$key] -is [System.Collections.IDictionary]) { throw 'ARM test union does not support nested objects' }
                    $result[$key] = $value[$key]
                }
            }
            return $result
        }
        concat {
            $result = @()
            foreach ($value in $values) { $result += $value }
            return ,$result
        }
        equals { return ($values[0] -ceq $values[1]) }
        and { return (-not ($values -contains $false)) }
        or { return ($values -contains $true) }
        not { return (-not $values[0]) }
        true { return $true }
        false { return $false }
        contains { return ($values[0] -contains $values[1]) }
        length {
            if ($values[0] -is [string]) { return $values[0].Length }
            return $values[0].Count
        }
        toLower { return $values[0].ToLowerInvariant() }
        empty { return ($null -eq $values[0] -or $values[0].Length -eq 0) }
        first {
            if ($values[0] -is [string]) { return $values[0].Substring(0, 1) }
            return ,$values[0][0]
        }
        indexOf { return [array]::IndexOf($values[0], $values[1]) }
        range {
            $result = @()
            for ($i = 0; $i -lt $values[1]; $i++) { $result += $values[0] + $i }
            return ,$result
        }
        sub { return $values[0] - $values[1] }
        split { return ,$values[0].Split($values[1]) }
        replace {
            if ($values[1] -eq '') { return $values[0] }
            return $values[0].Replace($values[1], $values[2])
        }
        format { return [string]::Format($values[0], [object[]]$values.GetRange(1, $values.Count - 1).ToArray()) }
        newGuid { return [guid]::NewGuid().ToString() }
        default { throw "Unsupported ARM test function: $($Node.Name)" }
    }
}
