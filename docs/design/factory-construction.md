# DomainParticipantFactory construction

## Status

Proposal, with four open decisions (below). Follows WaitSet and GuardCondition onto zidl's
`@standalone` construction ([#167](https://github.com/zz-iot/zzdds/pull/167), zidl
`docs/design/standalone-construction.md`). A throwaway prototype of the constructor half is
on the local branch `proto-factory-standalone` (557bb74); its findings are recorded here.

## Today

Every binding creates a factory with a hand-written function and destroys it with another.

| Binding | Create | Destroy |
| --- | --- | --- |
| C | `zzdds_create_factory[_with_allocator]()`, checked with `zzdds_factory_is_nil` | `zzdds_destroy_factory` |
| C++ | `zzdds::create_factory([allocator])`, a hand-written `DomainParticipantFactorySupport` | dropping the last `shared_ptr` |
| Java | `ZzddsRuntime.createFactory()` (JNI), returning the DDS view; `ZzddsRuntime.asZzddsFactory` reaches zzdds's operations | never |
| Zig | `zzdds.createFactory[WithAllocator]()` | `factory.deinit()` |

Destroying a factory cannot fail: it deletes every participant it still has, and everything
those contain. The examples rely on that: no C or Java example deletes its participants, and
2 of 22 C++ examples do. Java never destroys a factory, so each Java process leaves its
factory to process exit.

There is no `get_instance()`. DDS defines `DomainParticipantFactory::get_instance()` as a
static operation, which IDL cannot declare, so `dcps.idl` leaves it out.

## What the specs say

DDS 1.4 §2.2.2.2.2 describes the factory as "a pre-existing singleton object that can be
accessed by means of the get_instance class operation". Its sole purpose is to create and
destroy participants, and it has no factory of its own.

- **`get_instance`** (§2.2.2.2.2.3) returns that singleton. It is idempotent: every call
  returns the same instance, without side effects. It is a static operation "implemented
  using the syntax of the native language", since IDL cannot express one, and §2.3 says each
  language mapping should provide it. `TheParticipantFactory` is an alias for it.
- **No `delete_instance`.** DDS 1.4 has no way to destroy, recreate or create a factory. A
  process has exactly one, for its whole life. Factories of one's own, and deleting one, are
  zzdds extensions.
- **The factory has no `delete_contained_entities`.** Tearing down means deleting each
  participant, which refuses with `PRECONDITION_NOT_MET` while it still contains entities.

`delete_instance` comes from DDS-XTypes 1.3, which gives `DynamicTypeBuilderFactory`
(§7.5.2.2.9, §7.5.2.2.11) and `DynamicDataFactory` (§7.5.2.10.3, §7.5.2.10.4) a static pair:

- **`get_instance`** returns an object that "behaves like a singleton, although the caller
  cannot assume pointer equality". Calling it after `delete_instance` is legal, and the
  implementation recreates the singleton.
- **`delete_instance`** reclaims everything previously returned from `get_instance`. "Any
  references to these objects held by previous callers ... may become invalid at the
  discretion of the implementation." It fails only with `RETCODE_ERROR`, for
  implementation-specific reasons, and has no precondition.

So nothing specifies `delete_instance` for the participant factory. Borrowing XTypes' pair
is a zzdds choice, as is whether it refuses or tears down.

## Proposal

```idl
// dcps.idl
@shared_c_abi_box interface DomainParticipantFactory {
    @static DomainParticipantFactory get_instance();   // needs zidl: see decision 4
    @static ReturnCode_t delete_instance();
    // ... create_participant and the rest, unchanged
};

// zzdds.idl
@shared_c_abi_box @standalone interface DomainParticipantFactory : DDS::DomainParticipantFactory {
    @constructor DomainParticipantFactory create();
    @destructor  DDS::ReturnCode_t destroy();   // refuses while participants remain
    @finalizer   void release();                // deletes them, as zzdds_destroy_factory does
    // ... create_participant_ex and the config operations, unchanged
};
```

Two ways to get a factory:

- **The process-wide instance.** `get_instance()` creates it on first use, with the default
  allocator and the process configuration, and returns it to every later caller. It is
  borrowed: dropping a C++ or Java reference to it releases nothing. `delete_instance()`
  deletes it, and refuses while it has participants. A later `get_instance()` creates a new
  one. This is the spec's shape, and what portable DDS code expects.
- **A factory of one's own.** `zzdds::DomainParticipantFactory::create([allocator])` makes a
  new, independent factory, as `zzdds_create_factory` does today. The creator owns it. Its
  strict `destroy()` refuses while participants remain. Its `release()`, which C++ and Java
  run when the owner is dropped or closed, deletes them, as `zzdds_destroy_factory` does
  today. Needed for a custom allocator, or for more than one factory in a process.

The hand-written C functions, `zzdds::create_factory`, `ZzddsRuntime.createFactory` and
`ZzddsRuntime.asZzddsFactory` become deprecated, and are removed once rmw_zzdds stops calling
them, as the WaitSet functions were (#172).

## Decisions

1. **Drop the factory's exemption from generated construction.**
   `generated-class-lifecycle-design.md` says the factory "stays a deliberate exception"
   because it is where the allocator everything inherits comes from. That was written before
   `@standalone` existed. A generated `create_with_allocator` serves an allocator's origin as
   well as any hand-written one, so the reason no longer holds. *Recommendation: drop it, and
   update that document.*
2. **Strict `destroy`, cascading `release`.** zidl's model fits the factory well: the strict
   destructor refuses with `PRECONDITION_NOT_MET` while participants remain, as every DDS
   `delete_*` does, and the finalizer keeps today's cascade. Code that drops or closes its
   factory behaves as today. *Recommendation: as proposed.* The prototype checks both
   through the generated C functions.
3. **`get_instance` beside factories of one's own.** *Recommendation: have both, as
   proposed, with `delete_instance` strict.* Two choices within it:
   - *Where `get_instance` lives.* On `DDS::DomainParticipantFactory`, where the spec puts
     it, it returns the DDS view. Code that calls zzdds's own operations
     (`create_participant_ex`, the participant config) then narrows: in C with the existing
     generated `DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory`, in Java with
     `ZzddsRuntime.asZzddsFactory`, which would then stay. On
     `zzdds::DomainParticipantFactory` it would return the zzdds view, which C++ and Java can
     use as either, but the spec's `DDS::DomainParticipantFactory::get_instance()` would not
     exist. *Recommendation: the DDS interface.* Only four programs use zzdds's factory
     operations, and those could create their own factory instead.
   - *Whether `delete_instance` cascades.* XTypes' `delete_instance` tears down, invalidating
     references, but DDS deletes refuse while anything is contained. Strict means a program
     deletes its participants first, which decision 5 shortens to one call. Cascading is
     shorter, but deleting the process-wide factory then silently deletes participants other
     code in the process created. *Recommendation: strict, as DDS deletes are.*
4. **zidl work first.** Detailed below: one fix and one new feature, released before zzdds
   can move. *Recommendation: both, in one zidl PR.*
5. **A factory `delete_contained_entities`, and loans in the cascade.** A zzdds operation
   with the participant's semantics: delete every participant and its contents, or return
   `PRECONDITION_NOT_MET` and delete nothing while any loan is outstanding. A
   `get_instance` program then tears down with
   `factory->delete_contained_entities(); DomainParticipantFactory::delete_instance();`. It
   also defines `release`: `delete_contained_entities`, then `destroy`. A finalizer cannot
   fail, though, so `release` still needs an answer for outstanding loans, which today's
   cascade handles badly in C++ and Java (see "Loans in the cascade" below). Either:
   - *Force*, as today. The loan's entity stays allocated, but C++ and Java can never return
     the loan, so it leaks until the process exits.
   - *Finish later.* `release` deletes everything without a loan at once. An entity with
     an outstanding loan keeps its handle usable until the last loan is returned, and is then
     deleted along with whatever contains it.

   *Recommendation: add the operation, and finish later.* A loan being returned is the only
   event that can complete it, so finishing later loses nothing.

## Loans in the cascade

Checked with throwaway tests on the local branch `probe-cascade-loans` (0e51f46). They tear
down the factory while a reader holds a read loan or a writer holds a write loan, using the
in-process fixture and the inner factory's teardown, which `zzdds_destroy_factory` reaches
through each participant.

- **The cascade itself is safe.** Each loan holds a reference on its reader or writer and on
  that endpoint's protocol reader or writer, so neither is freed while the loan is
  outstanding. The loaned bytes stay valid.
- **Returning the loan afterwards frees everything,** with no leak, in Zig and C: the C
  export still reaches zzdds, because the handle's storage lives as long as the entity.
- **C++ and Java cannot return it.** Deletion retires the entity's handle, which retires
  every wrapper of it. A retired wrapper's `return_loan_raw` returns `ALREADY_DELETED`
  without calling zzdds (generated C++: `if (_zidl_is_retired()) return 9;`; Java clears its
  pointer). Read from the generated code; the probes ran in Zig only.
- **A loan never returned leaks** its reader or writer, protocol endpoint and samples: 23
  allocations for a read loan and 15 for a write loan in the probes.
- **Not checked:** publishing a write loan (`publish_loan_raw`) after the cascade, which
  would try to send through a participant whose transport is being torn down. The probes
  only cancelled it.

## What zidl needs

The prototype marked `zzdds::DomainParticipantFactory` `@standalone`, implemented its
`destroy` and `release` slots, exported its constructor with `exportCAbiConstructors`, and
built every binding.

**Supported as is: the constructor, destructor and finalizer.** zidl accepted the IDL without
change. zidl's documented limit is constructors on a shared-box family *root*.
`zzdds::DomainParticipantFactory` is a *member* of `DDS::DomainParticipantFactory`'s
family, the shape GuardCondition already has. The generated C functions are
`zzdds_DomainParticipantFactory_create[_with_allocator]`, `_destroy` and `_release`. Java
generates `Zzdds.zzdds.DomainParticipantFactory.create()` returning an `AutoCloseable`
zzdds view, so Java no longer needs `asZzddsFactory` for a factory it creates. A C program
against the prototype confirmed that `destroy` refuses while a participant remains and
succeeds after it is deleted, and that `release` deletes a remaining participant.

**Needs a fix: C++.** The C++ binding does not compile. `zzdds::DomainParticipantFactoryImpl`
is abstract: the generated class implements zzdds's operations but not the ones it inherits
from `DDS::DomainParticipantFactory`, which is declared in another IDL file. That is why
`include/zzdds_cpp.hpp` has the hand-written `DomainParticipantFactorySupport`, which
forwards them. Until now nothing generated ever constructed the class. `@standalone` makes
zidl emit an identity cache and a `_getOrCreate` that constructs it, and that fails to
compile even with `--cpp-impl-override` pointing `create()` at
`DomainParticipantFactorySupport`. Two fixes:

- *Smaller:* when an interface has `--cpp-impl-override`, construct only the override class.
  WaitSet already works this way, but `WaitSetImpl` is concrete, so the problem never
  showed. `DomainParticipantFactorySupport` then supplies `_getOrCreate`, as `WaitSetSupport`
  does, and its destructor stops calling `zzdds_destroy_factory`, since the generated owner
  releases the factory.
- *Larger:* generate forwarding for operations inherited from an interface in another IDL
  file, so the zzdds class is concrete and `DomainParticipantFactorySupport` goes away.

*Recommendation: the smaller fix now.* The larger one also removes hand-written forwarding
elsewhere, and can come later.

**New: static operations.** `get_instance` and `delete_instance` have no receiver and confer
no ownership, which no zidl annotation expresses. A `@constructor` won't do: its result is
owned, so dropping the last C++ reference to the process-wide factory would delete it.
Proposed `@static`:

- Allowed on any interface, not only `@standalone` ones: no ownership is involved.
- No receiver, no vtable slot, not inherited. Parameters are `in`, and it is not `oneway`,
  as for constructors.
- An interface it returns is borrowed: boxed through the identity cache, never adopted.
- C: a free function, `DDS_DomainParticipantFactory_get_instance(void)`.
- Zig provider: implementations passed at comptime, as `exportCAbiConstructors` does.
- C++: a static member function.
- Java: a static interface method with a static JNI native.

zidl#80, which added `@standalone`, was about 2,300 lines including tests. `@static` reuses
most of its C, Zig and JNI plumbing without the ownership parts. Later it could also replace
other hand-written statics, such as `ZzddsRuntime.configureFromFile` and
`zzdds_process_configure`.

**Minor: the default allocator.** The generated `create_with_allocator(NULL)` resolves NULL to
zidl's default allocator before calling zzdds. zzdds's `-Ddebug-allocator` currently routes
factories created with NULL through its DebugAllocator and checks them for leaks
(`FactoryLeakCheck`), and the generated path hides that NULL. `get_instance` is zzdds's own
code and is unaffected. Either zzdds recognizes zidl's default allocator, or zidl passes the
raw `ZidlAllocator` pointer to constructors that ask for it. *Recommendation: decide during
implementation.*

## Application code, before and after

### C

Before:

```c
zzdds_DomainParticipantFactory factory = zzdds_create_factory();
if (zzdds_factory_is_nil(factory)) return 1;
DDS_DomainParticipantFactory dds_factory =
    zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);
DDS_DomainParticipant dp = DDS_DomainParticipantFactory_create_participant(dds_factory, domain, NULL, NULL, 0);
/* ... */
zzdds_destroy_factory(factory);   /* also deletes dp and everything in it */
```

After, with the process-wide instance:

```c
DDS_DomainParticipantFactory factory = DDS_DomainParticipantFactory_get_instance();
if (factory == NULL) return 1;
DDS_DomainParticipant dp = DDS_DomainParticipantFactory_create_participant(factory, domain, NULL, NULL, 0);
/* ... */
DDS_DomainParticipant_delete_contained_entities(dp);
DDS_DomainParticipantFactory_delete_participant(factory, dp);
DDS_DomainParticipantFactory_delete_instance();
```

After, with a factory of one's own:

```c
zzdds_DomainParticipantFactory factory = zzdds_DomainParticipantFactory_create_with_allocator(&pool);
if (factory == NULL) return 1;
/* ... as before, through zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory ... */
zzdds_DomainParticipantFactory_release(factory);   /* deletes what remains, as before */
```

### C++

Before:

```cpp
auto factory = zzdds::create_factory();
if (!factory) return 1;
auto dp = factory->create_participant(domain, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
// ...
// dropping the last reference to `factory` deletes dp and everything in it
```

After, with the process-wide instance:

```cpp
auto factory = ::DDS::DomainParticipantFactory::get_instance();
if (!factory) return 1;
auto dp = factory->create_participant(domain, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
// ...
dp->delete_contained_entities();
factory->delete_participant(dp);
::DDS::DomainParticipantFactory::delete_instance();
```

After, with a factory of one's own, the change is the name. Dropping it behaves as before,
and `create_participant_ex` and the config operations are on it directly, as today:

```cpp
auto factory = zzdds::DomainParticipantFactory::create(&static_pool_allocator);
```

### Java

Before:

```java
Dcps.DDS.DomainParticipantFactory factory =
    (Dcps.DDS.DomainParticipantFactory) io.zzdds.runtime.ZzddsRuntime.createFactory();
if (factory == null) System.exit(1);
Dcps.DDS.DomainParticipant participant = factory.create_participant(DOMAIN_ID, null, null, 0);
// ... the factory is never destroyed.
// zzdds's own operations need a second view of the same factory:
Zzdds.zzdds.DomainParticipantFactory zf =
    (Zzdds.zzdds.DomainParticipantFactory) io.zzdds.runtime.ZzddsRuntime.asZzddsFactory(factory);
```

After, with the process-wide instance:

```java
Dcps.DDS.DomainParticipantFactory factory = Dcps.DDS.DomainParticipantFactory.get_instance();
if (factory == null) System.exit(1);
Dcps.DDS.DomainParticipant participant = factory.create_participant(DOMAIN_ID, null, null, 0);
// ...
participant.delete_contained_entities();
factory.delete_participant(participant);
Dcps.DDS.DomainParticipantFactory.delete_instance();
```

After, with a factory of one's own. It is both views at once, and closing it deletes what
remains, which today never happens in Java:

```java
try (Zzdds.zzdds.DomainParticipantFactory factory = Zzdds.zzdds.DomainParticipantFactory.create()) {
    factory.set_default_participant_config(cfg);
    Dcps.DDS.DomainParticipant participant = factory.create_participant(DOMAIN_ID, null, null, 0);
    // ...
}
```

### Zig

Zig programs use zzdds's own `zzdds.createFactory()` wrapper, not generated code, and are
unaffected. A `zzdds.getInstance()` can follow if wanted.

## Impact on examples and tests

| | Examples creating a factory | Of those, deleting their participants | Tests and integration tests | Need their own factory |
| --- | --- | --- | --- | --- |
| C | 20 | 0 | 22 | 3 (custom-allocator) |
| C++ | 22 | 2 | 22 | 2 (custom-allocator) |
| Java | 19 | 0 | 20 | none |
| Zig | | | | unaffected |

Two ways to migrate them:

- *Rename only:* every program creates its own factory with the generated functions and keeps
  relying on the cascade. Mechanical, a line or two per file. Java gains `try`-with-resources
  and stops leaking its factory.
- *Move the examples to `get_instance`* and leave the tests on factories of their own. Each
  example that relied on the cascade gains two or three lines of explicit teardown: about 20
  C, 20 C++ and 19 Java examples. The examples then read like portable DDS code, which is what
  people copy. The examples' DebugAllocator lane needs `delete_instance` to succeed, so their
  teardown must be complete.

*Recommendation: the second, in its own PR after the API lands.* The rename is the first
PR's in-tree migration, as #167 did for WaitSet.

The language spikes (Python, Rust, Go, Haskell) call `zzdds_create_factory` over FFI and
need the rename. rmw_zzdds creates one factory per ROS context and destroys it at shutdown
(`rmw_init.cpp`, and its C binding test). A factory of its own,
`zzdds_DomainParticipantFactory_create` and `_release`, keeps that lifetime: another
migration like rmw_zzdds#16.

## Plan

1. **zidl:** C++ constructs only the override class of an overridden `@standalone`
   interface; `@static` operations. Then a release.
2. **zzdds:** the IDL above; `destroy`, `release`, the constructor, `get_instance` and
   `delete_instance` in `extensions.zig`; `DomainParticipantFactorySupport` as the C++
   override; the old functions deprecated; every in-tree caller renamed; this document's
   decisions recorded in `generated-class-lifecycle-design.md`. Then a release.
3. **rmw_zzdds:** move to the generated functions.
4. **zzdds:** remove the deprecated functions and bump the rmw_zzdds pin.
5. **zzdds, optional:** move the examples to `get_instance`.

ExecutionRuntime's construction and the factory's `set_default_runtime` build on the result.
