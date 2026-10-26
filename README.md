# Jeff's Intune Remediation Framework
AKA Intune Remediations at Scale Best Practices, Pitfalls, and Engineering Patterns

## Level 100: The warm up
*What Even is a Remediation?* Does this count?

Detect Lightly. Remediate Gently. Exit Predictably.
- Minimalistic detection
- Minimalistic remediation
- Deterministic exit codes 

## Level 200: Detection, Remediation, and Receipts.
*The ‘Okay, Now We’re Doing This’ Level*

Detection and remediation scripts that don’t break things
- Minimal error handling (Try, Catch)
- Basic logging (console transcript to IME logs directory)
- Basic detection output to Intune admin center (PASS or FAIL w/short message)

## Level 300: The ‘You’re In Too Deep to Back Out’ Level
*Watch Intune clean up your environment like it’s tired of your nonsense.*

Functions, Logs, Versions… Adult Supervision
- Comment-based help 
- Functions in regions for reusable logic readability 
    - Automatic 64-bit PowerShell relaunch
    - Custom log directory
    - CMTrace-compatible logging
    - Useful Intune output (aggregate and emit once)
- Version tracking
- Default compliance state
- Basic log clean-up (no detection error = no log)
- Turn on/off interactive logging to console

## Level 400: The ‘Jeff Has Entered the Chat’ Level
*Enterprise‑Grade Wizardry: Remediations That Scare Your Security Team.*

Telemetry That Keeps You Out of Trouble
- Registry Checkpointing
    - Script version used
    - Remediation begin / end times / exit codes
    - Total execution duration
    - Last run results tracking
    - Remediation run count
    - Run ID
    - All available automagically from the Intune admin center
- Correlation IDs to match logs to registry
- Advanced log management
    - Optional verbose Logging  
    - Aged remediation log clean-up

## Scripts
### Create-IntuneRemediation
Install from the PowerShell Gallery (recommended so you can run it repeatedly easily):

    Install-Script Create-IntuneRemediation
    
Or just save it locally to have a look:

    Save-Script Create-IntuneRemediation –Path <path>

Run it:

    Create-IntuneRemediation -WorkspaceName <MyWorkspaceName>

### Collect-RemediationLogs
Install from the PowerShell Gallery:

    Install-Script Collect-RemediationLogs

Just save it locally so you can run it on remote devices (recommended for this one): 

    Save-Script Collect-RemediationLogs –Path <path>

Run it:

    Collect-RemediationLogs
    
   or from an admin PowerShell console:

    Collect-RemediationLogs -System (this grabs teh actual remediaton scripts too)