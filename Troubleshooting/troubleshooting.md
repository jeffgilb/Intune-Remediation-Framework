# Intune Remediation Troubleshooting

For Intune Remediations, use the workflow below when troubleshooting a device. It follows the remediation lifecycle from assignment through script execution, reporting, and the next scheduled evaluation.

## High-Level Workflow

```text
Intune Service
   |
   v
Policy Assignment
   |
   v
IME Policy Sync
(IntuneManagementExtension.log)
   |
   v
Scripts Downloaded
(C:\Windows\IMECache\HealthScripts)
   |
   v
Detection Script Runs
(AgentExecutor.log / HealthScripts.log)
   |
   +-- Exit 0 = Compliant --> Report Success
   |
   +-- Exit 1 = Issue Found
           |
           v
      Remediation Script Runs
      (AgentExecutor.log)
           |
           v
      Results Reported
      (HealthScripts.log)
           |
           v
      Next Scheduled Evaluation
```

A remediation script runs only when the detection script exits with code 1. If detection returns exit code 0, remediation is skipped.

## Log Investigation Path

### 1. Get the Remediation GUID
You can identify the GUID of an Intune Remediation from the Intune admin center browser address bar. The GUID is useful when troubleshooting policy deployment, reviewing logs, or locating the downloaded scripts.

**From the Intune Admin Center**

1. Navigate to Devices â†’ Scripts and remediations â†’ Remediations.
2. Select the remediation script.
3. In the browser address bar, locate the value after /id/. This value is the remediation GUID.

**Example**
```text
https://intune.microsoft.com/#view/Microsoft_Intune_Enrollment/UXAnalyticsScriptMenu/~/overview/id/23105e5c-553d-4b05-ac3e-09c677ef0ab4/scriptName/Autopatch%20Health%20Check/isFirstParty~/false
```

**GUID**
```text
23105e5c-553d-4b05-ac3e-09c677ef0ab4
```

### 2. IntuneManagementExtension.log

**Location**

```text
C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log
```

Use this log to determine:

- Whether the device received the policy
- Whether IME successfully synced
- Whether the remediation assignment was evaluated
- Whether download or processing failures occurred

**Useful search terms:**

- HealthScripts
- Remediation
- Policy
- Assignment

Start here when you need to determine whether the device knows about the remediation assignment.

### 3. Verify Script Download

Check the remediation cache:

```text
C:\Windows\IMECache\HealthScripts
```

A package is typically stored in a GUID-named folder containing the detection and remediation scripts:

```text
C:\Windows\IMECache\HealthScripts\<GUID>\
    DetectionScript.ps1
    RemediationScript.ps1
```

- Confirm the scripts downloaded
- Confirm the content is the expected version
- Confirm the detection and remediation files are present

If the expected package is absent, focus on assignment, IME synchronization, or download processing.

### 4. HealthScripts.log

```text
C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\HealthScripts.log
```

This is the primary remediation-specific lifecycle log. Review it for policy processing, detection execution, detection output and exit code, remediation launch, remediation results, and status reporting.

```text
Detection Script Exit Code: 1
Launching remediation script

Detection Script Exit Code: 0
Remediation skipped
```

### 5. AgentExecutor.log

```text
C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log
```

Use this log for the PowerShell execution layer. Look for script output, exceptions, exit codes, access-denied errors, missing paths, registry errors, and execution-context problems.

## Registry Validation

IME script policy data can be inspected under:

```text
HKLM\SOFTWARE\Microsoft\IntuneManagementExtension\SideCarPolicies\Scripts
```

Use this area to confirm that policy data exists and to correlate package identifiers and updates. The remediation framework examples also record checkpoints under:

```text
HKLM\SOFTWARE\<COMPANY>\IntuneRemediations\<ScriptName>
```

Checkpoint values can help confirm the last detection and remediation results, run times, correlation Id's, script version, and more.

## Troubleshooting Decision Tree

### Remediation never runs

- Confirm the device or user assignment in Intune
- Review IntuneManagementExtension.log
- Review HealthScripts.log
- Verify that the Microsoft Intune Management Extension service is installed and running

### Detection runs but remediation never runs

Review HealthScripts.log for the detection exit code. Exit 0 means compliant and skips remediation. Exit 1 means an issue was detected and remediation should run.

### Remediation runs but doesn't fix the issue

- Review AgentExecutor.log
- Review the script-specific error log, such as C:\Logs\IR\<logname>_ERR.log
- Check exceptions, access problems, validation failures, and user-versus-system execution context

## Fastest Troubleshooting Path

1. `HealthScripts.log`
2. `AgentExecutor.log`
3. `C:\Windows\IMECache\HealthScripts`
4. `IntuneManagementExtension.log`
5. `Registry checkpoint key`

This sequence usually answers the key questions: Was the remediation assigned? Did detection run? What exit code was returned? Did remediation launch? What error occurred?

## Collect-RemediationLogs
This script (available in the PowerShell Gallery) collects Microsoft Intune Management Extension and Remediation troubleshooting information from a Windows endpoint.
    
The script collects:
- Remediation-related Intune Management Extension logs
- Custom Intune Remediation logs [$customLogPath]
- Custom registry checkpoint paths [$checkpointPath]
- IME service information
- HealthScripts cache inventory
- Script package file hashes
- Relevant registry information
- DeviceManagement Enterprise Diagnostics event log
- Device and enrollment summary
- Recent IME log entries containing remediation-related terms

Run this from an elevated PowerShell session. It creates a timestamped ZIP file in C:\Windows\Temp by default.

**TIP:**

    You can run this script as System from an elevated PowerShell console using PSExec64.exe by adding the -System command line switch to collect the cached detection and remediation script files along with the logs.

Install from the PowerShell Gallery:

    Install-Script Collect-RemediationLogs

Just save it locally so you can run it on remote devices (recommended for this one): 

    Save-Script Collect-RemediationLogs –Path <path>

Run it:

    Collect-RemediationLogs
    
   or from an admin PowerShell console:

    Collect-RemediationLogs -System (this grabs the actual remediaton scripts too)

## References

- [Microsoft Learn: Use Remediations to detect and fix support issues](https://learn.microsoft.com/en-us/intune/device-management/tools/deploy-remediations)
- [Microsoft Learn: Understand Microsoft Intune Management Extension](https://learn.microsoft.com/en-us/intune/device-management/tools/management-extension-windows)

