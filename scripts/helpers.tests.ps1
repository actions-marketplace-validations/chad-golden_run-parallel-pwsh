using namespace System.Collections.Generic

BeforeAll {
  # Set up GitHub Actions environment
  $env:GITHUB_ACTIONS = $true
  $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'step-summary.md'
    
  # Create empty summary file
  New-Item -Path $env:GITHUB_STEP_SUMMARY -ItemType File -Force

  . $PSScriptRoot/helpers.ps1
}

AfterAll {
  Remove-Item -Path $env:GITHUB_STEP_SUMMARY -Force -ErrorAction SilentlyContinue
  Remove-Item -Path "$TestDrive\*.ps1" -Force -ErrorAction SilentlyContinue
}

Describe 'JobDefinition' {
  Context 'Constructor' {
    It 'Creates a new job with default values' {
      $job = [JobDefinition]::new('test-job')
      $job.Name | Should -Be 'test-job'
      $job.Status | Should -Be 'Pending'
      $job.Needs | Should -BeNullOrEmpty
      $job.Job | Should -BeNullOrEmpty
      $job.StartTime | Should -Be ([DateTime]::MinValue)
      $job.EndTime | Should -Be ([DateTime]::MinValue)
    }
  }

  Context 'AreDependenciesMet' {
    It 'Returns true when there are no dependencies' {
      $job = [JobDefinition]::new('solo-job')
      $allJobs = [Dictionary[string, JobDefinition]]::new()
      $allJobs['solo-job'] = $job
            
      $job.AreDependenciesMet($allJobs) | Should -Be $true
    }

    It 'Returns true when all dependencies are completed' {
      $allJobs = [Dictionary[string, JobDefinition]]::new()
            
      $dep1 = [JobDefinition]::new('dep1')
      $dep1.Status = 'Completed'
      $allJobs['dep1'] = $dep1
            
      $dep2 = [JobDefinition]::new('dep2')
      $dep2.Status = 'Completed'
      $allJobs['dep2'] = $dep2
            
      $job = [JobDefinition]::new('dependent-job')
      $job.Needs = @('dep1', 'dep2')
      $allJobs['dependent-job'] = $job
            
      $job.AreDependenciesMet($allJobs) | Should -Be $true
    }

    It 'Returns false when any dependency is not completed' {
      $allJobs = [Dictionary[string, JobDefinition]]::new()
            
      $dep1 = [JobDefinition]::new('dep1')
      $dep1.Status = 'Completed'
      $allJobs['dep1'] = $dep1
            
      $dep2 = [JobDefinition]::new('dep2')
      $dep2.Status = 'Running'
      $allJobs['dep2'] = $dep2
            
      $job = [JobDefinition]::new('dependent-job')
      $job.Needs = @('dep1', 'dep2')
      $allJobs['dependent-job'] = $job
            
      $job.AreDependenciesMet($allJobs) | Should -Be $false
    }
  }
}

Describe 'JobParser' {
  Context 'ParseYaml' {
    It 'Parses basic YAML correctly' {
      $yaml = @'
job1:
  run: |
    Write-Host "Hello"
job2:
  needs: [job1]
  run: |
    Write-Host "World"
'@
      $jobs = [JobParser]::ParseYaml($yaml)
      $jobs.Count | Should -Be 2
      $jobs['job1'].Name | Should -Be 'job1'
      $jobs['job2'].Needs | Should -Contain 'job1'
      $jobs['job1'].Script.Trim() | Should -Be 'Write-Host "Hello"'
    }

    It 'Handles empty needs' {
      $yaml = @'
job1:
  needs:
  run: |
    Write-Host "Test"
'@
      $jobs = [JobParser]::ParseYaml($yaml)
      $jobs['job1'].Needs | Should -BeNullOrEmpty
    }

    It 'Handles multiple dependencies' {
      $yaml = @'
job1:
  run: |
    Write-Host "First"
job2:
  run: |
    Write-Host "Second"
job3:
  needs: [job1, job2]
  run: |
    Write-Host "Third"
'@
      $jobs = [JobParser]::ParseYaml($yaml)
      $jobs['job3'].Needs.Count | Should -Be 2
      $jobs['job3'].Needs | Should -Contain 'job1'
      $jobs['job3'].Needs | Should -Contain 'job2'
    }
  }
}

Describe 'JobSummaryGenerator' {
  BeforeAll {
    $jobs = [Dictionary[string, JobDefinition]]::new()
        
    $job1 = [JobDefinition]::new('job1')
    $job1.Status = 'Completed'
    $job1.StartTime = Get-Date
    $job1.EndTime = $job1.StartTime.AddSeconds(5)
    $jobs['job1'] = $job1
        
    $job2 = [JobDefinition]::new('job2')
    $job2.Status = 'Failed'
    $job2.Needs = @('job1')
    $job2.StartTime = $job1.EndTime
    $job2.EndTime = $job2.StartTime.AddSeconds(3)
    $jobs['job2'] = $job2

    $generator = [JobSummaryGenerator]::new($jobs)
    Write-Debug "generator intialized: $generator"
  }

  It 'Generates valid Mermaid Gantt chart' {
    $chart = $generator.GenerateMermaidGanttChart($jobs['job1'].StartTime)
    $chart | Should -Match 'gantt'
    $chart | Should -Match 'job1'
    $chart | Should -Match 'job2'
    $chart | Should -Match 'dateFormat ss\.SSS'
  }

  It 'Generates valid dependency graph' {
    $graph = $generator.GenerateDependencyGraph()
    $graph | Should -Match 'graph TD'
    $graph | Should -Match 'job1\[job1\]'
    $graph | Should -Match 'job1 --> job2'
    $graph | Should -Match 'style job1 fill:#3fb950'  # Completed jobs are green
    $graph | Should -Match 'style job2 fill:#f85149'  # Failed jobs are red
  }

  It 'Returns jobs in correct dependency order' {
    $sortedJobs = $generator.GetSortedJobs()
    $sortedJobs[0].Name | Should -Be 'job1'
    $sortedJobs[1].Name | Should -Be 'job2'
  }

  It 'Identifies root jobs correctly' {
    $rootJobs = $generator.GetRootJobs()
    $rootJobs.Count | Should -Be 1
    $rootJobs | Should -Contain 'job1'
  }
}

Describe 'JobRunner Integration Tests' {
  BeforeEach {
    # Reset environment for each test
    $env:STEPS_CONFIG = $null
        
    # Ensure summary file exists and is empty
    Set-Content -Path $env:GITHUB_STEP_SUMMARY -Value ''
  }

  It 'Successfully runs a simple job chain' {
    $yaml = @'
job1:
  run: |
    Write-Host "Step 1"
job2:
  needs: [job1]
  run: |
    Write-Host "Step 2"
job3:
  needs: [job2]
  run: |
    Write-Host "Step 3"
'@
    $env:STEPS_CONFIG = $yaml

    $jobs = [JobParser]::ParseYaml($yaml)
    $runner = [JobRunner]::new($jobs)
        
    { $runner.Run() } | Should -Not -Throw
    $jobs['job3'].Status | Should -Be 'Completed'
  }

  It 'Handles parallel execution correctly' {
    $yaml = @'
parallel1:
  run: |
    Write-Host "Parallel 1"
    Start-Sleep -Milliseconds 100
parallel2:
  run: |
    Write-Host "Parallel 2"
    Start-Sleep -Milliseconds 100
final:
  needs: [parallel1, parallel2]
  run: |
    Write-Host "Final Step"
'@
    $env:STEPS_CONFIG = $yaml

    $jobs = [JobParser]::ParseYaml($yaml)
    $runner = [JobRunner]::new($jobs)
        
    { $runner.Run() } | Should -Not -Throw
    $jobs['final'].Status | Should -Be 'Completed'
        
    # Verify parallel jobs ran before final
    $jobs['parallel1'].EndTime | Should -BeLessThan $jobs['final'].StartTime
    $jobs['parallel2'].EndTime | Should -BeLessThan $jobs['final'].StartTime
  }

  It 'Handles job failures correctly' {
    $yaml = @'
pre-build:
  run: |
    Write-Output 'Doing pre-build things'
build:
  needs: [pre-build]
  run: |
test-group-1:
  needs: [build]
  run: |
test-group-2:
  needs: [build]
  run: |
    throw 'Unexpected failure'
summary:
  needs: [test-group-1, test-group-2]
  run: |
    Write-Output "Summary uploaded"
'@
    $env:STEPS_CONFIG = $yaml

    $jobs = [JobParser]::ParseYaml($yaml)
    $runner = [JobRunner]::new($jobs)
        
    { $runner.Run() } | Should -Throw "Some jobs did not complete successfully"
    $jobs['pre-build'].Status | Should -Be 'Completed'
    $jobs['build'].Status | Should -Be 'Completed'
    $jobs['test-group-1'].Status | Should -Be 'Completed'
    $jobs['test-group-2'].Status | Should -Be 'Failed'
    $jobs['summary'].Status | Should -Be 'Pending'
  }

  It 'Handles first job failing' {
    $yaml = @'
pre-build:
  run: |
    throw 'Unexpected failure'
build:
  needs: [pre-build]
  run: |
test-group-1:
  needs: [build]
  run: |
test-group-2:
  needs: [build]
  run: |
summary:
  needs: [test-group-1, test-group-2]
  run: |
'@
    $env:STEPS_CONFIG = $yaml

    $jobs = [JobParser]::ParseYaml($yaml)
    $runner = [JobRunner]::new($jobs)
        
    { $runner.Run() } | Should -Throw "Some jobs did not complete successfully"
    $jobs['pre-build'].Status | Should -Be 'Failed'
    $jobs['build'].Status | Should -Be 'Pending'
    $jobs['test-group-1'].Status | Should -Be 'Pending'
    $jobs['test-group-2'].Status | Should -Be 'Pending'
    $jobs['summary'].Status | Should -Be 'Pending'
  }

  It 'Does not render timeline with incomplete jobs' {
        $yaml = @'
build:
  run: |
    throw 'Failure'
post-summary-output:
  needs: [build]
  run: |
'@
    $env:STEPS_CONFIG = $yaml

    $jobs = [JobParser]::ParseYaml($yaml)
    $runner = [JobRunner]::new($jobs)

    { $runner.Run() } | Should -Throw "Some jobs did not complete successfully"
    $jobs['post-summary-output'].Status | Should -Be 'Pending'
    $env:GITHUB_STEP_SUMMARY | Should -Not -FileContentMatch "section post-summary-output"
    $env:GITHUB_STEP_SUMMARY | Should -Not -FileContentMatch "post-summary-output : active"
  }
}