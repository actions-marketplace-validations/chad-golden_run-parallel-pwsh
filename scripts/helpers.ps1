using namespace System.Collections.Generic

class JobDefinition {
  [string]$Name
  [string]$Script
  [string[]]$Needs
  [string]$Status = 'Pending'
  [System.Management.Automation.Job]$Job
  [DateTime]$StartTime
  [DateTime]$EndTime

  JobDefinition([string]$name) {
    $this.Name = $name
    $this.Needs = @()
  }

  [bool]AreDependenciesMet([Dictionary[string, JobDefinition]]$allJobs) {
    if ($this.Needs.Count -eq 0) { return $true }
    return -not ($this.Needs | Where-Object { $allJobs[$_].Status -ne 'Completed' })
  }
}

class GitHubActionsLogger {
  static [void] WriteGroup([string]$name) {
    Write-Host "::group::$name"
  }

  static [void] WriteEndGroup([string]$name) {
    Write-Host "::endgroup::$name"
  }

  static [void] WriteDebug([string]$message) {
    Write-Host "::debug::$message"
  }

  static [void] WriteError([string]$message) {
    Write-Host "::error::$message"
  }
}

class JobSummaryGenerator {
  [Dictionary[string, JobDefinition]]$jobs

  JobSummaryGenerator([Dictionary[string, JobDefinition]]$jobs) {
    $this.jobs = $jobs
  }

  [string]GenerateMermaidGanttChart([DateTime]$firstStart) {
    $chart = @"
```````mermaid
gantt
    title Job Execution Timeline
    dateFormat ss.SSS
    axisFormat %S.%L
"@
    $sortedJobsThatCompleted = $this.GetSortedJobs() | Where-Object { $_.StartTime -ne [DateTime]::MinValue -and $_.EndTime -ne [DateTime]::MinValue } 
    foreach ($job in $sortedJobsThatCompleted) {
      $relativeStartMs = [Math]::Round(($job.StartTime - $firstStart).TotalMilliseconds)
      $durationMs = [Math]::Round(($job.EndTime - $job.StartTime).TotalMilliseconds)
      $status = if ($job.Status -eq 'Failed') { "crit" } else { "active" }
      $timeSpan = [TimeSpan]::FromMilliseconds($relativeStartMs)
      $formattedStart = $timeSpan.ToString("ss\.fff")
            
      $chart += "`n    section $($job.Name)"
      $chart += "`n    $($job.Name) : $status, $formattedStart, ${durationMs}ms"
    }
    return $chart + "`n``````"
  }

  [string]GenerateDependencyGraph() {
    $graph = @"
```````mermaid
graph TD
"@
    foreach ($job in $this.jobs.Values) {
      $style = switch ($job.Status) {
        'Completed' { "style $($job.Name) fill:#3fb950" }
        'Failed' { "style $($job.Name) fill:#f85149" }
        default { "style $($job.Name) fill:#0d1117" }
      }
      $graph += "`n    $($job.Name)[$($job.Name)]"
      $graph += "`n    $style"
            
      foreach ($dep in $job.Needs) {
        $graph += "`n    $dep --> $($job.Name)"
      }
    }
    return $graph + "`n``````"
  }

  [JobDefinition[]]GetSortedJobs() {
    $orderedJobs = [List[string]]::new()
    
    # Helper function to add job and its dependencies in correct order
    $addJobWithDeps = {
      param([string]$jobName)
        
      # Skip if already processed
      if ($orderedJobs.Contains($jobName)) { 
        [GitHubActionsLogger]::WriteDebug("Skipping already processed job: $jobName")
        return 
      }
        
      [GitHubActionsLogger]::WriteDebug("Processing job: $jobName")
      [GitHubActionsLogger]::WriteDebug("Current ordered jobs: $($orderedJobs -join ', ')")
        
      # First add all dependencies
      foreach ($dep in $this.jobs[$jobName].Needs) {
        [GitHubActionsLogger]::WriteDebug("Processing dependency: $dep for job: $jobName")
        & $addJobWithDeps $dep
      }
        
      # Then add this job
      [GitHubActionsLogger]::WriteDebug("Adding job to ordered list: $jobName")
      $orderedJobs.Add($jobName)
    }
    
    # Process each root job
    [GitHubActionsLogger]::WriteDebug("Starting root jobs processing")
    foreach ($root in $this.GetRootJobs()) {
      [GitHubActionsLogger]::WriteDebug("Processing root job: $root")
      & $addJobWithDeps $root
    }
    
    # Process any remaining jobs that weren't reached from roots
    [GitHubActionsLogger]::WriteDebug("Starting remaining jobs processing")
    foreach ($job in $this.jobs.Keys) {
      [GitHubActionsLogger]::WriteDebug("Checking remaining job: $job")
      & $addJobWithDeps $job
    }
    
    [GitHubActionsLogger]::WriteDebug("Final ordered jobs: $($orderedJobs -join ', ')")
    
    # Convert to array of JobDefinitions in correct order
    return $orderedJobs | ForEach-Object { $this.jobs[$_] }
  }

  hidden [string[]]GetRootJobs() {
    return $this.jobs.Keys | Where-Object {
      $this.jobs[$_].Needs.Count -eq 0
    }
  }

  hidden [string[]]GetDependencyChain([string]$jobName) {
    [GitHubActionsLogger]::WriteDebug("Getting dependency chain for: $jobName")
    $chain = [List[string]]::new()
    $job = $this.jobs[$jobName]
    [GitHubActionsLogger]::WriteDebug("Job needs: $($job.Needs -join ', ')")
        
    foreach ($dep in $job.Needs) {
      [GitHubActionsLogger]::WriteDebug("Processing dependency: $dep")
      $depChain = $this.GetDependencyChain($dep)
      [GitHubActionsLogger]::WriteDebug("Dependency chain for $($dep): $($depChain -join ', ')")
      $chain.AddRange($depChain)
    }
        
    [GitHubActionsLogger]::WriteDebug("Adding $jobName to chain")
    $chain.Add($jobName)
    [GitHubActionsLogger]::WriteDebug("Final chain for $($jobName): $($chain -join ', ')")
    return $chain
  }

  [void]WriteSummary() {
    [GitHubActionsLogger]::WriteDebug("Starting job summary")

    $firstStart = ($this.jobs.Values | Where-Object { $_.StartTime -ne [DateTime]::MinValue } | Measure-Object StartTime -Minimum).Minimum
    $lastEnd = ($this.jobs.Values | Measure-Object EndTime -Maximum).Maximum
    $wallTime = $lastEnd - $firstStart
    $totalDuration = ($this.jobs.Values | Measure-Object { ($_.EndTime - $_.StartTime).TotalSeconds } -Sum).Sum
    $timeSaved = $totalDuration - $wallTime.TotalSeconds

    [GitHubActionsLogger]::WriteDebug("firstStart: $firstStart")
    [GitHubActionsLogger]::WriteDebug("lastEnd: $lastEnd")
    [GitHubActionsLogger]::WriteDebug("wallTime: $wallTime")
    [GitHubActionsLogger]::WriteDebug("totalDuration: $totalDuration")
    [GitHubActionsLogger]::WriteDebug("timeSaved: $timeSaved")

    $summary = @"
## Parallel Tasks Summary
$($this.GenerateJobsTable())

### Time Analysis
- Total job processing time: $($totalDuration.ToString("N2"))s
- Time saved through parallelization: $($timeSaved.ToString("N2"))s
- Efficiency gain: $([Math]::Round(($timeSaved / $totalDuration) * 100))%

## Task Timeline
$($this.GenerateMermaidGanttChart($firstStart))

## Task Dependency Graph
$($this.GenerateDependencyGraph())
"@

    $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
  }

  hidden [string]GenerateJobsTable() {
    $table = @"
| Task | Duration | Status | Dependencies |
|-----|----------|--------|--------------|
"@
    foreach ($job in $this.jobs.Values) {
      $duration = $job.EndTime - $job.StartTime
      $durationStr = if ($duration.Minutes -gt 0) {
        "{0}m {1}s" -f [int]$duration.Minutes, [math]::Round($duration.TotalSeconds % 60)
      }
      else {
        "{0}s" -f [math]::Round($duration.TotalSeconds)
      }
            
      $status = switch ($job.Status) {
        'Completed' { "✅" }
        'Failed' { "❌" }
        default { "❓" }
      }
            
      $deps = if ($job.Needs.Count -gt 0) { 
        $job.Needs -join ", " 
      }
      else { 
        "none" 
      }
            
      $table += "`n| $($job.Name) | $durationStr | $status | $deps |"
    }
    return $table
  }
}

class JobParser {
  static [Dictionary[string, JobDefinition]]ParseYaml([string]$yaml) {
    $jobs = [Dictionary[string, JobDefinition]]::new()
    $currentJob = $null
    $inScript = $false
        
    $lines = $yaml -split "`n" | ForEach-Object { $_ -replace '\r$', '' }
        
    foreach ($line in $lines) {
      if ($line -match '^(\w+[-\w]*):$') {
        $currentJob = [JobDefinition]::new($matches[1])
        $inScript = $false
        $jobs[$currentJob.Name] = $currentJob
      }
      elseif ($line -match '^\s{2}needs:\s*\[?(.*?)\]?$') {
        $needsStr = $matches[1].Trim()
        if ($needsStr) {
          $currentJob.Needs = @($needsStr -split ',' | ForEach-Object { $_.Trim(' []') })
        }
      }
      elseif ($line -match '^\s{2}run:\s*\|?$') {
        $inScript = $true
      }
      elseif ($inScript -and $line -match '^(\s{4,})(.*)') {
        $currentJob.Script += $matches[2] + "`n"
      }
    }
        
    foreach ($job in $jobs.Values) {
      $job.Script = ($job.Script ?? "").TrimEnd()
    }
        
    return $jobs
  }
}

class JobRunner {
  [Dictionary[string, JobDefinition]]$jobs
  [bool]$summaryWritten = $false

  JobRunner([Dictionary[string, JobDefinition]]$jobs) {
    $this.jobs = $jobs
  }

  [void]Run() {
    try {
      $running = $true
      while ($running) {
        $running = $false

        $this.CheckCompletedJobs([ref]$running)
        $this.StartNewJobs([ref]$running)
                
        if ($running) {
          Start-Sleep -Milliseconds 10
        }
      }
    }
    catch {
      if (-not $this.summaryWritten) {
        $this.WriteSummary()
      }
      throw
    }
    finally {
      if (-not $this.summaryWritten) {
        $this.WriteSummary()
      }
    }
  }

  hidden [void]CheckCompletedJobs([ref]$running) {
    foreach ($job in $this.jobs.Values | Where-Object { $_.Status -eq 'Running' }) {
      if ($job.Job.State -eq 'Completed') {
        $this.HandleCompletedJob($job)
      }
      elseif ($job.Job.State -eq 'Failed') {
        $this.HandleFailedJob($job)
      }
      else {
        $running.Value = $true
      }
    }
  }

  hidden [void]HandleCompletedJob([JobDefinition]$job) {
    $job.EndTime = Get-Date
    $result = Receive-Job -Job $job.Job
    [GitHubActionsLogger]::WriteGroup("Output from $($job.Name)")
    $result | ForEach-Object { Write-Host $_ }
    [GitHubActionsLogger]::WriteEndGroup("Output from $($job.Name)")
                
    if ($job.Job.ChildJobs[0].Error) {
      $job.Status = 'Failed'
      $errorMsg = $job.Job.ChildJobs[0].Error.Exception.Message
      [GitHubActionsLogger]::WriteError("Job $($job.Name) failed: $errorMsg")
      [GitHubActionsLogger]::WriteDebug("Full error details for $($job.Name):")
      [GitHubActionsLogger]::WriteDebug($job.Job.ChildJobs[0].Error)
      throw "Some jobs did not complete successfully"
    }
    else {
      $job.Status = 'Completed'
      [GitHubActionsLogger]::WriteDebug("Job $($job.Name) completed successfully")
    }
  }

  hidden [void]HandleFailedJob([JobDefinition]$job) {
    $job.EndTime = Get-Date
    $job.Status = 'Failed'
    [GitHubActionsLogger]::WriteError("Job $($job.Name) failed")
    throw "Some jobs did not complete successfully"
  }

  hidden [void]StartNewJobs([ref]$running) {
    foreach ($job in $this.jobs.Values | Where-Object { $_.Status -eq 'Pending' }) {
      if ($job.AreDependenciesMet($this.jobs)) {
        $this.StartJob($job)
        $running.Value = $true
      }
    }
  }

  hidden [void]StartJob([JobDefinition]$job) {
    Write-Host "Starting $($job.Name)" -ForegroundColor Cyan
        
    $scriptPath = [System.IO.Path]::GetTempFileName() + '.ps1'
    $job.Script | Out-File -FilePath $scriptPath -Encoding UTF8
        
    $job.StartTime = Get-Date
    $job.Job = Start-Job -ScriptBlock {
      param($scriptPath)
      . $scriptPath
    } -ArgumentList $scriptPath
        
    $job.Status = 'Running'
  }

  hidden [void]WriteSummary() {
    $generator = [JobSummaryGenerator]::new($this.jobs)
    $generator.WriteSummary()
    $this.summaryWritten = $true
  }
}