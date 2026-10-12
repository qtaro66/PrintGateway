# Printer Commissioning Report: Epson TM-T82X (M352A)

## Scope

This report records the verified behavior of the sanitized test profile
`epson-tm-t82x-m352a-v1`. It intentionally excludes printer IP addresses,
serial numbers, MAC addresses, branch identifiers, and SNMP credentials.

Tested printer firmware: `13.07 ESC/POS`

Tested network firmware: `01.04`
Overall status: **PROVISIONAL**

`PROVISIONAL` means that the verified functions below may be used under the
stated safety policy, but this model/firmware combination is not fully
certified for every operating system and failure mode.

## Verified results

| Area | Result | Evidence-based conclusion |
|---|---:|---|
| Raw TCP transport | Pass | TCP port 9100 accepted a connection on the isolated commissioning network. A connection alone is not proof that paper was printed. |
| Thai raster output | Pass | A synthetic Thai fixture printed correctly using Noto Sans Thai Looped, 576-dot raster width, and threshold 180. Human observation confirmed Thai vowels and tone marks. |
| Paper cut | Pass | The commissioning print was physically cut. This verifies normal cutting only, not cutter-error reporting. |
| Drawer pulse | Pass | ESC/POS drawer pulse on drive pin 2 physically opened the connected drawer. |
| Drawer status | Pass | `GS r 2` mapping was physically verified: pin 3 HIGH = closed and LOW = open. |
| Cover status | Pass with limitation | SNMP Printer MIB cover status was physically verified: 3 = open and 4 = closed. `DLE EOT 2` returned no byte while the cover was open and must not be the sole cover-status method for this profile. |
| Paper status | Pass | SNMP reported level 0/status 19 when paper was absent, and level -3/status 0 when paper was restored. |
| Active paper-out alert | Pass | Printer MIB Alert Table reported code 808 with description `Roll Paper End`; restoring paper removed the active alert and returned the input unit to available/idle. |
| Safe regression suite | Pass | All 24 non-printing regression cases passed after recording the recovery result. |

## Safety policy

- A successful socket write means `SENT`; it does not mean `COMPLETED`.
- `COMPLETED` requires valid job-specific acknowledgement. This printer profile
  currently has no such acknowledgement, so automatic completion is disabled.
- Once sending has started, a timeout, invalid response, or uncertain result is
  recorded as `UNKNOWN` and must not be retried automatically.
- Before sending, detected `CoverOpen`, `PaperOut`, `CutterError`, or `Offline`
  conditions block the job.
- Hardware-print, drawer-pulse, and physical-network tests require explicit
  operator confirmation. The normal regression suite performs no printer I/O.

## Not yet verified

| Area | Status | Required evidence |
|---|---:|---|
| Cutter-error status and alert mapping | Unverified | A naturally occurring fault or a manufacturer-approved service procedure. Do not intentionally jam the cutter. |
| Windows production service path | Unverified | End-to-end run using the packaged PrintGateway service, persistent queue, restart recovery, and the target branch account. |
| Linux production service path | Unverified | Equivalent end-to-end run on the selected Linux distribution and deployment package. |
| Windows/Linux output equivalence | Unverified | Same fixture, renderer/font versions, payload hash, and physical output comparison on both platforms. |
| Static/DHCP address persistence | Unverified | Reboot and network reattachment test against the final branch addressing policy. |
| Job-specific print completion | Unsupported by current evidence | A protocol response that identifies and acknowledges the exact print job. Printer-ready status or disappearance of an alert is insufficient. |

## Release decision

The verified profile is suitable for continued development and controlled
pilot testing. It is not yet suitable for marking print jobs automatically
`COMPLETED`, nor for declaring full Windows/Linux certification. The profile
must remain `provisional` until the remaining evidence is collected and
reviewed.
