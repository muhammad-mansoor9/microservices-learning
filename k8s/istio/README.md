# Istio service mesh for Scenario 3

Once Istio is installed and the `default` namespace is labelled
`istio-injection=enabled`, every pod gets an Envoy sidecar automatically.
The manifests here then lock inter-service traffic down:

- `peer-authentication.yaml` — namespace-scoped `PeerAuthentication` with
  `mtls.mode: STRICT`. Any traffic that isn't authenticated with an Istio
  workload identity certificate is rejected at the sidecar. Legacy
  plaintext callers stop working the moment this is applied.
- `destination-rules.yaml` — one `DestinationRule` per service telling
  the *client* sidecar to originate TLS using `ISTIO_MUTUAL` when it
  talks to that host. Together with `STRICT` on the receiver, this
  gives you mesh-wide mTLS with zero application code.

## What this replaces

- Scenario 1's `X-Internal-Api-Key` header check.
- Scenario 2's SigV4 request signing between services.

Both were application-level auth mechanisms that had to be kept in
lock-step with rotation, header naming, and library versions.
Istio replaces both with sidecar-level mTLS driven by SPIFFE identities
issued by istiod — the app just sends plaintext HTTP to
`http://payment-service:8080` and the sidecar upgrades it to mTLS on
the wire.

## Boundary note

Istio only guards traffic *inside* the mesh. External north-south
traffic still enters through the AWS Load Balancer Controller (ALB
Ingress with Cognito auth on `order-service`); the Istio ingress
gateway installed by Terraform is `ClusterIP`-only and unused for now.
