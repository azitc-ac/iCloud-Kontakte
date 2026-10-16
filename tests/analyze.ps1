# Statische Analyse (PowerShell-AST) fuer tests/test_repo_checks.py. Ausgabe: je Zeile "KIND|datei|text".
param([Parameter(Mandatory)][string]$Files)
$reserved = 'home', 'host', 'args', 'input', 'error', 'event', 'sender', 'matches', 'pid', 'pshome', 'profile', 'pwd',
    'this', 'true', 'false', 'null', 'foreach', 'switch', 'psitem', 'myinvocation', 'pscmdlet', 'shellid', 'stacktrace',
    'lastexitcode', 'executioncontext', 'consolefilename', 'nestedpromptlevel', 'psboundparameters', 'psscriptroot',
    'pscommandpath', 'psversiontable', 'env'
foreach ($f in ($Files -split ";")) {
    $name = Split-Path $f -Leaf
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) { "SYNTAX|$name|Zeile $($e.Extent.StartLineNumber): $($e.Message)" }
    $isAssign = { param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] }
    foreach ($a in $ast.FindAll($isAssign, $true)) {
        foreach ($v in $a.Left.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            if ($v.VariablePath.UserPath.ToLowerInvariant() -in $reserved -and -not $v.VariablePath.IsScript) {
                "RESERVED|$name|Zeile $($v.Extent.StartLineNumber): Zuweisung an `$$($v.VariablePath.UserPath)"
            }
        }
    }
    foreach ($fe in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        if ($fe.Variable.VariablePath.UserPath.ToLowerInvariant() -in $reserved) { "RESERVED|$name|Zeile $($fe.Extent.StartLineNumber): foreach-Variable `$$($fe.Variable.VariablePath.UserPath)" }
    }
    foreach ($p in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
        $pn = $p.Name.VariablePath.UserPath
        if ($pn.ToLowerInvariant() -in $reserved) { "RESERVED|$name|Zeile $($p.Extent.StartLineNumber): Parameter `$$pn" }
    }
    if ($ast.ParamBlock) { foreach ($p in $ast.ParamBlock.Parameters) { "PARAM|$name|$($p.Name.VariablePath.UserPath)" } }
}
