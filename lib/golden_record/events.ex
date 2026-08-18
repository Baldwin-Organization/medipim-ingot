# lib/golden_record/ (split per module, GH #58) — the DDD + event-sourced engine (compiled by Mix; no demo, no run).
#
# Contexts: Ingestion (Substrate) · Identity Resolution (Cluster + IdentityLedger) ·
#           Stewardship · Catalog (read) · History (time-travel/lineage)
#
# Beyond the base model it supports SHARED CODES: a steward can declare a (scheme, code) to be
# legitimately shared across products (e.g. a GTIN on both a bundle and its unit). A shared code
# is carried on every variant that bears it but NEVER bridges them during clustering/matching —
# that is how "two sources use the same id, but they are two products" reaches a clean end state.

defmodule GoldenRecord.Events do
  defmodule ClaimAsserted do
    @enforce_keys [:source, :kind, :data, :valid_from, :recorded_at]
    defstruct [
      :source,
      :kind,
      :data,
      :valid_from,
      :valid_to,
      :recorded_at,
      :order,
      :record_ref,
      :record_revision
    ]
  end

  defmodule SourceRecordRevised do
    @enforce_keys [
      :source,
      :ref,
      :revision,
      :operation,
      :active,
      :claims,
      :fingerprint,
      :valid_from,
      :valid_to,
      :recorded_at
    ]
    defstruct [
      :source,
      :ref,
      :revision,
      :base_revision,
      :operation,
      :active,
      :claims,
      :fingerprint,
      :valid_from,
      :valid_to,
      :recorded_at,
      :order
    ]
  end

  defmodule SourceRecordKeyBound do
    @enforce_keys [:source, :ref, :lane, :key, :recorded_at]
    defstruct [:source, :ref, :lane, :key, :valid_from, :valid_to, :recorded_at, :order]
  end

  defmodule IdentityMinted do
    @enforce_keys [:key, :codes, :recorded_at]
    defstruct [:key, :codes, :valid_from, :valid_to, :recorded_at, :order]
  end

  defmodule IdentityMembersChanged do
    @enforce_keys [:key, :codes, :recorded_at]
    defstruct [:key, :codes, :valid_from, :valid_to, :recorded_at, :order]
  end

  defmodule IdentitiesMerged do
    @enforce_keys [:from, :into, :recorded_at]
    defstruct [:from, :into, :valid_from, :valid_to, :recorded_at, :order]
  end

  defmodule IdentitySplit do
    @enforce_keys [:key, :kept_codes, :into, :recorded_at]
    defstruct [:key, :kept_codes, :into, :valid_from, :valid_to, :recorded_at, :order]
  end

  # The bookend of IdentityMinted: a key whose EVERY contributing listing was retracted (identity
  # claim with codes: []) vanishes from the members map. `codes` carries the codes the key HELD
  # before retraction — the notification payload ("SK_3 with cnk:333 was retracted").
  defmodule IdentityRetracted do
    @enforce_keys [:key, :codes, :recorded_at]
    defstruct [:key, :codes, :valid_from, :valid_to, :recorded_at, :order]
  end

  # External-id continuity: `key` answers to `legacy_id` (a consumer-facing id from a system the
  # engine replaces). Assignment is an EVENT so the mapping is auditable and replayable; resolution
  # across merges/splits is a fold (see the ingest's LegacyIds).
  defmodule LegacyIdAssigned do
    @enforce_keys [:key, :legacy_id, :recorded_at]
    defstruct [:key, :legacy_id, :valid_from, :valid_to, :recorded_at, :order]
  end

  # subject: {:attr, key, field} | {:merge, [keys]} | {:collision, key} | {:code, {scheme, code}}
  #        | {:split, key}
  defmodule ConflictFlagged do
    @enforce_keys [:subject, :candidates, :recorded_at]
    defstruct [:subject, :candidates, :valid_from, :valid_to, :recorded_at, :order]
  end

  # Four-eyes on merges: one steward ENDORSES a flagged merge of established keys; nothing fuses
  # until a SECOND, different steward approves. The endorsement is an event so the pending
  # proposal is replayable state, not UI memory.
  defmodule MergeProposed do
    @enforce_keys [:keys, :by, :recorded_at]
    defstruct [:keys, :by, :reason, :valid_from, :valid_to, :recorded_at, :order]
  end

  # decision: {:pick, value} | :rejected | :approved | :shared
  # `reason` is the steward's optional free-text justification, kept in the log.
  defmodule ConflictResolved do
    @enforce_keys [:subject, :decision, :by, :recorded_at]
    defstruct [:subject, :decision, :by, :reason, :valid_from, :valid_to, :recorded_at, :order]
  end

  defmodule ReviewCaseOpened do
    @enforce_keys [
      :case_id,
      :subject,
      :evidence,
      :evidence_digest,
      :evidence_offset,
      :required_approvals,
      :recorded_at
    ]
    defstruct [
      :case_id,
      :subject,
      :evidence,
      :evidence_digest,
      :evidence_offset,
      :required_approvals,
      :recorded_at,
      :order
    ]
  end

  defmodule ReviewCaseEndorsed do
    @enforce_keys [:case_id, :principal, :evidence_offset, :recorded_at]
    defstruct [:case_id, :principal, :evidence_offset, :proposal, :reason, :recorded_at, :order]
  end
end
