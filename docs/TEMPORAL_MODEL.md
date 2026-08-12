# Two clocks: what we knew, and when it was true

Ingot answers two different questions:

1. **Known at** — what information had reached Ingot by this timestamp?
2. **Effective at** — what did the sources say was true on this date?

These clocks must stay separate. A correction received in April can say that a product name was
wrong for one week in February. Asking with a March `known_at` must return the old answer, because
Ingot had not received the correction yet. Asking with an April `known_at` and a February
`effective_at` returns the correction.

## Intervals

A source-record revision has:

- `recorded_at`: a UTC timestamp assigned by Ingot; clients cannot choose it.
- `valid_from`: the first date on which the revision applies.
- `valid_to`: the first date on which it no longer applies, or `null` when it stays applicable.

The interval includes `valid_from` and excludes `valid_to`. A revision valid from February 1 to
February 10 applies on February 9, but not on February 10.

## Selection order

For each source record, Ingot:

1. removes revisions received after `known_at`;
2. removes revisions that do not cover `effective_at`;
3. chooses the most recently recorded remaining revision;
4. contributes that revision's complete facts, unless it is a withdrawal;
5. only then resolves identities and chooses surviving attribute values.

Filtering before identity resolution matters. A future revision must not hide today's revision,
and an expired correction must allow the older, still-applicable revision to reappear.

## Examples

### A future change

- Revision 1 says `name = Old`, effective January 1 with no end date.
- Revision 2 says `name = New`, received today but effective August 1.

An ordinary read in July returns `Old`. A read with `effective_at=August 1` returns `New`.

### A late, bounded correction

- Revision 1 says `name = Original`, effective from January 1.
- In April, revision 2 says `name = Corrected` only from February 1 until February 10.

With `known_at` in March, February 5 returns `Original`. With `known_at` in April, February 5
returns `Corrected`. February 10 returns `Original` again.

### Withdrawal and reactivation

A withdrawal contributes no identity, attributes, media, grouping, or edges during its effective
interval. The source-record-to-key binding remains permanent. A later reactivation therefore
returns under the same Ingot key and legacy ID, even if the source supplies entirely different
codes.

## API reads

Product, by-code, and source-record reads accept independent query parameters:

```text
?known_at=2026-04-02T12:00:00Z&effective_at=2026-02-05
```

When omitted, `known_at` defaults to the current server time and `effective_at` defaults to today.
The older `as_of` parameter remains a compatibility shortcut that sets both clocks to one date.
