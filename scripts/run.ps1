$ErrorActionPreference = 'Stop'

. $PSScriptRoot\helpers.ps1

$stepsConfig = $env:STEPS_CONFIG
$jobs = [JobParser]::ParseYaml($stepsConfig)
$runner = [JobRunner]::new($jobs)
$runner.Run()