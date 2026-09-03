# Trust anchor for the QA-plan approval stamp

**Status:** design, not built. Blocks PR #76 from landing by the maintainer's
decision (2026-09-02). Follows gstack-extensions#71 and the open CodeRabbit
thread on #76, "Do not accept a literal `approval_source` as attestation".

## The problem, stated exactly

PR #76 makes the QA-plan approval stamp require a token minted by a PostToolUse
hook from a real human `AskUserQuestion` answer. That closes the defect in #71:
running the sanctioned tool at an unsanctioned moment no longer produces a
stamp, which is what put approval stamps on four pull requests, one of which
merged.

It does not make the record unforgeable, and the reason is structural:

> **The hook and the agent are the same OS principal on the same machine.**

Any file the hook reads, the agent can write. Any secret the hook can read, the
agent can read. So a hand-written token with a matching branch, a current epoch
and `"approval_source":"AskUserQuestion"` still yields a valid stamp. The same
argument defeats `ship-pr-clearance` and `land-deploy-clearance`, which is why
those two document themselves as accident-guards rather than sandboxes.

What #76 changed is the COST: forging moved from running the sanctioned tool at
the wrong moment (invisible, indistinguishable from a real approval, and the
actual 2026-09-02 failure) to hand-writing JSON into the git dir (a
recognizably illegitimate act). That is a real improvement and not a solution.

## What was measured on this machine (2026-09-02)

| Candidate | Result | Usable as an anchor |
|---|---|---|
| macOS Keychain generic password | A plain shell read the secret back with no prompt | **No.** Default items carry no ACL; an ACL binds to a signed application, and a hook script is not one. |
| Claude Code transcript | Harness writes `toolUseResult` with `questions` / `answers` / `annotations`, inside a `uuid` + `parentUuid` + `sessionId` chain | **Partially.** A witness, not a lock: it is a file the agent can append to. |
| `pam_tid` for `sudo` | Not enabled (`/etc/pam.d/sudo_local` carries no `pam_tid`) | Not today. One line would enable it. |
| Secure Enclave | Apple M4; `LocalAuthentication.framework` present; `swiftc` available | **Yes.** The only measured option a shell genuinely cannot satisfy. |

## Options

### A. Secure Enclave signature: ATTEMPTED 2026-09-02, DOES NOT WORK HERE

**Status: built and abandoned on measured evidence.** The spike source is kept at
`spec/plans/qa-approval-anchor-spike.m` so nobody re-derives it. What happened:

- Swift was unusable: this machine has no Xcode and the CommandLineTools `swiftc`
  does not match its own SDK (`failed to build module 'CoreFoundation'`).
  Rewritten in Objective-C, which compiled cleanly, since these APIs are C.
- `SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave` failed with
  **-34018 (`errSecMissingEntitlement`)** when unsigned: the Enclave key was
  created (`SecKeyRef:('com.apple.setoken')`) but persisting it to the keychain
  was refused.
- Signed ad-hoc with a `keychain-access-groups` entitlement, then with the real
  `Apple Development` identity and the team-prefixed group
  `NND6SPZ5YR.dev.mujtaba.gstack`. The entitlement embeds correctly (verified
  with `codesign -d --entitlements`). **No provisioning profile is installed**,
  which macOS requires for an Apple Development-signed binary to claim a
  keychain access group.
- With the real identity, key creation **HANGS** and is killed by timeout
  (`exit=137`), reproducibly.
- Controlled test: the same code with `.userPresence` REMOVED also hangs. So the
  blocker is Secure Enclave key persistence from a headless CLI context, not the
  Touch ID prompt.

**And the design was weaker than it looked even if it had worked.** A
presence-free Enclave key anchors nothing against a same-principal agent: the
agent simply invokes the same helper to sign its own payload. Only the
presence-gated form is an anchor, and that needs a GUI the hook context does not
have. Making it real means a provisioned, signed **app bundle**, not a CLI, which
is a different project than a hook.

### A-original. Secure Enclave signature (the theory)

A small signed helper owns a keypair created with `kSecAttrTokenIDSecureEnclave`
and an access control of `.privateKeyUsage + .userPresence`. The private key
never leaves the Enclave (non-exportable by construction) and every use requires
Touch ID. The minting hook asks the helper to SIGN the token payload; the stamp
writer verifies against the public key.

- **Closes it.** An agent can write any JSON it likes and cannot produce a valid
  signature.
- **Costs:** a Swift helper, code signing, key provisioning, and key rotation /
  recovery when the machine changes.
- **Friction, stated plainly:** a Touch ID tap on every QA-plan approval, on top
  of the modal click. Whether that is acceptable is a taste call, not a
  technical one. It is defensible: a record asserting "a human approved this" is
  exactly the kind of thing worth a deliberate physical act.

### B. Transcript cross-verification (detection, not prevention)

The stamp records the nonce and session id. A verifier checks that the session
transcript holds a harness-written `toolUseResult.answers` record whose question
carries the matching `<qa-plan-digest:HEX>` and whose answer is `Approve`, in a
consistent `uuid` / `parentUuid` chain.

- **Does not prevent forgery.** The transcript is a file.
- **Does make forgery expensive and auditable:** the forger must fabricate a
  self-consistent harness record, and any mismatch is visible after the fact.
- **Zero friction, no new binaries.** Roughly 80% of the value for ~5% of the
  cost of A.

### C. Move the hard check off-machine

Make the merge-time claim a GitHub artifact the local agent cannot forge: the
maintainer's own PR review approval, verified by a required check. GitHub auth
is outside the agent's reach.

- **Strong and needs no local crypto.**
- **Changes the UX the maintainer explicitly asked for**, which is the
  in-terminal modal ("I got a question with options ... that was a block"), so
  it cannot REPLACE the local flow.
- **Works well as a second factor at merge time only:** the local modal keeps
  fast feedback during the build; the GitHub review is the hard anchor at the
  moment that actually matters.

## The finding that changes everything

Working through A produced a conclusion that outranks the option list:

> **On a single-user machine where the agent has full shell access and can invoke
> any local binary, there is no purely local trust anchor.**

Anything the hook can read, the agent can read. Anything the hook can invoke, the
agent can invoke. A key the agent cannot extract is still a key the agent can ask
the helper to USE, unless every use demands physical presence, and physical
presence needs a GUI that a hook does not have.

Note what this does NOT say. The SIGNAL is sound: `.tool_response.answers` is
written by the harness from a real click and the model cannot emit it. Only the
DERIVED RECORD (a file on disk) is forgeable. So the honest framings are:

1. Verify the signal, not a file derived from it (Option B), which bounds the
   forgery to fabricating a self-consistent harness record.
2. Anchor off-machine, which needs a second party or a second device. Note the
   sharp edge for a solo maintainer: GitHub will not let a PR author approve
   their own PR, and the `gh` CLI here is authenticated AS the author, so
   "require an approving review" is simultaneously unforgeable by the agent and
   unsatisfiable by the human. Any Option C design has to solve that, and
   "require a review" alone does not.

## Recommendation

**C for the hard guarantee, plus B for cheap local detection. A only if the
Touch ID tap is wanted.**

Reasoning. The local gates exist to stop an agent from drifting past a step, and
for that an accident-guard is the right tool and is honest about itself. The
thing genuinely worth hard enforcement is the MERGE, because that is where a
false approval escaped and did damage. Anchoring the merge in GitHub gets the
strong property without asking the maintainer to tap a sensor during ordinary
build-time work, and without a signed helper to maintain. B then makes a local
forgery detectable rather than silent, which is what turns the residual from
"unknown" into "auditable".

A is the only option that makes the LOCAL record unforgeable. Take it if the
local stamp itself must be trustworthy on its own, and accept a tap per
approval.

## Non-goals

- Making `ship-pr-clearance` or `land-deploy-clearance` unforgeable. They share
  this property; whatever lands here should be applied to them deliberately, as
  its own change, not smuggled in.
- Any scheme whose secret lives in a file the hook can read. That is the failure
  this document exists to avoid repeating.
