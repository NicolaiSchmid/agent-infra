# Phone SBC on black

`hosts/black/phone-sbc.nix` persists the LiveKit leg of the synthetic-call
spike as the native NixOS `asterisk.service`. It uses the flake's pinned
Asterisk package, required SDES-SRTP and TLS server verification. There is no
Docker image to update or recording dialplan. CDR and CEL storage are disabled.

## Current boundary

This is an outbound test SBC, not a carrier-ready public receptionist.
Its SIP transport binds to TCP 5061 so outbound connections use a routable
source address; the firewall keeps public SIP ingress closed. The media firewall allows UDP 20000–20200 only from the pinned
LiveKit Frankfurt addresses. Those addresses and the project SIP hostname
have one home in the module. Confirm current LiveKit media source ranges
before widening this rule: SIP and media addresses may differ.

The global project hostname matches LiveKit's wildcard certificate; the EU
hostname did not on 2026-10-31. Static host mappings preserve the valid name
for SNI and verification while selecting Frankfurt. These addresses require
manual maintenance if LiveKit changes its frontends. Do not turn off TLS
verification to work around an address or certificate change.

## Install and verify

Validate with `nix flake check --no-build`, then build the black configuration.
Apply with the normal black rebuild procedure in the repository README.
Before the first start, stop the temporary `sip-spike` Docker container; keep
its files only until the synthetic test has been repeated successfully.
The native service uses the same media range as the spike.

Check `systemctl status asterisk` and run:

```sh
asterisk -rx 'pjsip show transports'
asterisk -rx 'pjsip show endpoint livekit'
asterisk -rx 'module show like res_srtp'
```

TCP 5061 should listen, with no public firewall accept rule. The upstream NixOS service deliberately
does not restart on configuration changes, to avoid dropping calls. After
checking `asterisk -rx 'core show channels count'`, explicitly restart it in
an idle window when changing TLS transports or upgrading the package.

The existing LiveKit inbound trunk must allow black's public IP and require
media encryption; its dispatch rule must select the receptionist worker.
Restore model access before testing speech. A SIP 200 and a dispatched room
do not prove that the model spoke. Use an invented caller and verify speech,
barge-in and hangup; inspect SRTP status without enabling SIP packet logging
(which exposes SDES keys and caller metadata). The service has no persistent
test recording or synthetic calling context.

## Before connecting a carrier

Obtain the firm's carrier account, allowed signaling/media ranges, called
number and TLS/SRTP settings. Provision a trusted certificate and private key
outside the Nix store, with renewal and service reload/restart handling.
Then add an authenticated or source-restricted carrier endpoint, a public
TLS transport and a dialplan restricted to that firm's called number.
Preserve the caller ID only according to the verified carrier headers.
Open public TCP 5061 only for the carrier sources and add its media ranges;
never expose an anonymous SIP endpoint or an arbitrary outbound dialplan.

Test both encrypted legs and the caller ID before Webex forwarding is enabled.
Transfers need a separately configured outbound carrier leg and a destination
that cannot forward back to the receptionist. Carrier ingress, outbound
transfers and actual spoken responses remain unverified. This service is not
yet approved for real callers.
