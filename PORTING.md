# Porting notes

Scope decisions for upstream files that have no (or not yet a) counterpart
under `lib/`, and why.

## `src/lib/polari-client-factory.c` has no `lib/polari/client_factory.rb`

Upstream's `PolariClientFactory` has exactly one job: when telepathy-glib's
`TpAccountManager`/`TpSimpleClientFactory` machinery constructs a `TpAccount`
or `TpConnection` for a given object path, the factory hands back a
`PolariAccount`-subclassed instance instead of the generic telepathy-glib
one, so the rest of the app always has the extra Polari-specific properties
(predefined-ness, nickname bookkeeping, etc.) on the object telepathy-glib
itself constructed.

This port's IRC transport (`lib/polari/telepathy_client.rb`) is a plain
socket client, not a telepathy-glib binding — there is no `TpAccountManager`
or `TpSimpleClientFactory` constructing anything from an object path for a
factory to intercept. `AccountsMonitor::Account` (ported in an earlier round)
is already the plain-Ruby model with the full set of Polari-specific
properties; it is never a generic object that needs upgrading to a
Polari-specific one, because nothing generic is ever constructed in the
first place.

Porting `client_factory.rb` as a decorator with no object to decorate and no
factory machinery to register with would be a method that exists only to
return its argument unchanged — exactly the kind of non-functional
placeholder this project treats as worse than not porting the file. So it is
left out, and this file is the record of that decision for whoever next
reads the component-identification report and sees the gap.

If a future round gives this port real telepathy-glib bindings (replacing
`telepathy_client.rb`'s socket transport), `client_factory.rb` becomes real
work again and this note should be deleted along with the decision it
records.
