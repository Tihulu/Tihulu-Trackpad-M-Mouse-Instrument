# R9a — authenticated capability query

V7 capabilities request uses exact common fields only; no client-supplied source. After normal binary invitation admission (unchanged legacy admitted ACK), an idle authenticated peer may request its logical capabilities. Runtime validates sequence, rate, idle state and freshness as with other frames. Bridge returns a bounded JSON response instead of ordinary accepted ACK for this query only. Transport remains one outstanding host message; rejected or unencodable responses close. Old clients and TLS diagnostic retain admitted/accepted behavior.

Manifest exposes booleans for mapped touch, tilt, acceleration, rotation and Air Drums plus active masks for eight drum pads, 25 piano keys/sustain and six pedals. It is derived from the configured patch for the paired source only, not a client's declared device. No patch name, secret, file path, local-only routes or MIDI destination metadata. Max 256 bytes. Active queries fail closed; cannot extend another stream's watchdog. Browser negotiation and UI gating follow in R9b. Custom mapping labels and the LAN diagnostic for motion-only patches require separate work. No hardware acceptance; stable untouched.

Four Swift scenarios for authenticated source isolation, unknown/replay rejection, active-query fail-close, exact schema and bounded response.
