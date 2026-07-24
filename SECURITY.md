# Security

## Reporting

Found a vulnerability in the escrow contracts or the arbiter agent? Please report
it privately to the maintainer rather than opening a public issue, so a fix can
ship before disclosure. Include the affected component, a reproduction, and the
impact you observed.

## Threat model notes

### Dispute evidence is attacker-controlled

Every evidence string reaches the contract through `raiseDispute` /
`submitEvidence` and is emitted verbatim in `DisputeRaised`. **Any party to a
dispute — including a malicious one — chooses that text.** It is therefore
untrusted input at two boundaries:

- **The AI arbiter.** The agent feeds evidence into the model to reach a ruling.
  Evidence is treated as *plain-text data, never as instructions*: it cannot
  redirect the ruling, change the output format, or exfiltrate anything. This was
  observed in the July 2026 settlement run — escrows 5, 14, and 15 embedded
  HTML/script content in their evidence, and the arbiter explicitly recorded that
  it was treated as plain text and did not affect the decision (see
  [`docs/settlements-2026-07.md`](docs/settlements-2026-07.md)). A ruling rests
  only on the substance of the evidence and the on-chain facts.

- **Any UI that renders evidence.** Because the string is attacker-authored, a
  front end MUST insert it as text (`textContent`), never as HTML. Treat it like
  any other user-generated content.

The contract never interprets evidence — it only stores and emits it — so an
evidence string can never alter escrow state or fund flow. The invariants that
protect funds are documented in the README's security-properties section.
